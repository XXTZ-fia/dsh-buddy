import time
from argparse import Namespace
from dataclasses import replace
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from radar.api import create_app
from radar.cli import _build_document
from radar.config import Env, load, with_paths
from radar.http import Throttle
from radar.models import RawItem
from radar.normalize import select_top, to_candidate
from radar.publication import materialize, publish, snapshot, transaction
from radar.sources.base import RateLimited

NOW = datetime(2026, 11, 11, tzinfo=UTC)


@pytest.fixture
def cfg(tmp_path):
    return with_paths(load(None, Env("", "t" * 32)), tmp_path / "radar.json", tmp_path / "state.db")


def test_interest_rank_survives_selection():
    a = to_candidate(RawItem("x", "1", "AI芯片研究", "https://example.invalid", heat_raw="10"), NOW)
    b = to_candidate(
        RawItem("weibo", "2", "明星婚礼现场", "https://example.invalid", heat_raw="100"), NOW
    )
    assert select_top((a, b), ("AI",), NOW, 1) == (a,)


def test_circuit_is_platform_scoped(cfg):
    throttle = Throttle(replace(cfg, min_interval_ms=0, jitter_ms=0))
    throttle.deny(None, "x")
    with pytest.raises(RateLimited):
        throttle.wait("x")
    throttle.wait("bili")


def test_failed_projection_recovers_without_losing_items(cfg, monkeypatch):
    args = Namespace(dry_run=True, no_model=True)
    raw = RawItem("weibo", "test", "测试内容", "https://example.invalid")

    def fail(*args):
        raise OSError("simulated disk error")

    with monkeypatch.context() as m:
        m.setattr("radar.publication.atomic_write", fail)
        with pytest.raises(OSError):
            _build_document(cfg, args, (raw,), (), NOW, time.monotonic())
    with transaction(cfg.db_path) as conn:
        assert snapshot(conn)["items"][0]["id"] == "weibo:test"
    monkeypatch.setattr("radar.outbox.protect_file", lambda path: None)
    assert materialize(cfg.db_path, cfg.outbox_path)
    assert "weibo:test" in cfg.outbox_path.read_text(encoding="utf-8")


def test_history_survives_next_run(cfg, monkeypatch):
    monkeypatch.setattr("radar.outbox.protect_file", lambda path: None)
    args = Namespace(dry_run=True, no_model=True)
    for i in range(2):
        _build_document(
            cfg,
            args,
            (RawItem("x", str(i), f"标题{i}", "https://example.invalid"),),
            (),
            NOW,
            time.monotonic(),
        )
    with transaction(cfg.db_path) as conn:
        assert len(snapshot(conn)["items"]) == 2
        assert conn.execute("SELECT count(*) FROM history").fetchone()[0] == 2


def test_api_auth_validation_and_version_conflict(cfg):
    client = TestClient(create_app(cfg))
    assert client.get("/radar/items").status_code == 401
    client.headers["Authorization"] = "Bearer " + cfg.env.bearer_token
    settings = client.get("/radar/config").json()
    settings["interests"] = ["机器人"]
    assert client.put("/radar/config", json=settings).json()["version"] == 1
    assert client.put("/radar/config", json=settings).status_code == 409
    settings["max_items"] = 100
    assert client.put("/radar/config", json=settings).status_code == 422
    assert client.get("/radar/items?limit=100").status_code == 422
    assert client.post("/runs", json={"key": "preview1"}).status_code == 422


def test_api_run_is_idempotent(cfg, monkeypatch):
    from radar.models import Health, RunReport

    calls = []

    def collect(*args):
        calls.append(1)
        return [], [Health("x", "ok", NOW.isoformat(), "")]

    def build(*args):
        return None, RunReport("", ("x",), (), 0, 0, True, 0), True

    monkeypatch.setattr("radar.cli._collect", collect)
    monkeypatch.setattr("radar.cli._build_document", build)
    client = TestClient(
        create_app(cfg), headers={"Authorization": "Bearer " + cfg.env.bearer_token}
    )
    body = {"key": "same-run-123", "dry_run": False}
    first = client.post("/runs", json=body)
    assert first.status_code == 200
    assert first.json()["status"] == "queued"
    assert client.post("/runs", json=body).json() == first.json()
    from radar.worker import execute_next

    assert execute_next(cfg)
    assert not execute_next(cfg)
    assert client.post("/runs", json=body).json()["status"] == "completed"
    assert len(calls) == 1


def test_summary_failure_does_not_consume_seen(cfg, monkeypatch):
    def fail(*args):
        raise ValueError("invalid model response")

    monkeypatch.setattr("radar.cli._make_items", fail)
    with pytest.raises(ValueError):
        _build_document(
            cfg,
            Namespace(dry_run=True, no_model=True),
            (RawItem("x", "rollback", "标题", "https://example.invalid"),),
            (),
            NOW,
            time.monotonic(),
        )
    with transaction(cfg.db_path) as conn:
        assert conn.execute("SELECT count(*) FROM seen").fetchone()[0] == 0
        assert snapshot(conn) is None


