"""财经站点的热榜抓取器（财联社、华尔街见闻、金十、雪球、36 氪……）。

财联社的接口需要 md5(sha1(排序后的 query)) 当 sign，算错会返回「签名错误」，
所以这里把签名收敛在 `_cls` 里，其余函数只关心路径与字段。
"""

from __future__ import annotations

import hashlib
import re
from urllib.parse import quote

from radar.hot.fetch import FetchError, get_json, get_text, post_json, rows, text
from radar.hot.parse import between, strip_tags
from radar.hot.providers.common import CLS, WSCN, Item, heat, iso, item, keep

WSCN_API = "https://api-one.wallstcn.com/apiv1/content"


def _cls(path: str, params: dict[str, str]) -> object:
    query = "&".join(f"{key}={params[key]}" for key in sorted(params))
    sign = hashlib.md5(hashlib.sha1(query.encode()).hexdigest().encode()).hexdigest()
    return get_json(f"https://www.cls.cn{path}?{query}&sign={sign}", CLS)


def cls_telegraph(limit: int) -> list[Item]:
    data = _cls(
        "/v1/roll/get_roll_list", {"app": "CailianpressWeb", "os": "web", "sv": "8.4.6", "rn": "40"}
    )
    out = [
        item(
            text(entry, "title") or text(entry, "content"),
            f"https://www.cls.cn/detail/{text(entry, 'id')}",
            f"{heat(text(entry, 'reading_num'))} 阅读" if text(entry, "reading_num") else "",
            text(entry, "share_img") or text(entry, "image"),
            iso(text(entry, "ctime")),
        )
        for entry in rows(data, "data", "roll_data")
    ]
    return keep(out, limit)


def cls_hot(limit: int) -> list[Item]:
    data = _cls("/v2/article/hot/list", {"app": "CailianpressWeb", "os": "web", "sv": "8.4.6"})
    out = [
        item(
            text(entry, "title"),
            f"https://www.cls.cn/detail/{text(entry, 'id')}",
            f"{heat(text(entry, 'reading_num'))} 阅读" if text(entry, "reading_num") else "",
            text(entry, "img"),
        )
        for entry in rows(data, "data")
    ]
    return keep(out, limit)


def cls_depth(limit: int) -> list[Item]:
    data = _cls(
        "/v3/depth/home/assembled/1000", {"app": "CailianpressWeb", "os": "web", "sv": "8.4.6"}
    )
    out = [
        item(
            text(entry, "title"),
            f"https://www.cls.cn/detail/{text(entry, 'id')}",
            text(entry, "brief"),
            text(entry, "image"),
            iso(text(entry, "ctime")),
        )
        for entry in rows(data, "data", "depth_list")
    ]
    return keep(out, limit)


def _wscn_lives(limit: int) -> list[Item]:
    data = get_json(f"{WSCN_API}/lives?channel=global-channel&limit=30", WSCN)
    out = [
        item(
            text(entry, "content_text") or text(entry, "title"),
            text(entry, "uri") or f"https://wallstreetcn.com/livenews/{text(entry, 'id')}",
            "",
            "",
            iso(text(entry, "display_time")),
        )
        for entry in rows(data, "data", "items")
    ]
    return keep(out, limit)


def wallstreetcn_quick(limit: int) -> list[Item]:
    return _wscn_lives(limit)


def wallstreetcn_news(limit: int) -> list[Item]:
    data = get_json(f"{WSCN_API}/articles?channel=global&limit=20&accept=article", WSCN)
    out = [
        item(
            text(entry, "title") or text(entry, "content_short"),
            text(entry, "uri") or f"https://wallstreetcn.com/articles/{text(entry, 'id')}",
            "",
            "",
            iso(text(entry, "display_time")),
        )
        for entry in rows(data, "data", "items")
    ]
    return keep(out, limit)


def wallstreetcn_hot(limit: int) -> list[Item]:
    data = get_json(f"{WSCN_API}/articles/hot?period=all", WSCN)
    out = [
        item(
            text(entry, "title"),
            text(entry, "uri") or f"https://wallstreetcn.com/articles/{text(entry, 'id')}",
            heat(text(entry, "pageviews")),
            "",
            iso(text(entry, "display_time")),
        )
        for entry in rows(data, "data", "day_items")
    ]
    return keep(out, limit)


FASTBULL_HOME = "https://www.fastbull.com"
FASTBULL_HEADERS: dict[str, str] = {"Referer": "https://www.fastbull.com/cn/"}


def _fastbull_chunks(html: str, marker: str) -> list[str]:
    """按条目起始标签把整页 HTML 切块——站点没有公开 JSON，只能读页面。"""
    return re.split(marker, html)[1:]


def fastbull_express(limit: int) -> list[Item]:
    """法布财经快讯：每块 div.news-list 里 title_name 是标题、data-href 是详情页。"""
    html = get_text(f"{FASTBULL_HOME}/cn/express-news", FASTBULL_HEADERS)
    if 'class="news-list' not in html:
        # 机房 IP 偶尔会被判成爬虫，返回 accessDenied 页；此时如实报错走缓存。
        raise FetchError("法布财经返回了拦截页")
    out: list[Item] = []
    for chunk in _fastbull_chunks(html, r'(?=<div class="news-list\b)'):
        title = between(r'<span class="title_name">(.*?)</span>', chunk)
        href = between(r'data-href="(/cn/fastshort/[^"]+)"', chunk)
        stamp = between(r'data-date="(\d+)"', chunk)
        if not title or not href:
            continue
        out.append(
            item(
                strip_tags(title[0]),
                FASTBULL_HOME + href[0],
                "",
                "",
                iso(stamp[0] if stamp else ""),
            )
        )
    return keep(out, limit)


