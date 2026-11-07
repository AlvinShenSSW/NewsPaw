"""Single-user configuration documents. Secrets live outside this schema."""

from __future__ import annotations

import hashlib
import json
import re
from copy import deepcopy
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dotenv import dotenv_values

from .config import parse_times, parse_topics

SCHEMA_VERSION = 2
STYLES = {"text", "source_image", "newspaper"}
LOCALES = {"zh-Hans", "en", "ja"}
PARTITIONS = {"normal", "adult"}
_ID = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,79}")
_CREDENTIAL = re.compile(r"keychain:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
_FIELDS = {
    "categories": {"id", "name", "partition", "primary_profile_id", "backup_profile_id", "style"},
    "sources": {"id", "name", "url", "kind", "partition", "category_ids", "enabled"},
    "subscriptions": {
        "id",
        "name",
        "category_id",
        "source_ids",
        "bot_ids",
        "times",
        "timezone",
        "enabled",
        "style",
        "max_items",
    },
    "accounts": {
        "id",
        "remote_id",
        "handle",
        "partition",
        "priority",
        "subscription_id",
        "bot_ids",
        "times",
        "style",
    },
    "model_profiles": {
        "id",
        "partition",
        "role",
        "provider",
        "base_url",
        "model",
        "credential_ref",
        "capabilities",
    },
    "bots": {
        "id",
        "name",
        "credential_ref",
        "telegram_id",
        "chat_id",
        "verified",
        "paired",
        "adult_allowed",
    },
}
_TOP_FIELDS = {
    "schema_version",
    "ui_locale",
    "news_output_locale",
    "timezone",
    "owner_id",
    "group_styles",
    *_FIELDS,
}


def new_id(kind: str) -> str:
    if kind not in _FIELDS:
        raise ValueError("Unknown configuration entity kind")
    return f"{kind}_{uuid4().hex}"


def default_config() -> dict:
    categories = [
        ("world", "世界新闻", "08:00"),
        ("japan", "日本新闻", "08:30"),
        ("australia", "澳洲新闻", "09:00"),
        ("china", "中国新闻", "09:30"),
        ("electronics", "数码电子", "18:00"),
        ("ai", "AI 动态", "18:30"),
        ("av", "AV 产业", "21:00"),
        ("x", "X 动态", "20:30"),
        ("x_adult", "X 成人博主", "22:00"),
    ]
    profiles = [
        (
            "normal_primary",
            "normal",
            "primary",
            "openai",
            "https://api.openai.com/v1",
            "gpt-6-luna",
        ),
        (
            "normal_backup",
            "normal",
            "backup",
            "mimo",
            "https://api.xiaomimimo.com/v1",
            "mimo-v2.6-flash",
        ),
        (
            "adult_primary",
            "adult",
            "primary",
            "deepseek",
            "https://api.deepseek.com",
            "deepseek-flash",
        ),
        ("adult_backup", "adult", "backup", "grok", "https://api.x.ai/v1", "grok-4.3"),
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "ui_locale": "zh-Hans",
        "news_output_locale": "zh-Hans",
        "timezone": "Asia/Tokyo",
        "owner_id": None,
        "group_styles": {"normal": "text", "adult": "text"},
        "categories": [
            dict(
                id=key,
                name=name,
                partition="adult" if key in {"av", "x_adult"} else "normal",
                primary_profile_id=None,
                backup_profile_id=None,
                style=None,
            )
            for key, name, _ in categories
        ],
        "subscriptions": [
            dict(
                id=f"sub_{key}",
                name=name,
                category_id=key,
                source_ids=[],
                bot_ids=[],
                times=[time],
                timezone="Asia/Tokyo",
                enabled=False,
                style="text",
                max_items=5,
            )
            for key, name, time in categories
        ],
        "model_profiles": [
            dict(
                id=key,
                partition=partition,
                role=role,
                provider=provider,
                base_url=url,
                model=model,
                credential_ref=None,
                capabilities=[],
            )
            for key, partition, role, provider, url, model in profiles
        ],
        "sources": [],
        "accounts": [],
        "bots": [],
    }


def _text(value, limit=500):
    if (
        not isinstance(value, str)
        or not value
        or len(value) > limit
        or any(ord(c) < 32 for c in value)
    ):
        raise ValueError("Invalid configuration text")


def _id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError("Invalid stable ID")


def _url(value):
    _text(value, 2048)
    try:
        parsed = urlsplit(value)
        port = parsed.port
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.fragment
            or (port is not None and not 1 <= port <= 65535)
        ):
            raise ValueError
        for key, _ in parse_qsl(parsed.query, keep_blank_values=True):
            normalized = re.sub(r"[^a-z]", "", key.lower())
            if normalized in {
                "key",
                "apikey",
                "token",
                "accesstoken",
                "password",
                "secret",
                "auth",
                "authorization",
                "sig",
                "signature",
                "credential",
                "keypairid",
                "googleaccessid",
                "authkey",
            } or normalized.endswith(
                (
                    "apikey",
                    "token",
                    "password",
                    "secret",
                    "authorization",
                    "signature",
                    "sig",
                    "keypairid",
                    "credential",
                    "accesskeyid",
                    "subscriptionkey",
                )
            ):
                raise ValueError
    except ValueError:
        raise ValueError("Configuration URLs must be HTTPS without credentials") from None


