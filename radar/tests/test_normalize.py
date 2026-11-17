"""纯函数层离线测试：时间、热度、id、RT 过滤、打分与跨平台合并。"""

from __future__ import annotations

import re
from datetime import UTC, datetime

from radar.models import ID_PATTERN, RawItem
from radar.normalize import (
    baseline_of,
    cluster,
    cross_platform_for,
    cross_platform_in_groups,
    heat_delta,
    heat_value,
    is_pure_repost,
    make_id,
    normalize_all,
    parse_published,
    parse_x_time,
    ranked_groups,
    same_event,
    score,
    select_top,
    to_candidate,
    to_radar_item,
)

NOW = datetime(2026, 11, 11, 8, 30, tzinfo=UTC)


def raw(title: str, platform: str = "weibo", heat: str = "100", **kwargs: object) -> RawItem:
    values = {
        "platform": platform,
        "native_id": title,
        "title": title,
        "url": f"https://example.invalid/{platform}",
        "author": "",
        "published_at_raw": "",
        "snippet": "",
        "heat_raw": heat,
        "lang": "zh",
        "is_repost": False,
    }
    values.update(kwargs)
    return RawItem(**values)  # type: ignore[arg-type]


def test_x_time_is_utc_not_local() -> None:
    parsed = parse_x_time("Tue Nov 10 23:12:00 +0000 2026")
    assert parsed.isoformat() == "2026-11-10T23:12:00+00:00"
    assert parsed.utcoffset().total_seconds() == 0
    assert parse_published("Tue Nov 10 23:12:00 +0000 2026", NOW).hour == 23


def test_parse_published_formats() -> None:
    assert parse_published("", NOW) == NOW
    assert parse_published("2026-11-11T07:00:00Z", NOW).hour == 7
    assert parse_published("2026-11-11T07:00:00", NOW).tzinfo == UTC
    assert parse_published("1762800000", NOW).tzinfo == UTC
    assert parse_published("3 hours ago", NOW) == NOW.replace(hour=5)
    assert parse_published("无法解析", NOW) == NOW


def test_heat_value_and_delta() -> None:
    assert heat_value("1234 likes") == 1234
    assert heat_value("512 万热度") == 5120000
    assert heat_value("1.2万") == 12000
    assert heat_value("2亿") == 200000000
    assert heat_value("无数据") == 0
    assert heat_delta(12, 10) == "+2"
    assert heat_delta(10, 12) == "-2"
    assert heat_delta(10, 10) == "+0"


def test_make_id_stable_and_safe() -> None:
    first = make_id("weibo", "开源Agent框架发布新版本")
    assert first == make_id("weibo", "开源Agent框架发布新版本")
    assert first != make_id("weibo", "开源Agent框架新版")
    assert re.fullmatch(ID_PATTERN, first)
    assert make_id("x", "1849201234567890123") == "x:1849201234567890123"


def test_pure_repost_filtered_in_normalization() -> None:
    repost = raw("RT @someone", platform="x", is_repost=True, snippet="")
    ordinary = raw("普通推文", platform="x", snippet="内容")
    assert is_pure_repost(repost)
    assert not is_pure_repost(ordinary)
    assert len(normalize_all((repost, ordinary), NOW)) == 1


def test_score_prefers_interest_words() -> None:
    hit = to_candidate(raw("开源Agent框架发布新版本", heat="100"), NOW)
    miss = to_candidate(raw("今日份晚霞", heat="1000"), NOW)
    ranked = score((miss, hit), ("Agent",), NOW)
    assert ranked[0].id == hit.id


def test_cluster_and_cross_platform() -> None:
    items = (
        to_candidate(raw("开源Agent框架发布新版本", "weibo", "500"), NOW),
        to_candidate(raw("开源Agent框架发布新版本", "douyin", "900"), NOW),
        to_candidate(raw("周末露营装备清单", "xhs", "50"), NOW),
    )
    assert same_event(items[0].title, items[1].title)
    assert not same_event(items[0].title, items[2].title)
    groups = cluster(items)
    assert len(groups) == 2
    assert cross_platform_for(groups[0][0], items) == ("douyin", "weibo")


def test_ranked_groups_match_actual_merge() -> None:
    # 回归：cross_platform 必须来自 select_top 用的同一批簇，不能串到相邻事件。
    items = (
        to_candidate(raw("开源Agent框架发布新版本", "weibo", "500"), NOW),
        to_candidate(raw("开源Agent框架发布新版本", "douyin", "900"), NOW),
        to_candidate(raw("周末露营装备清单", "xhs", "50"), NOW),
    )
    groups = ranked_groups(items, ("Agent",), NOW)
    for leader in select_top(items, ("Agent",), NOW, 5):
        cross = cross_platform_in_groups(leader, groups)
        matching = [group for group in groups if any(m.id == leader.id for m in group)]
        assert matching
        assert cross == tuple(sorted({m.platform for m in matching[0]}))
    ghost = to_candidate(raw("孤立事件", "x", "1"), NOW)
    assert cross_platform_in_groups(ghost, groups) == ("x",)


