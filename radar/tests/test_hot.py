import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from radar.api import create_app
from radar.config import Env, load, with_paths
from radar.hot import digest, providers, service
from radar.hot.catalog import BY_ID, COLUMNS, SOURCES, catalog
from radar.hot.fetch import FetchError


@pytest.fixture
def cfg(tmp_path: Path):
    return with_paths(load(None, Env("", "t" * 32)), tmp_path / "radar.json", tmp_path / "s.db")


@pytest.fixture(autouse=True)
def _no_model_key(monkeypatch):
    # 本机若配了模型 Key，测试不该真的去打外部接口。
    monkeypatch.delenv("RADAR_MODEL_API_KEY", raising=False)


def test_catalog_matches_newsnow_visible_sources():
    assert len(SOURCES) == 47
    assert len(BY_ID) == len(SOURCES)
    labels = {key for key, _ in COLUMNS}
    assert {source.column for source in SOURCES} == labels
    # 重复的 App 榜单只在副标题上区分，id 必须各不相同。
    assert len({(source.name, source.title) for source in SOURCES}) == len(SOURCES)
    # 收录进目录的源必须有直连实现：没有实现的源勾了也只会显示「暂不可用」。
    assert {source.id for source in SOURCES} == set(providers.PROVIDERS)


def test_catalog_payload_is_flat_and_ordered():
    rows = catalog()
    assert [row["id"] for row in rows] == [source.id for source in SOURCES]
    assert rows[0]["column_label"] == "国内"
    assert all(row["scheme"] == "" or "://" in row["scheme"] for row in rows)


def test_native_providers_are_known_sources():
    assert set(providers.PROVIDERS) <= set(BY_ID)
    # 没有直连实现的源不应该被注册，服务层会把它们标成 unavailable。
    assert "kaopu" not in providers.PROVIDERS
    assert "freebuf" not in providers.PROVIDERS


def test_native_coverage_is_at_least_forty():
    assert len(providers.PROVIDERS) >= 40


def _fake(items):
    return lambda limit: items[:limit]


def test_cache_avoids_second_fetch(cfg, monkeypatch):
    calls: list[str] = []

    def counted(limit):
        calls.append("hit")
        return [
            {"title": "t", "url": "https://example.invalid", "extra": "", "image": "", "time": ""}
        ]

    monkeypatch.setitem(providers.PROVIDERS, "jin10", counted)
    first = service.build(cfg.db_path, "jin10")
    second = service.build(cfg.db_path, "jin10")
    assert first["origin"] == "native" and first["status"] == "ok"
    assert second["origin"] == "cache" and second["items"][0]["rank"] == 1
    assert len(calls) == 1


def test_source_without_provider_is_unavailable(cfg, monkeypatch):
    # 目录里的每个源现在都有实现，所以人为摘掉一个来覆盖「先加目录、后补实现」
    # 的降级路径：宁可标不可用，也不伪造条目。
    monkeypatch.delitem(providers.PROVIDERS, "douban")
    feed = service.build(cfg.db_path, "douban")
    assert feed["status"] == "unavailable" and feed["items"] == []
    assert "直连实现" in feed["error"]


def test_total_failure_keeps_stale_items(cfg, monkeypatch):
    with service.transaction(cfg.db_path) as conn:
        service.ensure(conn)
        conn.execute(
            "INSERT OR REPLACE INTO hot_cache VALUES (?, ?, ?)",
            (
                "douban",
                json.dumps(
                    [
                        {
                            "title": "旧条目",
                            "url": "https://x.invalid",
                            "extra": "",
                            "image": "",
                            "time": "",
                        }
                    ]
                ),
                time.time() - service.TTL_S * 4,
            ),
        )
    monkeypatch.setitem(
        providers.PROVIDERS, "douban", lambda limit: (_ for _ in ()).throw(FetchError("x"))
    )
    feed = service.build(cfg.db_path, "douban")
    assert feed["status"] == "stale" and feed["items"][0]["title"] == "旧条目"
    assert "x" in feed["error"]


def test_build_many_keeps_order_and_isolates_failures(cfg, monkeypatch):
    monkeypatch.setitem(
        providers.PROVIDERS, "jin10", _fake([{"title": "a", "url": "https://a.invalid"}])
    )
    monkeypatch.setitem(
        providers.PROVIDERS, "douban", _fake([{"title": "b", "url": "https://b.invalid"}])
    )
    feeds = service.build_many(cfg.db_path, ["douban", "jin10", "nope", "douban"])
    assert [feed["source"] for feed in feeds] == ["douban", "jin10"]
    assert [feed["items"][0]["title"] for feed in feeds] == ["b", "a"]


