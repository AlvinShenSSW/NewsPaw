"""Target allocation, impact previews and live per-Bot authorization checks."""

from copy import deepcopy
from dataclasses import asdict

from ..app_config import in_x_aggregate, validate_config
from ..credentials import CredentialError
from ..routing import resolve_route
from .registry import Binding, TelegramError, remove_bot


class TargetError(CredentialError):
    pass


def _entry(config, kind, identity):
    entry = next((e for e in config[kind] if e["id"] == identity), None)
    if entry is None:
        raise TargetError("missing_" + kind.rstrip("s"))
    return entry


def _partition(config, subscription):
    return _entry(config, "categories", subscription["category_id"])["partition"]


def _special(config, identity):
    a = _entry(config, "accounts", identity)
    if a["priority"] != "special":
        raise TargetError("special_account_required")
    if a["subscription_id"] is None:
        raise TargetError("account_subscription_required")
    sub = _entry(config, "subscriptions", a["subscription_id"])
    if a["partition"] is None or a["partition"] != _partition(config, sub):
        raise TargetError("account_partition_mismatch")
    return a, sub


def _scopes(config):
    result = {}
    subscriptions = {sub["id"]: sub for sub in config["subscriptions"]}
    members = {key: [] for key in subscriptions}
    for a in config["accounts"]:
        sub = subscriptions.get(a["subscription_id"])
        targets = a["bot_ids"]
        if a["priority"] == "special" and targets is None and sub:
            targets = sub["bot_ids"]
        if sub and in_x_aggregate(a, sub):
            members[sub["id"]].append(a["id"])
        result[("account", a["id"])] = (
            a["partition"],
            a["subscription_id"],
            tuple(sorted(targets or [])),
        )
    for key, sub in subscriptions.items():
        result[("subscription", key)] = (
            _partition(config, sub),
            tuple(sorted(sub["bot_ids"])),
            tuple(sorted(members[key])),
        )
    return result


def _affected(before, after):
    old, new = _scopes(before), _scopes(after)
    changed = [k for k in old.keys() | new.keys() if old.get(k) != new.get(k)]
    return dict(
        affected_subscriptions=sorted(k[1] for k in changed if k[0] == "subscription"),
        affected_accounts=sorted(k[1] for k in changed if k[0] == "account"),
    )


