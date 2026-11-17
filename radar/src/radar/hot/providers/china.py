"""国内站点的热榜抓取器（知乎、微博、抖音、贴吧、B 站……）。

每条规则都对着站点当前真实返回写死字段路径；站点改版时这些函数会抛
FetchError，页面结构变了也只会让这一个源显示「暂不可用」，不影响其它源。
"""

from __future__ import annotations

import os
from urllib.parse import quote

from radar.hot.fetch import FetchError, get_json, get_text, post_json, rows, text
from radar.hot.parse import between, strip_tags
from radar.hot.providers.common import (
    BILI,
    Item,
    heat,
    iso,
    item,
    keep,
)


def baidu(limit: int) -> list[Item]:
    data = get_json("https://top.baidu.com/api/board?platform=wise&tab=realtime")
    out = [
        item(
            text(entry, "word"),
            text(entry, "url") or f"https://www.baidu.com/s?wd={quote(text(entry, 'word'))}",
            heat(text(entry, "hotScore")),
            text(entry, "img"),
        )
        for entry in rows(data, "data", "cards", 0, "content", 0, "content")
    ]
    return keep(out, limit)


def bilibili_hot_search(limit: int) -> list[Item]:
    data = get_json("https://api.bilibili.com/x/web-interface/search/square?limit=30", BILI)
    out = [
        item(
            text(entry, "show_name") or text(entry, "keyword"),
            f"https://search.bilibili.com/all?keyword={quote(text(entry, 'keyword'))}",
            heat(text(entry, "heat_score")),
            text(entry, "icon"),
        )
        for entry in rows(data, "data", "trending", "list")
    ]
    return keep(out, limit)


def bilibili_hot_video(limit: int) -> list[Item]:
    data = get_json("https://api.bilibili.com/x/web-interface/popular?ps=30&pn=1", BILI)
    out = [
        item(
            text(entry, "title"),
            f"https://www.bilibili.com/video/{text(entry, 'bvid')}",
            heat(text(entry, "stat", "view")),
            text(entry, "pic"),
            iso(text(entry, "pubdate")),
        )
        for entry in rows(data, "data", "list")
    ]
    return keep(out, limit)


def bilibili_ranking(limit: int) -> list[Item]:
    data = get_json("https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all", BILI)
    out = [
        item(
            text(entry, "title"),
            f"https://www.bilibili.com/video/{text(entry, 'bvid')}",
            heat(text(entry, "stat", "view")),
            text(entry, "pic"),
            iso(text(entry, "pubdate")),
        )
        for entry in rows(data, "data", "list")
    ]
    return keep(out, limit)


def nowcoder(limit: int) -> list[Item]:
    """牛客热榜：接口里混着讨论帖、老帖和广告位，只有前两种能拼出链接。

    type=74 是新版讨论帖（路径用 uuid），type=0 是旧版帖子（路径用 id），
    其余 type（广告、专题）直接跳过，不猜路径。
    """
    data = get_json("https://gw-c.nowcoder.com/api/sparta/hot-search/top-hot-pc?size=20")
    out: list[Item] = []
    for entry in rows(data, "data", "result"):
        kind = text(entry, "type")
        if kind == "74":
            link = f"https://www.nowcoder.com/feed/main/detail/{text(entry, 'uuid')}"
        elif kind == "0":
            link = f"https://www.nowcoder.com/discuss/{text(entry, 'id')}"
        else:
            continue
        out.append(item(text(entry, "title"), link, heat(text(entry, "hotValueFromDolphin"))))
    return keep(out, limit)


def zhihu(limit: int) -> list[Item]:
    """知乎对机房 IP 会要求验证；有登录态 cookie 才能读到，没有就如实报错。"""
    cookie = os.environ.get("RADAR_ZHIHU_COOKIE", "").strip()
    if not cookie:
        raise FetchError("知乎需要 RADAR_ZHIHU_COOKIE")
    data = get_json(
        "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=50&desktop=true",
        {"Referer": "https://www.zhihu.com/hot", "Cookie": cookie},
    )
    out = [
        item(
            text(entry, "target", "title"),
            f"https://www.zhihu.com/question/{text(entry, 'target', 'id')}",
            text(entry, "detail_text"),
            text(entry, "children", 0, "thumbnail"),
        )
        for entry in rows(data, "data")
    ]
    return keep(out, limit)


