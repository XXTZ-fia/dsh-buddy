"""论文来源：Hugging Face Daily Papers 与 arXiv。

为什么是这两个：

- **HF Daily Papers** 是社区投票筛出来的（约为 arXiv 每日投稿的 2–3%），自带
  upvote，噪声远低于直接拉 arXiv 全量；
- **arXiv API** 补上「关键词还没被社区发现」的新论文，按兴趣词与分类检索。

两个来源都可能挂（机房 IP 429、接口改版），所以每个源单独降级，不互相拖累，
也绝不编造条目 —— 与热榜同一套原则。
"""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from urllib.parse import quote

import httpx

from radar.http import DEFAULT_UA

HF_API = "https://huggingface.co/api/daily_papers?limit={limit}"
ARXIV_API = (
    "https://export.arxiv.org/api/query?search_query={query}"
    "&start=0&max_results={max_results}"
    "&sortBy=submittedDate&sortOrder=descending"
)

#: 默认关注的分类：AI / NLP / 机器学习 / 视觉。
CATEGORIES: tuple[str, ...] = ("cs.AI", "cs.CL", "cs.LG", "cs.CV")

ATOM = "{http://www.w3.org/2005/Atom}"

#: 注入点：测试用固定报文替换网络。
Getter = Callable[[str], str]


class PaperSourceError(RuntimeError):
    """一个来源取不到（网络、限流、格式变化）。"""


@dataclass(frozen=True)
class Paper:
    id: str
    title: str
    abstract: str
    authors: tuple[str, ...]
    url: str
    pdf_url: str | None
    source: str
    published_at: str
    upvotes: int = 0
    matched: tuple[str, ...] = field(default=())

    def as_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "title": self.title,
            "abstract": self.abstract,
            "authors": list(self.authors),
            "url": self.url,
            "pdf_url": self.pdf_url,
            "source": self.source,
            "published_at": self.published_at,
            "upvotes": self.upvotes,
            "matched": list(self.matched),
        }


def _get(url: str) -> str:
    response = httpx.get(
        url,
        timeout=20.0,
        follow_redirects=True,
        headers={"User-Agent": DEFAULT_UA, "Accept": "*/*"},
    )
    response.raise_for_status()
    return response.text


def _clean(text: str) -> str:
    return " ".join(text.split())


def parse_hf(payload: str) -> list[Paper]:
    """HF 每日榜单。条目形如 `{"paper": {...}, "publishedAt": ...}`。"""
    try:
        rows = json.loads(payload)
    except ValueError as error:
        raise PaperSourceError(f"HF returned invalid JSON: {error}") from error
    if not isinstance(rows, list):
        raise PaperSourceError("HF returned an unexpected shape")
    papers: list[Paper] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        paper = row.get("paper") if isinstance(row.get("paper"), dict) else row
        assert isinstance(paper, dict)
        pid = str(paper.get("id") or "").strip()
        title = _clean(str(paper.get("title") or row.get("title") or ""))
        if not pid or not title:
            continue
        authors = tuple(
            _clean(str(author.get("name") if isinstance(author, dict) else author))
            for author in paper.get("authors") or []
        )
        published = str(paper.get("publishedAt") or row.get("publishedAt") or "")
        papers.append(
            Paper(
                id=pid,
                title=title,
                abstract=_clean(str(paper.get("summary") or "")),
                authors=tuple(name for name in authors if name)[:6],
                url=f"https://arxiv.org/abs/{pid}",
                pdf_url=f"https://arxiv.org/pdf/{pid}",
                source="hf",
                published_at=published[:10],
                upvotes=int(paper.get("upvotes") or 0),
            )
        )
    return papers


def parse_arxiv(payload: str) -> list[Paper]:
    """arXiv Atom 报文。标题/摘要里的换行会被压成空格。"""
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as error:
        raise PaperSourceError(f"arXiv returned invalid XML: {error}") from error
    papers: list[Paper] = []
    for entry in root.findall(f"{ATOM}entry"):
        raw_id = entry.findtext(f"{ATOM}id") or ""
        pid = raw_id.rsplit("/", 1)[-1]
        title = _clean(entry.findtext(f"{ATOM}title") or "")
        if not pid or not title:
            continue
        pdf_url: str | None = None
        for link in entry.findall(f"{ATOM}link"):
            if link.get("title") == "pdf" or link.get("type") == "application/pdf":
                pdf_url = link.get("href")
        authors = tuple(
            _clean(node.findtext(f"{ATOM}name") or "") for node in entry.findall(f"{ATOM}author")
        )
        published = entry.findtext(f"{ATOM}published") or ""
        papers.append(
            Paper(
                id=pid,
                title=title,
                abstract=_clean(entry.findtext(f"{ATOM}summary") or ""),
                authors=tuple(name for name in authors if name)[:6],
                url=raw_id or f"https://arxiv.org/abs/{pid}",
                pdf_url=pdf_url or f"https://arxiv.org/pdf/{pid}",
                source="arxiv",
                published_at=published[:10],
            )
        )
    return papers


def arxiv_query(interests: Sequence[str]) -> str:
    """兴趣词 + 分类的 OR 查询。词太多会被 arXiv 截断，取前四个。"""
    terms: list[str] = []
    for word in list(interests)[:4]:
        phrase = _clean(word)
        if phrase:
            terms.append(f'all:"{phrase}"')
    terms.extend(f"cat:{category}" for category in CATEGORIES)
    return " OR ".join(terms)


def fetch_hf(limit: int, get: Getter | None = None) -> list[Paper]:
    reader = get or _get
    try:
        return parse_hf(reader(HF_API.format(limit=max(1, min(limit, 100)))))
    except httpx.HTTPError as error:
        raise PaperSourceError(f"HF request failed: {error}") from error


def fetch_arxiv(
    interests: Sequence[str], max_results: int, get: Getter | None = None
) -> list[Paper]:
    reader = get or _get
    query = quote(arxiv_query(interests), safe="")
    try:
        return parse_arxiv(
            reader(ARXIV_API.format(query=query, max_results=max(1, min(max_results, 100))))
        )
    except httpx.HTTPError as error:
        raise PaperSourceError(f"arXiv request failed: {error}") from error
