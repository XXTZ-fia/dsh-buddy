"""抓取器共用的值对象与小工具。

热榜条目统一成 {title,url,extra,image,time}：
- title 必填且非空，否则整条丢掉；
- url 必填，App 点击后第一跳就是它；
- extra 放热度/分数/评论数这类一行字，App 直接显示；
- time 放 ISO 时间，没有就留空串。
"""

from __future__ import annotations

from datetime import UTC, datetime

from radar.hot.fetch import FetchError

Headers = dict[str, str]
Item = dict[str, str]

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
)
BILI: Headers = {"Referer": "https://www.bilibili.com/"}
WSCN: Headers = {"Referer": "https://wallstreetcn.com/"}
CLS: Headers = {"Referer": "https://www.cls.cn/"}


def item(title: str, url: str, extra: str = "", image: str = "", time: str = "") -> Item:
    return {"title": title.strip(), "url": url, "extra": extra, "image": image, "time": time}


def heat(value: object) -> str:
    """把 12345678 变成「1234.6万」；非数字返回空串。"""
    try:
        number = float(str(value))
    except (TypeError, ValueError):
        return ""
    if number >= 100_000_000:
        return f"{number / 100_000_000:.1f}亿"
    if number >= 10_000:
        return f"{number / 10_000:.1f}万"
    return f"{int(number)}" if number else ""


def iso(epoch: object) -> str:
    """秒级时间戳 → ISO；兼容毫秒（大于 1e11 的按毫秒算）。"""
    try:
        number = int(str(epoch))
    except (TypeError, ValueError):
        return ""
    if number > 100_000_000_000:
        number //= 1000
    try:
        return (
            datetime.fromtimestamp(number, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        )
    except (OSError, OverflowError, ValueError):
        return ""


def keep(items: list[Item], limit: int) -> list[Item]:
    """去掉缺标题/缺链接的空壳；整份榜单为空时抛错，让上层记 unavailable。"""
    seen: set[str] = set()
    kept: list[Item] = []
    for row in items:
        title = row["title"].strip()
        link = row["url"].strip()
        if not title or not link or title in seen:
            continue
        seen.add(title)
        row["title"], row["url"] = title, link
        kept.append(row)
    if not kept:
        raise FetchError("空榜单")
    return kept[:limit]
