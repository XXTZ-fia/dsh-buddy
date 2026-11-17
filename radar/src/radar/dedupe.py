"""SQLite seen 表是全局唯一有状态处；只做 INSERT OR IGNORE。"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from radar.models import Candidate

_SCHEMA = (
    "CREATE TABLE IF NOT EXISTS seen ("
    "id TEXT PRIMARY KEY, platform TEXT NOT NULL, first_seen_at TEXT NOT NULL)"
)


@dataclass(frozen=True)
class DedupeResult:
    new_items: tuple[Candidate, ...]
    new_ids: tuple[str, ...]


class SeenStore:
    def __init__(self, db_path: Path) -> None:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(db_path))
        self.conn.execute(_SCHEMA)
        self.conn.commit()

    def insert_new(self, items: tuple[Candidate, ...], now: datetime) -> tuple[str, ...]:
        stamp = now.isoformat().replace("+00:00", "Z")
        added: list[str] = []
        for item in items:
            cursor = self.conn.execute(
                "INSERT OR IGNORE INTO seen (id, platform, first_seen_at) VALUES (?, ?, ?)",
                (item.id, item.platform, stamp),
            )
            if cursor.rowcount == 1:
                added.append(item.id)
        self.conn.commit()
        return tuple(added)

    def close(self) -> None:
        self.conn.close()


def ensure_unique(items: tuple[Candidate, ...]) -> tuple[Candidate, ...]:
    """纯函数：同一轮里 id 相同的条目只留一条。"""
    seen: set[str] = set()
    unique: list[Candidate] = []
    for item in items:
        if item.id not in seen:
            seen.add(item.id)
            unique.append(item)
    return tuple(unique)


def filter_new(items: tuple[Candidate, ...], new_ids: tuple[str, ...]) -> tuple[Candidate, ...]:
    """纯函数：把 SQLite 返回的「真正新增 id」映射回条目。"""
    wanted = set(new_ids)
    return tuple(item for item in items if item.id in wanted)


def dedupe(store: SeenStore, items: tuple[Candidate, ...], now: datetime) -> DedupeResult:
    unique = ensure_unique(items)
    new_ids = store.insert_new(unique, now)
    return DedupeResult(filter_new(unique, new_ids), new_ids)
