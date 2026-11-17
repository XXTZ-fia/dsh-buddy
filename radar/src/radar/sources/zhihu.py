"""知乎热榜：客户端 UA 由 config.PLATFORM_UA 统一配置（参照 zhihu.ts）。"""

from __future__ import annotations

import json
from dataclasses import dataclass

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, get_body, probe
from radar.images import normalize_image
from radar.models import RawItem
from radar.sources.base import AuthResult, ParseError

LIST_URL = "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=50"
CHECK_URL = "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=1"


def parse(body: str) -> list[RawItem]:
    try:
        rows = json.loads(body)["data"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("知乎热榜响应结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        target = row.get("target") or {}
        native_id = str(target.get("url") or "").rstrip("/").rsplit("/", 1)[-1]
        if not native_id:
            continue
        children = row.get("children")
        thumbnail = ""
        if isinstance(children, list):
            thumbnail = next(
                (
                    str(child.get("thumbnail") or "")
                    for child in children
                    if isinstance(child, dict) and child.get("thumbnail")
                ),
                "",
            )
        items.append(
            RawItem(
                "zhihu",
                native_id,
                str(target.get("title") or ""),
                f"https://www.zhihu.com/question/{native_id}",
                published_at_raw=str(target.get("created") or ""),
                snippet=str(target.get("excerpt") or ""),
                heat_raw=str(row.get("detail_text") or 0),
                image=normalize_image(thumbnail),
            )
        )
    return items


@dataclass(frozen=True)
class ZhihuSource:
    cfg: Config
    throttle: Throttle
    name: str = "zhihu"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, CHECK_URL, self.cfg, self.throttle)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(get_body(ctx, LIST_URL, self.name, self.cfg, self.throttle))[:limit]
