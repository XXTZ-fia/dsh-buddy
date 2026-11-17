"""Personal workspace: schedules, inbox, device credentials and bounded file storage."""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import time
import uuid
from typing import Any, Literal
from urllib.parse import quote
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from radar.config import Config
from radar.publication import transaction

#: 产物是「随手存一下」的附件，不是网盘：给一个明确上限，避免一条设备令牌把
#: SQLite 撑到备份/查询都变慢。20 MiB × 200 条 ≈ 4 GiB 上限，实际按字节再卡一道。
MAX_ARTIFACTS = 200
MAX_ARTIFACT_BYTES = 512 * 1024 * 1024


def schema(conn: sqlite3.Connection) -> None:
    for statement in (
        "CREATE TABLE IF NOT EXISTS schedules (id TEXT PRIMARY KEY, body TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, "
        "id TEXT UNIQUE NOT NULL, body TEXT NOT NULL, read INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, "
        "digest TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS artifacts (id TEXT PRIMARY KEY, name TEXT NOT NULL, "
        "host TEXT NOT NULL, session TEXT NOT NULL, created REAL NOT NULL, content BLOB NOT NULL)",
        "CREATE TABLE IF NOT EXISTS item_reads (id TEXT PRIMARY KEY)",
    ):
        conn.execute(statement)


def event(conn: sqlite3.Connection, event_id: str, kind: str, data: dict[str, Any]) -> None:
    conn.execute(
        "INSERT OR IGNORE INTO events(id,body) VALUES (?,?)",
        (
            event_id,
            json.dumps({"id": event_id, "kind": kind, "created": time.time(), **data}),
        ),
    )


class Schedule(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=100)
    version: int = Field(default=0, ge=0)
    enabled: bool = True
    interval_minutes: int = Field(default=60, ge=5, le=525600)
    time_zone: str = "Asia/Shanghai"
    next_run: float = Field(gt=0)
    no_model: bool = True

    @field_validator("time_zone")
    @classmethod
    def valid_zone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("unknown time zone") from exc
        return value


class DeviceRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)


class BridgeEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(min_length=1, max_length=500)
    host: str = Field(min_length=1, max_length=200)
    session: str = Field(min_length=1, max_length=200)
    kind: Literal["completed", "failed", "approval", "question", "cancelled"]
    event_id: str | None = Field(default=None, max_length=200)


