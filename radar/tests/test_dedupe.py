"""SQLite seen 表：INSERT OR IGNORE 与「同 fixture 连跑两次零新增」。"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from radar.dedupe import SeenStore, dedupe, ensure_unique, filter_new
from radar.models import Candidate

NOW = datetime(2026, 11, 11, 8, 30, tzinfo=UTC)


def candidate(item_id: str, platform: str = "weibo") -> Candidate:
    return Candidate(
        id=item_id,
        platform=platform,
        title="标题",
        url="https://example.invalid/x",
        author="",
        snippet="",
        published_at=NOW,
        heat=10,
        lang="zh",
        is_repost=False,
    )


def test_insert_new_only_once(tmp_path: Path) -> None:
    store = SeenStore(tmp_path / "seen.db")
    items = (candidate("weibo:abc"), candidate("bili:def"))
    try:
        first = store.insert_new(items, NOW)
        second = store.insert_new(items, NOW)
        assert first == ("weibo:abc", "bili:def")
        assert second == ()
    finally:
        store.close()


def test_dedupe_second_run_yields_zero(tmp_path: Path) -> None:
    items = (candidate("weibo:abc"), candidate("weibo:abc"), candidate("x:123"))
    store = SeenStore(tmp_path / "seen.db")
    try:
        first = dedupe(store, items, NOW)
        assert len(first.new_items) == 2
        assert first.new_ids == ("weibo:abc", "x:123")
        second = dedupe(store, items, NOW)
        assert second.new_items == ()
        assert second.new_ids == ()
    finally:
        store.close()


def test_seen_table_schema_is_minimal(tmp_path: Path) -> None:
    store = SeenStore(tmp_path / "seen.db")
    try:
        names = {row[1] for row in store.conn.execute("PRAGMA table_info(seen)")}
        tables = [
            row[0]
            for row in store.conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        ]
        assert names == {"id", "platform", "first_seen_at"}
        assert tables == ["seen"]
    finally:
        store.close()


def test_pure_helpers() -> None:
    items = (candidate("a:1"), candidate("a:1"), candidate("b:2"))
    assert len(ensure_unique(items)) == 2
    assert [item.id for item in filter_new(items, ("b:2",))] == ["b:2"]
