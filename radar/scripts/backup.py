"""Consistent online SQLite backup, including uploaded artifacts; never overwrites a backup."""

import argparse
import os
import sqlite3
from pathlib import Path


def backup(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        with (
            sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as src,
            sqlite3.connect(destination) as dst,
        ):
            src.backup(dst)
            if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("backup integrity check failed")
    except BaseException:
        destination.unlink()
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    backup(args.source.resolve(), args.destination.resolve())
