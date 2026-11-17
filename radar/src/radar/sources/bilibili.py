"""B 站排行榜：端点参照 mcp-trends-hub/src/tools/bilibili.ts，不自研 WBI 签名。"""

from __future__ import annotations

import json
from dataclasses import dataclass

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, get_body, probe
from radar.images import normalize_image
from radar.models import RawItem
from radar.sources.base import AuthResult, ParseError

LIST_URL = "https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all"
CHECK_URL = "https://api.bilibili.com/x/web-interface/nav"


def parse(body: str) -> list[RawItem]:
    try:
        payload = json.loads(body)
        if payload["code"] != 0:
            raise ParseError(f"B 站业务码 {payload['code']}")
        rows = payload["data"]["list"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("B 站排行榜响应结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict) or not row.get("bvid"):
            continue
        bvid = str(row["bvid"])
        owner = row.get("owner") or {}
        stat = row.get("stat") or {}
        items.append(
            RawItem(
                "bili",
                bvid,
                str(row.get("title") or ""),
                str(row.get("short_link_v2") or f"https://www.bilibili.com/video/{bvid}"),
                author=str(owner.get("name") or ""),
                published_at_raw=str(row.get("pubdate") or ""),
                snippet=str(row.get("desc") or ""),
                heat_raw=str(stat.get("view") or 0),
                image=normalize_image(row.get("pic")),
            )
        )
    return items


@dataclass(frozen=True)
class BiliSource:
    cfg: Config
    throttle: Throttle
    name: str = "bili"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, CHECK_URL, self.cfg, self.throttle)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(get_body(ctx, LIST_URL, self.name, self.cfg, self.throttle))[:limit]
