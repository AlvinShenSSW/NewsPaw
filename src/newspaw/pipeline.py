"""Restartable edition preparation in the existing single-backend database."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import sqlite3
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from .connectors import AICollector, api_scopes
from .connectors.av import AVCollector, av_scopes
from .connectors.web import WebCollector, web_scopes
from .credentials import CredentialError
from .editorial import EditorialError, EditorialService
from .evidence import EvidenceError, EvidenceStore, FeedCollector, feed_scopes
from .model_runner import ModelRunner, RunnerError
from .providers import ProviderError
from .routing import RouteBlocked, RouteSnapshot, RouteStale
from .x.digests import x_scopes
from .x.timelines import TimelineError

_ACTIVE = {"collecting", "editing", "preparing_media"}
_SUCCESSFUL_FETCH = {"fresh", "stale", "empty", "no_eligible", "not_modified"}
_COLLECTION = "json_extract(scope_json,'$.collection_id')"
_GROUP = "json_extract(scope_json,'$.collection_group')"
_KEY = re.compile(r"[A-Za-z0-9_.:-]{1,140}")
_LEASE_TIME = timedelta(minutes=2)


class PipelineError(CredentialError):
    pass


class _WorkStopped(RuntimeError):
    """An old or paused worker must exit without mutating the shared model task."""

    pass


def _json(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def _time(value=None):
    value = datetime.now(UTC) if value is None else value
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise PipelineError("invalid_time")
    return value.astimezone(UTC)


def _key(value):
    if not isinstance(value, str) or not _KEY.fullmatch(value):
        raise PipelineError("invalid_job_identity")
    return value


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS pipeline_jobs (
            id TEXT PRIMARY KEY, subscription_id TEXT NOT NULL, account_key TEXT NOT NULL,
            edition_key TEXT NOT NULL, partition TEXT NOT NULL, payload TEXT NOT NULL,
            stage TEXT NOT NULL, error_kind TEXT, paused INTEGER NOT NULL DEFAULT 0,
            cancelled INTEGER NOT NULL DEFAULT 0, lease_token TEXT, lease_until TEXT,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            UNIQUE(subscription_id, account_key, edition_key)
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS pipeline_events (
            id INTEGER PRIMARY KEY, job_id TEXT NOT NULL REFERENCES pipeline_jobs(id),
            occurred_at TEXT NOT NULL, action TEXT NOT NULL, stage TEXT NOT NULL, error_kind TEXT
        )"""
    )
    db.execute("CREATE INDEX IF NOT EXISTS pipeline_events_job ON pipeline_events(job_id,id)")
    db.execute(
        f"""CREATE INDEX IF NOT EXISTS feed_attempts_collection ON feed_attempts({_COLLECTION},{_GROUP})
            WHERE {_COLLECTION} IS NOT NULL"""
    )


