"""Pure, explainable routes. No network, credential reads, or execution authority."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from .app_config import STYLES, validate_config

# Version of the effective route contract, independent of additive config fields.
ROUTE_SCHEMA_VERSION = 2


class RouteBlocked(ValueError):
    pass


class RouteStale(ValueError):
    pass


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _fields(entry, names):
    return {key: entry[key] for key in names.split()}


@dataclass(frozen=True)
class RouteSnapshot:
    revision: int
    subscription_id: str
    account_id: str | None
    request_style: str | None
    fingerprint: str
    blockers: tuple[str, ...]
    _effective: str
    _explanation: str

    @property
    def effective(self) -> dict:
        return json.loads(self._effective)

    @property
    def explanation(self) -> dict:
        return json.loads(self._explanation)


def resolve_route(config, revision, subscription_id, *, account_id=None, style=None):
    validate_config(config)
    if type(revision) is not int or revision < 1:
        raise ValueError("Invalid configuration revision")
    if style is not None and style not in STYLES:
        raise ValueError("Invalid requested delivery style")
    index = {
        kind: {entry["id"]: entry for entry in config[kind]}
        for kind in ("categories", "subscriptions", "sources", "accounts", "model_profiles", "bots")
    }
    blockers = []
    explanation = {
        "language": "global news output locale",
        "credentials": "references only; live check required",
        "execution": "preflight only; revalidate before every side effect",
    }
    payload = {
        "schema_version": ROUTE_SCHEMA_VERSION,
        "subscription_id": subscription_id,
        "owner_id": config["owner_id"],
        "locale": config["news_output_locale"],
    }

    def snapshot():
        reasons = tuple(dict.fromkeys(blockers))
        serialized = _json(payload)
        fingerprint = hashlib.sha256(_json([payload, reasons]).encode()).hexdigest()
        return RouteSnapshot(
            revision,
            subscription_id,
            account_id,
            style,
            fingerprint,
            reasons,
            serialized,
            _json(explanation),
        )

    subscription = index["subscriptions"].get(subscription_id)
    if subscription is None:
        blockers.append("missing_subscription")
        return snapshot()
    category = index["categories"][subscription["category_id"]]
    partition = category["partition"]
    payload.update(
        category_id=category["id"],
        partition=partition,
        enabled=subscription["enabled"],
        max_items=subscription["max_items"],
    )
    selected_account = None
    if account_id is not None:
        selected_account = index["accounts"].get(account_id)
        if selected_account is None:
            blockers.append("missing_account")
            return snapshot()
        if selected_account["partition"] is None:
            blockers.append("unclassified_account")
            return snapshot()
        if selected_account["subscription_id"] != subscription_id:
            blockers.append("account_subscription_mismatch")
            return snapshot()
        payload["account"] = _fields(selected_account, "id remote_id handle partition priority")
        if selected_account["remote_id"] is None:
            blockers.append("account_identity_unverified")
    elif category["id"] in {"x", "x_adult"}:
        members = sorted(
            (
                a
                for a in config["accounts"]
                if a["subscription_id"] == subscription_id and a["priority"] == "normal"
            ),
            key=lambda a: a["id"],
        )
        payload["accounts"] = [
            _fields(a, "id remote_id handle partition priority") for a in members
        ]
        if not members:
            blockers.append("no_accounts")
        if any(a["remote_id"] is None for a in members):
            blockers.append("account_identity_unverified")
        explanation["accounts"] = "ordinary members; special daily accounts excluded"
    if not subscription["enabled"]:
        blockers.append("subscription_disabled")
    if config["owner_id"] is None:
        blockers.append("missing_owner")
    special = (
        selected_account if selected_account and selected_account["priority"] == "special" else None
    )
    choices = [
        ("request", style),
        ("special_account", special["style"] if special else None),
        ("subscription", subscription["style"]),
        ("category", category["style"]),
        ("partition_default", config["group_styles"][partition]),
    ]
    origin, effective_style = next((name, value) for name, value in choices if value is not None)
    explanation["style"] = origin
    payload.update(style=effective_style, timezone=subscription["timezone"])
    payload["times"] = (
        special["times"] if special and special["times"] is not None else subscription["times"]
    )
    explanation["times"] = (
        "special_account" if special and special["times"] is not None else "subscription"
    )
    for role in ("primary", "backup"):
        override = category[f"{role}_profile_id"]
        profile = index["model_profiles"].get(override or f"{partition}_{role}")
        explanation[role] = "category" if override else "partition_default"
        payload[role] = profile
        if profile is None:
            blockers.append(f"missing_{role}")
        elif profile["partition"] != partition or profile["role"] != role:
            blockers.append(f"incompatible_{role}")
            payload[role] = None
        elif profile["credential_ref"] is None:
            blockers.append(f"missing_{role}_credential")
    if subscription["source_ids"]:
        sources = [index["sources"][key] for key in subscription["source_ids"]]
        explanation["sources"] = "explicit subscription selection"
    else:
        sources = [
            source
            for source in config["sources"]
            if category["id"] in source["category_ids"] and source["enabled"]
        ]
        explanation["sources"] = "enabled category sources"
    payload["sources"] = [
        _fields(s, "id kind url partition enabled") for s in sorted(sources, key=lambda s: s["id"])
    ]
    if any(not s["enabled"] for s in sources):
        blockers.append("source_disabled")
    if any(s["kind"] == "draft" for s in sources):
        blockers.append("source_unadapted")
    if not sources and selected_account is None and category["id"] not in {"x", "x_adult"}:
        blockers.append("no_sources")
    bot_ids = (
        special["bot_ids"]
        if special and special["bot_ids"] is not None
        else subscription["bot_ids"]
    )
    explanation["bots"] = (
        "special_account" if special and special["bot_ids"] is not None else "subscription"
    )
    bots = [index["bots"][key] for key in sorted(bot_ids)]
    payload["targets"] = [
        _fields(b, "id credential_ref telegram_id chat_id verified paired adult_allowed")
        for b in bots
    ]
    payload["bots"] = [b for b in payload["targets"] if b["verified"] and b["paired"]]
    payload["target_diagnostics"] = {
        b["id"]: "target_unpaired" for b in bots if not b["verified"] or not b["paired"]
    }
    if not bots:
        blockers.append("no_target")
    elif not payload["bots"]:
        blockers.append("target_unpaired")
    return snapshot()