def test_cache_is_capped_and_pruned(cfg, monkeypatch):
    many = [{"title": f"t{n}", "url": f"https://a.invalid/{n}"} for n in range(60)]
    monkeypatch.setitem(providers.PROVIDERS, "jin10", _fake(many))
    feed = service.build(cfg.db_path, "jin10")
    # 单源最多留 30 条：盘小，不存整页。
    assert len(feed["items"]) == service.MAX_CACHE_ITEMS
    with service.transaction(cfg.db_path) as conn:
        conn.execute("UPDATE hot_cache SET fetched_at = ?", (time.time() - 7200,))
    assert service.prune(cfg.db_path) == 1
    assert service.snapshot(cfg.db_path) == {}


def test_digest_finds_cross_source_topics(cfg, monkeypatch):
    rows = {
        "weibo": [
            {"title": "英伟达黄仁勋辞职引发市场震动", "url": "https://a.invalid/1"},
            {"title": "无关的娱乐新闻", "url": "https://a.invalid/2"},
        ],
        "douyin": [
            {"title": "黄仁勋辞职英伟达股价大跌", "url": "https://b.invalid/1"},
            {"title": "另一条独立消息", "url": "https://b.invalid/2"},
        ],
        "zhihu": [
            {"title": "国家队出手稳定市场预期", "url": "https://c.invalid/1"},
        ],
    }
    with service.transaction(cfg.db_path) as conn:
        service.ensure(conn)
        for source, items in rows.items():
            conn.execute(
                "INSERT OR REPLACE INTO hot_cache VALUES (?, ?, ?)",
                (source, json.dumps(items, ensure_ascii=False), time.time()),
            )
    body = digest.build(cfg.db_path)
    assert body["sources"] == 3 and body["scanned"] == 5
    assert body["model"] == ""
    titles = [topic["title"] for topic in body["topics"]]
    assert any("黄仁勋" in title for title in titles)
    topic = next(topic for topic in body["topics"] if "黄仁勋" in topic["title"])
    assert set(topic["sources"]) == {"weibo", "douyin"}
    # 每条都同时给 id 与显示名：App 用 id 跳转、用人名显示。
    row = topic["items"][0]
    assert row["source"] in {"weibo", "douyin"}
    assert row["source_name"] in {"微博", "抖音"}


def test_digest_is_cached(cfg, monkeypatch):
    with service.transaction(cfg.db_path) as conn:
        service.ensure(conn)
        conn.execute(
            "INSERT OR REPLACE INTO hot_cache VALUES (?, ?, ?)",
            ("weibo", json.dumps([{"title": "x", "url": "https://a.invalid"}]), time.time()),
        )
    first = digest.build(cfg.db_path)
    monkeypatch.setattr(
        digest, "service", type("S", (), {"snapshot": staticmethod(lambda path: {})})()
    )
    second = digest.build(cfg.db_path)
    assert second["generated_at"] == first["generated_at"]


def test_hot_endpoints_require_token_and_serve_catalog(cfg, monkeypatch):
    monkeypatch.setitem(
        providers.PROVIDERS, "jin10", _fake([{"title": "a", "url": "https://a.invalid"}])
    )
    client = TestClient(create_app(cfg))
    assert client.get("/radar/hot/sources").status_code == 401
    headers = {"Authorization": "Bearer " + "t" * 32}
    body = client.get("/radar/hot/sources", headers=headers).json()
    assert len(body["sources"]) == 47
    assert all(row["native"] is True for row in body["sources"])
    assert client.get("/radar/hot/feed?source=nope", headers=headers).status_code == 404
    feed = client.get("/radar/hot/feed?source=jin10", headers=headers).json()
    assert feed["name"] == "金十数据" and feed["items"][0]["rank"] == 1
    boards = client.get("/radar/hot/boards?sources=jin10,douban", headers=headers).json()
    assert [entry["source"] for entry in boards["feeds"]] == ["jin10", "douban"]
    consensus = client.get("/radar/hot/digest", headers=headers).json()
    assert "topics" in consensus and consensus["sources"] >= 0
