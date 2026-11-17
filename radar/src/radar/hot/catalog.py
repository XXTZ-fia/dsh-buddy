"""热榜源目录：与 newsnow.world 可见来源一致，剔除其内部 redirect 别名。

只描述「有哪些源、怎么显示、点开落在哪个 App」，不含抓取逻辑。
加一个源 = 这里加一行 + providers 里可选地加一个原生抓取器。
"""

from __future__ import annotations

from dataclasses import dataclass

# 栏目顺序即 App 里的分组顺序（国内 → 国际 → 财经 → 科技 → 体育）。
COLUMNS: tuple[tuple[str, str], ...] = (
    ("china", "国内"),
    ("world", "国际"),
    ("finance", "财经"),
    ("tech", "科技"),
    ("sports", "体育"),
)


@dataclass(frozen=True)
class HotSource:
    id: str
    name: str
    title: str  # 副标题，空串表示不显示
    column: str
    home: str
    scheme: str  # Android 深链，空串表示没有可信的 App 入口


# (id, 名称, 副标题, 栏目, 官网, App 深链)
_TABLE: tuple[tuple[str, str, str, str, str, str], ...] = (
    ("zhihu", "知乎", "", "china", "https://www.zhihu.com", "zhihu://"),
    ("weibo", "微博", "实时热搜", "china", "https://weibo.com", "sinaweibo://"),
    ("douyin", "抖音", "", "china", "https://www.douyin.com", "snssdk1128://"),
    ("tieba", "百度贴吧", "热议", "china", "https://tieba.baidu.com", "com.baidu.tieba://"),
    ("toutiao", "今日头条", "", "china", "https://www.toutiao.com", "snssdk143://"),
    ("thepaper", "澎湃新闻", "热榜", "china", "https://www.thepaper.cn", "thepaper://"),
    (
        "bilibili-hot-search",
        "哔哩哔哩",
        "热搜",
        "china",
        "https://www.bilibili.com",
        "bilibili://",
    ),
    (
        "bilibili-hot-video",
        "哔哩哔哩",
        "热门视频",
        "china",
        "https://www.bilibili.com",
        "bilibili://",
    ),
    (
        "bilibili-ranking",
        "哔哩哔哩",
        "排行榜",
        "china",
        "https://www.bilibili.com",
        "bilibili://",
    ),
    ("kuaishou", "快手", "", "china", "https://www.kuaishou.com", "kwai://"),
    ("baidu", "百度热搜", "", "china", "https://www.baidu.com", "baiduboxapp://"),
    ("nowcoder", "牛客", "", "china", "https://www.nowcoder.com", "nowcoder://"),
    ("ifeng", "凤凰网", "热点资讯", "china", "https://www.ifeng.com", "ifengapp://"),
    (
        "chongbuluo-latest",
        "虫部落",
        "最新",
        "china",
        "https://www.chongbuluo.com/forum.php?mod=guide&view=newthread",
        "",
    ),
    (
        "chongbuluo-hot",
        "虫部落",
        "最热",
        "china",
        "https://www.chongbuluo.com/forum.php?mod=guide&view=hot",
        "",
    ),
    ("douban", "豆瓣", "热门电影", "china", "https://www.douban.com", "douban://"),
    (
        "tencent-hot",
        "腾讯新闻",
        "综合早报",
        "china",
        "https://news.qq.com/tag/aEWqxLtdgmQ=",
        "qqnews://",
    ),
    ("iqiyi-hot-ranklist", "爱奇艺", "热播榜", "china", "https://www.iqiyi.com", "iqiyi://"),
    ("zaobao", "联合早报", "", "world", "https://www.zaobao.com", ""),
    ("sputniknewscn", "卫星通讯社", "", "world", "https://sputniknews.cn", ""),
    ("cankaoxiaoxi", "参考消息", "", "world", "https://china.cankaoxiaoxi.com", ""),
    ("steam", "Steam", "在线人数", "world", "https://store.steampowered.com", "steam://"),
    ("mktnews-flash", "MKTNews", "快讯", "finance", "https://mktnews.net", ""),
    (
        "wallstreetcn-quick",
        "华尔街见闻",
        "快讯",
        "finance",
        "https://wallstreetcn.com/",
        "",
    ),
    (
        "wallstreetcn-news",
        "华尔街见闻",
        "最新",
        "finance",
        "https://wallstreetcn.com/",
        "",
    ),
    (
        "wallstreetcn-hot",
        "华尔街见闻",
        "最热",
        "finance",
        "https://wallstreetcn.com/",
        "",
    ),
    ("cls-telegraph", "财联社", "电报", "finance", "https://www.cls.cn", ""),
    ("cls-depth", "财联社", "深度", "finance", "https://www.cls.cn", ""),
    ("cls-hot", "财联社", "热门", "finance", "https://www.cls.cn", ""),
    ("xueqiu-hotstock", "雪球", "热门股票", "finance", "https://xueqiu.com", "xueqiu://"),
    ("gelonghui", "格隆汇", "事件", "finance", "https://www.gelonghui.com", ""),
    ("fastbull-express", "法布财经", "快讯", "finance", "https://www.fastbull.cn", ""),
    ("fastbull-news", "法布财经", "头条", "finance", "https://www.fastbull.cn", ""),
    ("jin10", "金十数据", "", "finance", "https://www.jin10.com", "jin10://"),
    ("v2ex-share", "V2EX", "最新分享", "tech", "https://v2ex.com/", ""),
    ("36kr-quick", "36氪", "快讯", "tech", "https://36kr.com", ""),
    ("36kr-renqi", "36氪", "人气榜", "tech", "https://36kr.com", ""),
    ("aihot", "AIHOT", "快讯", "tech", "https://aihot.news/all", ""),
    ("ithome", "IT之家", "快讯", "tech", "https://www.ithome.com", "ithome://"),
    ("solidot", "Solidot", "", "tech", "https://solidot.org", ""),
    ("hackernews", "Hacker News", "", "tech", "https://news.ycombinator.com/", ""),
    ("producthunt", "Product Hunt", "", "tech", "https://www.producthunt.com/", ""),
    ("github-trending-today", "Github", "Today", "tech", "https://github.com/", ""),
    ("sspai", "少数派", "热榜", "tech", "https://sspai.com", "sspai://"),
    ("juejin", "稀土掘金", "热榜", "tech", "https://juejin.cn", "juejin://"),
    ("hupu", "虎扑", "主干道热帖", "sports", "https://hupu.com", "hupu://"),
    ("dongqiudi", "懂球帝", "头条", "sports", "https://www.dongqiudi.com", "dongqiudi://"),
)

SOURCES: tuple[HotSource, ...] = tuple(HotSource(*row) for row in _TABLE)
BY_ID: dict[str, HotSource] = {source.id: source for source in SOURCES}

# 同一 App 的多个榜单共用一个图标/主色，App 侧按 名称+栏目 归组。
CHINESE_COLUMN = dict(COLUMNS)


def resolve(source_id: str) -> HotSource | None:
    return BY_ID.get(source_id)


def catalog() -> list[dict[str, str]]:
    return [
        {
            "id": source.id,
            "name": source.name,
            "title": source.title,
            "column": source.column,
            "column_label": CHINESE_COLUMN[source.column],
            "home": source.home,
            "scheme": source.scheme,
        }
        for source in SOURCES
    ]
