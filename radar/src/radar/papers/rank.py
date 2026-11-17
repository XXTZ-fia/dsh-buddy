"""论文排序：兴趣命中为主，认可度与新鲜度为辅。

分数刻意可解释（也便于单元测试）：

    score = 2.0 × 标题命中词数 + 0.8 × 摘要命中词数
          + 3.2 × min(1, log(1+upvotes)/log(201))     ← 认可度：社区投过票
          + 2.0 × 同时出现在两个来源                  ← 认可度：跨源印证
          + 1.0 × 新鲜度(半衰 14 天)

「认可度」是用户明确要求的排序维度：只按关键词排会把没人验证过的论文顶上首页，
所以赞数与「HF / arXiv 都收录」两项加起来占的权重，比摘要里的一个关键词更重
（近似于一次标题命中）。arXiv 没有投票，单源 arXiv 论文拿不到这两项，天然排在
「大家已经认可过」的后面，但仍能靠兴趣命中上榜。

只按 upvote 排会让「我感兴趣的」沉底；只按关键词排又会把旧论文翻上来，所以
三者相加，并把命中的词一并返回给界面显示。
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime

from radar.papers.sources import Paper

TITLE_WEIGHT = 2.0
ABSTRACT_WEIGHT = 0.8
#: 认可度：赞数归一化到 200 赞封顶（HF Daily 头部大约这个量级）。
VOTE_WEIGHT = 3.2
VOTE_REFERENCE = 200
#: 认可度：两个源都收录，说明它不只在一个社区里被挑出来。
BOTH_SOURCES_BONUS = 2.0
FRESH_WEIGHT = 1.0
HALF_LIFE_DAYS = 14.0

#: 摘要保留长度：卡片上折叠显示，原文链接在下方。
ABSTRACT_CHARS = 700


def matched_terms(paper: Paper, interests: Sequence[str]) -> tuple[str, ...]:
    title = paper.title.casefold()
    abstract = paper.abstract.casefold()
    hits: list[str] = []
    for interest in interests:
        word = " ".join(interest.split()).casefold()
        if not word:
            continue
        if word in title or word in abstract:
            hits.append(interest)
    return tuple(hits)


def _days_old(published_at: str, now: datetime) -> float:
    try:
        published = datetime.fromisoformat(published_at).replace(tzinfo=UTC)
    except ValueError:
        return 365.0
    return max(0.0, (now - published).total_seconds() / 86_400)


def score(paper: Paper, interests: Sequence[str], now: datetime | None = None) -> float:
    moment = now or datetime.now(UTC)
    title = paper.title.casefold()
    abstract = paper.abstract.casefold()
    total = 0.0
    for interest in interests:
        word = " ".join(interest.split()).casefold()
        if not word:
            continue
        if word in title:
            total += TITLE_WEIGHT
        elif word in abstract:
            total += ABSTRACT_WEIGHT
    total += VOTE_WEIGHT * min(1.0, math.log1p(paper.upvotes) / math.log1p(VOTE_REFERENCE))
    total += FRESH_WEIGHT * math.exp(-_days_old(paper.published_at, moment) / HALF_LIFE_DAYS)
    return total


def merge(papers: Iterable[Paper]) -> list[Paper]:
    """同一篇论文可能同时出现在 HF 与 arXiv：合一条，投票取最大。"""
    by_id: dict[str, Paper] = {}
    for paper in papers:
        seen = by_id.get(paper.id)
        if seen is None:
            by_id[paper.id] = paper
            continue
        by_id[paper.id] = Paper(
            id=seen.id,
            title=seen.title or paper.title,
            abstract=max((seen.abstract, paper.abstract), key=len),
            authors=seen.authors or paper.authors,
            url=seen.url,
            pdf_url=seen.pdf_url or paper.pdf_url,
            source="both",
            published_at=max(seen.published_at, paper.published_at),
            upvotes=max(seen.upvotes, paper.upvotes),
        )
    return list(by_id.values())


def rank(
    papers: Iterable[Paper],
    interests: Sequence[str],
    limit: int,
    now: datetime | None = None,
) -> list[Paper]:
    moment = now or datetime.now(UTC)
    ranked: list[tuple[float, Paper]] = []
    for paper in merge(papers):
        hits = matched_terms(paper, interests)
        bonus = BOTH_SOURCES_BONUS if paper.source == "both" else 0.0
        ranked.append((score(paper, interests, moment) + bonus, _with(paper, hits)))
    ranked.sort(key=lambda pair: pair[0], reverse=True)
    # 兴趣全不命中时也返回热度最高的一批：首页不能是空的。
    return [paper for _, paper in ranked[: max(1, limit)]]


def _with(paper: Paper, hits: tuple[str, ...]) -> Paper:
    return Paper(
        id=paper.id,
        title=paper.title,
        abstract=paper.abstract[:ABSTRACT_CHARS],
        authors=paper.authors,
        url=paper.url,
        pdf_url=paper.pdf_url,
        source=paper.source,
        published_at=paper.published_at,
        upvotes=paper.upvotes,
        matched=hits,
    )
