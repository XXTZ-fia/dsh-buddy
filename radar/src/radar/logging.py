"""结构化单行日志；所有输出先过凭证脱敏再落盘。"""

from __future__ import annotations

import json
import logging
import re
import sys
from datetime import UTC, datetime
from typing import Any

_PAIRS = re.compile(
    r"(?i)\b(SESSDATA|bili_jct|buvid3|auth_token|ct0|web_session|webId|a1|api_key|password)"
    r"(\s*[=:]\s*|\"\s*:\s*\"|'\s*:\s*')([^\s,;&\"'}]+)"
)
_BEARER = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")
_COOKIE_HEADER = re.compile(r"(?i)\bCookie\s*:\s*[^\r\n,}]+")


def redact(text: str) -> str:
    """纯函数：字段名保留、值替换；测试用假凭证验证，绝不打印真实值。"""
    text = _BEARER.sub("Bearer ***", text)
    text = _PAIRS.sub(lambda m: f"{m.group(1)}{m.group(2)}***", text)
    return _COOKIE_HEADER.sub("Cookie: ***", text)


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname.lower(),
            "event": record.getMessage(),
            "platform": getattr(record, "platform", ""),
            "count": getattr(record, "count", 0),
            "ms": getattr(record, "ms", 0),
        }
        note = getattr(record, "note", "")
        if note:
            payload["note"] = note
        return redact(json.dumps(payload, ensure_ascii=False))


def configure(level: str) -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(_JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.INFO))


def emit(
    level: str, event: str, *, platform: str = "", count: int = 0, ms: int = 0, note: str = ""
) -> None:
    logging.getLogger("radar").log(
        getattr(logging, level.upper(), logging.INFO),
        event,
        extra={"platform": platform, "count": count, "ms": ms, "note": note},
    )
