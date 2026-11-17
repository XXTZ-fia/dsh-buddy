"""6 个 parse() 用各自脱敏 fixture 喂通；零网络、零凭证。"""

from __future__ import annotations

import re
from datetime import UTC, datetime
from pathlib import Path

import pytest

from radar.models import ID_PATTERN, PLATFORMS
from radar.normalize import make_id, parse_x_time, same_event, to_candidate
from radar.sources import bilibili, douyin, weibo, x, xhs, zhihu
from radar.sources.base import ParseError
from radar.summarize import SYSTEM_PROMPT, build_messages

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
PARSERS = {
    "weibo": weibo.parse,
    "bili": bilibili.parse,
    "zhihu": zhihu.parse,
    "douyin": douyin.parse,
    "xhs": xhs.parse,
    "x": x.parse,
}


@pytest.mark.parametrize("platform", PLATFORMS)
def test_parse_fixture(platform: str) -> None:
    body = (FIXTURES / f"{platform}.json").read_text(encoding="utf-8")
    items = PARSERS[platform](body)
    assert len(items) > 0
    for item in items:
        assert item.platform == platform
        assert item.native_id and item.title and item.url
        assert item.lang in ("zh", "en")
        assert isinstance(item.is_repost, bool)
        assert re.fullmatch(ID_PATTERN, make_id(item.platform, item.native_id))


def test_pure_repost_filtered_at_collection() -> None:
    body = (FIXTURES / "x.json").read_text(encoding="utf-8")
    items = x.parse(body)
    assert not any(item.is_repost for item in items)
    assert all("RT @" not in item.title for item in items)
    assert len(items) == 4  # 5 条样本里有 1 条纯 RT


def test_x_created_at_is_parsable() -> None:
    body = (FIXTURES / "x.json").read_text(encoding="utf-8")
    first = x.parse(body)[0]
    assert parse_x_time(first.published_at_raw).utcoffset().total_seconds() == 0
    assert first.lang == "en"


def test_cross_platform_event_merges() -> None:
    first_weibo = weibo.parse((FIXTURES / "weibo.json").read_text(encoding="utf-8"))[0]
    first_douyin = douyin.parse((FIXTURES / "douyin.json").read_text(encoding="utf-8"))[0]
    assert same_event(first_weibo.title, first_douyin.title)


def test_changed_shape_raises_parse_error() -> None:
    with pytest.raises(ParseError):
        x.parse('{"unexpected":1}')
    with pytest.raises(ParseError):
        weibo.parse("not json")


def test_injection_sample_stays_as_data_only() -> None:
    body = (FIXTURES / "x.json").read_text(encoding="utf-8")
    hostile = x.parse(body)
    assert any("忽略上文" in item.title for item in hostile)
    now = datetime(2026, 11, 11, 8, 30, tzinfo=UTC)
    candidate = next(to_candidate(item, now) for item in hostile if "忽略上文" in item.title)
    messages = build_messages(candidate, ("Agent",))
    assert "忽略上文" not in messages[0].content
    assert messages[0].content == SYSTEM_PROMPT


def test_all_samples_and_template_are_sanitized() -> None:
    # 字段名拆开拼，等价于 §9 的 grep 自查，同时避免测试文件自身被误判。
    forbidden = ("SESS" + "DATA", "auth_" + "token", "web_" + "session", "bili_" + "jct")
    files = list(FIXTURES.glob("*.json")) + [ROOT / "config.example.yaml"]
    assert len(files) == 7
    for path in files:
        text = path.read_text(encoding="utf-8").lower()
        assert not any(word.lower() in text for word in forbidden)
