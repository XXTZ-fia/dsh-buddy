"""唯一读取配置与环境变量的地方；其余模块只能通过参数拿到 Config。"""

from __future__ import annotations

import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
MODEL_KEY_ENV = "RADAR_MODEL_API_KEY"
BEARER_ENV = "RADAR_BEARER_TOKEN"

# Cookie 只能发给这些 host：外发到模型/图床/CDN 时一律不带（§2 Cookie 外发禁令）。
COOKIE_HOSTS: dict[str, tuple[str, ...]] = {
    "weibo": ("weibo.com", "s.weibo.com"),
    "bili": ("api.bilibili.com", "www.bilibili.com"),
    "zhihu": ("www.zhihu.com", "api.zhihu.com"),
    "douyin": ("www.douyin.com",),
    "xhs": ("www.xiaohongshu.com", "edith.xiaohongshu.com"),
    "x": ("x.com", "api.x.com"),
}
FORBIDDEN_KEYS = ("api_key", "cookie", "token", "password", "sessdata")

# 知乎热榜只认这套客户端 UA，其余平台用 http.DEFAULT_UA。
PLATFORM_UA: dict[str, str] = {
    "zhihu": (
        "osee2unifiedRelease/22916 osee2unifiedReleaseVersion/10.49.0 "
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    ),
}


@dataclass(frozen=True)
class Env:
    model_api_key: str
    bearer_token: str


def read_env() -> Env:
    """只在 CLI 入口调用一次；程序其它位置不再触碰 os.environ。"""
    return Env(os.environ.get(MODEL_KEY_ENV, ""), os.environ.get(BEARER_ENV, ""))


def with_model_key(cfg: Config, key: str) -> Config:
    """App 随请求带来的模型 Key：只覆盖这一次调用，不落盘、不进日志。

    服务端自己配了 `RADAR_MODEL_API_KEY` 时优先用服务端的——手机换了、卸载了，
    服务端的翻译与洞察也不该跟着断。Key 形状先粗筛一遍，避免把噪声当凭证发出去。
    """
    candidate = (key or "").strip()
    if cfg.env.model_api_key or not _looks_like_key(candidate):
        return cfg
    return replace(cfg, env=Env(candidate, cfg.env.bearer_token))


def _looks_like_key(value: str) -> bool:
    return 12 <= len(value) <= 200 and all(33 <= ord(char) <= 126 for char in value)


@dataclass(frozen=True)
class Config:
    root: Path
    outbox_path: Path
    db_path: Path
    fixtures_dir: Path
    profiles_dir: Path
    secrets_dir: Path
    log_level: str
    model_base_url: str
    model_name: str
    interests: tuple[str, ...]
    min_interval_ms: int
    jitter_ms: int
    per_source_limit: int
    timeout_s: float
    backoff_minutes: tuple[int, ...]
    snapshot_size: int
    max_items: int
    env: Env


def _section(data: dict[str, Any], key: str) -> dict[str, Any]:
    value = data.get(key, {})
    if not isinstance(value, dict):
        raise ValueError(f"配置段 {key} 必须是映射")
    return value


def _forbidden_field(value: Any, path: str = "") -> str | None:
    """递归找凭证字段：只看顶层会漏掉 `paths.token` 这类嵌套写法。"""
    if isinstance(value, dict):
        for key, item in value.items():
            name = str(key).lower()
            if name in FORBIDDEN_KEYS:
                return f"{path}{key}"
            found = _forbidden_field(item, f"{path}{key}.")
            if found is not None:
                return found
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found = _forbidden_field(item, f"{path}[{index}].")
            if found is not None:
                return found
    return None


def load(config_path: Path | None, env: Env) -> Config:
    path = config_path or ROOT / "config.yaml"
    if not path.exists():
        path = ROOT / "config.example.yaml"
    data: dict[str, Any] = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    # 配置里出现凭证字段就拒绝启动，避免用户把 Key 抄进可能被提交的文件。
    forbidden = _forbidden_field(data)
    if forbidden is not None:
        raise ValueError(f"配置中不得出现凭证字段（{forbidden}），请使用环境变量或浏览器 profile")
    paths = _section(data, "paths")
    limits = _section(data, "limits")
    raw_interests = data.get("interests", [])
    if not isinstance(raw_interests, list) or any(
        not isinstance(word, str) for word in raw_interests
    ):
        raise ValueError("配置段 interests 必须是字符串数组")
    interests = tuple(word.strip() for word in raw_interests if word.strip())
    return Config(
        root=ROOT,
        outbox_path=ROOT / str(paths.get("outbox", "outbox/radar.json")),
        db_path=ROOT / str(paths.get("db", "outbox/seen.db")),
        fixtures_dir=ROOT / str(paths.get("fixtures", "fixtures")),
        profiles_dir=ROOT / str(paths.get("profiles", "browser_profiles")),
        secrets_dir=ROOT / str(paths.get("secrets", "secrets")),
        log_level=str(data.get("log_level", "INFO")),
        model_base_url=str(data.get("model_base_url", "")),
        model_name=str(data.get("model_name", "")),
        interests=interests,
        min_interval_ms=int(limits.get("min_interval_ms", 600)),
        jitter_ms=int(limits.get("jitter_ms", 250)),
        per_source_limit=int(limits.get("per_source_limit", 20)),
        timeout_s=float(limits.get("timeout_s", 12)),
        backoff_minutes=tuple(int(v) for v in limits.get("backoff_minutes", (5, 10, 20, 30))),
        snapshot_size=int(limits.get("snapshot_size", 50)),
        max_items=int(limits.get("max_items", 5)),
        env=env,
    )


def with_paths(cfg: Config, outbox_path: Path, db_path: Path) -> Config:
    """dry-run 改写到临时目录，避免污染真实 outbox 与 seen 表。"""
    return replace(cfg, outbox_path=outbox_path, db_path=db_path)
