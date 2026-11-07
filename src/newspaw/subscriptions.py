"""Versioned local subscription drafts and sanitized activation previews."""

from copy import deepcopy

from .app_config import validate_config
from .credentials import CredentialError
from .providers import ProfileRegistry, ProviderError
from .routing import resolve_route
from .telegram.registry import TelegramError

_REQUIRED = {
    "id",
    "name",
    "category_id",
    "source_ids",
    "source_mode",
    "bot_ids",
    "times",
    "timezone",
    "max_items",
    "style",
}


class SubscriptionError(CredentialError):
    pass


class Subscriptions:
    def __init__(self, credentials, sources, bots):
        self.credentials, self.sources, self.bots = credentials, sources, bots
        self.store = credentials.store
        self.profiles = ProfileRegistry(self.store)

    def _candidate(self, config, draft, revision):
        if not isinstance(draft, dict) or not _REQUIRED <= draft.keys() <= _REQUIRED | {
            "focus_weights"
        }:
            raise SubscriptionError("invalid_subscription_draft")
        value = deepcopy(draft)
        value["enabled"] = False
        entries = config["subscriptions"]
        existing = next((row for row in entries if row["id"] == value["id"]), None)
        if existing is not None and existing["category_id"] != value["category_id"]:
            raise SubscriptionError("subscription_category_is_fixed")
        if existing is None:
            entries.append(value)
        else:
            entries[entries.index(existing)] = value
        try:
            validate_config(config)
        except ValueError:
            raise SubscriptionError("invalid_subscription_draft") from None
        route = resolve_route(config, revision, value["id"])
        return value, route

    def _preview(self, draft, route, config):
        effective = route.effective
        blockers = [code for code in route.blockers if code != "subscription_disabled"]
        if not draft["times"]:
            blockers.append("schedule_missing")
        profiles = {}
        for role in ("primary", "backup"):
            profile = effective.get(role)
            if profile is None:
                continue
            try:
                status = self.profiles.status(profile["id"])["text"]["state"]
            except ProviderError:
                status = "untested"
            if status != "verified":
                blockers.append(role + "_unverified")
            profiles[role] = dict(
                id=profile["id"],
                provider=profile["provider"],
                model=profile["model"],
                status=status,
            )
        valid_bots = []
        for bot in effective["bots"]:
            try:
                binding = self.bots.snapshot(bot["id"])
            except TelegramError:
                continue
            if binding.owner_id == config["owner_id"]:
                valid_bots.append(bot["id"])
        if not valid_bots:
            blockers.append("no_ready_bot")
        configured = {source["id"]: source for source in config["sources"]}
        sources = []
        for entry in effective["sources"]:
            source = configured[entry["id"]]
            ready = source["enabled"] and self.sources._ready(source)
            if not ready:
                blockers.append("source_preview_required")
            sources.append(dict(id=source["id"], name=source["name"], ready=ready))
        return dict(
            revision=route.revision,
            subscription_id=draft["id"],
            partition=effective["partition"],
            timezone=effective["timezone"],
            times=effective["times"],
            style=effective["style"],
            profiles=profiles,
            bots=valid_bots,
            sources=sources,
            blockers=list(dict.fromkeys(blockers)),
        )

    def preview(self, draft, revision):
        config = self.credentials._current(revision)
        value, route = self._candidate(config, draft, revision)
        return self._preview(value, route, config)

    async def save(self, draft, revision, *, enable=False):
        if type(enable) is not bool:
            raise SubscriptionError("invalid_subscription_draft")

        async def operation():
            config = self.credentials._current(revision)
            value, route = self._candidate(config, draft, revision)
            preview = self._preview(value, route, config)
            if enable and preview["blockers"]:
                raise SubscriptionError("subscription_not_ready")
            value["enabled"] = enable
            validate_config(config)
            saved = await self.credentials._commit(config, revision)
            return dict(
                revision=saved["revision"],
                subscription_id=value["id"],
                enabled=enable,
                blockers=preview["blockers"],
            )

        return await self.credentials._submit(operation)
