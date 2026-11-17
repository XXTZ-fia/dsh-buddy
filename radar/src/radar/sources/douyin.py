"""抖音热搜：榜单端点（参照 mcp-trends-hub/src/tools/douyin.ts），不解析临时 csrf。"""

from __future__ import annotations

import json
from dataclasses import dataclass

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, get_body, probe
from radar.images import normalize_image
from radar.models import RawItem
from radar.sources.base import AuthResult, ParseError

LIST_URL = (
    "https://www.douyin.com/aweme/v1/web/hot/search/list/"
    "?device_platform=webapp&aid=6383&channel=channel_pc_web&detail_list=1"
)
CHECK_URL = LIST_URL


def parse(body: str) -> list[RawItem]:
    try:
        payload = json.loads(body)
        if payload["status_code"] != 0:
            raise ParseError(f"抖音业务码 {payload['status_code']}")
        rows = payload["data"]["word_list"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("抖音热搜响应结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        sentence_id = str(row.get("sentence_id") or "")
        if not sentence_id:
            continue
        items.append(
            RawItem(
                "douyin",
                sentence_id,
                str(row.get("word") or ""),
                f"https://www.douyin.com/hot/{sentence_id}",
                published_at_raw=str(row.get("event_time") or ""),
                heat_raw=str(row.get("hot_value") or 0),
                image=normalize_image(row.get("word_cover")),
            )
        )
    return items


@dataclass(frozen=True)
class DouyinSource:
    cfg: Config
    throttle: Throttle
    name: str = "douyin"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, CHECK_URL, self.cfg, self.throttle)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(get_body(ctx, LIST_URL, self.name, self.cfg, self.throttle))[:limit]
