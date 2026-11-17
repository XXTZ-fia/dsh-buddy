"""纯函数：把各源结果/异常聚合成恰好 6 条 health[]。"""

from __future__ import annotations

from radar.models import PLATFORMS, Health, HealthStatus
from radar.sources.base import AuthExpired, AuthResult, ParseError, RateLimited, SourceUnavailable


def from_result(result: AuthResult, checked_at: str) -> Health:
    return Health(result.platform, result.status, checked_at, result.note)


def status_of(exc: Exception) -> HealthStatus:
    if isinstance(exc, AuthExpired):
        return "auth_expired"
    if isinstance(exc, RateLimited):
        return "rate_limited"
    if isinstance(exc, (SourceUnavailable, ParseError)):
        return "unavailable"
    return "unavailable"


def from_exception(exc: Exception, platform: str, checked_at: str) -> Health:
    # note 只写异常类型，不带响应体与任何凭证。
    note = type(exc).__name__
    if isinstance(exc, RateLimited):
        if type(exc.http_status) is int:
            note += f" HTTP {exc.http_status}"
        if type(exc.code) is int:
            note += f" code={exc.code}"
    return Health(platform, status_of(exc), checked_at, note)


def success(platform: str, checked_at: str, count: int) -> Health:
    return Health(platform, "ok", checked_at, f"采集 {count} 条")


def aggregate(
    entries: tuple[Health, ...], checked_at: str, selected: tuple[str, ...] = PLATFORMS
) -> tuple[Health, ...]:
    """缺哪个平台就补一条 unavailable，保证 health[] 恰好 6 条（D7）。"""
    known = {entry.platform: entry for entry in entries}
    return tuple(
        known.get(name)
        or Health(
            name,
            "unavailable",
            checked_at,
            "本轮未返回结果" if name in selected else "本轮未启用",
        )
        for name in PLATFORMS
    )


def failed_platforms(entries: tuple[Health, ...]) -> tuple[str, ...]:
    return tuple(
        entry.platform for entry in entries if entry.status != "ok" and entry.note != "本轮未启用"
    )


def ok_platforms(entries: tuple[Health, ...]) -> tuple[str, ...]:
    return tuple(entry.platform for entry in entries if entry.status == "ok")
