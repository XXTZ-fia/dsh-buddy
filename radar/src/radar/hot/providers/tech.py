"""科技/开发者站点的热榜抓取器（V2EX、IT 之家、少数派、掘金、HN……）。

RSS 站点（Solidot、Product Hunt）用 parse.feed 解析，不额外引解析库。
"""

from __future__ import annotations

from urllib.parse import quote

from radar.hot.fetch import get_json, get_text, post_json, rows, text
from radar.hot.parse import between, feed, strip_tags
from radar.hot.providers.common import Item, heat, iso, item, keep

GITHUB = {"Accept": "application/vnd.github+json", "Referer": "https://github.com/"}


def v2ex_share(limit: int) -> list[Item]:
    data = get_json("https://www.v2ex.com/api/topics/latest.json")
    out = [
        item(text(entry, "title"), text(entry, "url"), f"{text(entry, 'replies')} 回复")
        for entry in data
    ]
    return keep(out, limit)


def ithome(limit: int) -> list[Item]:
    data = get_json("https://api.ithome.com/json/newslist/news")
    out = [
        item(
            text(entry, "title"),
            "https://www.ithome.com" + text(entry, "url"),
            text(entry, "description"),
            text(entry, "image"),
        )
        for entry in rows(data, "newslist")
    ]
    return keep(out, limit)


def sspai(limit: int) -> list[Item]:
    data = get_json("https://sspai.com/api/v1/article/index/page/get?limit=30&offset=0")
    out = [
        item(
            text(entry, "title"),
            f"https://sspai.com/post/{text(entry, 'id')}",
            text(entry, "summary"),
            text(entry, "banner") and f"https://cdn.sspai.com/{text(entry, 'banner')}",
        )
        for entry in rows(data, "data")
    ]
    return keep(out, limit)


def github_trending(limit: int) -> list[Item]:
    data = get_json(
        "https://api.github.com/search/repositories"
        "?q=created:%3E2026-10-01&sort=stars&order=desc&per_page=30",
        GITHUB,
    )
    out = [
        item(
            text(entry, "full_name"),
            text(entry, "html_url"),
            f"{heat(text(entry, 'stargazers_count'))} stars",
            text(entry, "owner", "avatar_url"),
        )
        for entry in rows(data, "items")
    ]
    return keep(out, limit)


def solidot(limit: int) -> list[Item]:
    xml = get_text("https://www.solidot.org/index.rss", {"Referer": "https://www.solidot.org/"})
    out = [item(title, link, "", "", published) for title, link, published in feed(xml)]
    return keep(out, limit)


def producthunt(limit: int) -> list[Item]:
    xml = get_text("https://www.producthunt.com/feed", {"Referer": "https://www.producthunt.com/"})
    out = [item(title, link, "", "", published) for title, link, published in feed(xml)]
    return keep(out, limit)


def hackernews(limit: int) -> list[Item]:
    """Algolia 一次就能拿到首页前 30 名，避免逐条打 Firebase。"""
    data = get_json("https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30")
    out = [
        item(
            text(entry, "title"),
            text(entry, "url") or f"https://news.ycombinator.com/item?id={text(entry, 'objectID')}",
            f"{text(entry, 'points')} 分",
            "",
            text(entry, "created_at"),
        )
        for entry in rows(data, "hits")
    ]
    return keep(out, limit)


def juejin(limit: int) -> list[Item]:
    data = post_json(
        "https://api.juejin.cn/recommend_api/v1/article/recommend_all_feed",
        {"id_type": 2, "client_type": 2608, "cursor": "0", "limit": 30, "sort_type": 200},
        {"Referer": "https://juejin.cn/"},
    )
    out: list[Item] = []
    for entry in rows(data, "data"):
        info = entry.get("item_info") if isinstance(entry, dict) else None
        if not isinstance(info, dict):
            continue
        body = info.get("article_info") if isinstance(info.get("article_info"), dict) else {}
        article = text(body, "article_id")
        if not article:
            continue
        views = text(body, "view_count")
        out.append(
            item(
                text(body, "title"),
                f"https://juejin.cn/post/{article}",
                f"{heat(views)} 阅读" if views else "",
                text(body, "cover_image"),
                iso(text(body, "ctime")),
            )
        )
    return keep(out, limit)


def aihot(limit: int) -> list[Item]:
    page = get_text("https://aihot.news/", {"Referer": "https://aihot.news/"})
    found = between(r'href="(/items/[a-z0-9]+)"[^>]*>(.{8,120}?)<', page)
    out = [
        item(strip_tags(title), f"https://aihot.news{path}")
        for path, title in found
        if not title.strip().startswith("<")
    ]
    return keep(out, limit)


def douyin_search(keyword: str) -> str:
    return f"https://www.douyin.com/search/{quote(keyword)}"
