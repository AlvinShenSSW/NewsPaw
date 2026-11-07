"""Validated local configuration. Credentials never appear in diagnostics."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dotenv import dotenv_values


class ConfigError(ValueError):
    pass


def parse_times(value: str) -> list[str]:
    times = sorted(set(part.strip() for part in value.split(",") if part.strip()))
    if (
        not times
        or len(times) > 12
        or any(not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", item) for item in times)
    ):
        raise ConfigError("推送时间格式应为 09:00,18:00，每天最多 12 次。")
    return times


def parse_topics(value: str) -> list[str]:
    topics = list(dict.fromkeys(part.strip() for part in value.split(";") if part.strip()))
    if not topics or len(topics) > 10 or any(len(item) > 150 for item in topics):
        raise ConfigError("请设置 1–10 个主题，用英文分号分隔，每个主题最多 150 字。")
    return topics


def parse_bool(value: str) -> bool:
    if value.lower() not in {"true", "false", "1", "0", "yes", "no"}:
        raise ConfigError("布尔设置应为 true 或 false。")
    return value.lower() in {"true", "1", "yes"}


@dataclass(frozen=True)
class Settings:
    config_path: Path
    data_dir: Path
    telegram_token: str = field(default="", repr=False)
    owner_id: int | None = None
    pairing_code: str = field(default="", repr=False)
    api_key: str = field(default="", repr=False)
    model: str = "gpt-5-mini"
    base_url: str | None = field(default=None, repr=False)
    transcription_model: str = "gpt-transcribe"
    voice: str = "Tingting"
    language: str = "简体中文"
    feed_language: str = "zh-CN"
    region: str = "US"
    topics: list[str] = field(default_factory=lambda: ["国际", "日本", "澳洲", "数码电子"])
    feeds: list[str] = field(default_factory=list)
    sources_file: Path | None = None
    times: list[str] = field(default_factory=lambda: ["09:00", "18:00"])
    timezone: str = "Asia/Tokyo"
    max_age_hours: int = 24
    digest_size: int = 5
    catchup_hours: int = 6
    voice_digest: bool = False

    def validate_run(self) -> None:
        if not self.telegram_token:
            raise ConfigError("请在 .env 中填写 TELEGRAM_BOT_TOKEN，再启动服务。")
        # An existing persisted owner is also accepted by the bot. A random init
        # pairing code remains available in config without granting a second owner.
        if self.owner_id is None and len(self.pairing_code) < 16:
            raise ConfigError("请设置 TELEGRAM_OWNER_ID，或用 newspaw init 生成配对码。")


def load_settings(path: Path) -> Settings:
    path = path.expanduser().resolve()
    values = {**dotenv_values(path), **os.environ}

    def value(key: str, default: str = "") -> str:
        return str(values.get(key) or default).strip()

    def number(key: str, default: int, low: int, high: int) -> int:
        try:
            result = int(value(key, str(default)))
        except ValueError:
            raise ConfigError(f"{key} 必须为整数。") from None
        if not low <= result <= high:
            raise ConfigError(f"{key} 应在 {low}–{high} 之间。")
        return result

    timezone = value("TIMEZONE", "Asia/Tokyo")
    try:
        ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError):
        raise ConfigError("TIMEZONE 必须为有效时区，例如 Asia/Tokyo。") from None
    owner = number("TELEGRAM_OWNER_ID", 0, 0, 2**52) or None
    data_dir = Path(value("DATA_DIR", "data")).expanduser()
    if not data_dir.is_absolute():
        data_dir = path.parent / data_dir
    sources_file = Path(value("SOURCES_FILE", "sources.toml")).expanduser()
    if not sources_file.is_absolute():
        sources_file = path.parent / sources_file
    from .news import public_url

    feeds = list(
        dict.fromkeys(item.strip() for item in value("NEWS_FEEDS").split(";") if item.strip())
    )
    if len(feeds) > 20 or any(not public_url(url, https_only=True) for url in feeds):
        raise ConfigError("NEWS_FEEDS 最多允许 20 个公开 HTTPS RSS 地址。")
    return Settings(
        config_path=path,
        data_dir=data_dir.resolve(),
        telegram_token=value("TELEGRAM_BOT_TOKEN"),
        owner_id=owner,
        pairing_code=value("PAIRING_CODE"),
        api_key=value("OPENAI_API_KEY"),
        model=value("OPENAI_MODEL", "gpt-5-mini"),
        base_url=value("OPENAI_BASE_URL") or None,
        transcription_model=value("TRANSCRIPTION_MODEL", "gpt-transcribe"),
        voice=value("MACOS_VOICE", "Tingting"),
        language=value("NEWS_LANGUAGE", "简体中文"),
        feed_language=value("NEWS_FEED_LANGUAGE", "zh-CN"),
        region=value("NEWS_REGION", "US"),
        topics=parse_topics(value("NEWS_TOPICS", "国际;日本;澳洲;数码电子")),
        feeds=feeds,
        sources_file=sources_file.resolve(),
        times=parse_times(value("DIGEST_TIMES", "09:00,18:00")),
        timezone=timezone,
        max_age_hours=number("NEWS_MAX_AGE_HOURS", 24, 1, 720),
        digest_size=number("DIGEST_SIZE", 5, 1, 10),
        catchup_hours=number("CATCHUP_HOURS", 6, 0, 24),
        voice_digest=parse_bool(value("VOICE_DIGEST", "false")),
    )