class TargetManager:
    def __init__(self, credentials, registry):
        self.credentials, self.registry = credentials, registry
        self.store = credentials.store

    def preview(self, subscription_id, *, account_id=None):
        revision, config = self.store.load_config()
        _entry(config, "subscriptions", subscription_id)
        if account_id is not None:
            _, account_sub = _special(config, account_id)
            if account_sub["id"] != subscription_id:
                raise TargetError("account_subscription_mismatch")
        route = resolve_route(config, revision, subscription_id, account_id=account_id)
        effective = route.effective
        status, bindings = {}, []
        targets = []
        for target in effective.get("targets", []):
            identity = target["id"]
            try:
                current = self.registry.status(identity)
                reason = (
                    "paused"
                    if current["paused"]
                    else "unverified"
                    if not current["verified"]
                    else "unpaired"
                    if not current["paired"]
                    else "adult_not_allowed"
                    if effective["partition"] == "adult" and not target["adult_allowed"]
                    else "ready"
                )
                if reason == "ready":
                    bindings.append(asdict(self.registry.snapshot(identity)))
                target = {
                    **target,
                    "verified": current["verified"],
                    "paired": current["paired"] and not current["paused"],
                    "telegram_id": current["telegram_id"],
                    "chat_id": current["chat_id"],
                }
            except TelegramError:
                reason = (
                    "unpaired" if any(b["id"] == identity for b in config["bots"]) else "missing"
                )
            status[identity] = reason
            targets.append(target)
        effective["targets"] = targets
        effective["bots"] = [t for t in targets if status[t["id"]] == "ready"]
        effective["target_diagnostics"] = {
            key: reason for key, reason in status.items() if reason != "ready"
        }
        blockers = [b for b in route.blockers if b not in {"no_target", "target_unpaired"}]
        if not targets:
            blockers.append("no_target")
        elif not bindings:
            blockers.append("no_ready_target")
        return dict(
            revision=revision,
            subscription_id=subscription_id,
            account_id=account_id,
            effective=effective,
            explanation=route.explanation,
            blockers=blockers,
            target_status=status,
            ready_bot_ids=sorted(b["bot_id"] for b in bindings),
            bindings=bindings,
            target_origin=route.explanation.get("bots"),
            fingerprint=route.fingerprint,
        )

    def revalidate_target(self, subscription_id, bot_id, binding, *, account_id=None):
        if not isinstance(binding, Binding) or binding.bot_id != bot_id:
            raise TargetError("invalid_binding")
        preview = self.preview(subscription_id, account_id=account_id)
        if not preview["effective"]["enabled"]:
            raise TargetError("subscription_disabled")
        if preview["target_status"].get(bot_id) != "ready":
            raise TargetError("target_not_ready")
        try:
            return self.registry.revalidate(binding)
        except TelegramError:
            raise TargetError("binding_changed") from None

    def _targets(self, config, values, partition):
        if (
            not isinstance(values, list)
            or len(values) > 200
            or any(not isinstance(v, str) for v in values)
        ):
            raise TargetError("invalid_targets")
        if len(values) != len(set(values)):
            raise TargetError("duplicate_target")
        for identity in values:
            bot = _entry(config, "bots", identity)
            if partition == "adult" and not bot["adult_allowed"]:
                raise TargetError("adult_permission_required")
        return list(values)

    async def _mutate(self, revision, change):
        async def operation():
            config = self.credentials._current(revision)
            before = deepcopy(config)
            details = change(config) or {}
            validate_config(config)
            affected = _affected(before, config)
            saved = (
                await self.credentials._commit(config, revision)
                if config != before
                else {"revision": revision}
            )
            return {**saved, **affected, **details}

        return await self.credentials._submit(operation)

    async def set_subscription(self, identity, bot_ids, revision):
        def change(config):
            sub = _entry(config, "subscriptions", identity)
            sub["bot_ids"] = self._targets(config, bot_ids, _partition(config, sub))

        return await self._mutate(revision, change)

    async def set_category(self, identity, bot_ids, revision):
        def change(config):
            category = _entry(config, "categories", identity)
            targets = self._targets(config, bot_ids, category["partition"])
            for sub in config["subscriptions"]:
                if sub["category_id"] == identity:
                    sub["bot_ids"] = list(targets)

        return await self._mutate(revision, change)

    async def set_account(self, identity, bot_ids, revision):
        def change(config):
            a, _ = _special(config, identity)
            a["bot_ids"] = (
                None if bot_ids is None else self._targets(config, bot_ids, a["partition"])
            )

        return await self._mutate(revision, change)

    async def account_partition(self, identity, partition, revision):
        if partition not in {"normal", "adult", None}:
            raise TargetError("invalid_partition")

        def change(config):
            account = _entry(config, "accounts", identity)
            if account["partition"] != partition:
                account.pop("include_in_aggregate", None)
                account.pop("post_types", None)
                account.update(
                    partition=partition, subscription_id=None, bot_ids=[], times=None, style=None
                )

        return await self._mutate(revision, change)

    async def adult_permission(self, identity, allowed, revision):
        if type(allowed) is not bool:
            raise TargetError("invalid_adult_permission")

        def change(config):
            bot = _entry(config, "bots", identity)
            bot["adult_allowed"] = allowed
            if not allowed:
                for sub in config["subscriptions"]:
                    if _partition(config, sub) == "adult":
                        sub["bot_ids"] = [b for b in sub["bot_ids"] if b != identity]
                for account in config["accounts"]:
                    if account["partition"] == "adult" and account["bot_ids"] is not None:
                        account["bot_ids"] = [b for b in account["bot_ids"] if b != identity]

        return await self._mutate(revision, change)

    def bot_impact(self, identity):
        revision, config = self.store.load_config()
        return self._bot_impact(config, identity, revision)

    def _bot_impact(self, config, identity, revision):
        _entry(config, "bots", identity)
        subs = [s for s in config["subscriptions"] if identity in s["bot_ids"]]
        accounts = []
        for a in config["accounts"]:
            if a["priority"] != "special":
                continue
            sub = next(
                (s for s in config["subscriptions"] if s["id"] == a["subscription_id"]), None
            )
            targets = a["bot_ids"] if a["bot_ids"] is not None else sub["bot_ids"] if sub else []
            if identity in targets:
                accounts.append(
                    dict(
                        id=a["id"],
                        inherited=a["bot_ids"] is None,
                        last_target=len(targets) == 1,
                        bot_ids=sorted(targets),
                    )
                )
        return dict(
            revision=revision,
            bot_id=identity,
            subscriptions=sorted(s["id"] for s in subs),
            categories=sorted({s["category_id"] for s in subs}),
            last_target_subscriptions=sorted(s["id"] for s in subs if s["bot_ids"] == [identity]),
            subscription_targets={s["id"]: sorted(s["bot_ids"]) for s in subs},
            accounts=accounts,
        )

    async def delete_bot(self, identity, revision):
        def change(config):
            impact = self._bot_impact(config, identity, revision)
            remove_bot(config, identity)
            return {"impact": impact}

        return await self._mutate(revision, change)
