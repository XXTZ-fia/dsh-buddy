"""SourceAdapter 契约、四种统一异常、显式注册表。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

from playwright.sync_api import BrowserContext

from radar.models import HealthStatus, RawItem

if TYPE_CHECKING:
    from radar.config import Config
    from radar.http import Throttle


class AuthExpired(Exception):
    """登录态失效，需要用户重新扫码。"""


class RateLimited(Exception):
    """命中限流或风控码，必须退避而不是重试。"""

    def __init__(
        self, message: str = "", *, http_status: int | None = None, code: int | None = None
    ) -> None:
        super().__init__(message)
        self.http_status = http_status
        self.code = code


class SourceUnavailable(Exception):
    """端点不可达或业务码异常，静默降级。"""


class ParseError(Exception):
    """响应结构与 fixture 不一致，改 fixture 而不是加兼容分支。"""


@dataclass(frozen=True)
class AuthResult:
    platform: str
    status: HealthStatus
    note: str


class SourceAdapter(Protocol):
    @property
    def name(self) -> str: ...

    def check_auth(self, ctx: BrowserContext) -> AuthResult: ...

    def fetch(self, ctx: BrowserContext, limit: int) -> list[RawItem]: ...


def build_sources(cfg: Config, throttle: Throttle) -> dict[str, SourceAdapter]:
    """显式注册表：加一个源 = 加一个文件 + 这里加一行。"""
    # 适配器需要 import 本模块的异常类型，函数内静态导入可断开循环依赖。
    from radar.sources.bilibili import BiliSource
    from radar.sources.douyin import DouyinSource
    from radar.sources.weibo import WeiboSource
    from radar.sources.x import XSource
    from radar.sources.xhs import XhsSource
    from radar.sources.zhihu import ZhihuSource

    return {
        "weibo": WeiboSource(cfg, throttle),
        "bili": BiliSource(cfg, throttle),
        "zhihu": ZhihuSource(cfg, throttle),
        "douyin": DouyinSource(cfg, throttle),
        "xhs": XhsSource(cfg, throttle),
        "x": XSource(cfg, throttle),
    }
