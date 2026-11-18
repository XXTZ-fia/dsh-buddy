"""热榜只读接口：来源目录、单源榜单、多源批量、共识简报。"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Body, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

from radar.authz import allow_refresh
from radar.config import Config, with_model_key
from radar.hot import digest, service
from radar.hot.catalog import COLUMNS, catalog, resolve
from radar.hot.providers import PROVIDERS


class ZhihuCookie(BaseModel):
    cookie: str = Field(min_length=8, max_length=8192)


def router(cfg: Config) -> APIRouter:
    api = APIRouter()

    # 机房 IP 抓知乎必须带登录 Cookie。手机端在 WebView 里登录后把 Cookie
    # 上传到这里，落盘到数据目录，API 进程当场生效，不用重启服务。
    cookie_path = Path(cfg.db_path).parent / "zhihu_cookie"
    if not os.environ.get("RADAR_ZHIHU_COOKIE") and cookie_path.exists():
        os.environ["RADAR_ZHIHU_COOKIE"] = cookie_path.read_text(encoding="utf-8").strip()

    @api.get("/radar/hot/sources")
    def sources() -> dict[str, Any]:
        return {
            "columns": [{"id": key, "label": label} for key, label in COLUMNS],
            # native=false 的来源没有直连实现，App 里显示「暂不可用」而不是转圈。
            "sources": [{**row, "native": row["id"] in PROVIDERS} for row in catalog()],
        }

    @api.put("/radar/hot/sources/zhihu/cookie")
    def put_zhihu_cookie(request: Request, body: ZhihuCookie = Body(...)) -> dict[str, Any]:
        if request.state.device != "admin":
            raise HTTPException(403, "administrator credential required")
        value = body.cookie.strip()
        if "z_c0=" not in value:
            raise HTTPException(422, "cookie must contain z_c0")
        os.environ["RADAR_ZHIHU_COOKIE"] = value
        cookie_path.write_text(value, encoding="utf-8")
        cookie_path.chmod(0o600)
        return {"ok": True}

    @api.get("/radar/hot/feed")
    def feed(
        request: Request,
        source: str = Query(min_length=1, max_length=64),
        limit: int = Query(default=service.DEFAULT_LIMIT, ge=1, le=service.MAX_CACHE_ITEMS),
        refresh: bool = False,
    ) -> dict[str, Any]:
        if resolve(source) is None:
            raise HTTPException(404, "unknown source")
        return service.build(
            cfg.db_path, source, limit=limit, refresh=allow_refresh(request, refresh)
        )

    @api.get("/radar/hot/boards")
    def boards(
        request: Request,
        sources: str = Query(min_length=1, max_length=4096),
        limit: int = Query(default=service.DEFAULT_LIMIT, ge=1, le=service.MAX_CACHE_ITEMS),
        refresh: bool = False,
    ) -> dict[str, Any]:
        wanted = [part.strip() for part in sources.split(",") if part.strip()]
        if not wanted:
            raise HTTPException(422, "sources is empty")
        # 目录里有 47 个源；上限留在 64，让手机一次就能取全，而不是静默截断前 30 个。
        if len(wanted) > 64:
            raise HTTPException(422, "at most 64 sources per request")
        return {
            "feeds": service.build_many(
                cfg.db_path, wanted, limit=limit, refresh=allow_refresh(request, refresh)
            )
        }

    @api.get("/radar/hot/digest")
    def consensus(
        request: Request,
        refresh: bool = False,
        model_key: str = Header(default="", alias="X-Radar-Model-Key"),
    ) -> dict[str, Any]:
        # App 带来的 Key 只影响这一次请求：服务端没配 Key 时，手机填一个也能用上 AI 归纳。
        return digest.build(
            cfg.db_path,
            cfg=with_model_key(cfg, model_key),
            refresh=allow_refresh(request, refresh),
        )

    return api