def test_select_top_limit_and_radar_item() -> None:
    titles = (
        "开源Agent框架发布新版本",
        "具身智能数据集开放下载",
        "城市夜跑路线推荐",
        "周末做菜三道家常菜",
        "机器人跑马拉松",
        "今日份晚霞",
        "通勤时间安排",
        "咖啡冲煮比例",
    )
    items = tuple(
        to_candidate(raw(title, "weibo" if index % 2 else "bili", str(index * 10)), NOW)
        for index, title in enumerate(titles)
    )
    top = select_top(items, ("AI",), NOW, 5)
    assert len(top) == 5
    baseline = baseline_of(top)
    radar = to_radar_item(top[0], "中文摘要", "中文理由", ("bili", "weibo"), baseline)
    assert radar.published_at.endswith("Z")
    assert radar.summary == "中文摘要"
    assert radar.heat.delta.startswith(("+", "-"))
    assert radar.cross_platform == ("bili", "weibo")


def test_baseline_of() -> None:
    assert baseline_of(()) == 0
    assert baseline_of((to_candidate(raw("a", heat="10"), NOW),)) == 10


def test_naive_timestamps_are_read_as_beijing_time() -> None:
    """中文源给的 "2026-11-17 19:00:00" 是北京时间，按 UTC 解释会早 8 小时。"""
    now = datetime(2026, 11, 17, 12, 0, tzinfo=UTC)
    assert parse_published("2026-11-17 19:00:00", now) == datetime(2026, 11, 17, 11, 0, tzinfo=UTC)


def test_future_timestamps_are_clamped_to_now() -> None:
    """源站写错年份时不该拿到额外新鲜度（旧实现会给 78 而不是 48 的上限）。"""
    now = datetime(2026, 11, 17, 12, 0, tzinfo=UTC)
    assert parse_published("2027-11-17T12:00:00Z", now) == now
    future = to_candidate(raw("a", heat="10", published_at_raw="2027-11-17T12:00:00Z"), now)
    assert future.published_at == now


def test_cluster_keeps_the_first_group_that_matches() -> None:
    """合并语义不能因为缓存 gram 而改变：先匹配到的簇优先。"""
    a = to_candidate(raw("苹果发布新款手机"), NOW)
    b = to_candidate(raw("苹果发布新款手机 详情"), NOW)
    groups = cluster((a, b))
    assert [len(group) for group in groups] == [2]


def test_select_top_keeps_one_platform_from_taking_everything() -> None:
    """抖音热度是千万级：纯按分数取前 5，线上简报 20 条里 19 条来自抖音。"""
    # 标题必须互不相似，否则会被 same_event 合并成同一个簇（那是另一件事）。
    douyin = (
        "某地发布人工智能监管新规",
        "新能源汽车补贴退坡",
        "演唱会门票开售三分钟售罄",
        "城市马拉松报名通道开启",
        "台风路径最新预报",
    )
    items = tuple(
        to_candidate(raw(title, "douyin", str(9000000 - index * 100000)), NOW)
        for index, title in enumerate(douyin)
    ) + tuple(
        to_candidate(raw(title, platform, str(3000000 - index * 100000)), NOW)
        for platform, titles in (
            ("weibo", ("高校食堂价格调整", "防汛应急响应升级")),
            ("bili", ("开源模型发布新版本", "独立游戏销量破百万")),
        )
        for index, title in enumerate(titles)
    )
    top = select_top(items, (), NOW, 5)
    assert len(top) == 5
    platforms = [item.platform for item in top]
    assert set(platforms) == {"douyin", "weibo", "bili"}
    # 5 个名额、3 个平台 → 每平台配额 2，抖音只能拿到 2 条。
    assert platforms.count("douyin") == 2
    # 配额只决定谁能进来，输出仍按分数从高到低。
    assert [item.heat for item in top] == sorted((item.heat for item in top), reverse=True)


def test_select_top_still_fills_the_slot_when_platforms_are_few() -> None:
    """只有两个平台时不硬套配额，否则会白留空位。"""
    titles = (
        "芯片出口新规",
        "暑期档票房破纪录",
        "地铁新线开通",
        "高校毕业典礼",
        "外卖骑手社保",
        "景区限流公告",
    )
    items = tuple(
        to_candidate(raw(title, "weibo" if index % 2 else "bili", str(1000 - index * 10)), NOW)
        for index, title in enumerate(titles)
    )
    assert len(select_top(items, (), NOW, 5)) == 5
