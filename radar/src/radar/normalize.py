"""纯函数层：归一化、打分、跨平台合并、格式化；时间一律由参数注入。"""

from __future__ import annotations

import hashlib
import math
import re
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

from radar.models import Candidate, Heat, RadarItem, RawItem

_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
_MONTHS = dict(zip(_MON, range(1, 13), strict=True))
_UNITS = {"": 1, "万": 10000, "亿": 100000000}
_GRAM = 4
_SAME_EVENT_RATIO = 0.25
# 中文站点的裸时间戳（"2026-11-17 20:00:00"）是北京时间；按 UTC 解释会早 8 小时。
SOURCE_TZ = ZoneInfo("Asia/Shanghai")
# 未来时间不该拿到额外新鲜度：源站写错年份时会把条目顶到最前。
MAX_FRESH_HOURS = 48.0
Candidates = tuple[Candidate, ...]
Groups = tuple[Candidates, ...]
Words = tuple[str, ...]


def is_pure_repost(raw: RawItem) -> bool:
    return raw.is_repost and not raw.snippet.strip()


def make_id(platform: str, native_id: str) -> str:
    """含中文/特殊字符时整体哈希，避免只保留英文字母导致不同热点词碰撞。"""
    lowered = native_id.lower()
    if re.fullmatch(r"[a-z0-9_-]+", lowered) is None:
        lowered = hashlib.sha1(native_id.encode("utf-8")).hexdigest()[:16]
    return f"{platform}:{lowered}"


def parse_x_time(raw: str) -> datetime:
    """X 的 '%a %b %d %H:%M:%S +0000 %Y' 单独解析；手写月份表避免 locale 依赖。"""
    parts = raw.strip().split()
    if len(parts) != 6 or parts[4] != "+0000" or parts[1] not in _MONTHS:
        raise ValueError("不是 X 时间格式")
    hour, minute, second = (int(v) for v in parts[3].split(":"))
    return datetime(
        int(parts[5]),
        _MONTHS[parts[1]],
        int(parts[2]),
        hour,
        minute,
        second,
        tzinfo=UTC,
    )


def parse_published(raw: str, now: datetime) -> datetime:
    """兼容 ISO8601 / unix 秒 / X 格式 / 相对时间；无法解析时降级为本轮时间。

    无时区的时间串按来源所在地（北京时间）解释，未来时间钳到 `now`——两者都会
    直接把条目推到榜首，宁可保守。
    """
    value = raw.strip()
    if not value:
        return now
    x_time: datetime | None
    try:
        x_time = parse_x_time(value)
    except ValueError:
        x_time = None
    if x_time is not None:
        return _clamp_to_now(x_time, now)
    parsed: datetime | None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        parsed = None
    if parsed is not None:
        return _clamp_to_now(
            parsed.replace(tzinfo=SOURCE_TZ).astimezone(UTC)
            if parsed.tzinfo is None
            else parsed.astimezone(UTC),
            now,
        )
    if value.isdigit():
        return _clamp_to_now(datetime.fromtimestamp(int(value), UTC), now)
    ago = re.match(r"(\d+)\s+(hour|day|minute)s?\s+ago", value, re.I)
    if ago:
        amount = int(ago.group(1))
        unit = {"hour": 3600, "day": 86400, "minute": 60}[ago.group(2).lower()]
        return now - timedelta(seconds=amount * unit)
    return now


def _clamp_to_now(value: datetime, now: datetime) -> datetime:
    """源站写错的未来时间按「刚刚」处理，别让它拿到额外加权。"""
    return now if value > now else value


def heat_value(raw: str) -> int:
    match = re.search(r"(\d+(?:\.\d+)?)\s*([万亿]?)", raw)
    if match is None:
        return 0
    return int(float(match.group(1)) * _UNITS[match.group(2)])


def heat_delta(value: int, baseline: int) -> str:
    diff = value - baseline
    return f"+{diff}" if diff >= 0 else str(diff)


def to_candidate(raw: RawItem, now: datetime) -> Candidate:
    return Candidate(
        id=make_id(raw.platform, raw.native_id),
        platform=raw.platform,
        title=raw.title.strip(),
        url=raw.url,
        author=raw.author,
        snippet=raw.snippet,
        published_at=parse_published(raw.published_at_raw, now),
        heat=heat_value(raw.heat_raw),
        lang=raw.lang,
        is_repost=raw.is_repost,
        image=raw.image,
    )


def normalize_all(raws: tuple[RawItem, ...], now: datetime) -> tuple[Candidate, ...]:
    return tuple(to_candidate(raw, now) for raw in raws if not is_pure_repost(raw))


