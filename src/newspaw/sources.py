"""Explicit publisher subscriptions; a source name is never invented by the model."""

import tomllib
from pathlib import Path

from .config import ConfigError
from .news import public_url


def load_sources(path: Path | None) -> dict[str, list[str]]:
    if path is None:
        return {}
    if not path.exists():
        raise ConfigError("找不到来源配置 SOURCES_FILE，请设置 sources.toml 的有效路径。")
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
        result = {}
        groups = data["topics"]
        if not isinstance(groups, dict) or len(groups) > 30:
            raise ValueError
        for name, group in groups.items():
            feeds, aliases = group["feeds"], group.get("aliases", [])
            if not isinstance(feeds, list) or not 1 <= len(feeds) <= 20:
                raise ValueError
            if any(
                not isinstance(url, str) or not public_url(url, https_only=True) for url in feeds
            ):
                raise ValueError
            if not isinstance(aliases, list) or any(not isinstance(item, str) for item in aliases):
                raise ValueError
            for alias in [name, *aliases]:
                if alias.casefold() in result and result[alias.casefold()] != feeds:
                    raise ValueError
                result[alias.casefold()] = feeds
        return result
    except (ValueError, KeyError, TypeError, OSError):
        raise ConfigError(
            "来源配置无效，请检查 sources.toml 的 topics、aliases 和 HTTPS feeds。"
        ) from None
