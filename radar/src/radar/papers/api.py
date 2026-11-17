"""论文只读接口：首页「为你推荐的论文」一次取完。

兴趣词、来源开关、显示条数都以手机端设置为准（settings 表），没有设置时才
回落到 config.yaml——用户改完点保存，下一次请求就按新规则出结果。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Header, Query, Request

from radar import preferences
from radar.authz import allow_refresh
from radar.config import Config, with_model_key
from radar.papers import service


def router(cfg: Config) -> APIRouter:
    api = APIRouter()

    @api.get("/radar/papers")
    def papers(
        request: Request,
        limit: int = Query(default=0, ge=0, le=service.MAX_LIMIT),
        refresh: bool = False,
        model_key: str = Header(default="", alias="X-Radar-Model-Key"),
    ) -> dict[str, Any]:
        # 兴趣词与简报共用一份（/radar/config 里可改），避免两处口径不一致。
        # limit=0 表示「按手机端设置」，显式传值仍可覆盖（调试与测试用）。
        selected = preferences.paper_limit(cfg.db_path, service.DEFAULT_LIMIT, service.MAX_LIMIT)
        # 带上 cfg：标题与摘要的中文化需要翻译引擎，服务端没配 Key 时走机器翻译；
        # App 自己带来的 Key 顶上（只用于这一次请求）。
        return service.build(
            cfg.db_path,
            preferences.interests(cfg.db_path, cfg.interests),
            limit=limit or selected,
            sources=preferences.paper_sources(cfg.db_path),
            cfg=with_model_key(cfg, model_key),
            refresh=allow_refresh(request, refresh),
        )

    return api
