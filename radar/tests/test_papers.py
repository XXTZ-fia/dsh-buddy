"""论文流：解析、排序、缓存与降级。

全部用固定报文，不联网；真实的 HF / arXiv 只在服务器上跑。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from radar.papers import rank, service
from radar.papers.sources import (
    Paper,
    PaperSourceError,
    arxiv_query,
    parse_arxiv,
    parse_hf,
)

HF_FIXTURE = """
[
  {
    "paper": {
      "id": "2501.00001",
      "title": "An AI Agent that Reads Its Own Traces",
      "summary": "We study an AI Agent loop. The agent reflects on traces.",
      "authors": [{"name": "Ada Lovelace"}, {"name": "Alan Turing"}],
      "upvotes": 42,
      "publishedAt": "2026-11-14T00:00:00.000Z"
    },
    "publishedAt": "2026-11-14T00:00:00.000Z"
  },
  {
    "paper": {
      "id": "2501.00002",
      "title": "A Benchmark for Table Question Answering",
      "summary": "Tables are hard.",
      "authors": [{"name": "Grace Hopper"}],
      "upvotes": 7,
      "publishedAt": "2026-11-13T00:00:00.000Z"
    },
    "publishedAt": "2026-11-13T00:00:00.000Z"
  }
]
"""

ARXIV_FIXTURE = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2501.00003v1</id>
    <title>Embodied
      Agents in the Wild</title>
    <summary>We deploy 具身智能 agents.</summary>
    <published>2026-11-12T00:00:00Z</published>
    <author><name>Barbara Liskov</name></author>
    <link href="http://arxiv.org/pdf/2501.00003v1" title="pdf" type="application/pdf"/>
  </entry>
  <entry>
    <title>No id, dropped</title>
  </entry>
</feed>
"""


def _paper(
    pid: str, title: str, abstract: str = "", *, votes: int = 0, source: str = "hf"
) -> Paper:
    return Paper(
        id=pid,
        title=title,
        abstract=abstract,
        authors=("A",),
        url=f"https://arxiv.org/abs/{pid}",
        pdf_url=None,
        source=source,
        published_at="2026-11-14",
        upvotes=votes,
    )


def test_parse_hf_reads_nested_and_short_rows() -> None:
    papers = parse_hf(HF_FIXTURE)
    assert [paper.id for paper in papers] == ["2501.00001", "2501.00002"]
    first = papers[0]
    assert first.title == "An AI Agent that Reads Its Own Traces"
    assert first.authors == ("Ada Lovelace", "Alan Turing")
    assert first.upvotes == 42
    assert first.published_at == "2026-11-14"
    assert first.url == "https://arxiv.org/abs/2501.00001"
    assert first.pdf_url == "https://arxiv.org/pdf/2501.00001"


def test_parse_hf_rejects_garbage() -> None:
    with pytest.raises(PaperSourceError):
        parse_hf("not json")
    with pytest.raises(PaperSourceError):
        parse_hf('{"papers": []}')


def test_parse_arxiv_flattens_text_and_keeps_pdf() -> None:
    papers = parse_arxiv(ARXIV_FIXTURE)
    assert len(papers) == 1
    paper = papers[0]
    assert paper.id == "2501.00003v1"
    assert paper.title == "Embodied Agents in the Wild"
    assert paper.pdf_url == "http://arxiv.org/pdf/2501.00003v1"
    assert paper.source == "arxiv"


def test_arxiv_query_quotes_interest_and_adds_categories() -> None:
    query = arxiv_query(["AI Agent", "具身智能"])
    assert 'all:"AI Agent"' in query
    assert 'all:"具身智能"' in query
    assert "cat:cs.AI" in query
    assert " OR " in query


def test_interest_hit_outranks_more_upvoted_stranger() -> None:
    relevant = _paper("1", "An AI Agent with Memory", votes=3)
    stranger = _paper("2", "Protein Folding at Scale", votes=99)
    ranked = rank.rank([stranger, relevant], ["AI Agent"], limit=2)
    assert [paper.id for paper in ranked] == ["1", "2"]
    assert ranked[0].matched == ("AI Agent",)


