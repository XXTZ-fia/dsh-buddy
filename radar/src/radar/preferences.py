"""手机端可改的偏好（settings 表）的只读视图。

`Settings` 的 pydantic 模型住在 `radar.api` 里，论文路由再反过来 import 它就会
绕成环，所以这里只读那一行 JSON、按需取字段、缺字段用调用方给的默认值——
模型怎么演进都不影响取值。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

from radar.publication import transaction


def raw(db_path: Path) -> dict[str, Any]:
    """settings 行的原始字典；表还没有或读不出来时给空字典。"""
    try:
        with transaction(db_path, write=False) as conn:
            row = conn.execute("SELECT body FROM settings WHERE id=1").fetchone()
    except sqlite3.Error:
        return {}
    if not row:
        return {}
    try:
        data = json.loads(row[0])
    except (ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def interests(db_path: Path, fallback: tuple[str, ...]) -> tuple[str, ...]:
    """兴趣词以手机端设置为准（和简报共用一份），没有就用配置文件里的。"""
    values = raw(db_path).get("interests")
    if not isinstance(values, list):
        return fallback
    cleaned = tuple(str(word).strip() for word in values if str(word).strip())
    return cleaned or fallback


def paper_sources(db_path: Path, allowed: tuple[str, ...] = ("hf", "arxiv")) -> tuple[str, ...]:
    """论文来源开关：至少保留一个，坏了就回全部。"""
    values = raw(db_path).get("paper_sources")
    if not isinstance(values, list):
        return allowed
    picked = tuple(source for source in allowed if source in {str(v) for v in values})
    return picked or allowed


def paper_limit(db_path: Path, default: int, maximum: int) -> int:
    value = raw(db_path).get("paper_limit")
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return min(max(1, value), maximum)