def _timezone(value):
    _text(value, 100)
    try:
        ZoneInfo(value)
    except (ValueError, ZoneInfoNotFoundError):
        raise ValueError("Invalid IANA timezone") from None


def _integer(value, low, high, *, optional=False):
    if value is None and optional:
        return
    if type(value) is not int or not low <= value <= high:
        raise ValueError("Invalid configuration integer")


def _boolean(value):
    if type(value) is not bool:
        raise ValueError("Invalid configuration boolean")


def _list(value, limit=200):
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError("Invalid configuration list")


def _times(value, *, optional=False):
    if value is None and optional:
        return
    _list(value, 12)
    if optional and not value:
        return
    if not all(isinstance(item, str) for item in value) or parse_times(",".join(value)) != value:
        raise ValueError("Times must be unique and sorted HH:MM")


def _style(value, *, optional=False):
    if value is None and optional:
        return
    if value not in STYLES:
        raise ValueError("Invalid delivery style")


def upgrade_v1(config: dict) -> dict:
    """Explicit document transformation, never mutate the stored source."""
    result = deepcopy(config)
    if type(result.get("schema_version")) is not int or result["schema_version"] != 1:
        raise ValueError("Expected version1 configuration")
    result["schema_version"] = 2
    result["group_styles"] = {"normal": "text", "adult": "text"}
    for kind in ("categories", "accounts"):
        for entry in result[kind]:
            entry["style"] = None
    validate_config(result)
    return result


def validate_config(config: dict) -> None:
    try:
        _validate_config(config)
    except (TypeError, KeyError):
        raise ValueError("Invalid configuration structure") from None


