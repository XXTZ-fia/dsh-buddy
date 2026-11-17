"""Single scheduler/worker authority. Interrupted work is never blindly replayed."""

from __future__ import annotations

import argparse
import json
import signal
import threading
import time
from dataclasses import replace
from datetime import UTC, datetime
from typing import Any

from radar.api import initialize, read_settings
from radar.config import Config, load, read_env
from radar.locking import exclusive
from radar.management import Schedule, event
from radar.publication import materialize, transaction


def recover(cfg: Config) -> None:
    # Caller holds the lifetime worker lock: no other worker can still be running.
    with transaction(cfg.db_path) as conn:
        for (key,) in conn.execute("SELECT key FROM runs WHERE status='running'").fetchall():
            conn.execute(
                "UPDATE runs SET status='interrupted',result=? WHERE key=?",
                ('{"error":"worker_interrupted"}', key),
            )
            event(conn, f"run-{key}", "interrupted", {"run": key})
    materialize(cfg.db_path, cfg.outbox_path)


def enqueue_due(cfg: Config, now: float) -> None:
    with transaction(cfg.db_path) as conn:
        if conn.execute("SELECT 1 FROM runs WHERE status IN ('running','queued')").fetchone():
            return
        for identifier, body in conn.execute("SELECT id,body FROM schedules ORDER BY rowid"):
            schedule = Schedule.model_validate_json(body)
            if not schedule.enabled or schedule.next_run > now:
                continue
            key = f"schedule-{identifier}-{int(schedule.next_run)}"
            conn.execute(
                "INSERT OR IGNORE INTO runs VALUES (?,'queued',?)",
                (
                    key,
                    json.dumps(
                        {
                            "no_model": schedule.no_model,
                            "schedule": identifier,
                        }
                    ),
                ),
            )
            # Coalesce missed intervals after downtime into one execution.
            step = schedule.interval_minutes * 60
            due = schedule.next_run + (int((now - schedule.next_run) // step) + 1) * step
            updated = schedule.model_copy(update={"next_run": due, "version": schedule.version + 1})
            conn.execute(
                "UPDATE schedules SET body=? WHERE id=?", (updated.model_dump_json(), identifier)
            )
            break


def execute_next(cfg: Config) -> bool:
    from radar.cli import _build_document, _collect, _stamp
    from radar.health import aggregate
    from radar.http import Throttle

    with transaction(cfg.db_path) as conn:
        row = conn.execute(
            "SELECT key,result FROM runs WHERE status='queued' ORDER BY rowid LIMIT 1"
        ).fetchone()
        if not row:
            return False
        key, options = row[0], json.loads(row[1])
        conn.execute("UPDATE runs SET status='running' WHERE key=?", (key,))
        settings = read_settings(conn)
    active = replace(
        cfg,
        interests=tuple(settings.interests),
        max_items=settings.max_items,
        model_name=settings.summary_model or cfg.model_name,
    )
    args = argparse.Namespace(dry_run=False, no_model=options.get("no_model", True))
    now, started = datetime.now(UTC), time.monotonic()
    result: dict[str, Any]
    try:
        if not args.no_model and not cfg.env.model_api_key:
            raise ValueError("summary model is not configured")
        # CLI and queue share this lock; browser profiles cannot be used concurrently.
        with exclusive(cfg.db_path.with_suffix(".collection.lock")):
            raws, entries = _collect(
                active,
                args,
                Throttle(active),
                tuple(settings.platforms),
                min(active.per_source_limit, 20),
                _stamp(now),
            )
            _, report, _ = _build_document(
                active,
                args,
                tuple(raws),
                aggregate(tuple(entries), _stamp(now), tuple(settings.platforms)),
                now,
                started,
            )
        # 「run 失败」只表示流程出错；六个源全挂属于「跑完了但没取到内容」，
        # 用 sources_failed 表达，否则运维会在源站故障时看到一堆假失败。
        result = {
            "new_items": report.new_items,
            "written": report.written,
            "sources_failed": list(report.sources_failed),
        }
        status = "completed"
    except Exception as exc:
        result, status = {"error": type(exc).__name__}, "failed"
    with transaction(cfg.db_path) as conn:
        result.update({"started": _stamp(now), "finished": time.time(), **options})
        conn.execute(
            "UPDATE runs SET status=?,result=? WHERE key=?", (status, json.dumps(result), key)
        )
        event(conn, f"run-{key}", status, {"run": key, "result": result})
    return True


def refresh_hot(cfg: Config, stopping: threading.Event) -> None:
    """热榜每 5 分钟全量刷一次，App 打开时直接命中缓存；顺带清掉过期行。

    独立线程：抓 50 个站点要十几秒，不能卡住采集任务的下发循环。
    """
    from radar.hot import service as hot

    while not stopping.is_set():
        try:
            hot.warm_all(cfg.db_path)
        except Exception as exc:  # noqa: BLE001 - 热榜挂了不影响采集
            print(f"hot warm failed: {type(exc).__name__}")
        try:
            hot.prune(cfg.db_path)
        except Exception as exc:  # noqa: BLE001
            print(f"hot prune failed: {type(exc).__name__}")
        stopping.wait(hot.TTL_S)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str)
    args = parser.parse_args()
    from pathlib import Path

    cfg = load(Path(args.config) if args.config else None, read_env())
    initialize(cfg)
    stopping = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopping.set())
    with exclusive(cfg.db_path.with_suffix(".worker.lock")):
        recover(cfg)
        threading.Thread(target=refresh_hot, args=(cfg, stopping), daemon=True).start()
        while not stopping.is_set():
            enqueue_due(cfg, time.time())
            execute_next(cfg)
            stopping.wait(2)


if __name__ == "__main__":
    main()
