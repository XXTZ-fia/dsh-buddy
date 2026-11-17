"""热榜抓取的 HTTP 边界：统一 UA/超时/体积上限，失败抛 FetchError。

热榜接口都是 JSON，不走浏览器；这里只做一次 GET/POST 和结构校验，
把网络/解析异常收敛成 FetchError，让上层决定降级到中继还是返回旧缓存。
"""

from __future__ import annotations

import json
from typing import Any

import httpx

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
MAX_BYTES = 3_000_000


class FetchError(Exception):
    """单个源抓取失败：网络、状态码或结构不符，都可以换下一个通道。"""


def _client() -> httpx.Client:
    return httpx.Client(
        timeout=httpx.Timeout(9.0, connect=6.0),
        follow_redirects=True,
        headers={"User-Agent": UA, "Accept": "application/json, text/plain, */*"},
    )


def get_json(url: str, headers: dict[str, str] | None = None, *, home: str | None = None) -> Any:
    """[home] 用于需要先拿一枚站点 cookie 的接口（抖音的 __ac_nonce 等）。"""
    try:
        with _client() as client:
            if home:
                client.get(home)
            resp = client.get(url, headers=headers or {})
    except httpx.HTTPError as exc:
        raise FetchError(f"网络失败: {type(exc).__name__}") from exc
    return _parse(resp)


def get_text(url: str, headers: dict[str, str] | None = None) -> str:
    """HTML / RSS 站点用；调用方自己决定怎么解析。"""
    try:
        with _client() as client:
            resp = client.get(url, headers=headers or {})
    except httpx.HTTPError as exc:
        raise FetchError(f"网络失败: {type(exc).__name__}") from exc
    if resp.status_code != 200:
        raise FetchError(f"HTTP {resp.status_code}")
    if len(resp.content) > MAX_BYTES:
        raise FetchError("响应过大")
    return resp.text


def post_json(
    url: str,
    payload: Any,
    headers: dict[str, str] | None = None,
    *,
    home: str | None = None,
) -> Any:
    try:
        with _client() as client:
            if home:
                client.get(home)
            resp = client.post(url, json=payload, headers=headers or {})
    except httpx.HTTPError as exc:
        raise FetchError(f"网络失败: {type(exc).__name__}") from exc
    return _parse(resp)


def _parse(resp: httpx.Response) -> Any:
    if resp.status_code != 200:
        raise FetchError(f"HTTP {resp.status_code}")
    if len(resp.content) > MAX_BYTES:
        raise FetchError("响应过大")
    try:
        return resp.json()
    except (ValueError, json.JSONDecodeError) as exc:
        raise FetchError("响应不是 JSON") from exc


def pick(node: Any, *path: str | int) -> Any:
    """按路径取嵌套字段；任一节点缺失就抛 FetchError（结构变了要看见）。"""
    current = node
    for step in path:
        try:
            current = current[step]
        except (KeyError, IndexError, TypeError) as exc:
            raise FetchError(f"缺少字段 {step}") from exc
    return current


def rows(node: Any, *path: str | int) -> list[Any]:
    value = pick(node, *path)
    if not isinstance(value, list):
        raise FetchError("期望数组")
    return value


def text(node: Any, *path: str | int, default: str = "") -> str:
    current = node
    for step in path:
        if isinstance(current, dict):
            current = current.get(step)
        elif (
            isinstance(current, list)
            and isinstance(step, int)
            and -len(current) <= step < len(current)
        ):
            current = current[step]
        else:
            return default
        if current is None:
            return default
    if isinstance(current, (int, float)):
        return str(int(current))
    return current if isinstance(current, str) else default
