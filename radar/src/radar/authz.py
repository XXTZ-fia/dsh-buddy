"""授权策略：路由只声明「谁能做什么」，判断集中在这里。"""

from __future__ import annotations

from fastapi import HTTPException, Request


def require_admin(request: Request) -> None:
    if getattr(request.state, "device", None) != "admin":
        raise HTTPException(403, "administrator credential required")


def allow_refresh(request: Request, refresh: bool) -> bool:
    """`refresh=true` 会绕过 TTL 直接打上游（热榜 47 站）或调模型（共识/论文）。

    设备令牌只能读缓存：把它开放给任何令牌，等于给了一条「无限频率采集」的入口，
    与合规红线（频率压到个人阅读量级）冲突。手动下拉刷新由管理员令牌完成。
    """
    if not refresh:
        return False
    require_admin(request)
    return True