def weibo(limit: int) -> list[Item]:
    data = get_json("https://weibo.com/ajax/side/hotSearch", {"Referer": "https://weibo.com/"})
    out: list[Item] = []
    for entry in rows(data, "data", "realtime"):
        if text(entry, "is_ad"):
            continue
        word = text(entry, "word_scheme") or text(entry, "word")
        out.append(
            item(
                text(entry, "note") or text(entry, "word"),
                f"https://s.weibo.com/weibo?q={quote(word)}",
                heat(text(entry, "num")),
                "",
            )
        )
    return keep(out, limit)


def douyin(limit: int) -> list[Item]:
    data = get_json(
        "https://www.douyin.com/aweme/v1/web/hot/search/list/"
        "?device_platform=webapp&aid=6383&channel=channel_pc_web&detail_list=1",
        {"Referer": "https://www.douyin.com/hot"},
        home="https://www.douyin.com/",
    )
    out = [
        item(
            text(entry, "word"),
            f"https://www.douyin.com/hot/{text(entry, 'sentence_id')}",
            heat(text(entry, "hot_value")),
            text(entry, "word_cover", "url_list", 0),
        )
        for entry in rows(data, "data", "word_list")
    ]
    return keep(out, limit)


def tieba(limit: int) -> list[Item]:
    page = get_text(
        "https://tieba.baidu.com/hottopic/browse/topicList?res_type=1",
        {"Referer": "https://tieba.baidu.com/"},
    )
    out: list[Item] = []
    for block in page.split('<div class="topic-info">')[1:]:
        found = between(r'topic_id=(\d+)[^"]*"[^>]*class="topic-text"[^>]*>(.+?)</a>', block)
        if not found:
            continue
        topic_id, title = found[0]
        score = between(r'class="topic-num">(.+?)</span>', block)
        out.append(
            item(
                strip_tags(title),
                f"https://tieba.baidu.com/hottopic/browse/hottopic?topic_id={topic_id}",
                strip_tags(score[0][0]) if score else "",
            )
        )
    return keep(out, limit)


def kuaishou(limit: int) -> list[Item]:
    payload = {
        "operationName": "visionHotRank",
        "variables": {"page": "home"},
        "query": (
            "query visionHotRank($page: String) {"
            ' visionHotRank(page: $page, webPageArea: "brilliant") {'
            " items { id name hotValue __typename } __typename } }"
        ),
    }
    data = post_json("https://www.kuaishou.com/graphql", payload, home="https://www.kuaishou.com/")
    out = [
        item(
            text(entry, "name"),
            f"https://www.kuaishou.com/search/video?searchKey={quote(text(entry, 'name'))}",
            heat(text(entry, "hotValue")),
        )
        for entry in rows(data, "data", "visionHotRank", "items")
    ]
    return keep(out, limit)


def toutiao(limit: int) -> list[Item]:
    data = get_json("https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc")
    out = [
        item(
            text(entry, "Title"),
            text(entry, "Url"),
            heat(text(entry, "HotValue") or text(entry, "HotValueNum")),
            text(entry, "Image", "url"),
        )
        for entry in rows(data, "data")
    ]
    return keep(out, limit)


def thepaper(limit: int) -> list[Item]:
    data = get_json("https://cache.thepaper.cn/contentapi/wwwIndex/rightSidebar")
    out = [
        item(
            text(entry, "name"),
            f"https://www.thepaper.cn/newsDetail_forward_{text(entry, 'contId')}",
            heat(text(entry, "praiseTimes")),
            text(entry, "smallPic") or text(entry, "pic"),
        )
        for entry in rows(data, "data", "hotNews")
    ]
    return keep(out, limit)


def _ifeng_arrays(page: str) -> list[dict[str, str]]:
    """凤凰首页把热榜直接嵌在 script 里（"hotNews1":[…]），按括号配对切出来。"""
    out: list[dict[str, str]] = []
    for marker in ('"hotNews1":', '"hotNews2":', '"hotNews":'):
        start = page.find(marker)
        if start < 0:
            continue
        begin = page.find("[", start)
        depth = 0
        for index in range(begin, len(page)):
            if page[index] == "[":
                depth += 1
            elif page[index] == "]":
                depth -= 1
                if depth == 0:
                    chunk = page[begin : index + 1]
                    out.extend(_ifeng_rows(chunk))
                    break
    return out


