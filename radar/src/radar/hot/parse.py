"""HTML / RSS 的轻量抽取：只用标准库，不引第三方解析器。

热榜站点里一半没有公开 JSON，只能读页面。这里提供两个够用的工具：
`between` 抓一段正则、`feed` 把 RSS/Atom 转成条目。规则写在各 provider 里，
解析失败一律当成「没有数据」，由上层降级，不做猜测。
"""

from __future__ import annotations

import html
import re
from typing import Any
from xml.etree import ElementTree

TAG_RE = re.compile(r"<[^>]+>")


def strip_tags(value: str) -> str:
    return html.unescape(TAG_RE.sub("", value)).strip()


def between(pattern: str, text: str, *, flags: int = re.S) -> list[Any]:
    """正则批量抽取。单捕获组时每项是 str，多捕获组时是 tuple——由调用方的正则决定。"""
    return re.findall(pattern, text, flags)


def _child(node: ElementTree.Element, name: str) -> ElementTree.Element | None:
    """按标签本地名找子节点：Atom 的 entry 带默认命名空间，find("title") 会落空。"""
    for child in node:
        if child.tag.rsplit("}", 1)[-1] == name:
            return child
    return None


def _text(node: ElementTree.Element, *names: str) -> str:
    for name in names:
        found = _child(node, name)
        if found is not None and (found.text or "").strip():
            return (found.text or "").strip()
    return ""


def feed(xml_text: str) -> list[tuple[str, str, str]]:
    """RSS 2.0 / Atom → [(title, link, published)]，保持文档顺序。"""
    try:
        root = ElementTree.fromstring(xml_text)
    except ElementTree.ParseError as exc:
        raise ValueError("不是合法 XML") from exc
    out: list[tuple[str, str, str]] = []
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1]
        if tag not in ("item", "entry"):
            continue
        title = _text(node, "title")
        link = _text(node, "link")
        if not link:
            for child in node:
                if child.tag.rsplit("}", 1)[-1] == "link" and child.get("href"):
                    link = child.get("href", "")
                    break
        published = _text(node, "pubDate", "published", "updated", "dc:date")
        if title and link:
            out.append((strip_tags(title), link, published))
    return out
