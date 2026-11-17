"""唯一写 radar.json 的地方：原子写、无新增不重写、契约校验。"""

from __future__ import annotations

import json
import os
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from radar.credentials import protect_file
from radar.images import normalize_image
from radar.models import (
    ID_PATTERN,
    PLATFORMS,
    SCHEMA_VERSION,
    SNAPSHOT_SIZE,
    RadarDocument,
    RadarItem,
)


@dataclass(frozen=True)
class VerifyResult:
    ok: bool
    errors: tuple[str, ...]


def item_to_dict(item: RadarItem) -> dict[str, Any]:
    return {
        "id": item.id,
        "platform": item.platform,
        "title": item.title,
        "summary": item.summary,
        "why": item.why,
        "url": item.url,
        "author": item.author,
        "lang": item.lang,
        "published_at": item.published_at,
        "heat": {"value": item.heat.value, "delta": item.heat.delta},
        "cross_platform": list(item.cross_platform),
        "image": item.image,
    }


def to_dict(doc: RadarDocument) -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "generated_at": doc.generated_at,
        "health": [
            {"platform": h.platform, "status": h.status, "checked_at": h.checked_at, "note": h.note}
            for h in doc.health
        ],
        "items": [item_to_dict(item) for item in doc.items],
    }


def atomic_write(path: Path, text: str) -> None:
    """临时文件 → 收紧权限 → fsync → os.replace；半截文件永远不会对外可见。

    临时名带随机后缀：进程被强杀留下的 `<name>.<pid>.tmp` 不会让下一次写入
    以 FileExistsError 永久失败（PID 会被复用）。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        # 随机后缀撞车的概率可以忽略；真撞上就换一个再试一次。
        temp = path.with_name(f"{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            protect_file(temp)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def write_document(path: Path, doc: RadarDocument, has_new: bool) -> bool:
    """没有新增内容时不重写文件，App 据此判断「无事发生」不弹通知。"""
    if not has_new:
        return False
    atomic_write(path, json.dumps(to_dict(doc), ensure_ascii=False, indent=2) + "\n")
    return True


def _parse_time(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


STATUSES: tuple[str, ...] = ("ok", "auth_expired", "rate_limited", "unavailable")


def _item_errors(index: int, item: dict[str, Any], ids: set[str]) -> list[str]:
    prefix = f"items[{index}]"
    item_id = str(item.get("id") or "")
    published = str(item.get("published_at") or "")
    heat = item.get("heat")
    image = item.get("image")
    checks = (
        (not re.fullmatch(ID_PATTERN, item_id) or item_id in ids, "id 格式错误或重复"),
        (item.get("platform") not in PLATFORMS, "platform 不在枚举内"),
        (not re.search(r"[\u4e00-\u9fff]", str(item.get("summary") or "")), "summary 不是中文"),
        (
            not published.endswith(("Z", "+00:00")) or _parse_time(published) is None,
            "published_at 不是 UTC ISO8601",
        ),
        (not (isinstance(heat, dict) and isinstance(heat.get("value"), int)), "heat 结构错误"),
        (not isinstance(item.get("cross_platform"), list), "cross_platform 不是数组"),
        (
            image is not None
            and (not isinstance(image, str) or (bool(image) and normalize_image(image) != image)),
            "image 不是白名单 CDN 外链",
        ),
    )
    return [f"{prefix}.{label}" for bad, label in checks if bad]


def verify(path: Path, now: datetime) -> VerifyResult:
    """纯读取校验：schema / 条数 / id / 时间戳新鲜度 / 语种 / health。"""
    errors: list[str] = []
    if not path.exists():
        return VerifyResult(False, ("文件不存在",))
    try:
        doc: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return VerifyResult(False, ("radar.json 不是合法 JSON",))
    if doc.get("schema") != SCHEMA_VERSION:
        errors.append("schema 版本号不符")
    generated = _parse_time(str(doc.get("generated_at") or ""))
    if generated is None or abs((now - generated).total_seconds()) > 86400:
        errors.append("generated_at 缺失或超过 24 小时")
    items = doc.get("items")
    if not isinstance(items, list):
        return VerifyResult(False, (*errors, "items 不是数组"))
    if len(items) > SNAPSHOT_SIZE:
        errors.append(f"items 超过 {SNAPSHOT_SIZE} 条")
    ids: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            errors.append(f"items[{index}] 不是对象")
            continue
        errors.extend(_item_errors(index, item, ids))
        ids.add(str(item.get("id") or ""))
    health = doc.get("health")
    if not isinstance(health, list) or len(health) > len(PLATFORMS):
        errors.append("health 结构错误")
    elif any(not isinstance(h, dict) or h.get("status") not in STATUSES for h in health):
        errors.append("health 状态非法")
    return VerifyResult(not errors, tuple(errors))
