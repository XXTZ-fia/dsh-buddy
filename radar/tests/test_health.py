"""health 聚合与异常映射：单源失败不动其它源（D7）。"""

from __future__ import annotations

from radar.health import (
    aggregate,
    failed_platforms,
    from_exception,
    from_result,
    ok_platforms,
    status_of,
    success,
)
from radar.models import PLATFORMS
from radar.sources.base import (
    AuthExpired,
    AuthResult,
    ParseError,
    RateLimited,
    SourceUnavailable,
)

STAMP = "2026-11-11T08:30:00Z"


def test_status_mapping() -> None:
    assert status_of(AuthExpired()) == "auth_expired"
    assert status_of(RateLimited()) == "rate_limited"
    assert status_of(SourceUnavailable()) == "unavailable"
    assert status_of(ParseError()) == "unavailable"
    assert status_of(ValueError()) == "unavailable"
    assert from_exception(AuthExpired(), "xhs", STAMP).note == "AuthExpired"


def test_from_result_and_success() -> None:
    health = from_result(AuthResult("xhs", "auth_expired", "需要重新扫码"), STAMP)
    assert health.platform == "xhs" and health.note == "需要重新扫码"
    ok = success("weibo", STAMP, 3)
    assert ok.status == "ok" and ok.checked_at == STAMP


def test_aggregate_always_six() -> None:
    entries = (success("x", STAMP, 1), from_exception(RateLimited(), "bili", STAMP))
    result = aggregate(entries, STAMP)
    assert len(result) == 6
    assert tuple(item.platform for item in result) == PLATFORMS
    assert result[0].status == "ok"
    assert result[1].status == "unavailable"
    assert result[2].status == "rate_limited"


def test_ok_and_failed_lists() -> None:
    entries = aggregate((success("x", STAMP, 1),), STAMP)
    assert ok_platforms(entries) == ("x",)
    assert len(failed_platforms(entries)) == 5


def test_selected_platforms_do_not_report_disabled_sources_as_failed() -> None:
    entries = aggregate(
        (from_exception(RateLimited(http_status=412), "bili", STAMP),), STAMP, ("bili",)
    )
    assert len(entries) == 6
    assert failed_platforms(entries) == ("bili",)
    assert all(e.note == "本轮未启用" for e in entries if e.platform != "bili")


def test_rate_diagnostics_never_include_exception_message() -> None:
    entry = from_exception(
        RateLimited("private response body", http_status=200, code=-352), "bili", STAMP
    )
    assert entry.note == "RateLimited HTTP 200 code=-352"
