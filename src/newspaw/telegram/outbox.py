"""One frozen edition, with independent receipts for its authorized Bots."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import sqlite3
from contextlib import suppress
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import httpx

from ..credentials import CredentialError
from ..pipeline import PipelineError
from .client import TelegramClient, TelegramError, TelegramSendError
from .registry import Binding
from .targets import TargetError
from .text import split_delivery_text

_MAX_PHOTO = 10_000_000
_MAX_PARTS = 80
_AUTOMATIC_ATTEMPTS = 3
_MAX_ATTEMPTS = 6
_FINISHED_PARTS = {"delivered", "owner_confirmed", "skipped"}
_INITIAL_BLOCKERS = {"paused", "unverified", "unpaired", "adult_not_allowed"}
_ID = re.compile(r"[A-Za-z0-9_.:-]{1,140}")
_ASSET_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}")
_SHA = re.compile(r"[a-f0-9]{64}")


class OutboxError(CredentialError):
    pass


def _clock(now=None):
    now = datetime.now(UTC) if now is None else now
    if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
        raise OutboxError("invalid_time")
    return now.astimezone(UTC)


def _json(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def _id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise OutboxError("invalid_identity")
    return value


def _pending_parts(count):
    return [dict(state="pending", attempts=[]) for _ in range(count)]


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS delivery_manifests (
            job_id TEXT PRIMARY KEY REFERENCES pipeline_jobs(id), manifest TEXT NOT NULL,
            started INTEGER NOT NULL DEFAULT 0, stopped_reason TEXT, created_at TEXT NOT NULL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS delivery_targets (
            job_id TEXT NOT NULL REFERENCES delivery_manifests(job_id), bot_id TEXT NOT NULL,
            telegram_id INTEGER, chat_id INTEGER, binding TEXT, selected INTEGER NOT NULL,
            reason TEXT, parts TEXT NOT NULL, inflight_part INTEGER, backoff_until TEXT,
            PRIMARY KEY(job_id,bot_id)
        )"""
    )
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS delivery_one_inflight_bot
           ON delivery_targets(telegram_id) WHERE inflight_part IS NOT NULL"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS delivery_bot_backoff
           ON delivery_targets(telegram_id,backoff_until) WHERE backoff_until IS NOT NULL"""
    )


def send_lane_blocked(db, remote, now):
    clock = now.isoformat()
    return (
        db.execute(
            """SELECT 1 FROM delivery_targets WHERE telegram_id=?
           AND (inflight_part IS NOT NULL OR backoff_until>?)
           UNION ALL
           SELECT 1 FROM command_replies WHERE telegram_id=?
           AND (inflight_part IS NOT NULL OR backoff_until>?) LIMIT 1""",
            (remote, clock, remote, clock),
        ).fetchone()
        is not None
    )


def _photo(item):
    if (
        not isinstance(item, dict)
        or set(item) != {"asset_id", "sha256", "mime", "width", "height", "caption"}
        or not isinstance(item["asset_id"], str)
        or not _ASSET_ID.fullmatch(item["asset_id"])
        or not isinstance(item["sha256"], str)
        or not _SHA.fullmatch(item["sha256"])
        or item["mime"] not in ("image/jpeg", "image/png")
        or not isinstance(item["caption"], str)
        or len(item["caption"].encode("utf-16-le")) > 2048
    ):
        raise OutboxError("invalid_photo")
    width, height = item["width"], item["height"]
    if (
        type(width) is not int
        or type(height) is not int
        or min(width, height) < 1
        or width + height > 10_000
        or max(width, height) > 20 * min(width, height)
    ):
        raise OutboxError("invalid_photo")
    return {"kind": "photo", **item}


def _manifest(route, text, media):
    try:
        parts = [dict(kind="text", text=part) for part in split_delivery_text(text)]
    except ValueError:
        raise OutboxError("citation_line_too_long") from None
    photos = media.get("photos", []) if media else []
    if not isinstance(photos, list) or len(photos) > 2:
        raise OutboxError("invalid_photo")
    for item in photos:
        photo = _photo(item)
        if route.effective["partition"] != "normal" and photo["asset_id"].startswith("source_"):
            raise OutboxError("incompatible_photo_partition")
        parts.append(photo)
    if not parts or len(parts) > _MAX_PARTS or len(_json(parts).encode()) > 512 * 1024:
        raise OutboxError("invalid_manifest_size")
    return dict(
        subscription_id=route.subscription_id,
        account_id=route.account_id,
        partition=route.effective["partition"],
        locale=route.effective["locale"],
        parts=parts,
    )


class Outbox:
    def __init__(self, pipeline, targets, *, client_factory=TelegramClient, asset_resolver=None):
        self.pipeline, self.targets = pipeline, targets
        self.store, self.db = pipeline.store, pipeline.db
        self.client_factory, self.asset_resolver = client_factory, asset_resolver

    def _manifest_row(self, job_id):
        row = self.db.execute(
            "SELECT manifest,started,stopped_reason FROM delivery_manifests WHERE job_id=?",
            (_id(job_id),),
        ).fetchone()
        if row is None:
            raise OutboxError("missing_delivery")
        return json.loads(row[0]), bool(row[1]), row[2]

    def _rows(self, job_id, bot_id=None):
        query = "SELECT * FROM delivery_targets WHERE job_id=?"
        args = [job_id]
        if bot_id is not None:
            query += " AND bot_id=?"
            args.append(_id(bot_id))
        cursor = self.db.execute(query + " ORDER BY bot_id", args)
        names = [item[0] for item in cursor.description]
        for values in cursor:
            row = dict(zip(names, values, strict=True))
            row["parts"] = json.loads(row["parts"])
            row["binding"] = Binding(**json.loads(row["binding"])) if row["binding"] else None
            yield row

    def _row(self, job_id, bot_id):
        row = next(self._rows(job_id, _id(bot_id)), None)
        if row is None:
            raise OutboxError("missing_target")
        return row

    def _save(self, target):
        self.db.execute(
            """UPDATE delivery_targets
               SET selected=?,reason=?,parts=?,inflight_part=?,backoff_until=?
               WHERE job_id=? AND bot_id=?""",
            (
                target["selected"],
                target["reason"],
                _json(target["parts"]),
                target["inflight_part"],
                target["backoff_until"],
                target["job_id"],
                target["bot_id"],
            ),
        )

    def _add(self, job_id, bot_id, binding, reason, count):
        self.db.execute(
            "INSERT INTO delivery_targets VALUES (?,?,?,?,?,1,?,?,NULL,NULL)",
            (
                job_id,
                bot_id,
                binding.telegram_id if binding else None,
                binding.chat_id if binding else None,
                _json(asdict(binding)) if binding else None,
                reason,
                _json(_pending_parts(count) if binding else []),
            ),
        )

    def _live(self, job_id):
        manifest, started, stopped = self._manifest_row(job_id)
        if stopped:
            return None
        try:
            route = self.pipeline.delivery_scope(job_id)
        except PipelineError as exc:
            if str(exc) != "job_paused":
                self.db.execute(
                    "UPDATE delivery_manifests SET stopped_reason=? WHERE job_id=?",
                    (str(exc), job_id),
                )
            return None
        current = self.targets.preview(route.subscription_id, account_id=route.account_id)
        states = current["target_status"]
        bindings = {entry["bot_id"]: Binding(**entry) for entry in current["bindings"]}
        existing = {row["bot_id"]: row for row in self._rows(job_id)}
        for bot_id, target in existing.items():
            if bot_id not in states and target["selected"]:
                target["selected"] = 0
                # A lifecycle-revoked row may never be revived by reselecting it.
                target["reason"] = target["reason"] or "target_removed"
                self._save(target)
            elif (
                not started
                and target["reason"] == "target_removed"
                and not target["selected"]
                and target["binding"] is not None
                and bindings.get(bot_id) == target["binding"]
            ):
                target.update(selected=1, reason=None)
                self._save(target)
        if not started:
            for bot_id in states.keys() - existing.keys():
                binding = bindings.get(bot_id)
                self._add(
                    job_id,
                    bot_id,
                    binding,
                    None if binding else states[bot_id],
                    len(manifest["parts"]),
                )
        return route, manifest

    def enqueue(self, job_id, *, now=None):
        now = _clock(now)
        with self.store._write():
            if not self.db.execute(
                "SELECT 1 FROM delivery_manifests WHERE job_id=?", (_id(job_id),)
            ).fetchone():
                try:
                    route, text, media = self.pipeline.delivery_input(job_id)
                except PipelineError as exc:
                    raise OutboxError(str(exc)) from None
                self.db.execute(
                    "INSERT INTO delivery_manifests VALUES (?,?,0,NULL,?)",
                    (job_id, _json(_manifest(route, text, media)), now.isoformat()),
                )
            self._live(job_id)
        return self.status(job_id)

    def requeue_target(self, job_id, bot_id):
        """Explicitly arm one originally unready target before the edition's first intent."""
        with self.store._write():
            manifest, started, stopped = self._manifest_row(job_id)
            if started:
                raise OutboxError("recipient_set_frozen")
            if stopped:
                raise OutboxError(stopped)
            target = self._row(job_id, bot_id)
            if (
                not target["selected"]
                or target["binding"] is not None
                or target["parts"]
                or target["reason"] not in _INITIAL_BLOCKERS
            ):
                raise OutboxError("target_not_requeueable")
            route = self.pipeline.delivery_scope(job_id)
            preview = self.targets.preview(route.subscription_id, account_id=route.account_id)
            binding = next((item for item in preview["bindings"] if item["bot_id"] == bot_id), None)
            if binding is None:
                raise OutboxError("target_not_ready")
            self.db.execute(
                """UPDATE delivery_targets
                   SET telegram_id=?,chat_id=?,binding=?,reason=NULL,parts=?
                   WHERE job_id=? AND bot_id=?""",
                (
                    binding["telegram_id"],
                    binding["chat_id"],
                    _json(binding),
                    _json(_pending_parts(len(manifest["parts"]))),
                    job_id,
                    bot_id,
                ),
            )
        return self.status(job_id, bot_id=bot_id)

    def status(self, job_id, *, bot_id=None):
        manifest, started, stopped = self._manifest_row(job_id)
        job = self.pipeline.get(job_id)
        reason = stopped or (
            "job_cancelled" if job["cancelled"] else "job_paused" if job["paused"] else None
        )
        targets = {}
        for target in self._rows(job_id, bot_id):
            parts = target["parts"]
            states = [part["state"] for part in parts]
            delivered = sum(state in {"delivered", "owner_confirmed"} for state in states)
            if "outcome_unknown" in states:
                state = "outcome_unknown"
            elif "inflight" in states:
                state = "inflight"
            elif parts and delivered == len(parts):
                state = "delivered"
            elif delivered:
                state = "partial"
            elif target["reason"] in {
                "target_removed",
                "binding_changed",
                "token_revoked",
                "forbidden",
            }:
                state = "revoked"
            elif target["reason"] or reason or "failed" in states:
                state = "blocked"
            elif parts and all(value in _FINISHED_PARTS for value in states):
                state = "skipped"
            else:
                state = "pending"
            backoff = self.db.execute(
                "SELECT MAX(backoff_until) FROM delivery_targets WHERE telegram_id=?",
                (target["telegram_id"],),
            ).fetchone()[0]
            part_reason = next(
                (part.get("reason") for part in parts if part["state"] not in _FINISHED_PARTS),
                None,
            )
            view = dict(
                status=state,
                selected=bool(target["selected"]),
                chat_id=target["chat_id"],
                reason=target["reason"] or reason or part_reason,
                backoff_until=backoff,
                delivered=delivered,
                part_count=len(parts),
            )
            if bot_id is not None:
                view["parts"] = [dict(ordinal=index, **part) for index, part in enumerate(parts)]
            targets[target["bot_id"]] = view
        if bot_id is not None and bot_id not in targets:
            raise OutboxError("missing_target")
        return dict(
            job_id=job_id,
            edition_id=job["edition_id"],
            partition=manifest["partition"],
            locale=manifest["locale"],
            started=started,
            reason=reason,
            targets=targets,
        )

    def _revalidate(self, route, target):
        binding = target["binding"]
        if not target["selected"] or target["reason"] or binding is None:
            return False
        try:
            self.targets.revalidate_target(
                route.subscription_id, target["bot_id"], binding, account_id=route.account_id
            )
        except TargetError:
            target["reason"] = "binding_changed"
            self._save(target)
            return False
        return True

    def _eligible(self, job_id, bot_id, now):
        current = self._live(job_id)
        if current is None:
            return None
        route, manifest = current
        target = next(self._rows(job_id, bot_id), None)
        if target is None or not self._revalidate(route, target):
            return None
        remote = target["telegram_id"]
        if send_lane_blocked(self.db, remote, now):
            return None
        for ordinal, part in enumerate(target["parts"]):
            if part["state"] in _FINISHED_PARTS:
                continue
            if part["state"] == "pending":
                return target, ordinal, manifest["parts"][ordinal], manifest["partition"]
            break
        return None

    def _begin(self, target, ordinal, now):
        attempt = uuid4().hex
        part = target["parts"][ordinal]
        part["state"] = "inflight"
        part["attempts"].append(dict(id=attempt, state="inflight", started_at=now.isoformat()))
        target["inflight_part"] = ordinal
        self.db.execute(
            "UPDATE delivery_manifests SET started=1 WHERE job_id=?", (target["job_id"],)
        )
        self._save(target)
        return attempt

    @staticmethod
    def _end_attempt(target, ordinal, state, now, *, reason=None, message_id=None):
        part = target["parts"][ordinal]
        part.update(state=state, reason=reason, message_id=message_id)
        part["attempts"][-1].update(
            state=state,
            finished_at=now.isoformat(),
            reason=reason,
            message_id=message_id,
        )
        target["inflight_part"] = None
        return part

    def _complete(self, job_id, bot_id, ordinal, attempt, now, *, message_id=None, error=None):
        with self.store._write():
            target = self._row(job_id, bot_id)
            if (
                target["inflight_part"] != ordinal
                or target["parts"][ordinal]["attempts"][-1]["id"] != attempt
            ):
                raise OutboxError("attempt_changed")
            if error is None:
                self._end_attempt(target, ordinal, "delivered", now, message_id=message_id)
            elif error.kind == "rate_limited":
                part = self._end_attempt(target, ordinal, "rejected", now, reason=error.kind)
                part["state"] = (
                    "pending" if len(part["attempts"]) < _AUTOMATIC_ATTEMPTS else "failed"
                )
                target["backoff_until"] = (now + timedelta(seconds=error.retry_after)).isoformat()
            elif error.kind in {
                "payload_rejected",
                "token_revoked",
                "forbidden",
                "rate_limit_invalid",
            }:
                self._end_attempt(target, ordinal, "failed", now, reason=error.kind)
                if error.kind in {"token_revoked", "forbidden"}:
                    target["reason"] = error.kind
                    self.targets.registry.revoke_send_binding(target["binding"], error.kind)
            else:
                self._end_attempt(target, ordinal, "outcome_unknown", now, reason=error.kind)
            self._save(target)

    async def _asset(self, part):
        if self.asset_resolver is None:
            raise OutboxError("media_unavailable")
        try:
            data = await asyncio.to_thread(self.asset_resolver, part["asset_id"])
        except (OSError, ValueError):
            raise OutboxError("media_unavailable") from None
        magic = {"image/png": b"\x89PNG\r\n\x1a\n", "image/jpeg": b"\xff\xd8\xff"}
        if (
            not isinstance(data, bytes)
            or not 0 < len(data) <= _MAX_PHOTO
            or not data.startswith(magic[part["mime"]])
            or hashlib.sha256(data).hexdigest() != part["sha256"]
        ):
            raise OutboxError("media_unavailable")
        return data

    async def advance(self, job_id, bot_id, *, now=None, effect_guard=None):
        _id(bot_id)
        client = None
        try:
            with self.store._write():
                selected = self._eligible(job_id, bot_id, _clock(now))
            if selected is None:
                return self.status(job_id, bot_id=bot_id)
            target, ordinal, part, partition = selected
            binding = target["binding"]
            pre_dispatch_error = None
            try:
                token = await asyncio.to_thread(
                    self.targets.credentials.backend.read, binding.credential_ref
                )
                client = self.client_factory(token)
            except (CredentialError, TelegramError, OSError):
                pre_dispatch_error = "credential_unavailable"
            data = None
            if part["kind"] == "photo" and pre_dispatch_error is None:
                try:
                    data = await self._asset(part)
                except OutboxError:
                    pre_dispatch_error = "media_unavailable"
            with self.store._write():
                current = self._eligible(job_id, bot_id, _clock(now))
                if current is None or current[0]["binding"] != binding or current[1] != ordinal:
                    return self.status(job_id, bot_id=bot_id)
                if pre_dispatch_error:
                    current[0]["parts"][ordinal].update(state="failed", reason=pre_dispatch_error)
                    self._save(current[0])
                    return self.status(job_id, bot_id=bot_id)
                if effect_guard is not None and effect_guard() is False:
                    return self.status(job_id, bot_id=bot_id)
                attempt = self._begin(current[0], ordinal, _clock(now))
            try:
                if part["kind"] == "text":
                    message_id = await client.send_message(binding, part["text"])
                else:
                    message_id = await client.send_photo(
                        binding, data, part["mime"], part["caption"], spoiler=partition == "adult"
                    )
            except asyncio.CancelledError:
                self._complete(
                    job_id,
                    bot_id,
                    ordinal,
                    attempt,
                    _clock(now),
                    error=TelegramSendError("cancelled_after_intent"),
                )
                raise
            except TelegramSendError as exc:
                self._complete(job_id, bot_id, ordinal, attempt, _clock(now), error=exc)
            else:
                self._complete(job_id, bot_id, ordinal, attempt, _clock(now), message_id=message_id)
            return self.status(job_id, bot_id=bot_id)
        except (sqlite3.Error, OSError):
            raise OutboxError("storage_failed") from None
        finally:
            if client is not None:
                with suppress(httpx.HTTPError, OSError):
                    await client.close()

    def resolve(
        self,
        job_id,
        bot_id,
        ordinal,
        action,
        *,
        acknowledge_duplicate_send=False,
        message_id=None,
        now=None,
    ):
        now = _clock(now)
        if (
            type(ordinal) is not int
            or ordinal < 0
            or action not in ("retry", "skip", "owner_confirmed")
            or type(acknowledge_duplicate_send) is not bool
            or (
                action == "owner_confirmed"
                and (type(message_id) is not int or not 0 < message_id <= 2**63 - 1)
            )
            or (action != "owner_confirmed" and message_id is not None)
        ):
            raise OutboxError("invalid_resolution")
        with self.store._write():
            target = self._row(job_id, bot_id)
            if (
                ordinal >= len(target["parts"])
                or target["parts"][ordinal]["state"] != "outcome_unknown"
            ):
                raise OutboxError("part_not_unknown")
            part = target["parts"][ordinal]
            if action == "retry":
                if not acknowledge_duplicate_send:
                    raise OutboxError("duplicate_send_ack_required")
                if len(part["attempts"]) >= _MAX_ATTEMPTS:
                    raise OutboxError("retry_exhausted")
                live = self._live(job_id)
                target = self._row(job_id, bot_id)
                if live is None or not self._revalidate(live[0], target):
                    raise OutboxError("target_not_authorized")
                part = target["parts"][ordinal]
            part.update(
                state="pending"
                if action == "retry"
                else "skipped"
                if action == "skip"
                else "owner_confirmed",
                message_id=message_id,
                resolution=dict(action=action, occurred_at=now.isoformat()),
            )
            self._save(target)
        return self.status(job_id, bot_id=bot_id)

    def recover_interrupted(self):
        """Only on startup under the exclusive backend process lock."""
        now = _clock()
        with self.store._write():
            targets = self.db.execute(
                "SELECT job_id,bot_id FROM delivery_targets WHERE inflight_part IS NOT NULL"
            ).fetchall()
            for job_id, bot_id in targets:
                target = self._row(job_id, bot_id)
                self._end_attempt(
                    target, target["inflight_part"], "outcome_unknown", now, reason="interrupted"
                )
                self._save(target)
        return len(targets)
