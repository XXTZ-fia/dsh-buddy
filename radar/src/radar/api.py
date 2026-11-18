"""Authenticated management API. Run behind HTTPS; one worker per database."""

from __future__ import annotations

import hashlib
import hmac
import json
import sqlite3
from dataclasses import replace
from typing import Annotated, Any, Literal

from fastapi import Body, Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from radar import daily as daily_service
from radar.config import Config, load, read_env, with_model_key
from radar.hot import service as hot_service
from radar.hot.api import router as hot_router
from radar.management import router, schema
from radar.papers import service as papers_service
from radar.papers.api import router as papers_router
from radar.publication import snapshot, transaction

Platform = Literal["x", "douyin", "bili", "weibo", "zhihu", "xhs"]


class UsageRecord(BaseModel):
    day: str
    device: str = "unknown"
    backend: str = "dsh"
    model: str = "unknown"
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0
    turns: int = 0


def default_platforms() -> list[Platform]:
    return ["x", "douyin", "bili", "weibo", "zhihu", "xhs"]


def _default_paper_sources() -> list[Literal["hf", "arxiv"]]:
    return ["hf", "arxiv"]


class Settings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: int = Field(default=0, ge=0)
    interests: list[str] = Field(default_factory=list, max_length=50)
    platforms: list[Platform] = Field(
        default_factory=default_platforms,
        min_length=1,
        max_length=6,
    )
    max_items: int = Field(default=5, ge=1, le=5)
    summary_model: str = Field(default="", max_length=100, pattern=r"^[a-zA-Z0-9_./:-]*$")
    # 论文推荐的三项手机端设置：来源开关、显示条数。兴趣词复用上面的 interests。
    paper_sources: list[Literal["hf", "arxiv"]] = Field(
        default_factory=_default_paper_sources,
        min_length=1,
        max_length=2,
    )
    paper_limit: int = Field(
        default=papers_service.DEFAULT_LIMIT,
        ge=1,
        le=papers_service.MAX_LIMIT,
    )

    @field_validator("interests")
    @classmethod
    def clean_interests(cls, values: list[str]) -> list[str]:
        cleaned = list(dict.fromkeys(value.strip() for value in values))
        if any(not value or len(value) > 200 for value in cleaned):
            raise ValueError("interests must contain 1 to 200 characters")
        return cleaned

    @field_validator("platforms")
    @classmethod
    def unique_platforms(cls, values: list[Platform]) -> list[Platform]:
        return list(dict.fromkeys(values))

    @field_validator("paper_sources")
    @classmethod
    def unique_paper_sources(cls, values: list[str]) -> list[str]:
        return list(dict.fromkeys(values))


class RunRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key: str = Field(min_length=8, max_length=100, pattern=r"^[a-zA-Z0-9_-]+$")
    dry_run: bool = True
    no_model: bool = True


def initialize(cfg: Config) -> None:
    with transaction(cfg.db_path) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS settings "
            " (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS runs "
            " (key TEXT PRIMARY KEY, status TEXT NOT NULL, result TEXT NOT NULL)"
        )
        schema(conn)
        hot_service.ensure(conn)
        try:
            initial = Settings(
                interests=list(cfg.interests),
                max_items=min(cfg.max_items, 5),
                summary_model=cfg.model_name,
            )
        except ValidationError as error:
            # 启动时把「config.yaml 哪一项不合法」说清楚，而不是抛 pydantic 堆栈。
            fields = ", ".join(
                f"{'.'.join(str(part) for part in item['loc'])}: {item['msg']}"
                for item in error.errors()
            )
            raise ValueError(f"config.yaml 不合法（{fields}）") from error
        conn.execute("INSERT OR IGNORE INTO settings VALUES (1, ?)", (initial.model_dump_json(),))


def read_settings(conn: sqlite3.Connection) -> Settings:
    return Settings.model_validate_json(
        conn.execute("SELECT body FROM settings WHERE id=1").fetchone()[0]
    )


