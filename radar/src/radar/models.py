"""§5.1 内部数据契约；跨模块边界只传这里的 frozen dataclass。"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Literal

PLATFORMS: tuple[str, ...] = ("x", "douyin", "bili", "weibo", "zhihu", "xhs")
SCHEMA_VERSION = 1
MAX_ITEMS = 5
SNAPSHOT_SIZE = 50
ID_PATTERN = r"^[a-z]+:[a-z0-9_-]+$"
X_TIME_FORMAT = "%a %b %d %H:%M:%S +0000 %Y"
HealthStatus = Literal["ok", "auth_expired", "rate_limited", "unavailable"]


@dataclass(frozen=True)
class Heat:
    value: int
    delta: str


@dataclass(frozen=True)
class RawItem:
    platform: str
    native_id: str
    title: str
    url: str
    # 榜单类源没有作者/时间/正文，默认值让适配器只写它真正有的字段。
    author: str = ""
    published_at_raw: str = ""
    snippet: str = ""
    heat_raw: str = "0"
    lang: str = "zh"
    is_repost: bool = False
    image: str = ""  # 白名单 CDN 外链；无图时为空串


@dataclass(frozen=True)
class Candidate:
    id: str
    platform: str
    title: str
    url: str
    author: str
    snippet: str
    published_at: datetime
    heat: int
    lang: str
    is_repost: bool
    image: str = ""


@dataclass(frozen=True)
class RadarItem:
    id: str
    platform: str
    title: str
    summary: str
    why: str
    url: str
    author: str
    lang: str
    published_at: str
    heat: Heat
    cross_platform: tuple[str, ...]
    image: str = ""


@dataclass(frozen=True)
class Health:
    platform: str
    status: HealthStatus
    checked_at: str
    note: str


@dataclass(frozen=True)
class RunReport:
    started_at: str
    sources_ok: tuple[str, ...]
    sources_failed: tuple[str, ...]
    fetched: int
    new_items: int
    written: bool
    duration_ms: int


@dataclass(frozen=True)
class RadarDocument:
    generated_at: str
    health: tuple[Health, ...]
    items: tuple[RadarItem, ...]
