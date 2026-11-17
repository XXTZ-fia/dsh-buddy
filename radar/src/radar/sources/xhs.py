"""小红书发现页：必须在浏览器上下文内读取；不自研 x-s/x-t 签名（§3 D2）。"""

from __future__ import annotations

import json
from dataclasses import dataclass

from playwright.sync_api import BrowserContext

from radar.config import Config
from radar.http import Throttle, probe, read_dom
from radar.images import normalize_image
from radar.models import RawItem
from radar.sources.base import AuthResult, ParseError

EXPLORE_URL = "https://www.xiaohongshu.com/explore"
# DOM 选择器随改版变化；改版时补 fixture 与选择器，不堆兼容分支（§10 B3）。
EXPLORE_JS = (
    "() => {const rows=[];"
    "for(const e of document.querySelectorAll('section.note-item')){"
    "const a=e.querySelector('a[href*=\"/explore/\"]'),h=a?a.getAttribute('href'):'';"
    "rows.push({id:h.split('/explore/')[1]?.split('?')[0]||'',"
    "title:e.querySelector('.title, .note-title')?.innerText||'',"
    "author:e.querySelector('.author, .name')?.innerText||'',"
    "snippet:e.querySelector('.desc')?.innerText||'',"
    "likes:e.querySelector('.like-wrapper .count, .count')?.innerText||'0',"
    "cover:e.querySelector('img')?.getAttribute('src')||'',"
    "created:e.querySelector('time')?.getAttribute('datetime')||''});}"
    "return JSON.stringify({items:rows});}"
)


def parse(body: str) -> list[RawItem]:
    # DOM 选择器随改版变化；改版时补 fixture 与选择器，不堆兼容分支（§10 B3）。
    try:
        rows = json.loads(body)["items"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ParseError("小红书发现页结构变化") from exc
    items: list[RawItem] = []
    for row in rows:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        native_id = str(row["id"])
        items.append(
            RawItem(
                "xhs",
                native_id,
                str(row.get("title") or ""),
                f"https://www.xiaohongshu.com/explore/{native_id}",
                author=str(row.get("author") or ""),
                published_at_raw=str(row.get("created") or ""),
                snippet=str(row.get("snippet") or ""),
                heat_raw=str(row.get("likes") or "0"),
                image=normalize_image(row.get("cover")),
            )
        )
    return items


@dataclass(frozen=True)
class XhsSource:
    cfg: Config
    throttle: Throttle
    name: str = "xhs"

    def check_auth(self, ctx: BrowserContext) -> AuthResult:
        return probe(ctx, self.name, EXPLORE_URL, self.cfg, self.throttle, EXPLORE_JS)

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]:
        return parse(read_dom(ctx, EXPLORE_URL, self.name, self.cfg, self.throttle, EXPLORE_JS))[
            :limit
        ]
