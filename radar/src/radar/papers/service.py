"""论文首页的编排：两个来源各自缓存、各自降级，再统一排序。

缓存策略与热榜一致但更宽松：论文一天也就更新一轮，TTL 30 分钟，每个来源只留
一份（主键覆盖写），7 天没刷新就删，DB 不随天数增长。
"""

from __future__ import annotations

import json
import sqlite3
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from radar.config import Config
from radar.papers import rank, translate
from radar.papers.sources import Paper, PaperSourceError, fetch_arxiv, fetch_hf
from radar.publication import transaction

TTL_S = 1800
KEEP_S = 7 * 24 * 3600
DEFAULT_LIMIT = 12
MAX_LIMIT = 30

#: 每次拉取的候选池：HF 100 条足够覆盖两天榜单，arXiv 60 条够一个分类日更。
HF_POOL = 100
ARXIV_POOL = 60

Fetchers = Mapping[str, Callable[[], list[Paper]]]

LABELS = {"hf": "Hugging Face Daily", "arxiv": "arXiv"}


def ensure(conn: sqlite3.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS paper_cache "
        " (source TEXT PRIMARY KEY, body TEXT NOT NULL, fetched_at REAL NOT NULL)"
    )


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def default_fetchers(interests: Sequence[str]) -> dict[str, Callable[[], list[Paper]]]:
    return {
        "hf": lambda: fetch_hf(HF_POOL),
        "arxiv": lambda: fetch_arxiv(interests, ARXIV_POOL),
    }


def fetchers_for(
    interests: Sequence[str], sources: Sequence[str] | None = None
) -> dict[str, Callable[[], list[Paper]]]:
    """按手机端勾选的来源取数：只留 hf / arxiv 里被选中的那些。"""
    all_fetchers = default_fetchers(interests)
    if not sources:
        return all_fetchers
    picked = {source: fetch for source, fetch in all_fetchers.items() if source in sources}
    return picked or all_fetchers


def _read(db_path: Path, source: str) -> tuple[list[dict[str, Any]], float] | None:
    try:
        with transaction(db_path, write=False) as conn:
            row = conn.execute(
                "SELECT body, fetched_at FROM paper_cache WHERE source=?", (source,)
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


def _write(db_path: Path, source: str, papers: Sequence[Paper]) -> None:
    with transaction(db_path) as conn:
        ensure(conn)
        conn.execute(
            "INSERT OR REPLACE INTO paper_cache VALUES (?, ?, ?)",
            (
                source,
                json.dumps([paper.as_dict() for paper in papers], ensure_ascii=False),
                time.time(),
            ),
        )


def prune(db_path: Path) -> None:
    cutoff = time.time() - KEEP_S
    with transaction(db_path) as conn:
        ensure(conn)
        conn.execute("DELETE FROM paper_cache WHERE fetched_at < ?", (cutoff,))


def _paper_from(item: Mapping[str, Any]) -> Paper:
    return Paper(
        id=str(item.get("id") or ""),
        title=str(item.get("title") or ""),
        abstract=str(item.get("abstract") or ""),
        authors=tuple(str(name) for name in item.get("authors") or ()),
        url=str(item.get("url") or ""),
        pdf_url=str(item["pdf_url"]) if item.get("pdf_url") else None,
        source=str(item.get("source") or "hf"),
        published_at=str(item.get("published_at") or ""),
        upvotes=int(item.get("upvotes") or 0),
    )


def build(
    db_path: Path,
    interests: Sequence[str],
    limit: int = DEFAULT_LIMIT,
    *,
    cfg: Config | None = None,
    refresh: bool = False,
    fetchers: Fetchers | None = None,
    sources: Sequence[str] | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    """首页论文：优先用未过期的缓存，过期才联网；联网失败退回旧缓存。

    `sources` 只取 `hf` / `arxiv` 中被选中的源（手机端可关掉其中一个）；
    传了 `cfg` 才会把标题与摘要译成中文——测试与离线调用不需要翻译。
    """
    moment = now if now is not None else time.time()
    picked = fetchers or fetchers_for(interests, sources)
    papers: list[Paper] = []
    statuses: list[dict[str, Any]] = []

    cached_rows = {source: _read(db_path, source) for source in picked}
    # 需要联网的源一起取：两个 HTTP 串行会让首屏多等一个来回。
    pending: dict[str, Callable[[], list[Paper]]] = {}
    for source, fetch in picked.items():
        row = cached_rows[source]
        if refresh or row is None or moment - row[1] >= TTL_S:
            pending[source] = fetch
    results: dict[str, list[Paper] | PaperSourceError] = {}
    if pending:
        with ThreadPoolExecutor(max_workers=len(pending)) as workers:
            futures = {source: workers.submit(fetch) for source, fetch in pending.items()}
            for source, future in futures.items():
                try:
                    results[source] = future.result()
                except PaperSourceError as error:
                    results[source] = error

    for source in picked:
        row = cached_rows[source]
        if source not in pending:
            # 没进 pending 就等于缓存还在 TTL 内。
            assert row is not None
            papers.extend(_paper_from(item) for item in row[0])
            statuses.append(_status(source, "cached", len(row[0]), row[1]))
            continue
        outcome = results[source]
        if isinstance(outcome, PaperSourceError):
            # 与热榜同一条原则：有旧数据就标 cached，没有就 unavailable，不编造。
            if row is not None:
                papers.extend(_paper_from(item) for item in row[0])
                statuses.append(_status(source, "cached", len(row[0]), row[1], note=str(outcome)))
            else:
                statuses.append(_status(source, "unavailable", 0, None, note=str(outcome)))
            continue
        fetched = outcome
        # 空结果也缓存：arXiv 某天没有新论文是正常状态，不该每次请求都再打一遍。
        _write(db_path, source, fetched)
        papers.extend(fetched)
        statuses.append(_status(source, "fresh", len(fetched), moment))

    ranked = [paper.as_dict() for paper in rank.rank(papers, interests, limit)]
    # 只译上榜的这一批：候选池 160 条，全译既慢又贵，且没人会看到。
    # 没有模型 Key 时走机器翻译，首页不该因为「服务端没配 Key」就一直是英文。
    translated = translate.attach(cfg, db_path, ranked) if cfg is not None else 0
    return {
        "generated_at": _now_iso(),
        "interests": list(interests),
        "sources": statuses,
        "translation": {
            "engine": translate.engine(cfg) if cfg is not None else "none",
            "translated": translated,
        },
        "items": ranked,
    }


def _status(
    source: str,
    status: str,
    count: int,
    fetched_at: float | None,
    *,
    note: str | None = None,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "source": source,
        "label": LABELS.get(source, source),
        "status": status,
        "count": count,
        "fetched_at": _iso(fetched_at) if fetched_at is not None else None,
    }
    if note:
        row["note"] = note
    return row