def _ifeng_rows(chunk: str) -> list[dict[str, str]]:
    import json

    try:
        data = json.loads(chunk)
    except ValueError:
        return []
    return [row for row in data if isinstance(row, dict)]


def ifeng(limit: int) -> list[Item]:
    page = get_text("https://www.ifeng.com/", {"Referer": "https://www.ifeng.com/"})
    out = [
        item(
            str(row.get("title") or ""),
            str(row.get("url") or ""),
            str(row.get("newsTime") or ""),
            str(row.get("thumbnail") or ""),
        )
        for row in _ifeng_arrays(page)
    ]
    return keep(out, limit)


def _chongbuluo(view: str, limit: int) -> list[Item]:
    page = get_text(
        f"https://www.chongbuluo.com/forum.php?mod=guide&view={view}",
        {"Referer": "https://www.chongbuluo.com/"},
    )
    found = between(r'<a href="thread-(\d+)[^"]*"[^>]*class="xst"[^>]*>(.+?)</a>', page)
    out = [
        item(strip_tags(title), f"https://www.chongbuluo.com/thread-{thread}-1-1.html")
        for thread, title in found
    ]
    return keep(out, limit)


def chongbuluo_hot(limit: int) -> list[Item]:
    return _chongbuluo("hot", limit)


def chongbuluo_latest(limit: int) -> list[Item]:
    return _chongbuluo("newthread", limit)


def douban(limit: int) -> list[Item]:
    data = get_json(
        "https://movie.douban.com/j/search_subjects"
        "?type=movie&tag=%E7%83%AD%E9%97%A8&page_limit=30&page_start=0"
    )
    out = [
        item(
            text(entry, "title"),
            text(entry, "url"),
            f"{text(entry, 'rate')} 分" if text(entry, "rate") else "",
            text(entry, "cover"),
        )
        for entry in rows(data, "subjects")
    ]
    return keep(out, limit)


def tencent_hot(limit: int) -> list[Item]:
    data = get_json("https://r.inews.qq.com/gw/event/hot_ranking_list?page_size=50")
    out: list[Item] = []
    for entry in rows(data, "idlist", 0, "newslist"):
        identifier = text(entry, "id")
        title = text(entry, "title")
        # 榜单头部是产品自身的说明项（「每10分钟更新一次」），不是新闻。
        if not identifier or "每10分钟更新一次" in title:
            continue
        out.append(
            item(
                title,
                f"https://new.qq.com/rain/a/{identifier}",
                "",
                text(entry, "miniProShareImage") or text(entry, "thumbnails_qqnews"),
            )
        )
    return keep(out, limit)


def iqiyi(limit: int) -> list[Item]:
    data = get_json(
        "https://pcw-api.iqiyi.com/search/recommend/list"
        "?channel_id=1&data_type=1&mode=11&page_id=1&ret_num=60",
        {"Referer": "https://www.iqiyi.com/"},
    )
    out = [
        item(
            text(entry, "name"),
            text(entry, "playUrl"),
            text(entry, "channel") or "",
            text(entry, "imageUrl"),
        )
        for entry in rows(data, "data", "list")
    ]
    return keep(out, limit)


def hupu(limit: int) -> list[Item]:
    page = get_text("https://bbs.hupu.com/topic-hot", {"Referer": "https://bbs.hupu.com/"})
    found = between(r'<a href="/(\d+)\.html"[^>]*>(.{6,90}?)</a>', page)
    out = [
        item(strip_tags(title), f"https://bbs.hupu.com/{thread}.html")
        for thread, title in found
        if "更多" not in title
    ]
    return keep(out, limit)


def dongqiudi(limit: int) -> list[Item]:
    data = get_json(
        "https://www.dongqiudi.com/api/app/tabs/web/1.json",
        {"Referer": "https://www.dongqiudi.com/"},
    )
    # is_business_ad 是 JSON 布尔，不能当字符串比较。
    articles = [row for row in rows(data, "articles") if row.get("is_business_ad") is not True]
    out = [
        item(
            text(entry, "title") or text(entry, "share_title"),
            text(entry, "share") or f"https://www.dongqiudi.com/article/{text(entry, 'id')}",
            f"{text(entry, 'comments_total')} 评论" if text(entry, "comments_total") != "0" else "",
            text(entry, "thumb"),
            iso(text(entry, "published_at")),
        )
        for entry in articles
    ]
    return keep(out, limit)