def _validate_config(config: dict) -> None:
    if not isinstance(config, dict) or set(config) != _TOP_FIELDS:
        raise ValueError("Unknown or missing configuration fields; secrets are not accepted")
    if type(config["schema_version"]) is not int or config["schema_version"] != SCHEMA_VERSION:
        raise ValueError("Unsupported configuration schema")
    for key in ("ui_locale", "news_output_locale"):
        if config[key] not in LOCALES:
            raise ValueError("Unsupported locale")
    if not isinstance(config["group_styles"], dict) or set(config["group_styles"]) != PARTITIONS:
        raise ValueError("Invalid group styles")
    for style in config["group_styles"].values():
        _style(style)
    _timezone(config["timezone"])
    _integer(config["owner_id"], 1, 2**52, optional=True)
    indexed = {}
    for kind, fields in _FIELDS.items():
        entries = config[kind]
        _list(entries)
        indexed[kind] = {}
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != fields:
                raise ValueError(f"Unknown or missing {kind} fields; secrets are not accepted")
            _id(entry["id"])
            if entry["id"] in indexed[kind]:
                raise ValueError("Duplicate stable ID")
            indexed[kind][entry["id"]] = entry
            if "name" in entry:
                _text(entry["name"], 150)
            if (
                "partition" in entry
                and entry["partition"] not in PARTITIONS
                and not (kind in {"sources", "accounts"} and entry["partition"] is None)
            ):
                raise ValueError("Explicit content partition required")
            if "credential_ref" in entry:
                ref = entry["credential_ref"]
                if ref is not None and (not isinstance(ref, str) or not _CREDENTIAL.fullmatch(ref)):
                    raise ValueError("Expected Keychain reference, never a raw credential")

    def references(values, kind):
        _list(values)
        if not all(isinstance(v, str) and v in indexed[kind] for v in values) or len(
            set(values)
        ) != len(values):
            raise ValueError("Missing or duplicate referenced entity")

    for category in config["categories"]:
        _style(category["style"], optional=True)
        for key in ("primary_profile_id", "backup_profile_id"):
            if category[key] is not None:
                references([category[key]], "model_profiles")
            role = key.split("_")[0]
            profile = indexed["model_profiles"].get(
                category[key] or f"{category['partition']}_{role}"
            )
            if profile is not None:
                if profile["partition"] != category["partition"]:
                    raise ValueError("Cross-partition model reference")
                if profile["role"] != role:
                    raise ValueError("Wrong model slot role")
    for source in config["sources"]:
        _url(source["url"])
        if source["kind"] not in {"rss", "atom", "web", "github", "huggingface", "draft"}:
            raise ValueError("Unknown source kind")
        _boolean(source["enabled"])
        references(source["category_ids"], "categories")
        if source["partition"] is None and (source["enabled"] or source["category_ids"]):
            raise ValueError("Unclassified source must remain an unassigned disabled draft")
        if any(
            indexed["categories"][key]["partition"] != source["partition"]
            for key in source["category_ids"]
        ):
            raise ValueError("Cross-partition source reference")
    for profile in config["model_profiles"]:
        _text(profile["provider"], 80)
        _text(profile["model"], 200)
        _url(profile["base_url"])
        if profile["role"] not in {"primary", "backup"}:
            raise ValueError("Invalid model role")
        _list(profile["capabilities"], 5)
        if any(c not in {"text", "vision", "image", "stt", "tts"} for c in profile["capabilities"]):
            raise ValueError("Invalid model capability")
    for bot in config["bots"]:
        for key in ("verified", "paired", "adult_allowed"):
            _boolean(bot[key])
        _integer(bot["telegram_id"], 1, 2**52, optional=True)
        _integer(bot["chat_id"], 1, 2**52, optional=True)
        if bot["verified"] and (bot["credential_ref"] is None or bot["telegram_id"] is None):
            raise ValueError("Verified Bot requires identity and credential reference")
        if bot["paired"] and (
            not bot["verified"]
            or bot["chat_id"] != config["owner_id"]
            or config["owner_id"] is None
        ):
            raise ValueError("Bot must pair with the single owner")
    for subscription in config["subscriptions"]:
        references([subscription["category_id"]], "categories")
        references(subscription["source_ids"], "sources")
        references(subscription["bot_ids"], "bots")
        _times(subscription["times"])
        _timezone(subscription["timezone"])
        _boolean(subscription["enabled"])
        _integer(subscription["max_items"], 1, 20)
        _style(subscription["style"], optional=True)
        partition = indexed["categories"][subscription["category_id"]]["partition"]
        if any(
            indexed["sources"][key]["partition"] != partition for key in subscription["source_ids"]
        ):
            raise ValueError("Cross-partition subscription source")
        if any(
            subscription["category_id"] not in indexed["sources"][key]["category_ids"]
            for key in subscription["source_ids"]
        ):
            raise ValueError("Source is not assigned to subscription category")
        if partition == "adult" and any(
            not indexed["bots"][key]["adult_allowed"] for key in subscription["bot_ids"]
        ):
            raise ValueError("Adult target requires explicit opt-in")
    for account in config["accounts"]:
        _style(account["style"], optional=True)
        _text(account["handle"], 30)
        if not re.fullmatch(r"[A-Za-z0-9_]{1,15}", account["handle"]):
            raise ValueError("Invalid X handle")
        if account["remote_id"] is not None and (
            not isinstance(account["remote_id"], str)
            or not re.fullmatch(r"[0-9]{1,30}", account["remote_id"])
        ):
            raise ValueError("Invalid stable X account ID")
        if account["priority"] not in {"normal", "special"}:
            raise ValueError("Invalid account priority")
        if account["subscription_id"] is not None:
            references([account["subscription_id"]], "subscriptions")
            sub = indexed["subscriptions"][account["subscription_id"]]
            if indexed["categories"][sub["category_id"]]["partition"] != account["partition"]:
                raise ValueError("Cross-partition account subscription")
        if account["bot_ids"] is not None:
            references(account["bot_ids"], "bots")
            if account["partition"] == "adult" and any(
                not indexed["bots"][key]["adult_allowed"] for key in account["bot_ids"]
            ):
                raise ValueError("Adult account target requires explicit opt-in")
        _times(account["times"], optional=True)
    try:
        payload = json.dumps(config, ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError):
        raise ValueError("Configuration must be JSON") from None
    if len(payload.encode()) > 1024 * 1024:
        raise ValueError("Configuration too large")


