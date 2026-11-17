"""微博热搜：榜单端点免登录（端点/UA 参照 mcp-trends-hub/src/tools/weibo.ts）。"""

from __future__ import annotations

import json
from dataclasses import dataclass
from urllib.parse import quote

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, get_body, probe
from radar.models import RawItem
from radar.sources.base import AuthResult, ParseError

LIST_URL = "https://weibo.com/ajax/side/hotSearch"
CHECK_URL = LIST_URL  # 榜单本身免登录，验活即是最低流量的只读请求


def parse(body: str) -> list[RawItem]:
    try:
        rows = json.loads(body)["data"]["realtime"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("微博热搜响应结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict) or row.get("is_ad") == 1:
            continue
        word = str(row.get("word") or "")
        if not word:
            continue
        items.append(
            RawItem(
                "weibo",
                word,
                word,
                f"https://s.weibo.com/weibo?q={quote(word)}&band_rank=1&Refer=top",
                snippet=str(row.get("note") or ""),
                heat_raw=str(row.get("num") or 0),
            )
        )
    return items


@dataclass(frozen=True)
class WeiboSource:
    cfg: Config
    throttle: Throttle
    name: str = "weibo"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, CHECK_URL, self.cfg, self.throttle)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(get_body(ctx, LIST_URL, self.name, self.cfg, self.throttle))[:limit]
