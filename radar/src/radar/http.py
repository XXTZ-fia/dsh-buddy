"""统一 UA / Referer / 超时 / Cookie 白名单 / 节流与熔断。"""

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx
from playwright.sync_api import BrowserContext

from radar.config import COOKIE_HOSTS, PLATFORM_UA, Config
from radar.sources.base import AuthExpired, AuthResult, RateLimited, SourceUnavailable

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
)
RISK_CODES = (-352, -799, -509, -10403)
AUTH_CODES = (-101,)
BUSINESS_CODES = (-412,)  # playurl 的大会员/地区限制，不熔断（CHANGELOG v0.4.5）
RATE_STATUS = (412, 429)


@dataclass(frozen=True)
class Message:
    role: str
    content: str


class Throttle:
    """实例由 CLI 创建并显式传参，不是全局单例（F3）。"""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.count = 0
        self.strikes: dict[str, int] = {}
        self.last_at = 0.0
        self.denied_until: dict[str, float] = {}

    def wait(self, platform: str = "") -> None:
        now = time.monotonic()
        if self.denied_until.get(platform, 0) > now:
            raise RateLimited(f"熔断中，剩余 {int(self.denied_until[platform] - now)} 秒")
        gap = self.cfg.min_interval_ms / 1000 + random.uniform(0, self.cfg.jitter_ms / 1000)
        if self.last_at and now - self.last_at < gap:
            time.sleep(gap - (now - self.last_at))
        self.last_at = time.monotonic()
        self.count += 1

    def deny(self, retry_after: str | None, platform: str = "") -> None:
        idx = min(self.strikes.get(platform, 0), len(self.cfg.backoff_minutes) - 1)
        seconds = float(self.cfg.backoff_minutes[idx] * 60)
        # Retry-After 只作为下限，不允许短于平台要求。
        if retry_after and retry_after.isdigit():
            seconds = max(seconds, float(retry_after))
        self.strikes[platform] = self.strikes.get(platform, 0) + 1
        self.denied_until[platform] = time.monotonic() + seconds


def build_headers(platform: str, url: str, cookie: str = "") -> dict[str, str]:
    """只有 host 在白名单内才附加凭证；其它域名只给 UA/Referer。"""
    hosts = COOKIE_HOSTS.get(platform, ())
    headers = {
        "User-Agent": PLATFORM_UA.get(platform, DEFAULT_UA),
        "Referer": (
            "https://www.bilibili.com/"
            if platform == "bili"
            else f"https://{hosts[0]}/"
            if hosts
            else ""
        ),
        "Accept": "application/json, text/plain, */*",
    }
    if cookie and (urlparse(url).hostname or "") in hosts:
        headers["Cookie"] = cookie
    return headers


def extract_code(body: str) -> int | None:
    """解析业务码；非 JSON 响应返回 None 而不是吞掉异常继续乱判。"""
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return None
    code = payload.get("code") if isinstance(payload, dict) else None
    return int(code) if isinstance(code, (int, str)) and str(code).lstrip("-").isdigit() else None


def get_body(ctx: BrowserContext, url: str, platform: str, cfg: Config, throttle: Throttle) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in COOKIE_HOSTS.get(platform, ()):
        raise SourceUnavailable("请求域名不在平台白名单")
    throttle.wait(platform)
    resp = ctx.request.get(
        url,
        headers=build_headers(platform, url),
        timeout=cfg.timeout_s * 1000,
        max_redirects=0,
    )
    if resp.status in (401, 403):
        raise AuthExpired("登录态失效")
    if resp.status in RATE_STATUS:
        throttle.deny(resp.headers.get("retry-after"), platform)
        raise RateLimited(f"HTTP {resp.status}", http_status=resp.status)
    if not resp.ok:
        raise SourceUnavailable(f"HTTP {resp.status}")
    body = resp.text()
    code = extract_code(body)
    if code in RISK_CODES:
        throttle.deny(None, platform)
        raise RateLimited("命中风控码", http_status=resp.status, code=code)
    if code in AUTH_CODES:
        raise AuthExpired("业务码提示未登录")
    if code in BUSINESS_CODES and "playurl" not in url:
        raise SourceUnavailable("业务码 -412")
    return body


def read_dom(
    ctx: BrowserContext, url: str, platform: str, cfg: Config, throttle: Throttle, script: str
) -> str:
    """X/小红书必须在页面上下文内读取，签名与设备指纹交给浏览器（D2/D3）。"""
    throttle.wait(platform)
    page = ctx.new_page()
    try:
        resp = page.goto(url, wait_until="domcontentloaded", timeout=cfg.timeout_s * 1000)
        if resp is None:
            raise SourceUnavailable("页面无响应")
        if resp.status in (401, 403):
            raise AuthExpired("登录态失效")
        if resp.status in RATE_STATUS:
            throttle.deny(None, platform)
            raise RateLimited(f"HTTP {resp.status}", http_status=resp.status)
        if not resp.ok:
            raise SourceUnavailable(f"HTTP {resp.status}")
        selector = {"x": "article[data-testid=tweet]", "xhs": "section.note-item"}[platform]
        page.wait_for_selector(selector, timeout=cfg.timeout_s * 1000)
        body = str(page.evaluate(script))
        if not extract_items_len(body):
            raise SourceUnavailable("页面未返回内容")
        return body
    finally:
        page.close()


def probe(
    ctx: BrowserContext,
    platform: str,
    url: str,
    cfg: Config,
    throttle: Throttle,
    script: str | None = None,
) -> AuthResult:
    """验活只发一次只读请求；异常在这里统一转成状态，不在适配器里吞。"""
    try:
        body = (
            read_dom(ctx, url, platform, cfg, throttle, script)
            if script
            else get_body(ctx, url, platform, cfg, throttle)
        )
    except AuthExpired:
        return AuthResult(platform, "auth_expired", "需要重新扫码")
    except RateLimited:
        return AuthResult(platform, "rate_limited", "按退避时长停止该源")
    except SourceUnavailable:
        return AuthResult(platform, "unavailable", "端点不可用")
    if not body.strip():
        return AuthResult(platform, "unavailable", "空响应")
    if script and not extract_items_len(body):
        return AuthResult(platform, "auth_expired", "空时间线，需要重新扫码")
    return AuthResult(platform, "ok", "")


def extract_items_len(body: str) -> int:
    """纯函数：页面摘要里的条目数，用于识别「空时间线」这类登录态失效。"""
    try:
        rows = json.loads(body).get("items", [])
    except (ValueError, AttributeError):
        return 0
    return len(rows) if isinstance(rows, list) else 0


def post_model(cfg: Config, messages: tuple[Message, ...]) -> str:
    """模型端点不属于任何平台域名，请求头里绝不出现 Cookie 或平台凭证。"""
    if not cfg.env.model_api_key or not cfg.model_base_url:
        raise SourceUnavailable("模型未配置")
    payload = {
        "model": cfg.model_name,
        "messages": [{"role": m.role, "content": m.content} for m in messages],
        "temperature": 0.2,
    }
    try:
        resp = httpx.post(
            cfg.model_base_url,
            headers={
                "Authorization": f"Bearer {cfg.env.model_api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
            timeout=cfg.timeout_s,
        )
    except httpx.HTTPError as exc:
        raise SourceUnavailable("模型请求失败") from exc
    if not resp.is_success:
        raise SourceUnavailable(f"模型 HTTP {resp.status_code}")
    try:
        return str(resp.json()["choices"][0]["message"]["content"])
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise SourceUnavailable("模型响应格式异常") from exc
