"""X 时间线：只在浏览器页面上下文内读取 DOM，时间用 X 原生格式交给 normalize。"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, probe, read_dom
from radar.images import normalize_image
from radar.models import RawItem
from radar.normalize import is_pure_repost
from radar.sources.base import AuthResult, ParseError

TIMELINE_URL = "https://x.com/home"
# 页面内只读取 DOM 文本，签名与登录态完全由浏览器上下文提供（D2）。
TIMELINE_JS = (
    "() => {const D=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];"
    "const M=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];"
    "const p=n=>String(n).padStart(2,'0'),rows=[];"
    "for(const e of document.querySelectorAll('article[data-testid=tweet]')){"
    "const a=e.querySelector('a[href*=\"/status/\"]');"
    "const t=e.querySelector('time'),d=t?new Date(t.getAttribute('datetime')):new Date();"
    "const c=D[d.getUTCDay()]+' '+M[d.getUTCMonth()]+' '+p(d.getUTCDate())+' '"
    "+p(d.getUTCHours())+':'+p(d.getUTCMinutes())+':'+p(d.getUTCSeconds())"
    "+' +0000 '+d.getUTCFullYear();"
    "rows.push({href:a?a.getAttribute('href'):'',"
    "text:e.querySelector('[data-testid=tweetText]')?.innerText||'',createdAt:c,"
    "author:e.querySelector('[data-testid=User-Name]')?.innerText||'',"
    "image:e.querySelector('[data-testid=tweetPhoto] img,img[alt=Image]')?.getAttribute('src')||'',"
    "likes:e.querySelector('[data-testid=like]')?.getAttribute('aria-label')||'0'});}"
    "return JSON.stringify({items:rows});}"
)


def parse(body: str) -> list[RawItem]:
    try:
        rows = json.loads(body)["items"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("X 时间线结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        match = re.search(r"/status/(\d+)", str(row.get("href") or ""))
        if match is None:
            continue
        text = str(row.get("text") or "")
        is_repost = text.startswith("RT @")
        item = RawItem(
            "x",
            match.group(1),
            text.split("\n")[0][:120],
            f"https://x.com{row['href']}",
            author=str(row.get("author") or ""),
            published_at_raw=str(row.get("createdAt") or ""),
            snippet="" if is_repost else text,
            heat_raw=str(row.get("likes") or "0"),
            image=normalize_image(row.get("image")),
            lang="en",
            is_repost=is_repost,
        )
        # 纯 RT 在采集层就丢弃，不进入去重、更不交给模型（§5.2.7）。
        if not is_pure_repost(item):
            items.append(item)
    return items


@dataclass(frozen=True)
class XSource:
    cfg: Config
    throttle: Throttle
    name: str = "x"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, TIMELINE_URL, self.cfg, self.throttle, TIMELINE_JS)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(read_dom(ctx, TIMELINE_URL, self.name, self.cfg, self.throttle, TIMELINE_JS))[
            :limit
        ]