class Pipeline:
    def __init__(
        self,
        store,
        backend,
        *,
        runner=None,
        feed_factory=FeedCollector,
        ai_factory=AICollector,
        web_factory=WebCollector,
        av_factory=AVCollector,
        source_images=None,
        x_digests=None,
    ):
        self.store, self.db = store, store._db
        self.runner = runner if runner is not None else ModelRunner(store, backend)
        self.editorial = EditorialService(store, self.runner)
        self.feed_factory, self.ai_factory = feed_factory, ai_factory
        self.web_factory, self.av_factory = web_factory, av_factory
        self.source_images = source_images
        self.x_digests = x_digests
        self._active = {}

    def _row(self, job_id):
        cursor = self.db.execute("SELECT * FROM pipeline_jobs WHERE id=?", (_key(job_id),))
        row = cursor.fetchone()
        if row is None:
            raise PipelineError("missing_job")
        result = dict(zip((field[0] for field in cursor.description), row, strict=True))
        result["payload"] = json.loads(result["payload"])
        return result

    @staticmethod
    def _edition_id(job_id):
        return "brief." + job_id

    def _event(self, job_id, action, stage, now, error=None):
        self.db.execute(
            "INSERT INTO pipeline_events(job_id,occurred_at,action,stage,error_kind) VALUES (?,?,?,?,?)",
            (job_id, now.isoformat(), action, stage, error),
        )

    def create(
        self,
        subscription_id,
        edition_key,
        *,
        holds,
        account_id=None,
        style=None,
        task_limit=None,
        now=None,
    ):
        now = _time(now)
        account_key = "" if account_id is None else _key(account_id)
        identity = [_key(subscription_id), account_key, _key(edition_key)]
        job_id = "job." + hashlib.sha256(_json(identity).encode()).hexdigest()
        with self.store._write():
            prior = self.db.execute(
                "SELECT payload FROM pipeline_jobs WHERE id=?", (job_id,)
            ).fetchone()
            if prior:
                saved = json.loads(prior[0])
                if (saved["route"]["request_style"], saved["holds"], saved["task_limit"]) != (
                    style,
                    holds,
                    task_limit,
                ):
                    raise PipelineError("job_key_conflict")
            else:
                route = self.store.preview_route(
                    subscription_id, account_id=account_id, style=style
                )
                if route.blockers:
                    raise PipelineError("route_blocked")
                effective = route.effective
                if account_id is not None and effective["account"]["priority"] != "special":
                    raise PipelineError("special_account_required")
                profiles = [effective[role]["id"] for role in ("primary", "backup")]
                if (
                    not isinstance(holds, dict)
                    or set(holds) != set(profiles)
                    or any(
                        type(value) is not int or not 1 <= value <= 2**53
                        for value in holds.values()
                    )
                    or (
                        task_limit is not None
                        and (type(task_limit) is not int or not 0 <= task_limit <= 2**53)
                    )
                ):
                    raise PipelineError("invalid_job_budget")
                config = self.store.load_config()[1]
                if effective["category_id"] in {"x", "x_adult"}:
                    scopes = x_scopes(config, route)
                else:
                    scopes = (
                        feed_scopes(config, [subscription_id])
                        + api_scopes(config, [subscription_id])
                        + web_scopes(config, [subscription_id])
                        + av_scopes(config, [subscription_id])
                    )
                covered = {item["source"]["id"] for scope in scopes for item in scope["selected"]}
                payload = dict(
                    route=asdict(route),
                    generations={key: self.runner.registry.profile(key)[1] for key in profiles},
                    holds=holds,
                    task_limit=task_limit,
                    scopes=scopes,
                    unsupported_source_ids=sorted(
                        s["id"] for s in effective["sources"] if s["id"] not in covered
                    ),
                    attempt_ids=[],
                    media=None,
                )
                self.db.execute(
                    """INSERT INTO pipeline_jobs(
                         id,subscription_id,account_key,edition_key,partition,payload,stage,created_at,updated_at
                       ) VALUES (?,?,?,?,?,?,'collecting',?,?)""",
                    (
                        job_id,
                        *identity,
                        effective["partition"],
                        _json(payload),
                        now.isoformat(),
                        now.isoformat(),
                    ),
                )
                self._event(job_id, "created", "collecting", now)
        return self.get(job_id)

    def get(self, job_id):
        row = self._row(job_id)
        payload = row["payload"]
        route = RouteSnapshot(**payload["route"]).effective
        edition_id = self._edition_id(payload.get("alert", {}).get("parent", job_id))
        model = self.editorial.task_status(edition_id) if "alert" not in payload else None
        stage, status = row["stage"], row["stage"]
        if model and model["state"] in {"outcome_unknown", "inflight"}:
            status = model["state"]
        elif row["cancelled"]:
            status = "cancelled"
        elif row["paused"]:
            status = "paused"
        elif stage == "editing" and model and model["state"] in {"waiting", "blocked"}:
            status = model["state"]
        return dict(
            job_id=job_id,
            edition_key=row["edition_key"],
            subscription_id=row["subscription_id"],
            account_id=row["account_key"] or None,
            partition=row["partition"],
            locale=route["locale"],
            style=route["style"],
            stage=stage,
            status=status,
            paused=bool(row["paused"]),
            cancelled=bool(row["cancelled"]),
            lease_until=row["lease_until"],
            error_kind=row["error_kind"],
            collection_id=job_id,
            attempt_ids=payload["attempt_ids"],
            unsupported_source_ids=payload["unsupported_source_ids"],
            edition_id=edition_id,
            model=model,
            media=payload["media"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    @staticmethod
    def _limit(limit):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise PipelineError("invalid_limit")
        return limit

    def list(self, limit=25):
        return [
            self.get(row[0])
            for row in self.db.execute(
                "SELECT id FROM pipeline_jobs ORDER BY rowid DESC LIMIT ?", (self._limit(limit),)
            )
        ]

    def audit(self, job_id, *, after=0, limit=50):
        self._row(job_id)
        if type(after) is not int or not 0 <= after <= 2**63 - 1:
            raise PipelineError("invalid_cursor")
        cursor = self.db.execute(
            """SELECT id,occurred_at,action,stage,error_kind FROM pipeline_events
               WHERE job_id=? AND id>? ORDER BY id LIMIT ?""",
            (job_id, after, self._limit(limit)),
        )
        keys = [field[0] for field in cursor.description]
        return [dict(zip(keys, row, strict=True)) for row in cursor]

    def _preflight(self, row):
        payload = row["payload"]
        route = RouteSnapshot(**payload["route"])
        self.store.revalidate_route(route)
        self._check_profile_generations(payload)
        return route

    def _check_profile_generations(self, payload):
        for key, generation in payload["generations"].items():
            if self.runner.registry.profile(key)[1] != generation:
                raise RouteStale("profile_changed")

    def delivery_scope(self, job_id):
        """Revalidate frozen content while leaving Bot authorization to TargetManager."""
        row = self._row(job_id)
        if row["cancelled"]:
            raise PipelineError("job_cancelled")
        if row["paused"]:
            raise PipelineError("job_paused")
        if row["stage"] != "awaiting_delivery":
            raise PipelineError("edition_not_ready")
        payload = row["payload"]
        if alert := payload.get("alert"):
            parent = self.delivery_scope(alert["parent"])
            result = self.editorial.get(self._edition_id(alert["parent"]))["result"]
            if (
                not result
                or not any(
                    item["event_key"] == alert["item"]
                    and hashlib.sha256(_json(item).encode()).hexdigest() == alert["item_hash"]
                    for item in result["items"]
                )
            ):
                raise PipelineError("edition_changed")
            return parent
        route = RouteSnapshot(**payload["route"])
        current = self.store.preview_route(
            route.subscription_id, account_id=route.account_id, style=route.request_style
        )
        current_content, frozen_content = current.effective, route.effective
        for field in ("targets", "bots", "target_diagnostics"):
            current_content.pop(field, None)
            frozen_content.pop(field, None)
        if (
            set(current.blockers) - {"no_target", "target_unpaired"}
            or current_content != frozen_content
        ):
            raise PipelineError("edition_changed")
        try:
            self._check_profile_generations(payload)
            if current_content["category_id"] in {
                "x",
                "x_adult",
            } and not self.editorial.x_evidence_current(self._edition_id(job_id), route):
                raise RouteStale("x_evidence_changed")
        except (ProviderError, RouteStale, EditorialError):
            raise PipelineError("edition_changed") from None
        try:
            delivery_allowed = self.editorial.delivery_allowed(self._edition_id(job_id), route)
        except EditorialError:
            raise PipelineError("edition_changed") from None
        if not delivery_allowed:
            raise PipelineError("edition_changed")
        return route

    def delivery_input(self, job_id):
        route = self.delivery_scope(job_id)
        payload = self._row(job_id)["payload"]
        if alert := payload.get("alert"):
            return route, alert["text"], None
        edition_id = self._edition_id(job_id)
        if self.editorial.get(edition_id)["state"] != "ready":
            raise PipelineError("edition_changed")
        return route, self.editorial.render(edition_id), payload["media"]

    def _claim(self, job_id, now):
        with self.store._write():
            row = self._row(job_id)
            if (
                row["stage"] not in _ACTIVE
                or row["paused"]
                or row["cancelled"]
                or (row["lease_until"] and datetime.fromisoformat(row["lease_until"]) > now)
            ):
                return None
            if row["stage"] == "editing":
                model = self.editorial.task_status(self._edition_id(job_id))
                if model and (
                    model["state"] in {"blocked", "inflight", "outcome_unknown"}
                    or (model["next_at"] and datetime.fromisoformat(model["next_at"]) > now)
                ):
                    return None
            token = uuid4().hex
            self.db.execute(
                "UPDATE pipeline_jobs SET lease_token=?,lease_until=? WHERE id=?",
                (token, (now + _LEASE_TIME).isoformat(), job_id),
            )
            return token

    def _leased(self, job_id, token, *, starting=False, now=None):
        row = self._row(job_id)
        if row["lease_token"] != token:
            raise _WorkStopped("lease_lost")
        if starting:
            if datetime.fromisoformat(row["lease_until"]) <= _time(now):
                raise _WorkStopped("lease_expired")
            if row["paused"] or row["cancelled"]:
                raise _WorkStopped("job_paused_or_cancelled")
            self._preflight(row)
        return row

    def _transition(self, job_id, token, stage, now, *, error=None, effect_guard=None, **updates):
        with self.store._write():
            row = self._leased(job_id, token, starting=stage == "awaiting_delivery", now=now)
            if row["cancelled"] or (effect_guard is not None and effect_guard() is False):
                return
            payload = {**row["payload"], **updates}
            self.db.execute(
                "UPDATE pipeline_jobs SET stage=?,error_kind=?,payload=?,updated_at=? WHERE id=?",
                (stage, error, _json(payload), now.isoformat(), job_id),
            )
            if stage != row["stage"] or error != row["error_kind"]:
                self._event(job_id, "transition", stage, now, error)

    def _collection_attempts(self, job_id, partition):
        return {
            index: identity
            for index, identity in self.db.execute(
                f"""SELECT {_GROUP},id FROM feed_attempts WHERE {_COLLECTION}=?
                    AND partition=? AND status NOT IN ('running','interrupted','cancelled')
                    ORDER BY rowid""",
                (job_id, partition),
            )
        }

    async def _collect(self, row, token, now, effect_guard):
        job_id, partition = row["id"], row["partition"]
        scopes = row["payload"]["scopes"]
        attempts = self._collection_attempts(job_id, partition)
        pending = next((index for index in range(len(scopes)) if index not in attempts), None)

        def guard(scope, *, starting):
            self._leased(job_id, token, starting=starting, now=now)
            if starting:
                if effect_guard is not None and effect_guard() is False:
                    return False
                self.db.execute(
                    f"""UPDATE feed_attempts SET status='interrupted',outcome_json=?,completed_at=?
                        WHERE {_COLLECTION}=? AND {_GROUP}=? AND status='running'""",
                    (
                        _json({"error_kind": "interrupted"}),
                        _time(now).isoformat(),
                        job_id,
                        scope["collection_group"],
                    ),
                )

        def before_request():
            with self.store._write():
                self._leased(job_id, token, starting=True, now=now)
                return effect_guard() if effect_guard is not None else None

        evidence = EvidenceStore(self.store, collection_guard=guard)
        outcomes = [evidence.attempt(key, partition=partition) for key in attempts.values()]
        if pending is not None and all(
            result["status"] != "configuration_changed" for result in outcomes
        ):
            scope = dict(scopes[pending], collection_id=job_id, collection_group=pending)
            kinds = scope.get("kinds")
            if kinds == ["x_account"]:
                if self.x_digests is None:
                    raise EvidenceError("x_digest_unavailable")

                def authorize_x():
                    self._leased(job_id, token, starting=True, now=now)
                    if not evidence.current(scope):
                        raise RouteStale("x_scope_changed")
                    return effect_guard() if effect_guard is not None else None

                try:
                    result = await self.x_digests.fetch_scope(
                        evidence,
                        scope,
                        datetime.fromisoformat(row["created_at"]),
                        before_intent=authorize_x,
                    )
                except TimelineError as exc:
                    if str(exc) == "configuration_changed":
                        raise RouteStale("x_scope_changed") from None
                    raise EvidenceError(str(exc)) from None
            else:
                if kinds == ["web"]:
                    factory = self.av_factory if scope["partition"] == "adult" else self.web_factory
                else:
                    factory = self.ai_factory if kinds else self.feed_factory
                collector = factory(evidence)
                try:
                    if kinds == ["web"]:
                        result = await collector.fetch_scope(
                            scope, 24, now, before_request=before_request
                        )
                    else:
                        result = await collector.fetch_scope(scope, 24, now)
                finally:
                    await collector.close()
            if result is None:
                return
            attempts[pending] = result["id"]
            outcomes.append(result)
        ids = [attempts[index] for index in sorted(attempts)]
        if any(result["status"] == "configuration_changed" for result in outcomes):
            self._transition(
                job_id, token, "stale", _time(now), error="configuration_changed", attempt_ids=ids
            )
            return
        if len(attempts) != len(scopes):
            self._transition(job_id, token, "collecting", _time(now), attempt_ids=ids)
            return
        successful = any(
            result["status"] in _SUCCESSFUL_FETCH
            and (
                result.get("coverage_complete", True)
                or result.get("accepted_count", 0) > 0
                or (
                    result["evidence_scope"] in {"public_metadata", "av_industry"}
                    and not result.get("error_kind")
                )
            )
            for result in outcomes
        )
        if scopes and scopes[0].get("kinds") == ["x_account"]:
            successful = any(result["accepted_count"] > 0 for result in outcomes) or all(
                result["status"] == "empty" and result["coverage_complete"] for result in outcomes
            )
        self._transition(
            job_id,
            token,
            "editing" if successful else "collection_failed",
            _time(now),
            error=None if successful else "all_sources_failed",
            attempt_ids=ids,
        )

    async def _edit(self, row, token, now, effect_guard):
        job_id, payload = row["id"], row["payload"]
        edition_id = self._edition_id(job_id)

        route = RouteSnapshot(**payload["route"])

        def before_dispatch():
            self._leased(job_id, token, starting=True, now=now)
            if route.effective["category_id"] in {
                "x",
                "x_adult",
            } and not self.editorial.x_evidence_current(edition_id, route):
                raise RouteStale("x_evidence_changed")
            return effect_guard() if effect_guard is not None else None

        edition = self.editorial.prepare(
            edition_id,
            route,
            payload["attempt_ids"],
            payload["holds"],
            payload["task_limit"],
            now=now,
        )
        if edition["state"] in {
            "pending",
            "waiting",
            "blocked",
            "inflight",
            "outcome_unknown",
        }:
            edition = await self.editorial.advance(
                edition_id,
                now=now,
                before_dispatch=before_dispatch,
            )
        state = edition["state"]
        if state in {"ready", "no_news"}:
            if state == "ready" and not edition["result"]["items"]:
                self._transition(job_id, token, "blocked", _time(now), error="no_publishable_items")
            else:
                self._transition(
                    job_id, token, "preparing_media" if state == "ready" else "no_news", _time(now)
                )
        elif state in {"stale", "cancelled", "refused"}:
            self._transition(job_id, token, state, _time(now), error=edition["error_kind"])

    async def _media(self, row, token, now, effect_guard):
        job_id = row["id"]
        route = RouteSnapshot(**row["payload"]["route"])
        style = route.effective["style"]
        edition_id = self._edition_id(job_id)
        if self.editorial.get(edition_id)["state"] != "ready":
            raise EditorialError("edition_not_ready")
        media = dict(
            style="text", fallback_reason=None if style == "text" else "media_not_available"
        )
        if style == "source_image" and route.effective["partition"] == "adult":
            media["fallback_reason"] = "adult_source_media_disabled"
        elif style == "source_image" and self.source_images is not None:

            def authorize():
                with self.store._write():
                    self._leased(job_id, token, starting=True, now=now)
                    if self.editorial.get(edition_id)["state"] != "ready":
                        raise EditorialError("edition_not_ready")
                    return effect_guard() if effect_guard is not None else None

            media = await self.source_images.prepare(
                route,
                row["payload"]["attempt_ids"],
                self.editorial.image_anchors(edition_id),
                authorize,
            )
            if media is None:
                return
        self._transition(
            job_id,
            token,
            "awaiting_delivery",
            _time(now),
            effect_guard=effect_guard,
            media=dict(media, edition_id=edition_id),
        )

    async def _step(self, job_id, token, now, effect_guard):
        try:
            row = self._leased(job_id, token, starting=True, now=now)
            if row["stage"] == "collecting":
                await self._collect(row, token, now, effect_guard)
            elif row["stage"] == "editing":
                await self._edit(row, token, now, effect_guard)
            else:
                await self._media(row, token, now, effect_guard)
        except (RouteBlocked, RouteStale):
            self._transition(job_id, token, "stale", _time(now), error="configuration_changed")
        except (EvidenceError, EditorialError, ProviderError, RunnerError) as exc:
            if str(exc) == "storage_failed":
                raise PipelineError("storage_failed") from None
            self._transition(job_id, token, "blocked", _time(now), error="preparation_failed")

    async def advance(self, job_id, *, now=None, effect_guard=None):
        try:
            token = self._claim(job_id, _time(now))
            if token is None:
                return self.get(job_id)
            task = asyncio.create_task(self._step(job_id, token, now, effect_guard))
            self._active[job_id, token] = task
            try:
                await task
            except _WorkStopped:
                pass
            except asyncio.CancelledError as exc:
                if not exc.args or exc.args[0] not in {"job_cancelled", "job_paused"}:
                    raise
            finally:
                self._active.pop((job_id, token), None)
                with self.store._write():
                    self.db.execute(
                        "UPDATE pipeline_jobs SET lease_token=NULL,lease_until=NULL WHERE id=? AND lease_token=?",
                        (job_id, token),
                    )
            return self.get(job_id)
        except (sqlite3.Error, OSError):
            raise PipelineError("storage_failed") from None

    def _control(self, job_id, action, now=None):
        now = _time(now)
        with self.store._write():
            row = self._row(job_id)
            if row["cancelled"] or row["stage"] not in _ACTIVE | {"awaiting_delivery"}:
                return
            if action == "cancel":
                self.db.execute(
                    "UPDATE pipeline_jobs SET cancelled=1,stage='cancelled',updated_at=? WHERE id=?",
                    (now.isoformat(), job_id),
                )
                self._event(job_id, action, "cancelled", now)
            else:
                self.set_paused_tx(job_id, action == "pause", now)

    def set_paused_tx(self, job_id, paused, now):
        """Set the absolute pause bit inside the caller's existing write transaction."""
        row = self._row(job_id)
        if (
            row["cancelled"]
            or row["stage"] not in _ACTIVE | {"awaiting_delivery"}
            or bool(row["paused"]) == paused
        ):
            return
        self.db.execute(
            "UPDATE pipeline_jobs SET paused=?,updated_at=? WHERE id=?",
            (int(paused), now.isoformat(), job_id),
        )
        self._event(job_id, "pause" if paused else "resume", row["stage"], now)

    def pause(self, job_id):
        self._control(job_id, "pause")
        return self.notify_paused(job_id)

    def notify_paused(self, job_id):
        """Nudge an unstarted model operation after its durable pause commits."""
        result = self.get(job_id)
        model = result["model"]
        if (
            result["paused"]
            and result["stage"] == "editing"
            and (model is None or model["state"] in {"pending", "waiting"})
        ):
            self._cancel_local(job_id, "job_paused")
        return result

    def _cancel_local(self, job_id, reason):
        for (identity, _), task in self._active.items():
            if identity == job_id:
                task.cancel(reason)

    def cancel(self, job_id):
        self._control(job_id, "cancel")
        if self._row(job_id)["cancelled"]:
            self._cancel_local(job_id, "job_cancelled")
        return self.get(job_id)

    def resume(self, job_id, *, acknowledge_duplicate_charge=False):
        if type(acknowledge_duplicate_charge) is not bool:
            raise PipelineError("invalid_acknowledgement")
        row = self._row(job_id)
        if row["cancelled"]:
            raise PipelineError("job_not_resumable")
        model = self.editorial.task_status(self._edition_id(job_id))
        if (
            row["stage"] == "editing"
            and model
            and model["state"] in {"blocked", "outcome_unknown"}
            and not (
                row["paused"]
                and model["state"] == "outcome_unknown"
                and not acknowledge_duplicate_charge
            )
        ):
            if row["lease_until"] and datetime.fromisoformat(row["lease_until"]) > _time():
                raise PipelineError("job_busy")
            try:
                self._preflight(row)
                self.runner.resume(
                    model["task_id"],
                    acknowledge_duplicate_charge=acknowledge_duplicate_charge,
                )
            except (RouteBlocked, RouteStale):
                raise PipelineError("configuration_changed") from None
            except RunnerError as exc:
                raise PipelineError(str(exc)) from None
        self._control(job_id, "resume")
        return self.get(job_id)

    def recover_interrupted(self):
        """Call only after acquiring the exclusive backend process lock."""
        self.runner.recover_interrupted()
        EvidenceStore(self.store).recover_interrupted()
        with self.store._write():
            self.db.execute(
                "UPDATE pipeline_jobs SET lease_token=NULL,lease_until=NULL WHERE lease_token IS NOT NULL"
            )

    async def close(self):
        tasks = tuple(self._active.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
