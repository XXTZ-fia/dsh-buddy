"""外链图片：CDN 白名单规范化 + 微博入选条目补图（失败静默降级）。"""

from __future__ import annotations

import json
import re
from dataclasses import replace
from typing import Any
from urllib.parse import quote, urlparse

from playwright.sync_api import Error as PlaywrightError

from radar.browser import open_context
from radar.config import Config
from radar.http import DEFAULT_UA, Throttle
from radar.logging import emit
from radar.models import Candidate
from radar.sources.base import RateLimited

# 平台文本是不可信 data：图片只允许指向各家自有 CDN，绝不接受任意外链。
# 只列图片域；s.weibo.com 是网页域，放进来会让卡片渲染成裂图。
IMAGE_HOSTS: tuple[str, ...] = (
    "hdslb.com",  # B 站封面
    "zhimg.com",  # 知乎配图 / 头像
    "sinaimg.cn",  # 微博正文配图
    "douyinpic.com",  # 抖音热词封面
    "byteimg.com",
    "pstatp.com",
    "xhscdn.com",  # 小红书
    "twimg.com",  # X
)
_CONTROL = re.compile(r"[\r\n\x00-\x1f\x7f]")
_MAX_LEN = 512
_MAX_LOOKUPS = 5
_WEIBO_SEARCH = "https://m.weibo.cn/api/container/getIndex?containerid={}&page_type=searchall"
_SEARCH_HEADERS = {
    "User-Agent": DEFAULT_UA,
    "Referer": "https://m.weibo.cn/",
    "Accept": "application/json, text/plain, */*",
}


def normalize_image(raw: object) -> str:
    """http→https / 协议相对 URL 补全；拒绝控制字符、非 https 与白名单外域名。"""
    if not isinstance(raw, str):
        return ""
    value = raw.strip()
    if not value or len(value) > _MAX_LEN or _CONTROL.search(value):
        return ""
    if value.startswith("//"):
        value = "https:" + value
    elif value.startswith("http://"):
        value = "https://" + value[len("http://") :]
    if not value.startswith("https://"):
        return ""
    try:
        host = (urlparse(value).hostname or "").lower()
    except ValueError:
        return ""
    if not any(host == suffix or host.endswith("." + suffix) for suffix in IMAGE_HOSTS):
        return ""
    return value


def first_weibo_photo(payload: Any) -> str:
    """纯函数：只取移动端搜索结果里的正文配图，忽略头像与 UI 图标。"""
    if not isinstance(payload, dict):
        return ""
    data = payload.get("data")
    cards = data.get("cards", []) if isinstance(data, dict) else []
    if not isinstance(cards, list):
        return ""
    for card in cards:
        if not isinstance(card, dict):
            continue
        mblog = card.get("mblog") or {}
        if not isinstance(mblog, dict):
            continue
        pics = mblog.get("pics") or []
        if isinstance(pics, list):
            for pic in pics:
                if isinstance(pic, dict):
                    url = normalize_image(pic.get("large") or pic.get("url"))
                    if url:
                        return url
        page_info = mblog.get("page_info")
        if isinstance(page_info, dict):
            page_pic = page_info.get("page_pic")
            if isinstance(page_pic, dict):
                url = normalize_image(page_pic.get("url"))
                if url:
                    return url
    return ""


def enrich_images(
    cfg: Config, items: tuple[Candidate, ...], *, enabled: bool
) -> tuple[Candidate, ...]:
    """只对入选且无图的微博条目补图；每轮最多 5 次只读请求，失败一律降级为无图。"""
    if not enabled:
        return items
    targets = [item for item in items if item.platform == "weibo" and not item.image][:_MAX_LOOKUPS]
    if not targets:
        return items
    throttle = Throttle(cfg)
    patched: dict[str, Candidate] = {}
    try:
        with open_context(cfg, "weibo") as ctx:
            for item in targets:
                try:
                    throttle.wait("weibo")
                    container = quote("100103type=1&q=" + item.title, safe="")
                    resp = ctx.request.get(
                        _WEIBO_SEARCH.format(container),
                        headers=_SEARCH_HEADERS,
                        timeout=cfg.timeout_s * 1000,
                        max_redirects=0,
                    )
                    if resp.status in (412, 429):
                        throttle.deny(resp.headers.get("retry-after"), "weibo")
                        break
                    photo = first_weibo_photo(json.loads(resp.text())) if resp.ok else ""
                except (ValueError, TypeError, OSError, PlaywrightError, RateLimited) as exc:
                    photo = ""
                    emit("WARNING", "images_skipped", platform="weibo", note=type(exc).__name__)
                if photo:
                    patched[item.id] = replace(item, image=photo)
    except (OSError, PlaywrightError, RateLimited) as exc:
        emit("WARNING", "images_degraded", platform="weibo", note=type(exc).__name__)
    return tuple(patched.get(item.id, item) for item in items)