def test_duplicates_merge_and_both_sources_win() -> None:
    hf = _paper("2501.00001", "Same Paper", votes=10, source="hf")
    arxiv = _paper("2501.00001", "Same Paper", votes=4, source="arxiv")
    other = _paper("2501.00002", "Other Paper")
    ranked = rank.rank([hf, arxiv, other], [], limit=5)
    assert len(ranked) == 2
    merged = next(paper for paper in ranked if paper.id == "2501.00001")
    assert merged.source == "both"
    assert merged.upvotes == 10


def test_abstract_is_trimmed_for_the_card() -> None:
    long = _paper("1", "Long", abstract="x" * 2000)
    ranked = rank.rank([long], [], limit=1)
    assert len(ranked[0].abstract) == rank.ABSTRACT_CHARS


def test_build_caches_and_reuses(tmp_path: Path) -> None:
    calls: list[str] = []

    def fetchers() -> dict[str, object]:
        def hf() -> list[Paper]:
            calls.append("hf")
            return [_paper("2501.00001", "An AI Agent")]

        def arxiv() -> list[Paper]:
            calls.append("arxiv")
            return []

        return {"hf": hf, "arxiv": arxiv}

    first = service.build(tmp_path / "state.db", ["AI Agent"], fetchers=fetchers())
    assert [paper["id"] for paper in first["items"]] == ["2501.00001"]
    assert {row["status"] for row in first["sources"]} == {"fresh"}
    assert calls == ["hf", "arxiv"]

    second = service.build(tmp_path / "state.db", ["AI Agent"], fetchers=fetchers())
    assert [paper["id"] for paper in second["items"]] == ["2501.00001"]
    assert {row["status"] for row in second["sources"]} == {"cached"}
    assert calls == ["hf", "arxiv"], "a warm cache must not hit the network"


def test_build_degrades_to_cache_then_unavailable(tmp_path: Path) -> None:
    def broken() -> list[Paper]:
        raise PaperSourceError("429")

    db = tmp_path / "state.db"
    # 先写一份缓存，再让两个来源都失败。
    service.build(
        db, ["AI Agent"], fetchers={"hf": lambda: [_paper("1", "Cached")], "arxiv": broken}
    )
    cached = service.build(
        db,
        ["AI Agent"],
        refresh=True,
        fetchers={"hf": broken, "arxiv": broken},
    )
    statuses = {row["source"]: row for row in cached["sources"]}
    assert statuses["hf"]["status"] == "cached"
    assert statuses["arxiv"]["status"] == "unavailable"
    assert [paper["id"] for paper in cached["items"]] == ["1"]

    empty = service.build(
        tmp_path / "empty.db", ["AI Agent"], fetchers={"hf": broken, "arxiv": broken}
    )
    assert empty["items"] == []
    assert {row["status"] for row in empty["sources"]} == {"unavailable"}


def test_only_selected_sources_are_polled() -> None:
    # 手机端关掉 arXiv 后，取数只该碰选中的那个源。
    picked = service.fetchers_for(["AI Agent"], ("hf",))
    assert set(picked) == {"hf"}
    # 空列表或全是无效值：回落到两个源，首页不该因此空掉。
    assert set(service.fetchers_for(["AI Agent"], ())) == {"hf", "arxiv"}
    assert set(service.fetchers_for(["AI Agent"], ("bogus",))) == {"hf", "arxiv"}


def test_build_respects_limit(tmp_path: Path) -> None:
    fetchers: Any = {
        "hf": lambda: [_paper(str(index), f"An AI Agent {index}") for index in range(6)]
    }
    result = service.build(tmp_path / "state.db", ["AI Agent"], limit=3, fetchers=fetchers)
    assert len(result["items"]) == 3


def test_votes_outrank_a_single_abstract_hit() -> None:
    # 认可度：99 个赞的陌生人应该压过只在摘要里提了一句兴趣词的论文。
    keyword_only = _paper("1", "Long", abstract="this mentions AI Agent once")
    endorsed = _paper("2", "Protein Folding at Scale", votes=99)
    ranked = rank.rank([keyword_only, endorsed], ["AI Agent"], limit=2)
    assert [paper.id for paper in ranked] == ["2", "1"]
