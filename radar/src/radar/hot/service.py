"""热榜编排：直接打各站点自己的接口，5 分钟一份快照，失败降级不倒退。

服务器盘小，所以缓存刻意压得很薄：
- 每个来源只留一份（PRIMARY KEY 覆盖写），不存历史；
- 单源最多 30 条，标题/链接原样，不存正文；
- 超过 `KEEP_S` 没刷新的记录由 `prune` 删掉，DB 不会随天数增长。

抓取失败时返回上一份数据并标 `stale`；连旧数据都没有就标 `unavailable`
（items 为空）——绝不拼接或编造条目。
"""

from __future__ import annotations

import json
import sqlite3
import time
from collections.abc import Iterable
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from radar.hot import providers
from radar.hot.catalog import HotSource, resolve
from radar.hot.fetch import FetchError
from radar.publication import transaction

TTL_S = 300
KEEP_S = 3600
MAX_CACHE_ITEMS = 30
DEFAULT_LIMIT = 30

Feed = dict[str, Any]


def ensure(conn: sqlite3.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS hot_cache "
        " (source TEXT PRIMARY KEY, body TEXT NOT NULL, fetched_at REAL NOT NULL)"
    )


def _now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _stamp(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _read(db_path: Path, source_id: str) -> tuple[list[dict[str, str]], float] | None:
    # 只读事务里不建表：并发批次下 DDL 会抢写锁，表由 ensure()/首次写入负责。
    try:
        with transaction(db_path, write=False) as conn:
            row = conn.execute(
                "SELECT body, fetched_at FROM hot_cache WHERE source=?", (source_id,)
            ).fetchone()
    except sqlite3.Error:
        return None
    if not row:
        return None
    try:
        items = json.loads(row[0])
    except (ValueError, TypeError):
        return None
    return (items if isinstance(items, list) else []), float(row[1])


def _write(db_path: Path, source_id: str, items: list[dict[str, str]]) -> None:
    with transaction(db_path) as conn:
        ensure(conn)
        conn.execute(
            "INSERT OR REPLACE INTO hot_cache VALUES (?, ?, ?)",
            (source_id, json.dumps(items, ensure_ascii=False), time.time()),
        )


def _feed(source: HotSource, items: list[dict[str, str]], *, status: str, origin: str) -> Feed:
    return {
        "source": source.id,
        "name": source.name,
        "title": source.title,
        "column": source.column,
        "home": source.home,
        "scheme": source.scheme,
        "status": status,
        "origin": origin,
        "updated_at": _now_iso(),
        "items": [{"rank": index + 1, **item} for index, item in enumerate(items)],
    }


def _gather(source: HotSource) -> tuple[list[dict[str, str]], str]:
    fetcher = providers.PROVIDERS.get(source.id)
    if fetcher is None:
        raise FetchError("该来源暂无直连实现")
    try:
        items = fetcher(MAX_CACHE_ITEMS)
    except FetchError:
        raise
    except Exception as exc:  # noqa: BLE001 - 单个源的结构异常不能拖垮整批
        raise FetchError(f"{type(exc).__name__}") from exc
    if not items:
        raise FetchError("空榜单")
    return items[:MAX_CACHE_ITEMS], "native"


def build(
    db_path: Path,
    source_id: str,
    *,
    limit: int = DEFAULT_LIMIT,
    ttl: int = TTL_S,
    refresh: bool = False,
) -> Feed:
    source = resolve(source_id)
    if source is None:
        raise KeyError(source_id)
    limit = max(1, min(limit, MAX_CACHE_ITEMS))
    cached = _read(db_path, source_id)
    if cached is not None and not refresh:
        items, fetched_at = cached
        if time.time() - fetched_at < ttl and items:
            return {
                **_feed(source, items[:limit], status="ok", origin="cache"),
                "updated_at": _stamp(fetched_at),
            }
    try:
        items, origin = _gather(source)
    except FetchError as exc:
        if cached is not None and cached[0]:
            # The rows are the cached ones, so the timestamp must be the cache's:
            # "stale" with a "just now" time reads as fresh to the App.
            return {
                **_feed(source, cached[0][:limit], status="stale", origin="cache"),
                "updated_at": _stamp(cached[1]),
                "error": str(exc),
            }
        return {**_feed(source, [], status="unavailable", origin="none"), "error": str(exc)}
    _write(db_path, source_id, items)
    return _feed(source, items[:limit], status="ok", origin=origin)


def build_many(
    db_path: Path,
    source_ids: Iterable[str],
    *,
    limit: int = DEFAULT_LIMIT,
    refresh: bool = False,
    workers: int = 8,
) -> list[Feed]:
    wanted = [source_id for source_id in dict.fromkeys(source_ids) if resolve(source_id)]
    if not wanted:
        return []

    def one(source_id: str) -> Feed:
        try:
            return build(db_path, source_id, limit=limit, refresh=refresh)
        except Exception as exc:  # noqa: BLE001 - 一个源炸了不影响其它源
            source = resolve(source_id)
            return (
                {**_feed(source, [], status="unavailable", origin="none")} if source else {}
            ) | {"error": type(exc).__name__}

    with ThreadPoolExecutor(max_workers=min(workers, len(wanted))) as pool:
        return list(pool.map(one, wanted))


def warm_all(db_path: Path, *, workers: int = 8) -> dict[str, int]:
    """worker 每 5 分钟把有直连实现的源抓一遍，App 请求时直接命中缓存。"""
    feeds = build_many(db_path, list(providers.PROVIDERS), refresh=True, workers=workers)
    ok = sum(1 for feed in feeds if feed.get("items"))
    return {"sources": len(feeds), "ok": ok}


def prune(db_path: Path, keep_s: int = KEEP_S) -> int:
    """删掉很久没刷新的行，顺手回收文件页面；返回删除条数。"""
    cutoff = time.time() - keep_s
    with transaction(db_path) as conn:
        ensure(conn)
        removed = conn.execute("DELETE FROM hot_cache WHERE fetched_at < ?", (cutoff,)).rowcount
    if removed:
        # VACUUM 不能跑在事务里，单独开一条连接把删掉的空间还回磁盘。
        raw = sqlite3.connect(db_path)
        try:
            raw.execute("VACUUM")
        finally:
            raw.close()
    return max(0, removed)


def snapshot(db_path: Path, keep_s: int = KEEP_S) -> dict[str, list[dict[str, str]]]:
    """给共识简报用：一次读出所有源的最新条目。"""
    cutoff = time.time() - keep_s
    try:
        with transaction(db_path, write=False) as conn:
            rows = conn.execute(
                "SELECT source, body FROM hot_cache WHERE fetched_at >= ?", (cutoff,)
            ).fetchall()
    except sqlite3.Error:
        return {}
    out: dict[str, list[dict[str, str]]] = {}
    for source_id, body in rows:
        try:
            items = json.loads(body)
        except (ValueError, TypeError):
            continue
        if isinstance(items, list) and items:
            out[str(source_id)] = [item for item in items if isinstance(item, dict)]
    return out