def import_preferences(env_path: Path | None, legacy: dict[str, str]) -> dict:
    """Import a narrow preference allowlist, without interpolation or credentials."""
    values = dotenv_values(env_path, interpolate=False) if env_path is not None else {}
    config = default_config()
    aliases = {
        "简体中文": "zh-Hans",
        "中文": "zh-Hans",
        "English": "en",
        "英文": "en",
        "日本語": "ja",
        "日语": "ja",
        **{x: x for x in LOCALES},
    }
    language = values.get("NEWS_LANGUAGE")
    if language in aliases:
        config["news_output_locale"] = aliases[language]
    zone = values.get("TIMEZONE") or "Asia/Tokyo"
    _timezone(zone)
    config["timezone"] = zone
    times = parse_times(legacy.get("times") or values.get("DIGEST_TIMES") or "09:00,18:00")
    aliases_by_topic = {
        "国际": "world",
        "国际新闻": "world",
        "世界新闻": "world",
        "world": "world",
        "日本": "japan",
        "日本新闻": "japan",
        "japan": "japan",
        "澳洲": "australia",
        "澳大利亚": "australia",
        "australia": "australia",
        "中国": "china",
        "china": "china",
        "数码电子": "electronics",
        "Apple": "electronics",
        "苹果": "electronics",
        "AI": "ai",
        "人工智能": "ai",
    }
    topics = parse_topics(
        legacy.get("topics") or values.get("NEWS_TOPICS") or "国际;日本;澳洲;数码电子"
    )
    subscriptions = []
    for topic in topics:
        key = aliases_by_topic.get(topic)
        if key is None:
            key = "legacy_" + hashlib.sha256(topic.encode()).hexdigest()[:16]
            config["categories"].append(
                dict(
                    id=key,
                    name=topic,
                    partition="normal",
                    primary_profile_id=None,
                    backup_profile_id=None,
                    style=None,
                )
            )
        if any(sub["category_id"] == key for sub in subscriptions):
            continue
        subscriptions.append(
            dict(
                id=f"sub_{key}",
                name=topic,
                category_id=key,
                source_ids=[],
                bot_ids=[],
                times=times.copy(),
                timezone=zone,
                enabled=False,
                style="text",
                max_items=5,
            )
        )
    config["subscriptions"] = subscriptions
    size = values.get("DIGEST_SIZE")
    if size:
        try:
            size = int(size)
        except ValueError:
            raise ValueError("Invalid legacy digest size") from None
        for subscription in subscriptions:
            subscription["max_items"] = size
    feeds = list(
        dict.fromkeys(
            url.strip() for url in (values.get("NEWS_FEEDS") or "").split(";") if url.strip()
        )
    )
    _list(feeds, 20)
    for url in feeds:
        _url(url)
        key = "source_" + hashlib.sha256(url.encode()).hexdigest()[:16]
        config["sources"].append(
            dict(
                id=key,
                name=urlsplit(url).hostname,
                url=url,
                kind="rss",
                partition="normal",
                category_ids=[s["category_id"] for s in subscriptions],
                enabled=False,
            )
        )
        for subscription in subscriptions:
            subscription["source_ids"].append(key)
    owner = legacy.get("owner_id") or values.get("TELEGRAM_OWNER_ID")
    if owner:
        try:
            config["owner_id"] = int(owner)
        except ValueError:
            raise ValueError("Invalid legacy owner ID") from None
    # Prototype defaults are not evidence that the user chose an override.
    model = values.get("OPENAI_MODEL")
    if model and model != "gpt-5-mini" and re.fullmatch(r"[A-Za-z0-9._:/-]{1,200}", model):
        config["model_profiles"][0]["model"] = model
    url = values.get("OPENAI_BASE_URL")
    if url and "${" not in url:
        _url(url)
        config["model_profiles"][0]["base_url"] = url
    validate_config(config)
    return deepcopy(config)