def test_configuration_deduplicates_platforms_and_rejects_empty_interest(cfg):
    client = TestClient(
        create_app(cfg), headers={"Authorization": "Bearer " + cfg.env.bearer_token}
    )
    current = client.get("/radar/config").json()
    current["platforms"] = ["x", "x", "bili"]
    current["interests"] = [" AI ", "AI"]
    updated = client.put("/radar/config", json=current).json()
    assert updated["platforms"] == ["x", "bili"]
    assert updated["interests"] == ["AI"]
    updated["interests"] = ["  "]
    assert client.put("/radar/config", json=updated).status_code == 422


def test_publishing_without_new_items_does_not_rewrite_the_file(cfg):
    """契约：没有新增内容时 written=false、mtime 不变（App 据此判断「无事发生」）。"""
    document = {
        "schema": 1,
        "generated_at": "2026-11-17T00:00:00Z",
        "health": [
            {"platform": "weibo", "status": "ok", "checked_at": "2026-11-17T00:00:00Z", "note": ""}
        ],
        "items": [{"id": "weibo:a"}],
    }
    with transaction(cfg.db_path) as conn:
        publish(conn, document, 50)
    assert materialize(cfg.db_path, cfg.outbox_path) is True
    before = cfg.outbox_path.stat().st_mtime_ns
    assert materialize(cfg.db_path, cfg.outbox_path, has_new=False) is False
    assert cfg.outbox_path.stat().st_mtime_ns == before


def test_refresh_needs_the_admin_credential(cfg, monkeypatch):
    """设备令牌只能读缓存；refresh=true 会绕过 TTL 直接打上游，必须留给管理员。"""
    import hashlib

    from radar.hot import api as hot_api

    seen: dict[str, object] = {}

    def fake_build(*_args, **kwargs):
        seen.update(kwargs)
        return {"source": "weibo", "items": []}

    monkeypatch.setattr(hot_api.service, "build", fake_build)
    device = "device-token-for-test"
    app = create_app(cfg)
    with transaction(cfg.db_path) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO devices VALUES ('d1','phone',?,0)",
            (hashlib.sha256(device.encode()).hexdigest(),),
        )
    admin = {"Authorization": "Bearer " + cfg.env.bearer_token}
    phone = {"Authorization": f"Bearer {device}"}
    client = TestClient(app)
    assert (
        client.get(
            "/radar/hot/feed", params={"source": "weibo", "refresh": "true"}, headers=phone
        ).status_code
        == 403
    )
    assert (
        client.get(
            "/radar/hot/feed", params={"source": "weibo", "refresh": "true"}, headers=admin
        ).status_code
        == 200
    )
    assert seen["refresh"] is True
    seen.clear()
    assert (
        client.get("/radar/hot/feed", params={"source": "weibo"}, headers=phone).status_code == 200
    )
    assert seen["refresh"] is False


def test_artifact_storage_is_bounded(cfg, monkeypatch):
    import radar.management as management

    monkeypatch.setattr(management, "MAX_ARTIFACTS", 1)
    client = TestClient(
        create_app(cfg), headers={"Authorization": "Bearer " + cfg.env.bearer_token}
    )
    assert client.post("/artifacts", params={"name": "a.bin"}, content=b"x").status_code == 200
    refused = client.post("/artifacts", params={"name": "b.bin"}, content=b"y")
    assert refused.status_code == 413


def test_items_page_keeps_published_order(cfg):
    """接口按 rowid 倒序分页，写入必须逆序：新一轮在前、轮内按排名。"""
    document = {
        "schema": 1,
        "generated_at": "2026-11-17T00:00:00Z",
        "health": [],
        "items": [{"id": f"weibo:{index}"} for index in range(3)],
    }
    with transaction(cfg.db_path) as conn:
        publish(conn, document, 50)
    client = TestClient(create_app(cfg))
    client.headers["Authorization"] = "Bearer " + cfg.env.bearer_token
    ids = [row["id"] for row in client.get("/radar/items?limit=3").json()["items"]]
    assert ids == ["weibo:0", "weibo:1", "weibo:2"]

    # 第二轮：新条目整体排在旧条目之前，轮内仍是排名顺序。
    with transaction(cfg.db_path) as conn:
        publish(conn, {**document, "items": [{"id": f"bili:{index}"} for index in range(2)]}, 50)
    ids = [row["id"] for row in client.get("/radar/items?limit=5").json()["items"]]
    assert ids == ["bili:0", "bili:1", "weibo:0", "weibo:1", "weibo:2"]