def router(cfg: Config) -> APIRouter:
    routes = APIRouter()

    @routes.post("/events")
    def ingest(value: BridgeEvent, request: Request) -> dict[str, bool]:
        # Only a configured host bridge/admin can publish authority-labelled events.
        if request.state.device != "admin":
            raise HTTPException(403, "host bridge credential required")
        identifier = hashlib.sha256(f"{value.host}\0{value.id}".encode()).hexdigest()
        with transaction(cfg.db_path) as conn:
            data = value.model_dump(exclude={"id", "kind"})
            event(conn, identifier, value.kind, data)
        return {"accepted": True}

    @routes.get("/schedules")
    def schedules() -> list[dict[str, Any]]:
        with transaction(cfg.db_path, write=False) as conn:
            return [
                {"id": i, "host": "radar-server", **json.loads(b)}
                for i, b in conn.execute("SELECT id,body FROM schedules ORDER BY rowid DESC")
            ]

    @routes.post("/schedules")
    def create(value: Schedule) -> dict[str, Any]:
        identifier = uuid.uuid4().hex
        with transaction(cfg.db_path) as conn:
            conn.execute(
                "INSERT INTO schedules VALUES (?,?)", (identifier, value.model_dump_json())
            )
        return {"id": identifier, **value.model_dump()}

    @routes.put("/schedules/{identifier}")
    def update(identifier: str, value: Schedule) -> dict[str, Any]:
        with transaction(cfg.db_path) as conn:
            row = conn.execute("SELECT body FROM schedules WHERE id=?", (identifier,)).fetchone()
            if not row:
                raise HTTPException(404, "schedule missing")
            if json.loads(row[0])["version"] != value.version:
                raise HTTPException(409, "reload before saving")
            value = value.model_copy(update={"version": value.version + 1})
            conn.execute(
                "UPDATE schedules SET body=? WHERE id=?", (value.model_dump_json(), identifier)
            )
        return {"id": identifier, **value.model_dump()}

    @routes.delete("/schedules/{identifier}")
    def delete(identifier: str, version: int) -> dict[str, bool]:
        with transaction(cfg.db_path) as conn:
            row = conn.execute("SELECT body FROM schedules WHERE id=?", (identifier,)).fetchone()
            if not row:
                raise HTTPException(404, "schedule missing")
            if json.loads(row[0])["version"] != version:
                raise HTTPException(409, "reload before deleting")
            conn.execute("DELETE FROM schedules WHERE id=?", (identifier,))
        return {"deleted": True}

    @routes.get("/events")
    def events(after: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=100)) -> dict[str, Any]:
        with transaction(cfg.db_path, write=False) as conn:
            rows = conn.execute(
                "SELECT seq,body,read FROM events WHERE seq>? ORDER BY seq LIMIT ?", (after, limit)
            ).fetchall()
        return {
            "events": [{**json.loads(b), "seq": s, "read": bool(r)} for s, b, r in rows],
            "cursor": rows[-1][0] if rows else after,
        }

    @routes.put("/events/{identifier}/read")
    def read_event(identifier: str) -> dict[str, bool]:
        with transaction(cfg.db_path) as conn:
            if not conn.execute("UPDATE events SET read=1 WHERE id=?", (identifier,)).rowcount:
                raise HTTPException(404, "event missing")
        return {"read": True}

    @routes.put("/radar/items/{identifier}/read")
    def read_item(identifier: str) -> dict[str, bool]:
        with transaction(cfg.db_path) as conn:
            if not conn.execute("SELECT 1 FROM history WHERE id=?", (identifier,)).fetchone():
                raise HTTPException(404, "item missing")
            conn.execute("INSERT OR IGNORE INTO item_reads VALUES (?)", (identifier,))
        return {"read": True}

    @routes.get("/devices")
    def devices() -> list[dict[str, Any]]:
        with transaction(cfg.db_path, write=False) as conn:
            return [
                {"id": i, "name": n, "revoked": bool(r)}
                for i, n, r in conn.execute("SELECT id,name,revoked FROM devices")
            ]

    def admin(request: Request) -> None:
        if request.state.device != "admin":
            raise HTTPException(403, "administrator credential required")

    @routes.post("/devices")
    def enroll(value: DeviceRequest, request: Request) -> dict[str, str]:
        admin(request)
        token, identifier = secrets.token_urlsafe(32), uuid.uuid4().hex
        with transaction(cfg.db_path) as conn:
            conn.execute(
                "INSERT INTO devices VALUES (?,?,?,0)",
                (identifier, value.name, hashlib.sha256(token.encode()).hexdigest()),
            )
        return {"id": identifier, "token": token}

    @routes.delete("/devices/{identifier}")
    def revoke(identifier: str, request: Request) -> dict[str, bool]:
        if request.state.device != identifier:
            admin(request)
        with transaction(cfg.db_path) as conn:
            if not conn.execute("UPDATE devices SET revoked=1 WHERE id=?", (identifier,)).rowcount:
                raise HTTPException(404, "device missing")
        return {"revoked": True}

    @routes.get("/artifacts")
    def artifacts(offset: int = Query(0, ge=0)) -> list[dict[str, Any]]:
        with transaction(cfg.db_path, write=False) as conn:
            return [
                {"id": i, "name": n, "host": h, "session": s, "created": c, "size": z}
                for i, n, h, s, c, z in conn.execute(
                    "SELECT id,name,host,session,created,length(content) FROM artifacts "
                    "ORDER BY rowid DESC LIMIT 50 OFFSET ?",
                    (offset,),
                )
            ]

    @routes.post("/artifacts")
    async def upload(
        request: Request,
        name: str = Query(min_length=1, max_length=200),
        host: str = Query("upload", max_length=200),
        session: str = Query("", max_length=200),
    ) -> dict[str, str]:
        # Store bytes, never a client-supplied filesystem path; no symlink traversal.
        content = bytearray()
        async for chunk in request.stream():
            if len(content) + len(chunk) > 20 * 1024 * 1024:
                raise HTTPException(413, "maximum file size is 20 MiB")
            content.extend(chunk)
        identifier = uuid.uuid4().hex
        with transaction(cfg.db_path) as conn:
            count, total = conn.execute(
                "SELECT count(*), coalesce(sum(length(content)), 0) FROM artifacts"
            ).fetchone()
            if count >= MAX_ARTIFACTS or total + len(content) > MAX_ARTIFACT_BYTES:
                raise HTTPException(413, "artifact storage is full; delete something first")
            conn.execute(
                "INSERT INTO artifacts VALUES (?,?,?,?,?,?)",
                (identifier, name, host, session, time.time(), bytes(content)),
            )
        return {"id": identifier}

    @routes.get("/artifacts/{identifier}")
    def download(identifier: str) -> Response:
        with transaction(cfg.db_path, write=False) as conn:
            row = conn.execute(
                "SELECT name, content FROM artifacts WHERE id=?", (identifier,)
            ).fetchone()
        if not row:
            raise HTTPException(404, "artifact missing")
        # Keep the uploaded name (RFC 5987 for non-ASCII); a fixed "artifact.bin"
        # made every download on the phone indistinguishable.
        filename = quote(str(row[0]) or "artifact.bin", safe="")
        return Response(
            bytes(row[1]),
            media_type="application/octet-stream",
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{filename}",
                "X-Content-Type-Options": "nosniff",
            },
        )

    @routes.delete("/artifacts/{identifier}")
    def delete_artifact(identifier: str) -> dict[str, bool]:
        with transaction(cfg.db_path) as conn:
            if not conn.execute("DELETE FROM artifacts WHERE id=?", (identifier,)).rowcount:
                raise HTTPException(404, "artifact missing")
        return {"deleted": True}

    return routes
