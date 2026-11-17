import json
import time

import pytest
from fastapi.testclient import TestClient

from radar.api import create_app
from radar.config import Env, load, with_paths
from radar.locking import exclusive
from radar.management import event
from radar.publication import transaction
from radar.worker import enqueue_due, recover


@pytest.fixture
def workspace(tmp_path):
    cfg = with_paths(load(None, Env("", "t" * 32)), tmp_path / "out.json", tmp_path / "db")
    client = TestClient(
        create_app(cfg), headers={"Authorization": "Bearer " + cfg.env.bearer_token}
    )
    return cfg, client


def test_schedules_conflicts_and_single_due_queue(workspace):
    cfg, client = workspace
    body = {"title": "daily", "interval_minutes": 60, "next_run": time.time() - 10000}
    created = client.post("/schedules", json=body).json()
    identifier = created.pop("id")
    updated = client.put(f"/schedules/{identifier}", json=created)
    assert updated.status_code == 200
    assert client.put(f"/schedules/{identifier}", json=created).status_code == 409
    enqueue_due(cfg, time.time())
    enqueue_due(cfg, time.time())
    assert len(client.get("/runs").json()) == 1
    schedule = client.get("/schedules").json()[0]
    assert schedule["next_run"] > time.time()
    assert client.delete(f"/schedules/{identifier}?version=0").status_code == 409
    assert (
        client.delete(f"/schedules/{identifier}?version={schedule['version']}").status_code == 200
    )
    assert client.post("/schedules", json={**body, "time_zone": "../no-zone"}).status_code == 422


def test_interrupted_run_is_not_replayed_and_events_are_deduplicated(workspace):
    cfg, client = workspace
    with transaction(cfg.db_path) as conn:
        conn.execute("INSERT INTO runs VALUES ('crashed','running','{}')")
    recover(cfg)
    recover(cfg)
    assert client.get("/runs").json()[0]["status"] == "interrupted"
    rows = client.get("/events").json()
    assert len(rows["events"]) == 1
    assert client.get(f"/events?after={rows['cursor']}").json()["events"] == []
    identifier = rows["events"][0]["id"]
    assert client.put(f"/events/{identifier}/read").status_code == 200
    assert client.get("/events").json()["events"][0]["read"]


def test_device_enrollment_revocation_and_no_privilege_escalation(workspace):
    _, client = workspace
    issued = client.post("/devices", json={"name": "phone"}).json()
    headers = {"Authorization": "Bearer " + issued["token"]}
    assert client.get("/radar/items", headers=headers).status_code == 200
    assert client.post("/devices", headers=headers, json={"name": "other"}).status_code == 403
    assert "token" not in json.dumps(client.get("/devices").json())
    assert client.delete(f"/devices/{issued['id']}").status_code == 200
    assert client.get("/radar/items", headers=headers).status_code == 401


def test_artifact_bytes_are_id_scoped_and_require_auth(workspace):
    _, client = workspace
    uploaded = client.post("/artifacts?name=..%2F..%2Fsecret", content=b"file content").json()
    path = f"/artifacts/{uploaded['id']}"
    assert client.get(path).content == b"file content"
    assert client.get(path, headers={"Authorization": "Bearer invalid"}).status_code == 401
    assert client.get("/artifacts/unknown").status_code == 404
    assert (
        client.post("/artifacts?name=large", content=b"x" * (20 * 1024 * 1024 + 1)).status_code
        == 413
    )
    assert client.delete(path).status_code == 200
    assert client.get(path).status_code == 404


def test_os_lock_prevents_second_owner(tmp_path):
    with (
        exclusive(tmp_path / "worker.lock"),
        pytest.raises(OSError),
        exclusive(tmp_path / "worker.lock"),
    ):
        pass
    with exclusive(tmp_path / "worker.lock"):
        pass


def test_event_dedupe_keeps_first_authoritative_payload(workspace):
    cfg, client = workspace
    with transaction(cfg.db_path) as conn:
        event(conn, "same-id", "completed", {"host": "one"})
        event(conn, "same-id", "failed", {"host": "two"})
    rows = client.get("/events").json()["events"]
    assert len(rows) == 1
    assert rows[0]["host"] == "one"


def test_bridge_requires_admin_and_namespaces_event_identity(workspace):
    _, client = workspace
    body = {"id": "session:123", "host": "laptop", "session": "session", "kind": "completed"}
    for _ in range(2):
        assert client.post("/events", json=body).status_code == 200
    assert client.post("/events", json={**body, "host": "server"}).status_code == 200
    assert len(client.get("/events").json()["events"]) == 2
    token = client.post("/devices", json={"name": "phone"}).json()["token"]
    assert (
        client.post("/events", json=body, headers={"Authorization": f"Bearer {token}"}).status_code
        == 403
    )


def test_sqlite_backup_restores_uploaded_bytes(workspace, tmp_path):
    import runpy
    import sqlite3
    from pathlib import Path

    cfg, client = workspace
    client.post("/artifacts?name=note.txt", content=b"durable artifact")
    backup = runpy.run_path(str(Path(__file__).parents[1] / "scripts" / "backup.py"))["backup"]
    destination = tmp_path / "backup.db"
    backup(cfg.db_path.resolve(), destination)
    with sqlite3.connect(destination) as restored:
        assert restored.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert (
            restored.execute("SELECT content FROM artifacts").fetchone()[0] == b"durable artifact"
        )


def test_platform_request_blocks_foreign_hosts_before_cookie_context(workspace):
    from radar.http import Throttle, get_body
    from radar.sources.base import SourceUnavailable

    cfg, _ = workspace
    for url in [
        "https://evil.invalid/api",
        "http://weibo.com/api",
        "https://weibo.com.evil.invalid",
    ]:
        with pytest.raises(SourceUnavailable):
            get_body(None, url, "weibo", cfg, Throttle(cfg))
