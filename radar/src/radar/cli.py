"""4 个子命令：只做参数解析与编排，业务逻辑都在下层模块。"""

from __future__ import annotations

import argparse
import json
import tempfile
import time
from collections.abc import Callable
from dataclasses import asdict, replace
from datetime import UTC, datetime
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError

from radar import health as hs
from radar import normalize as nz
from radar.browser import open_context, open_login
from radar.config import Config, load, read_env, with_paths
from radar.dedupe import ensure_unique
from radar.http import Throttle
from radar.images import enrich_images
from radar.locking import exclusive
from radar.logging import configure, emit
from radar.models import PLATFORMS, Health, RadarDocument, RadarItem, RawItem, RunReport
from radar.outbox import to_dict, verify
from radar.publication import materialize, publish, transaction
from radar.sources import bilibili, build_sources, douyin, weibo, x, xhs, zhihu
from radar.sources.base import AuthExpired, ParseError, RateLimited, SourceUnavailable
from radar.summarize import summarize_all

NS = argparse.Namespace
PARSERS: dict[str, Callable[[str], list[RawItem]]] = {
    "weibo": weibo.parse,
    "bili": bilibili.parse,
    "zhihu": zhihu.parse,
    "douyin": douyin.parse,
    "xhs": xhs.parse,
    "x": x.parse,
}
SOURCE_ERRORS = (AuthExpired, RateLimited, SourceUnavailable, ParseError, PlaywrightError, OSError)
DRYRUN_DIR = Path(tempfile.gettempdir()) / "radar-dryrun"


def _stamp(now: datetime) -> str:
    return now.isoformat().replace("+00:00", "Z")


def _check_auth(cfg: Config, platform: str) -> int:
    throttle = Throttle(cfg)
    source = build_sources(cfg, throttle)[platform]
    now = datetime.now(UTC)
    try:
        with open_context(cfg, platform) as ctx:
            entry = hs.from_result(source.check_auth(ctx), _stamp(now))
    except SOURCE_ERRORS as exc:
        entry = hs.from_exception(exc, platform, _stamp(now))
    emit("INFO", "check_auth", platform=platform, note=entry.status)
    print(json.dumps(asdict(entry), ensure_ascii=False))
    return 0 if entry.status == "ok" else 1


def _collect(
    cfg: Config,
    args: NS,
    throttle: Throttle,
    platforms: tuple[str, ...],
    limit: int,
    checked_at: str,
) -> tuple[list[RawItem], list[Health]]:
    """顺序执行，并发度恒为 1；单源失败只写 health，不中断整轮（D7）。"""
    sources = build_sources(cfg, throttle)
    raws: list[RawItem] = []
    entries: list[Health] = []
    for platform in platforms:
        try:
            if args.dry_run:
                body = (cfg.fixtures_dir / f"{platform}.json").read_text(encoding="utf-8")
                items = PARSERS[platform](body)[:limit]
            else:
                with open_context(cfg, platform) as ctx:
                    items = sources[platform].fetch(ctx, limit)
            raws.extend(items)
            entries.append(hs.success(platform, checked_at, len(items)))
            emit("INFO", "source_ok", platform=platform, count=len(items))
        except SOURCE_ERRORS as exc:
            entries.append(hs.from_exception(exc, platform, checked_at))
            emit("WARNING", "source_failed", platform=platform, note=entries[-1].note)
    return raws, entries


def _make_items(
    selected: nz.Candidates, groups: nz.Groups, cfg: Config, use_model: bool
) -> tuple[RadarItem, ...]:
    summaries = summarize_all(selected, cfg, cfg.interests, use_model)
    baseline = nz.baseline_of(selected)
    return tuple(
        nz.to_radar_item(
            item, s.summary, s.why, nz.cross_platform_in_groups(item, groups), baseline
        )
        for item, s in zip(selected, summaries, strict=True)
    )


def _build_document(
    cfg: Config,
    args: NS,
    raws: tuple[RawItem, ...],
    health: tuple[Health, ...],
    now: datetime,
    started: float,
) -> tuple[RadarDocument, RunReport, bool]:
    with exclusive(cfg.db_path.with_suffix(".publication.lock")):
        return _publish_document(cfg, args, raws, health, now, started)


