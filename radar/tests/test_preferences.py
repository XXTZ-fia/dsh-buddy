"""手机端偏好（settings 行）：兴趣词、论文来源、条数的读取与兜底。

这些值由 App 通过 PUT /radar/config 写入，论文接口只读；这里的用例锁住
「字段缺失 / 类型不对 / 服务还没写设置行」三种情况的默认值。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

from radar import preferences


def _db(tmp_path: Path, body: Any = None, *, create: bool = True, name: str = "state") -> Path:
    path = tmp_path / f"{name}.db"
    if not create:
        return path
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL)")
    conn.execute("INSERT INTO settings VALUES (1, ?)", (json.dumps(body or {}),))
    conn.commit()
    conn.close()
    return path


def test_interests_fall_back_to_config_when_unset(tmp_path: Path) -> None:
    db = _db(tmp_path, {"interests": []})
    assert preferences.interests(db, ("agent",)) == ("agent",)


def test_interests_prefer_phone_settings(tmp_path: Path) -> None:
    db = _db(tmp_path, {"interests": [" RAG ", "agent", ""]})
    assert preferences.interests(db, ("ignored",)) == ("RAG", "agent")


def test_missing_table_is_not_a_crash(tmp_path: Path) -> None:
    db = _db(tmp_path, create=False)
    assert preferences.raw(db) == {}
    assert preferences.interests(db, ("agent",)) == ("agent",)
    assert preferences.paper_sources(db) == ("hf", "arxiv")
    assert preferences.paper_limit(db, 12, 30) == 12


def test_paper_sources_keep_at_least_one(tmp_path: Path) -> None:
    assert preferences.paper_sources(_db(tmp_path, {"paper_sources": ["arxiv"]}, name="only")) == (
        "arxiv",
    )
    # 全是无效值 / 空列表：回落到两个源，论文页不能因此没有数据。
    assert preferences.paper_sources(_db(tmp_path, {"paper_sources": ["bogus"]}, name="bogus")) == (
        "hf",
        "arxiv",
    )
    assert preferences.paper_sources(_db(tmp_path, {"paper_sources": []}, name="empty")) == (
        "hf",
        "arxiv",
    )


def test_paper_limit_is_clamped(tmp_path: Path) -> None:
    assert preferences.paper_limit(_db(tmp_path, {"paper_limit": 20}, name="ok"), 12, 30) == 20
    assert preferences.paper_limit(_db(tmp_path, {"paper_limit": 999}, name="big"), 12, 30) == 30
    assert preferences.paper_limit(_db(tmp_path, {"paper_limit": 0}, name="zero"), 12, 30) == 1
    assert preferences.paper_limit(_db(tmp_path, {"paper_limit": "20"}, name="str"), 12, 30) == 12
    assert preferences.paper_limit(_db(tmp_path, {"paper_limit": True}, name="bool"), 12, 30) == 12
