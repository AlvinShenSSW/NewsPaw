"""Prevent two local polling workers sharing one configuration."""

import fcntl
import os
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def instance_lock(data_dir: Path):
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (data_dir / "agent.lock").open("a") as handle:
        os.chmod(handle.name, 0o600)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("NewsPaw 已在运行；请先停止后台服务。") from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