def _publish_document(
    cfg: Config,
    args: NS,
    raws: tuple[RawItem, ...],
    health: tuple[Health, ...],
    now: datetime,
    started: float,
) -> tuple[RadarDocument, RunReport, bool]:
    candidates = nz.normalize_all(raws, now)
    with transaction(cfg.db_path) as conn:
        unseen = tuple(
            c
            for c in ensure_unique(candidates)
            if not conn.execute("SELECT 1 FROM seen WHERE id=?", (c.id,)).fetchone()
        )
    selected = nz.select_top(unseen, cfg.interests, now, min(cfg.max_items, 5))
    selected = enrich_images(cfg, selected, enabled=not args.dry_run)
    use_model = not args.dry_run and not args.no_model and bool(cfg.env.model_api_key)
    groups = nz.ranked_groups(unseen, cfg.interests, now)
    doc = RadarDocument(_stamp(now), health, _make_items(selected, groups, cfg, use_model))
    with transaction(cfg.db_path) as conn:
        publish(conn, to_dict(doc), min(cfg.snapshot_size, 50))
        conn.executemany(
            "INSERT OR IGNORE INTO seen VALUES (?, ?, ?)",
            [(c.id, c.platform, _stamp(now)) for c in unseen],
        )
    written = materialize(cfg.db_path, cfg.outbox_path, has_new=bool(doc.items))
    elapsed = int((time.monotonic() - started) * 1000)
    report = RunReport(
        _stamp(now),
        hs.ok_platforms(health),
        hs.failed_platforms(health),
        len(raws),
        len(selected),
        written,
        elapsed,
    )
    return doc, report, written


def _run_once(cfg: Config, args: NS) -> int:
    started = time.monotonic()
    now = datetime.now(UTC)
    if args.dry_run:
        DRYRUN_DIR.mkdir(parents=True, exist_ok=True)
        cfg = with_paths(cfg, args.out or DRYRUN_DIR / "radar.json", DRYRUN_DIR / "seen.db")
    platforms = PLATFORMS
    if not args.dry_run:
        from radar.api import initialize, read_settings

        initialize(cfg)
        with transaction(cfg.db_path) as conn:
            settings = read_settings(conn)
        cfg = replace(
            cfg,
            interests=tuple(settings.interests),
            max_items=settings.max_items,
            model_name=settings.summary_model or cfg.model_name,
        )
        platforms = tuple(settings.platforms)
    limit = min(args.limit or cfg.per_source_limit, 20)
    if limit < 1:
        raise ValueError("limit must be positive")
    platforms = (args.only,) if args.only else platforms
    raws, entries = _collect(cfg, args, Throttle(cfg), platforms, limit, _stamp(now))
    health = hs.aggregate(tuple(entries), _stamp(now), platforms)
    _, report, written = _build_document(cfg, args, tuple(raws), health, now, started)
    emit("INFO", "run_once", count=report.new_items, ms=report.duration_ms)
    summary = {
        "file": str(cfg.outbox_path),
        "fetched": report.fetched,
        "new_items": report.new_items,
        "written": written,
        "sources_ok": list(report.sources_ok),
        "sources_failed": list(report.sources_failed),
        "duration_ms": report.duration_ms,
        "health": [asdict(entry) for entry in health],
    }
    print(json.dumps(summary, ensure_ascii=False))
    return 0


def _verify(cfg: Config, file: Path | None) -> int:
    path = file or cfg.outbox_path
    result = verify(path, datetime.now(UTC))
    print(
        json.dumps(
            {"file": str(path), "ok": result.ok, "errors": list(result.errors)}, ensure_ascii=False
        )
    )
    return 0 if result.ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="radar")
    parser.add_argument("--config", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check-auth")
    check.add_argument("--platform", required=True, choices=PLATFORMS)
    login = sub.add_parser("login")
    login.add_argument("--platform", required=True, choices=PLATFORMS)
    run = sub.add_parser("run-once")
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("--only", choices=PLATFORMS)
    run.add_argument("--limit", type=int)
    run.add_argument("--no-model", action="store_true")
    run.add_argument("--out", type=Path)
    verify_cmd = sub.add_parser("verify-outbox")
    verify_cmd.add_argument("--file", type=Path)
    args = parser.parse_args(argv)
    cfg = load(args.config, read_env())  # 环境变量只在此入口读取一次。
    configure(cfg.log_level)
    if args.command == "login":
        with exclusive(cfg.db_path.with_suffix(".collection.lock")):
            open_login(cfg, args.platform)
        return 0
    if args.command == "check-auth":
        return _check_auth(cfg, args.platform)
    if args.command == "verify-outbox":
        return _verify(cfg, args.file)
    with exclusive(cfg.db_path.with_suffix(".collection.lock")):
        return _run_once(cfg, args)
