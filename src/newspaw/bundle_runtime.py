"""Private smoke and preflight commands for the packaged Mac helper."""

from __future__ import annotations

import json
import os
import sqlite3
import stat
import sys
import time
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory

from .control import acquire_control_lock
from .migrations import DATABASE_VERSION
from .store import Store


def check_upgrade(directory):
    directory = Path(directory).absolute()
    fd = acquire_control_lock(directory)
    try:
        path = directory / "newspaw.sqlite3"
        try:
            info = path.lstat()
        except FileNotFoundError:
            return {"state": "fresh", "target_version": DATABASE_VERSION}
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
        ):
            raise ValueError("invalid_upgrade_database")
        deadline = time.monotonic() + 12

        def progress(status, remaining, pages):
            if time.monotonic() > deadline or status in {
                sqlite3.SQLITE_BUSY,
                sqlite3.SQLITE_LOCKED,
            }:
                raise ValueError("upgrade_snapshot_unavailable")

        with TemporaryDirectory(prefix="newspaw-upgrade-") as scratch:
            snapshot = Path(scratch) / path.name
            with (
                closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as source,
                closing(sqlite3.connect(snapshot)) as copied,
            ):
                version = source.execute("PRAGMA user_version").fetchone()[0]
                source.backup(copied, pages=128, progress=progress, sleep=0.01)
            snapshot.chmod(0o600)
            with closing(Store(snapshot)) as migrated:
                migrated._db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
                if migrated._db.execute("PRAGMA quick_check(1)").fetchone() != ("ok",):
                    raise ValueError("upgrade_snapshot_unavailable")
        return {
            "state": "compatible",
            "source_version": version,
            "target_version": DATABASE_VERSION,
        }
    finally:
        os.close(fd)


def main(args=None):
    args = sys.argv[1:] if args is None else args
    try:
        if args == ["self-check"]:
            prefix = Path(sys.base_prefix).resolve()
            if not Path(__file__).resolve().is_relative_to(prefix):
                raise ValueError("runtime_not_bundled")
            import feedparser
            import httpx
            import keyring
            import openai
            import PIL

            for module in (PIL, feedparser, httpx, keyring, openai):
                if not Path(module.__file__).resolve().is_relative_to(prefix):
                    raise ValueError("runtime_not_bundled")
            result = {"state": "bundled", "python": list(sys.version_info[:3])}
        elif len(args) == 2 and args[0] == "check-upgrade" and Path(args[1]).is_absolute():
            result = check_upgrade(args[1])
        elif len(args) == 2 and args[0] == "check-stopped" and Path(args[1]).is_absolute():
            os.close(acquire_control_lock(Path(args[1])))
            result = {"state": "stopped"}
        else:
            raise ValueError("invalid_runtime_action")
    except (OSError, RuntimeError, ValueError, sqlite3.Error, ImportError):
        print('{"state":"unavailable"}')
        return 2
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
