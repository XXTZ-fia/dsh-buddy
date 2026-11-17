"""共识简报：从所有热榜里挑出「好几个站点同时在上」的话题。

两步走，先便宜后聪明：
1. 规则聚类——按标题字符 bigram 做包含度合并，跨 ≥2 个来源才算共识。
   这一步不花钱，也是没有模型 Key 时的全部结果。
2. 可选润色——把规则选出的候选标题交给 DeepSeek，让它归并成不超过 8 条、
   每条一句标题 + 一句解读。输入只有几百个短标题，单次成本约千分之几元，
   结果缓存 2 小时，一天最多 12 次。

模型不可用（无 Key / 超时 / 返回不合法）时保留规则结果并标 `model=""`，
不重试、不嵌套调用，避免把一次失败放大成账单。
"""

from __future__ import annotations

import json
import re
import sqlite3
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from radar.config import Config
from radar.hot import service
from radar.hot.catalog import resolve
from radar.publication import transaction

TTL_S = 7200
MAX_TOPICS = 8
CANDIDATE_TOPICS = 24

PUNCT = re.compile(r"[\s\-—–·|丨/\\:：,，.。!！?？\"'“”‘’()（）\[\]【】<>《》…~`@#$%^&*+=]+")
TAIL = re.compile(r"(热点|热议|热榜|热搜|最新|快讯|实时|头条|排行榜|榜单)$")
STOP = frozenset(
    {
        "什么",
        "怎么",
        "为什么",
        "我们",
        "他们",
        "自己",
        "已经",
        "可以",
        "这个",
        "那个",
        "一个",
        "没有",
        "不是",
        "就是",
        "还是",
        "以及",
        "但是",
        "因为",
        "所以",
        "如果",
        "现在",
        "今日",
        "最新",
        "消息",
        "报道",
        "记者",
    }
)


def ensure(conn: sqlite3.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS digest_cache "
        " (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL, generated_at REAL NOT NULL)"
    )


def _norm(title: str) -> str:
    text = PUNCT.sub("", TAIL.sub("", title.strip().lower()))
    return text


def _is_chinese(text: str) -> bool:
    return any("\u4e00" <= char <= "\u9fff" for char in text)


def _tokens(text: str) -> set[str]:
    """中文用字符二元组，英文用长度 ≥4 的词：两种语言的巧合模式不同。"""
    norm = _norm(text)
    if not norm:
        return set()
    if _is_chinese(norm):
        return {norm[i : i + 2] for i in range(len(norm) - 1)} if len(norm) > 1 else {norm}
    return {word for word in re.split(r"[^a-z0-9]+", norm) if len(word) >= 4}


