"""Local setup, evidence inspection, and macOS service controls."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import secrets
import shutil
import sys
from pathlib import Path

from .config import ConfigError, Settings, load_settings
from .locking import instance_lock
from .news import NewsError, NewsService
from .service import ServiceError, manage_service
from .sources import load_sources
from .store import Store


def project_dir() -> Path:
    return Path(__file__).resolve().parents[2]


def initialize(path: Path) -> str:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    template = (project_dir() / ".env.example").read_text()
    template = template.replace("PAIRING_CODE=\n", f"PAIRING_CODE={secrets.token_urlsafe(24)}\n")
    if path.parent != project_dir():
        template = template.replace(
            "SOURCES_FILE=sources.toml", f"SOURCES_FILE={project_dir() / 'sources.toml'}"
        )
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(template)
    return f"已创建 {path}（权限 600）。请填入 TELEGRAM_BOT_TOKEN；配对码保存在 PAIRING_CODE。"


def make_news(settings: Settings) -> NewsService:
    return NewsService(
        settings.feeds,
        language=settings.feed_language,
        region=settings.region,
        max_age_hours=settings.max_age_hours,
        topic_feeds=load_sources(settings.sources_file),
    )


def doctor(settings: Settings) -> int:
    checks = {
        "Telegram Bot Token": bool(settings.telegram_token),
        "主人账号或本机配对码": bool(settings.owner_id or len(settings.pairing_code) >= 16),
        "模型 API Key（可选）": bool(settings.api_key),
        "ffmpeg（语音处理）": bool(shutil.which("ffmpeg")),
        "macOS say（本机播报）": bool(shutil.which("say")),
    }
    for label, ready in checks.items():
        print(f"{'✓' if ready else '○'} {label}：{'已配置' if ready else '未配置'}")
    print(f"时区：{settings.timezone}；推送：{', '.join(settings.times)}")
    print(f"主题：{'；'.join(settings.topics)}；时效：{settings.max_age_hours} 小时")
    print(f"来源配置：{len(load_sources(settings.sources_file))} 个主题别名")
    print("此检查不验证远程凭据是否有效，不发送消息，也不调用付费模型。")
    try:
        settings.validate_run()
    except ConfigError as exc:
        print(str(exc))
        return 1
    return 0


async def collect(settings: Settings, query: str | None, limit: int, raw: bool) -> int:
    news = make_news(settings)
    store = Store(settings.data_dir / "newspaw.sqlite3")
    error = False
    try:
        try:
            articles = (
                await news.search(query, limit)
                if query
                else await news.latest(settings.topics, limit)
            )
        except NewsError:
            articles, error = [], True
        report = news.last_report.to_dict()
        collection_id = store.save_collection(report)
        if raw:
            print(
                json.dumps({"collection_id": collection_id, **report}, ensure_ascii=False, indent=2)
            )
        else:
            from .bot import article_text

            for index, article in enumerate(articles, 1):
                print(article_text(article, index, settings.timezone) + "\n")
            print(
                f"证据记录：{collection_id}；结果 {len(articles)} 条；失败源 {news.last_failed_sources} 个。"
            )
            if not articles:
                print("没有符合明确发布时间和时效要求的新闻；未使用未知时间条目补数。")
        return 1 if error else 0
    finally:
        await news.close()
        store.close()


def run(settings: Settings) -> None:
    from .ai import AIService
    from .bot import NewsBot

    settings.validate_run()
    with instance_lock(settings.data_dir):
        # Python 3.14 no longer creates an event loop implicitly.
        asyncio.set_event_loop(asyncio.new_event_loop())
        store = Store(settings.data_dir / "newspaw.sqlite3")
        news = make_news(settings)
        ai = AIService(
            settings.api_key,
            settings.model,
            settings.base_url,
            settings.transcription_model,
            settings.voice,
            settings.language,
        )
        bot = NewsBot(settings, store, news, ai)
        bot.application().run_polling(allowed_updates=["message"], drop_pending_updates=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="NewsPaw — 本机 Telegram 新闻 agent")
    parser.add_argument("--config", type=Path, default=Path(".env"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init", help="生成私有配置和随机配对码，不覆盖已有文件")
    commands.add_parser("doctor", help="检查本机配置，不发送消息")
    commands.add_parser("run", help="前台运行 Telegram bot")
    for name in ("search", "collect"):
        sub = commands.add_parser(name, help="采集公开新闻并记录证据，不发送消息")
        if name == "search":
            sub.add_argument("query")
        sub.add_argument("--limit", type=int, choices=range(1, 51), default=5, metavar="1..50")
        sub.add_argument("--json", action="store_true", help="输出可检查的证据 JSON")
    audit = commands.add_parser("audit", help="查看近期采集与投递记录")
    audit.add_argument("--limit", type=int, choices=range(1, 21), default=5, metavar="1..20")
    audit.add_argument("--json", action="store_true")
    service = commands.add_parser("service", help="管理 macOS 登录后的常驻服务")
    service.add_argument("action", choices=["install", "start", "stop", "status", "uninstall"])
    args = parser.parse_args(argv)
    os.umask(0o077)
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
    # Transport URLs can contain credentials. Never enable verbose transport logs.
    for name in ("httpx", "httpcore", "openai", "telegram", "apscheduler"):
        logging.getLogger(name).setLevel(logging.CRITICAL)
    try:
        if args.command == "init":
            print(initialize(args.config))
            return 0
        if args.command == "service" and args.action in {"stop", "status", "uninstall"}:
            print(manage_service(args.action, project_dir(), args.config))
            return 0
        settings = load_settings(args.config)
        if args.command == "doctor":
            return doctor(settings)
        if args.command == "service":
            settings.validate_run()
            print(manage_service(args.action, project_dir(), args.config))
        elif args.command == "run":
            run(settings)
        elif args.command in {"search", "collect"}:
            return asyncio.run(
                collect(settings, getattr(args, "query", None), args.limit, args.json)
            )
        elif args.command == "audit":
            store = Store(settings.data_dir / "newspaw.sqlite3")
            try:
                records = store.get_audit(args.limit)
                if args.json:
                    print(json.dumps(records, ensure_ascii=False, indent=2))
                else:
                    for record in records:
                        brief = record.get("brief")
                        print(
                            f"{record['collection_id']} | {record['created_at']} | "
                            f"{brief['status'] if brief else '仅采集，未投递'}"
                        )
                    if not records:
                        print("尚无采集记录。")
            finally:
                store.close()
        return 0
    except FileExistsError:
        print("配置文件已存在，未覆盖。请直接编辑本机 .env。", file=sys.stderr)
    except (ConfigError, ServiceError, NewsError) as exc:
        print(str(exc), file=sys.stderr)
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        # Never print arbitrary exception reprs: URLs and provider errors may contain keys.
        print(f"执行失败（{type(exc).__name__}）。请检查配置、网络和运行状态。", file=sys.stderr)
    return 1
