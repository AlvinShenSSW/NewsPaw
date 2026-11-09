"""Entry point for the local NewsPaw worker that the macOS app starts."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="NewsPaw — 本机新闻管家后台")
    commands = parser.add_subparsers(dest="command", required=True)
    control = commands.add_parser("control", help="运行本机后台与私有配置接口")
    control.add_argument(
        "--data-dir", type=Path, default=Path.home() / "Library/Application Support/NewsPaw"
    )
    args = parser.parse_args(argv)
    os.umask(0o077)
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
    # Transport URLs can contain credentials. Never enable verbose transport logs.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.CRITICAL)
    try:
        from .control import serve_control

        asyncio.run(serve_control(args.data_dir))
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        # Never print arbitrary exception reprs: URLs and provider errors may contain keys.
        print(f"执行失败（{type(exc).__name__}）。请检查配置、网络和运行状态。", file=sys.stderr)
    return 1