def _overlap(left: set[str], right: set[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / min(len(left), len(right))


def _shared(left: set[str], right: set[str]) -> int:
    return len(left & right)


def _cluster(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """贪心合并：标题高度重叠、且语言一致的条目落进同一个簇。

    判定用「共同片段数 + 包含度」两个条件，任一按语言给不同门槛：
    中文一句 20 字有 19 个二元组，巧合本来就少；英文短标题常常互相包含，
    所以要求共享 2 个以上实词，否则会把不相干的英文标题串成一串。
    """
    clusters: list[dict[str, Any]] = []
    for entry in entries:
        tokens = _tokens(entry["title"])
        # 极短标题（栏目标签、作品名）没有可用信息，不参与聚类。
        if len(tokens) < 4:
            continue
        language = "zh" if _is_chinese(entry["title"]) else "en"
        need = 3 if language == "zh" else 2
        best: dict[str, Any] | None = None
        best_score = 0.0
        for cluster in clusters:
            if cluster["lang"] != language:
                continue
            score = _overlap(tokens, cluster["tokens"])
            if score > best_score:
                best, best_score = cluster, score
        if best is not None and best_score >= 0.5 and _shared(tokens, best["tokens"]) >= need:
            best["items"].append(entry)
            best["sources"].add(entry["source"])
            best["names"].add(entry["source_name"])
        else:
            clusters.append(
                {
                    "tokens": set(tokens),
                    "lang": language,
                    "items": [entry],
                    "sources": {entry["source"]},
                    "names": {entry["source_name"]},
                }
            )
    return clusters


def _rank(clusters: list[dict[str, Any]]) -> list[dict[str, Any]]:
    topics: list[dict[str, Any]] = []
    for cluster in clusters:
        items = cluster["items"]
        sources = cluster["sources"]
        names = cluster["names"]
        # 同一 App 的几个榜单（B 站热搜/热门/排行）算一个来源，否则自己跟自己「共识」。
        if len(names) < 2 or len(items) < 2:
            continue
        # 代表条目取 12–40 字里最长的：太短常是栏目名，太长是整段快讯正文。
        representative = max(
            items, key=lambda row: (12 <= len(row["title"]) <= 40, len(row["title"]))
        )
        headline = representative["title"]
        if len(headline) > 42:
            headline = headline[:40] + "…"
        topics.append(
            {
                "title": headline,
                "note": "、".join(sorted(names)),
                "sources": sorted(sources),
                "outlets": len(names),
                "count": len(items),
                "items": [
                    {
                        "title": row["title"],
                        "url": row["url"],
                        # 两个字段各司其职：source 是给 App 跳转用的 id，
                        # source_name 是给人看的站点名（「哔哩哔哩」）。
                        "source": row["source"],
                        "source_name": row["source_name"],
                    }
                    for row in items[:6]
                ],
            }
        )
    topics.sort(key=lambda topic: (topic["outlets"], topic["count"]), reverse=True)
    return topics[:CANDIDATE_TOPICS]


def _collect(snapshot: dict[str, list[dict[str, str]]]) -> tuple[list[dict[str, Any]], int]:
    entries: list[dict[str, Any]] = []
    total = 0
    for source_id, items in snapshot.items():
        source = resolve(source_id)
        name = source.name if source else source_id
        for item in items:
            title = str(item.get("title") or "").strip()
            link = str(item.get("url") or "").strip()
            if not title or not link:
                continue
            total += 1
            entries.append({"title": title, "url": link, "source": source_id, "source_name": name})
    return entries, total


def _model_config(cfg: Config | None) -> tuple[str, str, str]:
    if cfg is None:
        return "", "", ""
    return cfg.env.model_api_key.strip(), cfg.model_base_url.strip(), cfg.model_name.strip()


PROMPT = (
    "下面是多个中文资讯站点的热榜标题。请找出被至少两个站点同时报道的同一件事，"
    "输出不超过 8 条。每条给：title（18 字以内，纯事实，不要书名号和引号）、"
    "note（28 字以内，说明这件事的看点）、sources（涉及的站点名数组，只能用我给的名字）。"
    '只输出 JSON：{"topics":[{"title":"","note":"","sources":[""]}]}。'
)


def _polish(
    cfg: Config | None, candidates: list[dict[str, Any]], names: set[str]
) -> list[dict[str, Any]] | None:
    key, base, model = _model_config(cfg)
    if not key or not base or not candidates:
        return None
    lines: list[str] = []
    for index, topic in enumerate(candidates[:18], start=1):
        for row in topic["items"][:3]:
            lines.append(f"{index}. [{row['source_name']}] {row['title']}")
    try:
        with httpx.Client(timeout=httpx.Timeout(40.0, connect=8.0)) as client:
            resp = client.post(
                base,
                headers={"Authorization": f"Bearer {key}"},
                json={
                    "model": model,
                    "messages": [
                        {"role": "system", "content": PROMPT},
                        {"role": "user", "content": "\n".join(lines)[:6000]},
                    ],
                    "temperature": 0.2,
                    "max_tokens": 900,
                    "response_format": {"type": "json_object"},
                },
            )
    except httpx.HTTPError:
        return None
    if resp.status_code != 200:
        return None
    try:
        payload = resp.json()["choices"][0]["message"]["content"]
        data = json.loads(payload)
    except (KeyError, IndexError, ValueError, TypeError):
        return None
    raw = data.get("topics")
    if not isinstance(raw, list):
        return None
    out: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        title = str(entry.get("title") or "").strip()
        if not title:
            continue
        listed = entry.get("sources")
        picked = (
            [str(name) for name in listed if str(name) in names] if isinstance(listed, list) else []
        )
        # 模型只负责归纳文字；来源与条目一律沿用规则结果，防止张冠李戴。
        match = next(
            (topic for topic in candidates if _overlap(_tokens(title), topic_tokens(topic)) > 0.3),
            None,
        )
        out.append(
            {
                "title": title,
                "note": str(entry.get("note") or "").strip(),
                "sources": picked or (match["sources"] if match else []),
                "count": match["count"] if match else len(picked),
                "items": match["items"] if match else [],
            }
        )
    return out or None


def topic_tokens(topic: dict[str, Any]) -> set[str]:
    return _tokens(topic["title"])


def build(
    db_path: Path, *, cfg: Config | None = None, refresh: bool = False, ttl: int = TTL_S
) -> dict[str, Any]:
    if not refresh:
        cached = _cached(db_path, ttl)
        # 缓存里那条是「没 Key 时的规则结果」，而这次带了 Key：重算一次，
        # 不然用户刚填完 Key 还要等两小时缓存过期才看到 AI 归纳。
        if cached is not None and not (_upgradeable(cfg, cached)):
            return cached
    snapshot = service.snapshot(db_path)
    entries, total = _collect(snapshot)
    clusters = _cluster(entries) if entries else []
    candidates = _rank(clusters)
    names = {source.name for source_id in snapshot if (source := resolve(source_id)) is not None}
    polished = _polish(cfg, candidates, names) if candidates else None
    body: dict[str, Any] = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "model": _model_config(cfg)[2] if polished else "",
        "sources": len(snapshot),
        "scanned": total,
        # 契约写「不超过 8 条」：模型可能不听，客户端不该替它兜底。
        "topics": (polished or candidates)[:MAX_TOPICS],
    }
    _store(db_path, body)
    return body


def _upgradeable(cfg: Config | None, cached: dict[str, Any]) -> bool:
    """缓存是规则版、而这次能调模型了 —— 值得重算一遍。"""
    key, _base, _model = _model_config(cfg)
    return bool(key) and not str(cached.get("model") or "")


def _cached(db_path: Path, ttl: int) -> dict[str, Any] | None:
    try:
        with transaction(db_path, write=False) as conn:
            row = conn.execute("SELECT body, generated_at FROM digest_cache WHERE id=1").fetchone()
    except sqlite3.Error:
        return None
    if not row or time.time() - float(row[1]) > ttl:
        return None
    try:
        body = json.loads(row[0])
    except (ValueError, TypeError):
        return None
    return body if isinstance(body, dict) else None


def _store(db_path: Path, body: dict[str, Any]) -> None:
    with transaction(db_path) as conn:
        ensure(conn)
        conn.execute(
            "INSERT OR REPLACE INTO digest_cache VALUES (1, ?, ?)",
            (json.dumps(body, ensure_ascii=False), time.time()),
        )


def summary_of(topics: list[dict[str, Any]]) -> dict[int, int]:
    spread: dict[int, int] = defaultdict(int)
    for topic in topics:
        spread[len(topic["sources"])] += 1
    return dict(sorted(spread.items(), key=lambda pair: pair[0], reverse=True))
