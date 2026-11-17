"""国际/海外站点的热榜抓取器（卫星通讯社、参考消息、Steam 在线人数榜）。"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone

from radar.hot.fetch import FetchError, get_json, get_text, rows, text
from radar.hot.parse import between, feed, strip_tags
from radar.hot.providers.common import Item, heat, item, keep

CANKAO_CHANNELS = ("zhongguo", "guandian", "gj")
BEIJING = timezone(timedelta(hours=8))


def _beijing_iso(value: str) -> str:
    """参考消息给的是「2026-11-15 15:36:27」北京时间，转成 ISO UTC。"""
    try:
        stamp = datetime.strptime(value.strip(), "%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING)
    except (AttributeError, ValueError):
        return ""
    return stamp.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def zaobao(limit: int) -> list[Item]:
    """联合早报即时新闻：页面是服务端渲染的卡片列表，aria-label 就是标题。

    同一条有两个 <a>（图片位 + 标题位）指向同一篇，按链接去重。
    """
    html = get_text("https://www.zaobao.com/realtime/china", {"Referer": "https://www.zaobao.com/"})
    found = between(r'aria-label="([^"]{6,200})"[^>]*href="(/[^"]*story\d{8}-\d+)"', html)
    if not found:
        raise FetchError("联合早报页面结构变了")
    seen: dict[str, str] = {}
    for title, path in found:
        seen.setdefault(path, strip_tags(title))
    out = [item(title, f"https://www.zaobao.com{path}") for path, title in seen.items()]
    return keep(out, limit)


def cankaoxiaoxi(limit: int) -> list[Item]:
    """参考消息：中国/观点/国际三个频道各有一份 JSON，合并后按发布时间倒序。

    单个频道挂了只丢那一段，不让整张榜变 unavailable。
    """
    out: list[Item] = []
    for channel in CANKAO_CHANNELS:
        try:
            data = get_json(f"https://china.cankaoxiaoxi.com/json/channel/{channel}/list.json")
        except Exception:  # noqa: BLE001 - 单频道失败降级为少一段
            continue
        for entry in rows(data, "list"):
            published = text(entry, "data", "publishTime")
            out.append(
                item(
                    text(entry, "data", "title"),
                    text(entry, "data", "url"),
                    published[5:16] if published else "",
                    text(entry, "data", "indexPic") or text(entry, "data", "channelCoverImgs"),
                    _beijing_iso(published),
                )
            )
    out.sort(key=lambda row: row["time"], reverse=True)
    return keep(out, limit)


STEAM_API = "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/"
_STEAM_NAMES: dict[int, tuple[str, float]] = {}
_STEAM_NAME_TTL_S = 6 * 3600


def sputniknewscn(limit: int) -> list[Item]:
    xml = get_text(
        "https://sputniknews.cn/export/rss2/archive/index.xml",
        {"Referer": "https://sputniknews.cn/"},
    )
    out = [item(title, link, "", "", published) for title, link, published in feed(xml)]
    return keep(out, limit)


def _steam_name(appid: int) -> str:
    """Steam 榜单只给 appid；名字按 6 小时缓存在进程里，冷启动才多打几次。"""
    cached = _STEAM_NAMES.get(appid)
    if cached and time.time() - cached[1] < _STEAM_NAME_TTL_S:
        return cached[0]
    try:
        data = get_json(
            f"https://store.steampowered.com/api/appdetails?appids={appid}&filters=basic",
            {"Referer": "https://store.steampowered.com/"},
        )
    except Exception:  # noqa: BLE001 - 单个名字失败不该让整张榜消失
        return cached[0] if cached else ""
    entry = data.get(str(appid)) if isinstance(data, dict) else None
    name = ""
    if isinstance(entry, dict) and entry.get("success"):
        body = entry.get("data")
        if isinstance(body, dict):
            name = str(body.get("name") or "")
    if name:
        _STEAM_NAMES[appid] = (name, time.time())
    return name


def steam(limit: int) -> list[Item]:
    data = get_json(STEAM_API)
    ranks = data.get("response", {}).get("ranks") if isinstance(data, dict) else None
    if not isinstance(ranks, list) or not ranks:
        raise ValueError("Steam 榜单为空")
    picked: list[tuple[int, int]] = []
    for entry in ranks[: min(limit + 6, 40)]:
        if not isinstance(entry, dict):
            continue
        try:
            picked.append((int(entry["appid"]), int(entry.get("peak_in_game") or 0)))
        except (KeyError, TypeError, ValueError):
            continue
    with ThreadPoolExecutor(max_workers=6) as pool:
        names = list(pool.map(lambda pair: _steam_name(pair[0]), picked))
    out = [
        item(
            name,
            f"https://store.steampowered.com/app/{appid}/",
            f"峰值 {heat(peak)}" if peak else "",
            f"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/header.jpg",
        )
        for (appid, peak), name in zip(picked, names, strict=True)
        if name
    ]
    return keep(out, limit)
