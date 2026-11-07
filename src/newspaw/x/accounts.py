"""The owner's X directory. Account metadata and membership are separate from posts."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import sqlite3
from contextlib import suppress
from datetime import UTC, datetime

import httpx

from ..app_config import X_DEFAULT_POST_TYPES, in_x_aggregate, new_id, x_post_types
from ..budget import BudgetError, BudgetLedger
from ..credentials import CredentialError
from .client import XClient, XReadError, handle, list_id

_REQUEST = re.compile(r"[A-Za-z0-9_.:-]{1,140}")
_PARTITIONS = ("normal", "adult")
_QUOTE = {"known": True, "source": "x_read_cap"}


class XError(CredentialError):
    pass


def _json(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def _now():
    return datetime.now(UTC).isoformat()


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_identities (
            account_id TEXT PRIMARY KEY, remote_id TEXT UNIQUE, handle TEXT NOT NULL,
            state TEXT NOT NULL, credential_ref TEXT, observed_at TEXT, direct INTEGER NOT NULL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_lists (
            id TEXT PRIMARY KEY, partition TEXT NOT NULL, default_adult INTEGER NOT NULL,
            name TEXT, state TEXT NOT NULL, authorized INTEGER NOT NULL,
            credential_ref TEXT, members TEXT NOT NULL, checked_at TEXT
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_operations (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, scope_id TEXT NOT NULL, arguments TEXT NOT NULL,
            state TEXT NOT NULL, result TEXT NOT NULL, attempts TEXT NOT NULL, updated_at TEXT NOT NULL
        )"""
    )
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS x_operation_one_active
           ON x_operations(kind,scope_id) WHERE state='running'"""
    )


def invalidate_accounts(db, before, after):
    old = {a["id"]: (a["remote_id"], a["handle"]) for a in before["accounts"]}
    new = {a["id"]: (a["remote_id"], a["handle"]) for a in after["accounts"]}
    for identity, value in old.items():
        if new.get(identity) != value:
            db.execute(
                "UPDATE x_identities SET state='invalidated' WHERE account_id=?", (identity,)
            )


def _account(config, identity):
    item = next((a for a in config["accounts"] if a["id"] == identity), None)
    if item is None:
        raise XError("missing_account")
    return item


def _draft(identity, name, partition=None):
    return dict(
        id=identity,
        remote_id=None,
        handle=name,
        partition=partition,
        priority="normal",
        subscription_id=None,
        bot_ids=[],
        times=None,
        style=None,
    )


class XDirectory:
    def __init__(self, credentials, targets, *, client_factory=XClient):
        self.credentials, self.targets = credentials, targets
        self.store, self.db = credentials.store, credentials.store._db
        self.client_factory = client_factory
        self.budget = BudgetLedger(self.store)

    def _identity(self, identity):
        row = self.db.execute(
            """SELECT remote_id,handle,state,credential_ref,observed_at,direct
               FROM x_identities WHERE account_id=?""",
            (identity,),
        ).fetchone()
        if row is None:
            return None
        return dict(
            zip(
                ("remote_id", "handle", "state", "credential_ref", "observed_at", "direct"),
                row,
                strict=True,
            )
        )

    def _list(self, identity):
        cursor = self.db.execute("SELECT * FROM x_lists WHERE id=?", (list_id(identity),))
        row = cursor.fetchone()
        if row is None:
            raise XError("missing_list")
        value = dict(zip((key[0] for key in cursor.description), row, strict=True))
        value["members"] = json.loads(value["members"])
        return value

    def _membership(self, ref):
        if ref is None:
            return set()
        return {
            (member["account_id"], member["remote_id"])
            for (members,) in self.db.execute(
                "SELECT members FROM x_lists WHERE authorized=1 AND credential_ref=?", (ref,)
            )
            for member in json.loads(members)
        }

    @staticmethod
    def _identity_matches(account, observed):
        return (
            observed is not None
            and observed["state"] != "invalidated"
            and observed["remote_id"] is not None
            and observed["remote_id"] == account["remote_id"]
            and observed["handle"] == account["handle"]
        )

    def _account_status(self, account, ref, members, subscriptions):
        observed = self._identity(account["id"])
        state = observed["state"] if observed else "unverified"
        if (
            observed
            and observed["credential_ref"] is not None
            and observed["credential_ref"] != ref
        ):
            state = "credential_changed"
        elif state in {"ready", "protected"} and not self._identity_matches(account, observed):
            state = "unverified"
        direct = bool(observed["direct"]) if observed else True
        member = (account["id"], account["remote_id"]) in members
        subscription = subscriptions.get(account["subscription_id"])
        expected_category = "x_adult" if account["partition"] == "adult" else "x"
        return {
            **account,
            "state": state,
            "observed_at": observed["observed_at"] if observed else None,
            "direct": direct,
            "member_active": member,
            "can_collect": (
                state == "ready"
                and account["partition"] in _PARTITIONS
                and subscription is not None
                and subscription["category_id"] == expected_category
                and subscription["enabled"]
                and (direct or member)
            ),
        }

    def account_status(self, identity):
        _, config = self.store.load_config()
        ref = config["x_api"]["credential_ref"]
        return self._account_status(
            _account(config, identity),
            ref,
            self._membership(ref),
            {sub["id"]: sub for sub in config["subscriptions"]},
        )

    def binding(self, identity):
        """Current verified scope for X02. No network or model call."""
        account = self.account_status(identity)
        if not account["can_collect"]:
            raise XError("account_not_collectable")
        return account

    def accounts(self):
        revision, config = self.store.load_config()
        ref = config["x_api"]["credential_ref"]
        members = self._membership(ref)
        subscriptions = {sub["id"]: sub for sub in config["subscriptions"]}
        return dict(
            revision=revision,
            credential_configured=ref is not None,
            accounts=[
                self._account_status(a, ref, members, subscriptions) for a in config["accounts"]
            ],
        )

    def list_status(self, identity):
        entry = self._list(identity)
        current = self.store.load_config()[1]["x_api"]["credential_ref"]
        reference = entry.pop("credential_ref")
        entry["current"] = bool(entry.pop("authorized") and reference == current)
        entry["default_adult"] = bool(entry["default_adult"])
        if reference is not None and reference != current:
            entry["state"] = "credential_changed"
        return entry

    def lists(self):
        return [
            self.list_status(row[0])
            for row in self.db.execute("SELECT id FROM x_lists ORDER BY id")
        ]

    async def add_account(self, value, revision, *, partition=None):
        name = handle(value)
        if partition not in (*_PARTITIONS, None):
            raise XError("invalid_partition")

        async def operation():
            with self.store._write():
                config = self.credentials._current(revision)
                account = next((a for a in config["accounts"] if a["handle"].lower() == name), None)
                result_revision = revision
                if account is None:
                    if len(config["accounts"]) >= 200:
                        raise XError("account_limit")
                    account = _draft(new_id("accounts"), name, partition)
                    config["accounts"].append(account)
                    result_revision = self.store._save_config_tx(config, revision)
                identity = account["id"]
                self.db.execute(
                    """INSERT INTO x_identities VALUES (?,NULL,?,'unverified',NULL,NULL,1)
                       ON CONFLICT(account_id) DO UPDATE SET direct=1""",
                    (identity, account["handle"]),
                )
            return dict(revision=result_revision, account=self.account_status(identity))

        return await self.credentials._submit(operation)

    def partition_impact(self, identity):
        revision, config = self.store.load_config()
        account = _account(config, identity)
        partition, sub_id = account["partition"], account["subscription_id"]
        sub = next((item for item in config["subscriptions"] if item["id"] == sub_id), None)
        aggregate = bool(sub and in_x_aggregate(account, sub))
        special = bool(sub and account["priority"] == "special")
        special_bots = (
            account["bot_ids"]
            if account["bot_ids"] is not None
            else (sub["bot_ids"] if sub else [])
        )
        bodies = self.db.execute(
            """SELECT count(*) FROM x_posts
               WHERE partition=? AND account_id=? AND body IS NOT NULL AND tombstone=0""",
            (partition, identity),
        ).fetchone()[0]
        pending = self.db.execute(
            """SELECT count(*) FROM pipeline_jobs j
               LEFT JOIN delivery_manifests d ON d.job_id=j.id
               WHERE j.partition=? AND j.cancelled=0
                 AND (j.stage IN ('collecting','editing','preparing_media')
                      OR (j.stage='awaiting_delivery' AND d.stopped_reason IS NULL AND
                          (d.job_id IS NULL OR EXISTS(
                            SELECT 1 FROM delivery_targets t,json_each(t.parts) part
                            WHERE t.job_id=j.id AND t.selected=1 AND t.reason IS NULL
                              AND json_extract(part.value,'$.state')
                                  IN ('pending','inflight','outcome_unknown')
                          ))))
                 AND (j.account_key=? OR (j.account_key='' AND EXISTS(
                     SELECT 1 FROM json_each(j.payload,'$.scopes') scope
                     WHERE json_extract(scope.value,'$.x_digest.account')=?
                 )))""",
            (partition, identity, identity),
        ).fetchone()[0]
        return dict(
            revision=revision,
            account_id=identity,
            partition=partition,
            subscription_id=sub_id,
            aggregate=aggregate,
            special=special,
            aggregate_bot_ids=sorted(sub["bot_ids"]) if aggregate else [],
            special_bot_ids=sorted(special_bots) if special else [],
            clears_special_overrides=account["priority"] == "special"
            and any(account[name] is not None for name in ("bot_ids", "times", "style")),
            clears_post_types="post_types" in account,
            cached_posts=bodies,
            pending_jobs=pending,
        )

    async def classify(self, identity, partition, revision):
        return await self.targets.account_partition(identity, partition, revision)

    async def remove_account(self, identity, revision):
        def change(config):
            account = _account(config, identity)
            config["accounts"].remove(account)

        return await self.targets._mutate(revision, change)

    async def set_route(
        self,
        identity,
        subscription_id,
        priority,
        revision,
        *,
        include_in_aggregate=None,
        post_types=None,
        overrides=None,
    ):
        if priority not in ("normal", "special"):
            raise XError("invalid_priority")
        if include_in_aggregate is not None and (
            type(include_in_aggregate) is not bool
            or (include_in_aggregate and (priority != "special" or subscription_id is None))
        ):
            raise XError("invalid_aggregate_membership")
        if overrides is not None and (
            not isinstance(overrides, dict)
            or overrides.keys() != {"times", "bot_ids", "style"}
            or priority != "special"
            or subscription_id is None
        ):
            raise XError("invalid_account_overrides")
        if post_types is not None:
            try:
                post_types = x_post_types(post_types)
            except ValueError:
                raise XError("invalid_post_types") from None

        def change(config):
            account = _account(config, identity)
            prior = account.copy()
            if subscription_id is not None:
                sub = next((s for s in config["subscriptions"] if s["id"] == subscription_id), None)
                category = "x_adult" if account["partition"] == "adult" else "x"
                if account["partition"] is None or sub is None or sub["category_id"] != category:
                    raise XError("incompatible_subscription")
            if account["priority"] != priority:
                account.update(
                    bot_ids=None if priority == "special" else [], times=None, style=None
                )
            if priority != "special" or account["subscription_id"] != subscription_id:
                account.pop("include_in_aggregate", None)
            if include_in_aggregate is not None and priority == "special":
                if include_in_aggregate:
                    account["include_in_aggregate"] = True
                else:
                    account.pop("include_in_aggregate", None)
            if post_types is not None:
                if tuple(post_types) == X_DEFAULT_POST_TYPES:
                    account.pop("post_types", None)
                else:
                    account["post_types"] = post_types
            if overrides is not None:
                bot_ids = overrides["bot_ids"]
                account.update(
                    times=overrides["times"],
                    style=overrides["style"],
                    bot_ids=(
                        self.targets._targets(config, bot_ids, account["partition"])
                        if bot_ids is not None
                        else None
                    ),
                )
            account.update(subscription_id=subscription_id, priority=priority)
            if account != prior:
                affected = {prior["subscription_id"], subscription_id} - {None}
                return dict(
                    affected_accounts=[identity],
                    affected_subscriptions=sorted(affected),
                )
            return None

        return await self.targets._mutate(revision, change)

    def add_list(self, value, partition, revision, *, default_adult=False):
        identity = list_id(value)
        if (
            partition not in _PARTITIONS
            or type(default_adult) is not bool
            or (default_adult and partition != "adult")
        ):
            raise XError("invalid_list_partition")
        with self.store._write():
            self.credentials._current(revision)
            existing = self.db.execute(
                "SELECT partition,default_adult FROM x_lists WHERE id=?", (identity,)
            ).fetchone()
            if existing:
                if existing != (partition, int(default_adult)):
                    raise XError("list_conflict")
            else:
                if self.db.execute("SELECT COUNT(*) FROM x_lists").fetchone()[0] >= 30:
                    raise XError("list_limit")
                self.db.execute(
                    "INSERT INTO x_lists VALUES (?,?,?,NULL,'unverified',0,NULL,'[]',NULL)",
                    (identity, partition, int(default_adult)),
                )
        return self.list_status(identity)

    def _operation(self, identity):
        row = self.db.execute(
            "SELECT kind,scope_id,arguments,state,result,attempts,updated_at FROM x_operations WHERE id=?",
            (identity,),
        ).fetchone()
        if row is None:
            return None
        kind, scope, args, state, result, attempts, updated = row
        return dict(
            request_id=identity,
            kind=kind,
            scope_id=scope,
            arguments=json.loads(args),
            state=state,
            result=json.loads(result),
            attempts=json.loads(attempts),
            updated_at=updated,
        )

    def operation(self, identity):
        if not isinstance(identity, str) or not _REQUEST.fullmatch(identity):
            raise XError("invalid_request_id")
        item = self._operation(identity)
        if item is None:
            raise XError("missing_operation")
        item.pop("arguments")
        result = item.pop("result")
        return {**item, **result}

    def _start(self, kind, scope, request_id, revision, **options):
        if not isinstance(request_id, str) or not _REQUEST.fullmatch(request_id):
            raise XError("invalid_request_id")
        if not isinstance(scope, str) or not _REQUEST.fullmatch(scope):
            raise XError("invalid_scope")
        args = dict(revision=revision, **options)
        with self.store._write():
            prior = self._operation(request_id)
            if prior:
                if (prior["kind"], prior["scope_id"], prior["arguments"]) != (kind, scope, args):
                    raise XError("request_id_conflict")
                return None
            config = self.credentials._current(revision)
            subject = _account(config, scope) if kind == "account" else self._list(scope)
            if self.db.execute(
                "SELECT 1 FROM x_operations WHERE kind=? AND scope_id=? AND state='running'",
                (kind, scope),
            ).fetchone():
                raise XError("operation_busy")
            self.db.execute(
                "INSERT INTO x_operations VALUES (?,?,?,?,'running','{}','[]',?)",
                (request_id, kind, scope, _json(args), _now()),
            )
        return dict(
            id=request_id,
            kind=kind,
            scope=scope,
            subject=subject,
            revision=revision,
            ref=config["x_api"]["credential_ref"],
            partition=subject["partition"] or "normal",
        )

    def _current(self, context):
        revision, config = self.store.load_config()
        if revision != context["revision"] or config["x_api"]["credential_ref"] != context["ref"]:
            raise XError("configuration_changed")
        return config

    def _finish(self, context, state, result):
        self.db.execute(
            "UPDATE x_operations SET state=?,result=?,updated_at=? WHERE id=? AND state='running'",
            (state, _json(result), _now(), context["id"]),
        )

    async def _read(self, context, limit, request):
        identity = context["id"]
        with self.store._write():
            self._current(context)
            op = self._operation(identity)
            if op["state"] != "running":
                raise XError("operation_changed")
            attempts = op["attempts"]
            task = "xmeta." + hashlib.sha256(identity.encode()).hexdigest()
            budget_id = f"{task}.{len(attempts) + 1}"
            self.budget._reserve(
                budget_id,
                task,
                max_units=limit,
                quote=_QUOTE,
                meter="x",
                partition=context["partition"],
                account_id=context["scope"] if context["kind"] == "account" else None,
            )
            self.budget._begin_attempt(budget_id)
            attempts.append(dict(id=budget_id, state="inflight", started_at=_now()))
            self._save_attempts(identity, attempts)
        try:
            result, units = await request()
        except asyncio.CancelledError:
            self._settle(context, None, "cancelled")
            raise
        except XReadError as exc:
            self._settle(context, exc.units, exc.kind)
            raise
        self._settle(context, units)
        return result

    def _save_attempts(self, identity, attempts):
        self.db.execute(
            "UPDATE x_operations SET attempts=?,updated_at=? WHERE id=?",
            (_json(attempts), _now(), identity),
        )

    def _settle(self, context, units, reason=None):
        identity = context["id"]
        with self.store._write():
            attempts = self._operation(identity)["attempts"]
            attempt = attempts[-1]
            if units is None:
                self.budget._mark_unknown(attempt["id"])
            else:
                self.budget._settle(
                    attempt["id"], units=units, usage={"reads": units}, cost_source="usage_derived"
                )
            attempt.update(
                state="outcome_unknown" if units is None else "completed",
                finished_at=_now(),
                reads=units,
                reason=reason,
            )
            self._save_attempts(identity, attempts)

    def _failure(self, context, state, reason, retry_after=None):
        with self.store._write():
            if state not in {"outcome_unknown", "interrupted"}:
                try:
                    self._current(context)
                except XError:
                    state, reason = "configuration_changed", "configuration_changed"
            if state in {
                "unavailable",
                "permission_denied",
                "authentication_failed",
                "identity_mismatch",
            }:
                if context["kind"] == "account":
                    self.db.execute(
                        """INSERT INTO x_identities VALUES (?,NULL,?,?,?,?,1)
                           ON CONFLICT(account_id) DO UPDATE SET state=excluded.state,
                           credential_ref=excluded.credential_ref,observed_at=excluded.observed_at""",
                        (
                            context["scope"],
                            context["subject"]["handle"],
                            state,
                            context["ref"],
                            _now(),
                        ),
                    )
                else:
                    self.db.execute(
                        "UPDATE x_lists SET state=?,authorized=0,credential_ref=?,checked_at=? WHERE id=?",
                        (state, context["ref"], _now(), context["scope"]),
                    )
            elif context["kind"] == "list" and state not in {
                "configuration_changed",
                "interrupted",
            }:
                self.db.execute(
                    "UPDATE x_lists SET state=?,checked_at=? WHERE id=?",
                    (state, _now(), context["scope"]),
                )
            self._finish(context, state, dict(reason=reason, retry_after=retry_after))

    async def _run(self, context, request_id, work):
        if context is None:
            return self.operation(request_id)
        client = None
        try:
            ref = context["ref"]
            if ref is None:
                raise XReadError("credential_missing", units=0)
            try:
                token = await asyncio.to_thread(self.credentials.backend.read, ref)
            except (CredentialError, OSError):
                raise XReadError("credential_unavailable", units=0) from None
            client = self.client_factory(token)
            await work(context, client)
        except XReadError as exc:
            state = "outcome_unknown" if exc.units is None else exc.kind
            self._failure(context, state, exc.kind, exc.retry_after)
        except BudgetError as exc:
            self._failure(context, "budget_blocked", str(exc))
        except XError as exc:
            self._failure(context, str(exc), str(exc))
        except asyncio.CancelledError:
            attempts = self._operation(request_id)["attempts"]
            unknown = bool(attempts and attempts[-1]["state"] == "outcome_unknown")
            self._failure(context, "outcome_unknown" if unknown else "interrupted", "cancelled")
            raise
        except (sqlite3.Error, OSError):
            raise XError("storage_failed") from None
        finally:
            if client is not None:
                with suppress(httpx.HTTPError, OSError):
                    await client.close()
        return self.operation(request_id)

    def _remote_owner(self, remote):
        row = self.db.execute(
            "SELECT account_id FROM x_identities WHERE remote_id=?", (remote,)
        ).fetchone()
        return row[0] if row else None

    def _observe(self, account, item, ref, when, *, direct):
        self.db.execute(
            """INSERT INTO x_identities VALUES (?,?,?,?,?,?,?)
               ON CONFLICT(account_id) DO UPDATE SET
                 remote_id=excluded.remote_id,handle=excluded.handle,state=excluded.state,
                 credential_ref=excluded.credential_ref,observed_at=excluded.observed_at""",
            (
                account["id"],
                item["remote_id"],
                item["handle"],
                "protected" if item["protected"] else "ready",
                ref,
                when,
                int(direct),
            ),
        )

    def _apply_account(self, context, item, when):
        with self.store._write():
            config = self._current(context)
            original_accounts = _json(config["accounts"])
            requested = _account(config, context["scope"])
            if requested["remote_id"] is not None and requested["remote_id"] != item["remote_id"]:
                raise XError("identity_mismatch")
            owner = self._remote_owner(item["remote_id"])
            canonical = next((a for a in config["accounts"] if a["id"] == owner), None)
            duplicate = canonical is not None and canonical["id"] != requested["id"]
            if duplicate and canonical["remote_id"] != item["remote_id"]:
                raise XError("identity_conflict")
            account = canonical if duplicate else requested
            bare_duplicate = duplicate and requested == _draft(requested["id"], requested["handle"])
            if duplicate and not bare_duplicate:
                self._finish(
                    context,
                    "duplicate",
                    dict(
                        revision=context["revision"],
                        account=self.account_status(account["id"]),
                        canonical_account_id=account["id"],
                    ),
                )
                return
            if owner and canonical is None:
                self.db.execute(
                    "UPDATE x_identities SET remote_id=NULL WHERE account_id=?", (owner,)
                )
            observed = self._identity(account["id"])
            alias = self._identity(requested["id"]) if bare_duplicate else None
            if not observed or not observed["observed_at"] or observed["observed_at"] <= when:
                account.update(handle=item["handle"], remote_id=item["remote_id"])
                if bare_duplicate:
                    config["accounts"].remove(requested)
                if any(
                    other["id"] != account["id"]
                    and other["handle"].lower() == account["handle"].lower()
                    and other["id"] != requested["id"]
                    for other in config["accounts"]
                ):
                    raise XError("username_conflict")
                saved_revision = context["revision"]
                if _json(config["accounts"]) != original_accounts:
                    saved_revision = self.store._save_config_tx(config, saved_revision)
                self._observe(account, item, context["ref"], when, direct=True)
                if alias and alias["direct"]:
                    self.db.execute(
                        "UPDATE x_identities SET direct=1 WHERE account_id=?", (account["id"],)
                    )
            else:
                saved_revision = context["revision"]
            status = self.account_status(account["id"])
            state = "duplicate" if duplicate else status["state"]
            self._finish(
                context,
                state,
                dict(revision=saved_revision, account=status, canonical_account_id=account["id"]),
            )

    async def verify(self, identity, request_id, revision):
        context = self._start("account", identity, request_id, revision)

        async def work(ctx, client):
            account = ctx["subject"]
            observed = self._identity(identity)
            by_id = self._identity_matches(account, observed)
            value = account["remote_id"] if by_id else account["handle"]
            item = await self._read(ctx, 1, lambda: client.user(value, by_id=by_id))
            self._apply_account(ctx, item, _now())

        return await self._run(context, request_id, work)

    def _apply_list(self, context, metadata, entries):
        with self.store._write():
            config = self._current(context)
            original_accounts = _json(config["accounts"])
            by_local = {a["id"]: a for a in config["accounts"]}
            by_handle = {a["handle"].lower(): a for a in config["accounts"]}
            members, observations = [], []
            for item, when in entries:
                remote, name = item["remote_id"], item["handle"]
                owner = self._remote_owner(remote)
                account = by_local.get(owner)
                if owner is not None and account is None:
                    self.db.execute(
                        "UPDATE x_identities SET remote_id=NULL WHERE account_id=?", (owner,)
                    )
                if account is not None and account["remote_id"] != remote:
                    raise XError("identity_conflict")
                existing_handle = by_handle.get(name.lower())
                if account is None and existing_handle:
                    if existing_handle["remote_id"] not in {None, remote}:
                        raise XError("username_conflict")
                    account = existing_handle
                if account is None:
                    if len(config["accounts"]) >= 200:
                        raise XError("account_limit")
                    partition = "adult" if context["subject"]["default_adult"] else None
                    account = _draft(new_id("accounts"), name, partition)
                    config["accounts"].append(account)
                    by_local[account["id"]] = account
                observed = self._identity(account["id"])
                newer = observed and observed["observed_at"] and observed["observed_at"] > when
                if not newer:
                    if existing_handle is not None and existing_handle["id"] != account["id"]:
                        raise XError("username_conflict")
                    by_handle.pop(account["handle"].lower(), None)
                    account.update(handle=name, remote_id=remote)
                    by_handle[name.lower()] = account
                    observations.append(
                        (
                            account,
                            item,
                            when,
                            bool(observed["direct"]) if observed else existing_handle is not None,
                        )
                    )
                members.append(dict(account_id=account["id"], remote_id=remote))
            revision = context["revision"]
            if _json(config["accounts"]) != original_accounts:
                revision = self.store._save_config_tx(config, revision)
            for account, item, when, direct in observations:
                self._observe(account, item, context["ref"], when, direct=direct)
            self.db.execute(
                """UPDATE x_lists SET name=?,state='ready',authorized=1,credential_ref=?,members=?,
                   checked_at=? WHERE id=?""",
                (metadata["name"], context["ref"], _json(members), _now(), context["scope"]),
            )
            self._finish(
                context, "ready", dict(revision=revision, list=self.list_status(context["scope"]))
            )

    async def refresh_list(self, identity, request_id, revision, *, page_size=25, max_pages=4):
        identity = list_id(identity)
        if (
            type(page_size) is not int
            or not 1 <= page_size <= 100
            or type(max_pages) is not int
            or not 1 <= max_pages <= 4
        ):
            raise XError("invalid_page_bounds")
        context = self._start(
            "list", identity, request_id, revision, page_size=page_size, max_pages=max_pages
        )

        async def work(ctx, client):
            metadata = await self._read(ctx, 1, lambda: client.list(identity))
            if metadata["private"]:
                with self.store._write():
                    self._current(ctx)
                    self.db.execute(
                        """UPDATE x_lists SET name=?,state='private',authorized=0,credential_ref=?,
                           checked_at=? WHERE id=?""",
                        (metadata["name"], ctx["ref"], _now(), identity),
                    )
                    self._finish(ctx, "private", dict(list=self.list_status(identity)))
                return
            entries, seen_ids, seen_handles, seen_tokens = [], set(), set(), set()
            next_token = None
            for _ in range(max_pages):
                page, next_token = await self._read(
                    ctx,
                    page_size,
                    lambda token=next_token: client.members(identity, page_size, token),
                )
                when = _now()
                for item in page:
                    remote, name = item["remote_id"], item["handle"].lower()
                    if remote in seen_ids or name in seen_handles or len(entries) >= 200:
                        raise XError("partial")
                    seen_ids.add(remote)
                    seen_handles.add(name)
                    entries.append((item, when))
                if next_token is None:
                    self._apply_list(ctx, metadata, entries)
                    return
                if next_token in seen_tokens:
                    raise XError("partial")
                seen_tokens.add(next_token)
            raise XError("partial")

        return await self._run(context, request_id, work)

    def recover_interrupted(self):
        """Recover only after acquiring the existing backend process lock."""
        with self.store._write():
            rows = self.db.execute("SELECT id FROM x_operations WHERE state='running'").fetchall()
            for (identity,) in rows:
                attempts = self._operation(identity)["attempts"]
                unknown = bool(
                    attempts and attempts[-1]["state"] in {"inflight", "outcome_unknown"}
                )
                if unknown and attempts[-1]["state"] == "inflight":
                    self.budget._mark_unknown(attempts[-1]["id"])
                    attempts[-1].update(
                        state="outcome_unknown", finished_at=_now(), reason="interrupted"
                    )
                    self._save_attempts(identity, attempts)
                self._finish(
                    {"id": identity},
                    "outcome_unknown" if unknown else "interrupted",
                    {"reason": "interrupted"},
                )
        return len(rows)
