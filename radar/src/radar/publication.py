"""Durable publication: SQLite is authoritative; JSON is a recoverable projection."""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from pathlib import Path
from typing import Any

from radar.outbox import atomic_write

_WAL_READY: set[Path] = set()


@contextmanager
def transaction(path: Path, *, write: bool = True) -> Iterator[sqlite3.Connection]:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10)
    try:
        if write:
            # WAL lets readers run while a writer holds the lock; without it every
            # GET serializes behind the next INSERT/VACUUM. The mode is persisted
            # in the database file, so once per process is enough.
            if path not in _WAL_READY:
                # Older/odd filesystems may refuse WAL; rollback journal still works.
                with suppress(sqlite3.Error):
                    conn.execute("PRAGMA journal_mode=WAL")
                _WAL_READY.add(path)
            conn.execute(
                "CREATE TABLE IF NOT EXISTS seen "
                " (id TEXT PRIMARY KEY, platform TEXT NOT NULL, first_seen_at TEXT NOT NULL)"
            )
            conn.execute(
                "CREATE TABLE IF NOT EXISTS publications "
                " (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL)"
            )
            conn.execute(
                "CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, body TEXT NOT NULL)"
            )
        conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def snapshot(conn: sqlite3.Connection) -> dict[str, Any] | None:
    row = conn.execute("SELECT body FROM publications WHERE id=1").fetchone()
    return json.loads(row[0]) if row else None


def publish(conn: sqlite3.Connection, document: dict[str, Any], size: int) -> None:
    # 逆序写入：`/radar/items` 按 rowid 倒序分页，正序写入会让每轮里排名最低的先出现。
    # 这样倒序读出来的顺序就是「新一轮在前、轮内按排名」。
    for item in reversed(document["items"]):
        conn.execute(
            "INSERT OR IGNORE INTO history VALUES (?, ?)",
            (item["id"], json.dumps(item, ensure_ascii=False)),
        )
    previous = snapshot(conn)
    merged = {item["id"]: item for item in document["items"]}
    for item in (previous or {}).get("items", []):
        merged.setdefault(item["id"], item)
    document["items"] = list(merged.values())[:size]
    conn.execute(
        "INSERT OR REPLACE INTO publications VALUES (1, ?)",
        (json.dumps(document, ensure_ascii=False),),
    )


def materialize(db_path: Path, output: Path, *, has_new: bool = True) -> bool:
    """把数据库里的快照写成 radar.json。

    `has_new=False` 时不重写已存在的文件：契约要求「没有新增内容时不重写，
    written=false、mtime 不变」，App 据此判断「无事发生」。文件缺失时仍写一份，
    否则第一次空跑之后永远没有可读文件。
    """
    if not has_new and output.exists():
        return False
    # Keep the write lock through replacement so a concurrent run cannot publish an older snapshot.
    with transaction(db_path) as conn:
        document = snapshot(conn)
        if document is None:
            return False
        text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        if output.exists() and output.read_text(encoding="utf-8") == text:
            return False
        atomic_write(output, text)
        return True
