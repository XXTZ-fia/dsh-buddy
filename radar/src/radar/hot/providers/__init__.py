"""热榜抓取器注册表：一个源 id 对应一个直连实现。

新增来源 = catalog 里加一行 + 这里挂一个函数。没有实现的源不会出现在
PROVIDERS 里，服务层会直接把它标成 unavailable，不伪造条目。
"""

from __future__ import annotations

from collections.abc import Callable

from radar.hot.providers import china, finance, tech, world
from radar.hot.providers.common import Item

Fetcher = Callable[[int], list[Item]]

PROVIDERS: dict[str, Fetcher] = {
    # 国内
    "baidu": china.baidu,
    "nowcoder": china.nowcoder,
    "bilibili-hot-search": china.bilibili_hot_search,
    "bilibili-hot-video": china.bilibili_hot_video,
    "bilibili-ranking": china.bilibili_ranking,
    "zhihu": china.zhihu,
    "weibo": china.weibo,
    "douyin": china.douyin,
    "tieba": china.tieba,
    "kuaishou": china.kuaishou,
    "toutiao": china.toutiao,
    "thepaper": china.thepaper,
    "ifeng": china.ifeng,
    "chongbuluo-hot": china.chongbuluo_hot,
    "chongbuluo-latest": china.chongbuluo_latest,
    "douban": china.douban,
    "tencent-hot": china.tencent_hot,
    "iqiyi-hot-ranklist": china.iqiyi,
    "hupu": china.hupu,
    "dongqiudi": china.dongqiudi,
    # 财经
    "cls-telegraph": finance.cls_telegraph,
    "cls-hot": finance.cls_hot,
    "cls-depth": finance.cls_depth,
    "wallstreetcn-quick": finance.wallstreetcn_quick,
    "wallstreetcn-news": finance.wallstreetcn_news,
    "wallstreetcn-hot": finance.wallstreetcn_hot,
    "jin10": finance.jin10,
    "fastbull-express": finance.fastbull_express,
    "fastbull-news": finance.fastbull_news,
    "mktnews-flash": finance.mktnews_flash,
    "xueqiu-hotstock": finance.xueqiu_hotstock,
    "gelonghui": finance.gelonghui,
    "36kr-quick": finance.kr_quick,
    "36kr-renqi": finance.kr_renqi,
    # 科技
    "v2ex-share": tech.v2ex_share,
    "ithome": tech.ithome,
    "sspai": tech.sspai,
    "github-trending-today": tech.github_trending,
    "solidot": tech.solidot,
    "producthunt": tech.producthunt,
    "hackernews": tech.hackernews,
    "juejin": tech.juejin,
    "aihot": tech.aihot,
    # 国际
    "sputniknewscn": world.sputniknewscn,
    "cankaoxiaoxi": world.cankaoxiaoxi,
    "zaobao": world.zaobao,
    "steam": world.steam,
}


def native_ids() -> tuple[str, ...]:
    return tuple(PROVIDERS)


__all__ = ["PROVIDERS", "Fetcher", "native_ids"]
