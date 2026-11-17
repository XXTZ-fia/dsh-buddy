"""首次导入 Cookie：校验 → 原子规范化 → 注入浏览器 profile，全程不回显值。"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from playwright.sync_api import BrowserContext

from radar.config import COOKIE_HOSTS

_NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
_CONTROL = re.compile(r"[\r\n\x00-\x1f\x7f]")
_MAX = 8192


class CredentialError(Exception):
    """凭证输入不合法或写入失败；旧文件必须保持不变。"""


@dataclass(frozen=True)
class Cookie:
    name: str
    value: str


@dataclass(frozen=True)
class CookieBundle:
    platform: str
    cookies: tuple[Cookie, ...]


@dataclass(frozen=True)
class ImportReceipt:
    path: Path
    count: int
    platform: str


def parse_cookie(raw: str, platform: str) -> CookieBundle:
    """拒绝 CRLF / 控制字符，防 header injection；格式错误时不返回任何值。"""
    if len(raw) > _MAX or _CONTROL.search(raw):
        raise CredentialError("Cookie 串含控制字符或过长")
    cookies: list[Cookie] = []
    for part in raw.split(";"):
        if not part.strip():
            continue
        name, _, value = part.strip().partition("=")
        if not _NAME.fullmatch(name) or not value or len(value) > _MAX:
            raise CredentialError("Cookie 串格式无效")
        cookies.append(Cookie(name, value))
    if not cookies:
        raise CredentialError("Cookie 串为空")
    return CookieBundle(platform, tuple(cookies))


def protect_file(path: Path) -> None:
    """收紧权限：Windows 只授予当前 SID，其它平台 chmod 600。"""
    if os.name != "nt":
        os.chmod(path, 0o600)
        return
    # 中文 Windows 的 whoami/icacls 输出使用本地代码页（GBK）；按字节读取，
    # 避免 UTF-8 mode 下 subprocess 的文本解码抛 UnicodeDecodeError。SID 恒为 ASCII。
    who = subprocess.run(
        ["whoami", "/user", "/fo", "csv", "/nh"],
        capture_output=True,
        timeout=10,
        check=True,
    )
    match = re.search(rb"S-1-\d+(?:-\d+)+", who.stdout)
    if match is None:
        raise CredentialError("无法确认当前 Windows 用户")
    sid = match.group(0).decode("ascii")
    subprocess.run(
        ["icacls", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(F)", "/Q"],
        capture_output=True,
        timeout=10,
        check=True,
    )


def atomic_secret_write(path: Path, text: str) -> None:
    """单一写入器：空文件先收紧权限，再写 → fsync → replace；失败保留旧文件。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        protect_file(temp)
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(temp, path)
    except OSError as exc:
        temp.unlink(missing_ok=True)
        raise CredentialError("凭证写入失败，旧文件未变动") from exc


def apply_cookies(ctx: BrowserContext, bundle: CookieBundle) -> int:
    """Cookie 只作为 profile 的输入；注入后不另存副本（D3）。"""
    host = COOKIE_HOSTS[bundle.platform][0]
    ctx.add_cookies(
        [{"name": c.name, "value": c.value, "url": f"https://{host}"} for c in bundle.cookies]
    )
    return len(bundle.cookies)


def import_cookie_file(path: Path, platform: str, ctx: BrowserContext) -> ImportReceipt:
    """读取用户自行写入的 Cookie 串文件，规范化后原子重写，再注入持久化上下文。"""
    raw = path.read_text(encoding="utf-8")
    bundle = parse_cookie(raw, platform)
    normalized = "; ".join(f"{c.name}={c.value}" for c in bundle.cookies)
    atomic_secret_write(path, normalized)
    count = apply_cookies(ctx, bundle)
    return ImportReceipt(path, count, platform)
