"""外链图片：白名单规范化、各源取图、微博补图降级与产物契约。"""

from __future__ import annotations

import json
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest

from radar.config import Env, load
from radar.images import enrich_images, first_weibo_photo, normalize_image
from radar.models import Candidate, Heat, RadarItem
from radar.outbox import item_to_dict, verify
from radar.sources import bilibili, zhihu

CFG = load(None, Env("", ""))
NOW = datetime(2026, 11, 12, 8, 30, tzinfo=UTC)


def _candidate(item_id: str, platform: str = "weibo", image: str = "") -> Candidate:
    return Candidate(
        id=item_id,
        platform=platform,
        title="热搜词",
        url="https://example.invalid/x",
        author="",
        snippet="",
        published_at=NOW,
        heat=100,
        lang="zh",
        is_repost=False,
        image=image,
    )


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("http://i2.hdslb.com/bfs/archive/a.jpg", "https://i2.hdslb.com/bfs/archive/a.jpg"),
        ("//picx.zhimg.com/v2-a.jpg", "https://picx.zhimg.com/v2-a.jpg"),
        ("https://wx1.sinaimg.cn/large/a.jpg", "https://wx1.sinaimg.cn/large/a.jpg"),
        ("https://evil.example.com/a.jpg", ""),
        ("javascript:alert(1)", ""),
        ("https://i2.hdslb.com/a.jpg\r\nX: 1", ""),
        (None, ""),
        ("", ""),
    ],
)
def test_normalize_image(raw: object, expected: str) -> None:
    assert normalize_image(raw) == expected


def test_parsers_keep_allowlisted_covers() -> None:
    bili = bilibili.parse((CFG.fixtures_dir / "bili.json").read_text(encoding="utf-8"))
    assert bili[0].image.startswith("https://i0.hdslb.com/")
    hot = zhihu.parse((CFG.fixtures_dir / "zhihu.json").read_text(encoding="utf-8"))
    assert hot[0].image.startswith("https://picx.zhimg.com/")
    assert hot[2].image == ""


def test_first_weibo_photo_ignores_ui_images() -> None:
    payload = {
        "data": {
            "cardlistInfo": {"portrait": "https://wx1.sinaimg.cn/avatar.jpg"},
            "cards": [
                {"mblog": {}},
                {"mblog": {"pics": [{"url": "http://wx1.sinaimg.cn/orj360/a.jpg"}]}},
            ],
        }
    }
    assert first_weibo_photo(payload) == "https://wx1.sinaimg.cn/orj360/a.jpg"
    assert first_weibo_photo({"data": {"cards": []}}) == ""
    assert first_weibo_photo(["bad"]) == ""


def test_enrich_images_patches_only_weibo_within_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []

    def get(url: str, **kwargs: object) -> SimpleNamespace:
        calls.append(url)
        payload = {
            "data": {
                "cards": [{"mblog": {"pics": [{"large": "https://wx1.sinaimg.cn/large/a.jpg"}]}}]
            }
        }
        return SimpleNamespace(status=200, ok=True, headers={}, text=lambda: json.dumps(payload))

    @contextmanager
    def fake_open(cfg: object, platform: str):
        yield SimpleNamespace(request=SimpleNamespace(get=get))

    monkeypatch.setattr("radar.images.open_context", fake_open)
    monkeypatch.setattr(
        "radar.images.Throttle",
        lambda cfg: SimpleNamespace(wait=lambda p: None, deny=lambda *a: None),
    )
    items = (
        _candidate("weibo:1"),
        _candidate("weibo:2", image="https://wx1.sinaimg.cn/large/old.jpg"),
        _candidate("bili:1", "bili"),
    )
    result = enrich_images(CFG, items, enabled=True)
    assert len(calls) == 1  # 已有图的微博和 B 站条目不再发请求
    assert result[0].image.endswith("a.jpg")
    assert result[1].image.endswith("old.jpg")
    assert result[2].image == ""


def test_enrich_images_degrades_without_browser(monkeypatch: pytest.MonkeyPatch) -> None:
    def broken(cfg: object, platform: str):
        raise OSError("no chromium")

    monkeypatch.setattr("radar.images.open_context", broken)
    items = (_candidate("weibo:1"),)
    assert enrich_images(CFG, items, enabled=True) == items
    assert enrich_images(CFG, items, enabled=False) == items


def test_verify_accepts_optional_image(tmp_path: Path) -> None:
    item = {
        "id": "bili:bv1fixture001",
        "platform": "bili",
        "title": "中文标题",
        "summary": "中文摘要",
        "why": "理由",
        "url": "https://b23.tv/EXAMPLE01",
        "author": "",
        "lang": "zh",
        "published_at": "2026-11-12T08:30:00Z",
        "heat": {"value": 100, "delta": "+0"},
        "cross_platform": ["bili"],
        "image": "https://i0.hdslb.com/bfs/archive/a.jpg",
    }
    doc = {
        "schema": 1,
        "generated_at": "2026-11-12T08:30:00Z",
        "health": [],
        "items": [item],
    }
    path = tmp_path / "radar.json"
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    assert verify(path, NOW).ok
    doc["items"][0].pop("image")  # 旧版本产物没有 image 也要通过
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    assert verify(path, NOW).ok
    doc["items"][0]["image"] = "https://evil.example.com/a.jpg"
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    assert not verify(path, NOW).ok


def test_item_to_dict_carries_image() -> None:
    item = RadarItem(
        id="bili:bv1",
        platform="bili",
        title="标题",
        summary="中文摘要",
        why="理由",
        url="https://b23.tv/x",
        author="",
        lang="zh",
        published_at="2026-11-12T08:30:00Z",
        heat=Heat(1, "+0"),
        cross_platform=("bili",),
        image="https://i0.hdslb.com/a.jpg",
    )
    assert item_to_dict(item)["image"] == "https://i0.hdslb.com/a.jpg"