def score(items: Candidates, kw: Words, now: datetime) -> Candidates:
    def rank(item: Candidate) -> tuple[float, int]:
        # 热度取对数避免单个平台的大数压过其它维度；命中兴趣词加权。
        hit = sum(1 for word in kw if word.lower() in item.title.lower())
        fresh = min(
            MAX_FRESH_HOURS,
            max(0.0, MAX_FRESH_HOURS - (now - item.published_at).total_seconds() / 3600),
        )
        return math.log1p(item.heat) + hit * 3 + fresh / 24, item.heat

    return tuple(sorted(items, key=rank, reverse=True))


def _grams(title: str) -> set[str]:
    text = re.sub(r"[\s\W_]+", "", title.lower(), flags=re.UNICODE)
    return {text[i : i + _GRAM] for i in range(max(0, len(text) - _GRAM + 1))}


def _overlap(left: set[str], right: set[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / min(len(left), len(right))


def same_event(a: str, b: str) -> bool:
    return _overlap(_grams(a), _grams(b)) >= _SAME_EVENT_RATIO


def cluster(items: Candidates) -> Groups:
    """按标题 4-gram 重合度合并成「同一事件」。

    每条的 gram 只算一次：47 源 × 20 条时两两比较是几十万次，重算 gram 会让
    run-once 白白多花近一秒（实测 940 条 781 ms → 现在只算一遍）。
    """
    groups: list[list[Candidate]] = []
    members: list[list[set[str]]] = []
    for item in items:
        grams = _grams(item.title)
        target: int | None = None
        for index, siblings in enumerate(members):
            if any(_overlap(grams, sibling) >= _SAME_EVENT_RATIO for sibling in siblings):
                target = index
                break
        if target is None:
            groups.append([item])
            members.append([grams])
        else:
            groups[target].append(item)
            members[target].append(grams)
    return tuple(tuple(group) for group in groups)


def cross_platform_in_groups(leader: Candidate, groups: Groups) -> tuple[str, ...]:
    """只取所属簇内的平台，避免把相邻事件也算进 cross_platform。"""
    for group in groups:
        if any(member.id == leader.id for member in group):
            return tuple(sorted({member.platform for member in group}))
    return (leader.platform,)


def cross_platform_for(leader: Candidate, items: Candidates) -> tuple[str, ...]:
    return cross_platform_in_groups(leader, cluster(items))


def ranked_groups(items: Candidates, kw: Words, now: datetime) -> Groups:
    """与 select_top 共用同一排序后的分组，保证输出与实际合并一致。"""
    return cluster(score(items, kw, now))


def select_top(
    items: Candidates, kw: Words, now: datetime, max_items: int, *, per_platform: int | None = None
) -> Candidates:
    """按分数取前 N 条，同时限制单个平台的占比。

    抖音的热度是千万级，取对数后仍压过其它站点；纯按分数取前 5，简报会变成
    「抖音 5 条」（线上实测 20 条里 19 条来自抖音）。这里给每个平台一个配额，
    平台不够多时再用超出配额的高分条目补满——宁可少一点多样性，也不留空位。
    """
    groups = ranked_groups(items, kw, now)
    if max_items <= 0 or not groups:
        return ()
    platforms = {group[0].platform for group in groups}
    cap = (
        per_platform if per_platform is not None else max(2, math.ceil(max_items / len(platforms)))
    )
    chosen: list[int] = []
    counts: dict[str, int] = {}
    for index, group in enumerate(groups):
        if len(chosen) >= max_items:
            break
        platform = group[0].platform
        if counts.get(platform, 0) >= cap:
            continue
        chosen.append(index)
        counts[platform] = counts.get(platform, 0) + 1
    if len(chosen) < max_items:
        for index in range(len(groups)):
            if index in chosen:
                continue
            chosen.append(index)
            if len(chosen) >= max_items:
                break
    # 最终仍按排名输出：配额只决定「谁能进来」，不改变先后顺序。
    return tuple(groups[index][0] for index in sorted(chosen))


def to_radar_item(
    item: Candidate, summary: str, why: str, cross: tuple[str, ...], baseline: int
) -> RadarItem:
    return RadarItem(
        id=item.id,
        platform=item.platform,
        title=item.title,
        summary=summary,
        why=why,
        url=item.url,
        author=item.author,
        lang=item.lang,
        published_at=item.published_at.isoformat().replace("+00:00", "Z"),
        heat=Heat(item.heat, heat_delta(item.heat, baseline)),
        cross_platform=cross,
        image=item.image,
    )


def baseline_of(items: Candidates) -> int:
    if not items:
        return 0
    return sum(item.heat for item in items) // len(items)