def create_app(cfg: Config) -> FastAPI:
    if len(cfg.env.bearer_token) < 32:
        raise ValueError("RADAR_BEARER_TOKEN must contain at least 32 characters")
    initialize(cfg)

    def authorize(request: Request, authorization: Annotated[str | None, Header()] = None) -> None:
        expected = "Bearer " + cfg.env.bearer_token
        if hmac.compare_digest((authorization or "").encode(), expected.encode()):
            request.state.device = "admin"
            return
        token = (authorization or "").removeprefix("Bearer ")
        with transaction(cfg.db_path, write=False) as conn:
            row = conn.execute(
                "SELECT id FROM devices WHERE digest=? AND revoked=0",
                (hashlib.sha256(token.encode()).hexdigest(),),
            ).fetchone()
        if not row or not (authorization or "").startswith("Bearer "):
            raise HTTPException(401, "unauthorized")
        request.state.device = row[0]

    app = FastAPI(
        title="Personal Radar",
        dependencies=[Depends(authorize)],
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.get("/identity")
    def identity(request: Request) -> dict[str, Any]:
        return {
            "id": request.state.device,
            "admin": request.state.device == "admin",
            "model_configured": bool(cfg.env.model_api_key),
        }

    @app.get("/radar/items")
    def items(offset: int = 0, limit: int = 50) -> dict[str, Any]:
        if offset < 0 or not 1 <= limit <= 50:
            raise HTTPException(422, "invalid pagination")
        with transaction(cfg.db_path, write=False) as conn:
            doc = snapshot(conn) or {"schema": 1, "items": [], "health": [], "generated_at": None}
            rows = conn.execute(
                "SELECT h.body, r.id FROM history h LEFT JOIN item_reads r ON h.id=r.id "
                "ORDER BY h.rowid DESC LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
        return {
            **doc,
            "items": [{**json.loads(row[0]), "read": row[1] is not None} for row in rows],
        }

    @app.get("/radar/daily")
    def daily(day: str | None = None, model_key: str = Header(default="", alias="X-Radar-Model-Key")) -> dict[str, Any]:
        target = day or __import__("datetime").date.today().isoformat()
        with transaction(cfg.db_path, write=False) as conn:
            settings = read_settings(conn)
        active = replace(cfg, interests=tuple(settings.interests),
                         model_name=settings.summary_model or cfg.model_name)
        active = with_model_key(active, model_key)
        try:
            return daily_service.build(cfg.db_path, cfg=active, day=target)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

    @app.post("/radar/daily/refresh")
    def daily_refresh(day: str | None = None, model_key: str = Header(default="", alias="X-Radar-Model-Key")) -> dict[str, Any]:
        target = day or __import__("datetime").date.today().isoformat()
        with transaction(cfg.db_path, write=False) as conn:
            settings = read_settings(conn)
        active = replace(cfg, interests=tuple(settings.interests),
                         model_name=settings.summary_model or cfg.model_name)
        active = with_model_key(active, model_key)
        try:
            return daily_service.build(cfg.db_path, cfg=active, day=target, refresh=True)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

    @app.get("/radar/daily/calendar")
    def daily_calendar(month: str | None = None) -> dict[str, Any]:
        target = month or __import__("datetime").date.today().strftime("%Y-%m")
        try:
            return daily_service.calendar(cfg.db_path, target)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

    @app.post("/radar/usage")
    def usage(records: list[UsageRecord] = Body(...)) -> dict[str, Any]:
        with transaction(cfg.db_path) as conn:
            daily_service.ensure(conn)
            written = daily_service.record_usage(conn, [row.model_dump() for row in records])
        return {"written": written}

    @app.get("/radar/health")
    def health() -> dict[str, Any]:
        # 只读快照里的 health：不要为它再跑一次分页查询。
        with transaction(cfg.db_path, write=False) as conn:
            doc = snapshot(conn) or {"health": []}
        return {"health": doc["health"]}

    @app.get("/radar/config")
    def get_config() -> Settings:
        with transaction(cfg.db_path, write=False) as conn:
            return read_settings(conn)

    @app.put("/radar/config")
    def put_config(value: Settings, request: Request) -> Settings:
        # 采集面（兴趣词/平台/摘要模型）是账号级配置，设备令牌不该能改。
        if request.state.device != "admin":
            raise HTTPException(403, "administrator credential required")
        with transaction(cfg.db_path) as conn:
            if read_settings(conn).version != value.version:
                raise HTTPException(409, "configuration changed; reload before saving")
            updated = value.model_copy(update={"version": value.version + 1})
            conn.execute("UPDATE settings SET body=? WHERE id=1", (updated.model_dump_json(),))
        return updated

    @app.get("/runs")
    def runs(offset: int = 0) -> list[dict[str, Any]]:
        if offset < 0:
            raise HTTPException(422, "invalid pagination")
        with transaction(cfg.db_path, write=False) as conn:
            return [
                {"key": k, "status": s, "result": json.loads(r)}
                for k, s, r in conn.execute(
                    "SELECT key,status,result FROM runs ORDER BY rowid DESC LIMIT 50 OFFSET ?",
                    (offset,),
                )
            ]

    @app.post("/runs")
    def run(request: RunRequest) -> dict[str, Any]:
        if request.dry_run:
            raise HTTPException(422, "use radar run-once --dry-run for isolated previews")
        with transaction(cfg.db_path) as conn:
            old = conn.execute(
                "SELECT status,result FROM runs WHERE key=?", (request.key,)
            ).fetchone()
            if old:
                return {"key": request.key, "status": old[0], "result": json.loads(old[1])}
            if conn.execute("SELECT 1 FROM runs WHERE status IN ('running','queued')").fetchone():
                raise HTTPException(409, "a run is active")
            result = {"no_model": request.no_model}
            conn.execute(
                "INSERT INTO runs VALUES (?, 'queued', ?)", (request.key, json.dumps(result))
            )
        return {"key": request.key, "status": "queued", "result": result}

    # 手机弱网下，热榜/日报 JSON 经常几十 KB；压缩后首屏明显更快。
    app.add_middleware(GZipMiddleware, minimum_size=512)
    app.include_router(router(cfg))
    app.include_router(hot_router(cfg))
    app.include_router(papers_router(cfg))
    return app


def main() -> None:
    import argparse
    from pathlib import Path

    import uvicorn

    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()

    uvicorn.run(
        create_app(load(args.config, read_env())), host="127.0.0.1", port=8787, access_log=False
    )