def fastbull_news(limit: int) -> list[Item]:
    """法布财经头条：每块 a.trending_type 里 h4.title 是标题，时间在 span.new_time。"""
    html = get_text(f"{FASTBULL_HOME}/cn/news", FASTBULL_HEADERS)
    if "trending_type" not in html:
        raise FetchError("法布财经返回了拦截页")
    out: list[Item] = []
    for chunk in _fastbull_chunks(html, r'(?=<a [^>]*class="[^"]*trending_type)'):
        href = between(r'href="(/cn/news-detail/[^"]+)"', chunk)
        title = between(r'<h4 class="title[^"]*">(.*?)</h4>', chunk)
        stamp = between(r'data-date="(\d+)"', chunk)
        cover = between(r'<img src="([^"]+)"', chunk)
        if not title or not href:
            continue
        out.append(
            item(
                strip_tags(title[0]),
                FASTBULL_HOME + href[0],
                "",
                cover[0] if cover else "",
                iso(stamp[0] if stamp else ""),
            )
        )
    return keep(out, limit)


def jin10(limit: int) -> list[Item]:
    data = get_json(
        "https://flash-api.jin10.com/get_flash_list?channel=-8200&vip=1",
        {"x-app-id": "bVBF4FyRTn5NJF5n", "x-version": "1.0.0", "Referer": "https://www.jin10.com/"},
    )
    out = [
        item(
            text(entry, "data", "content"),
            f"https://flash.jin10.com/detail/{text(entry, 'id')}",
            "重要" if text(entry, "important") == "1" else "",
            text(entry, "data", "pic"),
        )
        for entry in rows(data, "data")
    ]
    return keep(out, limit)


def mktnews_flash(limit: int) -> list[Item]:
    """快讯只有正文：有【标题】就用方括号里的，否则截断正文当标题。"""
    data = get_json("https://api.mktnews.net/api/flash")
    out: list[Item] = []
    for entry in rows(data, "data"):
        body = text(entry, "data", "content").strip()
        if not body:
            continue
        headline = text(entry, "data", "title").strip()
        if not headline and body.startswith("【") and "】" in body:
            headline, body = body[1:].split("】", 1)
        title = headline or body
        out.append(
            item(
                title if len(title) <= 90 else title[:88] + "…",
                f"https://mktnews.net/flash#{text(entry, 'id')}",
                "重要" if text(entry, "important") == "1" else "",
                "",
                text(entry, "time"),
            )
        )
    return keep(out, limit)


def xueqiu_hotstock(limit: int) -> list[Item]:
    data = get_json(
        "https://stock.xueqiu.com/v5/stock/hot_stock/list.json?size=30&_type=10&type=10",
        {"Referer": "https://xueqiu.com/hq"},
        home="https://xueqiu.com/",
    )
    out = [
        item(
            text(entry, "name") or text(entry, "code"),
            f"https://xueqiu.com/S/{text(entry, 'code')}",
            f"{heat(text(entry, 'value'))} 人气",
        )
        for entry in rows(data, "data", "items")
    ]
    return keep(out, limit)


def gelonghui(limit: int) -> list[Item]:
    """格隆汇首页把热门文章排在 <h2> 里，链接在标题上方，所以按标题回溯最近的 /p/ 链接。"""
    page = get_text("https://www.gelonghui.com/", {"Referer": "https://www.gelonghui.com/"})
    out: list[Item] = []
    for match in re.finditer(r"<h2[^>]*>(.{4,90}?)</h2>", page, re.S):
        title = strip_tags(match.group(1))
        window = page[max(0, match.start() - 1200) : match.start()]
        links = re.findall(r"/p/(\d+)\.html", window)
        if not links or not title:
            continue
        out.append(item(title, f"https://www.gelonghui.com/p/{links[-1]}.html"))
    return keep(out, limit)


def _36kr(path: str, body: dict[str, object], limit: int, *, newsflash: bool) -> list[Item]:
    data = post_json(
        f"https://gateway.36kr.com/api/mis/nav/{path}",
        body,
        {"Referer": "https://36kr.com/"},
    )
    listing = rows(data, "data", "itemList" if newsflash else "hotRankList")
    out: list[Item] = []
    for entry in listing:
        material = entry.get("templateMaterial") if isinstance(entry, dict) else None
        if not isinstance(material, dict):
            continue
        title = str(material.get("widgetTitle") or "").strip()
        slug = "newsflashes" if newsflash else "p"
        out.append(
            item(
                title,
                f"https://36kr.com/{slug}/{text(entry, 'itemId')}",
                "",
                str(material.get("widgetImage") or ""),
                iso(material.get("publishTime")),
            )
        )
    return keep(out, limit)


def kr_quick(limit: int) -> list[Item]:
    return _36kr(
        "newsflash/flow",
        {
            "partner_id": "wap",
            "param": {
                "siteId": 1,
                "platformId": 2,
                "pageSize": 30,
                "pageEvent": 0,
                "pageCallback": "",
            },
            "timestamp": 0,
        },
        limit,
        newsflash=True,
    )


def kr_renqi(limit: int) -> list[Item]:
    return _36kr(
        "home/nav/rank/hot",
        {"partner_id": "wap", "param": {"siteId": 1, "platformId": 2}, "timestamp": 0},
        limit,
        newsflash=False,
    )


def search_link(keyword: str) -> str:
    return f"https://www.baidu.com/s?wd={quote(keyword)}"
