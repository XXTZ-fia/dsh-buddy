"""唯一持有 Playwright 持久化上下文的模块；每平台一个 profile 目录。"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from playwright.sync_api import BrowserContext, sync_playwright

from radar.config import Config
from radar.models import PLATFORMS

LOGIN_URLS: dict[str, str] = {
    "weibo": "https://weibo.com/",
    "bili": "https://www.bilibili.com/",
    "zhihu": "https://www.zhihu.com/",
    "douyin": "https://www.douyin.com/",
    "xhs": "https://www.xiaohongshu.com/",
    "x": "https://x.com/i/flow/login",
}


@contextmanager
def open_context(cfg: Config, platform: str) -> Iterator[BrowserContext]:
    if platform not in PLATFORMS:
        raise ValueError(f"未知平台 {platform}")
    profile = cfg.profiles_dir / platform
    profile.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as pw:
        ctx = pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=True,
            locale="zh-CN",
        )
        try:
            yield ctx
        finally:
            ctx.close()


def open_login(cfg: Config, platform: str) -> None:
    """首次扫码：有头浏览器打开平台首页，用户自行登录，回车后 profile 落盘。"""
    if platform not in PLATFORMS:
        raise ValueError(f"未知平台 {platform}")
    profile = cfg.profiles_dir / platform
    profile.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as pw:
        ctx = pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=False,
            locale="zh-CN",
        )
        page = ctx.new_page()
        page.goto(LOGIN_URLS[platform], wait_until="domcontentloaded")
        print(f"请在浏览器里登录 {platform}，完成后回到终端按回车。")
        input()
        ctx.close()
