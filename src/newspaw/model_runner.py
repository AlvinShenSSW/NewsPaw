"""One local durable executor; paid uncertainty never authorizes automatic replay."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import re
import sqlite3
from dataclasses import asdict
from datetime import UTC, datetime, timedelta

import httpx

from .budget import BudgetError, BudgetLedger
from .credentials import CredentialError
from .providers import ModelRequest, ProfileRegistry, ProviderAdapter, ProviderError, identity
from .routing import RouteBlocked, RouteSnapshot, RouteStale

_ID = re.compile(r"[A-Za-z0-9_.:-]{1,140}")
TRANSIENT = {"connection_failed", "transport_rejected", "rate_limited", "provider_failed"}
CONFIGURATION = {
    "authentication_failed",
    "permission_denied",
    "model_unavailable",
    "protocol_error",
    "quota_exhausted",
}
FORMAT = {"invalid_output", "incomplete_output"}


class RunnerError(ValueError):
    pass


def _json(value):
    return json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False
    )


def _time(value=None):
    value = datetime.now(UTC) if value is None else value
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise RunnerError("invalid_time")
    return value.astimezone(UTC)


def initialize(db):
    db.execute(
        "CREATE TABLE IF NOT EXISTS model_tasks (id TEXT PRIMARY KEY, payload TEXT NOT NULL, state TEXT NOT NULL, next_at TEXT, result_json TEXT, error_kind TEXT)"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS model_attempts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, ordinal INTEGER NOT NULL, profile_id TEXT NOT NULL, generation INTEGER NOT NULL, identity_hash TEXT NOT NULL, budget_id TEXT NOT NULL UNIQUE, repair INTEGER NOT NULL, state TEXT NOT NULL, started_at TEXT NOT NULL, finished_at TEXT, result_json TEXT, error_kind TEXT, UNIQUE(task_id,ordinal))"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS model_attempts_profile ON model_attempts(profile_id,generation,state)"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS model_health (profile_id TEXT NOT NULL, generation INTEGER NOT NULL, failures INTEGER NOT NULL, cooldown_until TEXT, error_kind TEXT, checked_at TEXT NOT NULL, PRIMARY KEY(profile_id,generation))"
    )


class ModelRunner:
    def __init__(self, store, backend, *, adapter_factory=ProviderAdapter):
        self.store, self.db, self.backend = store, store._db, backend
        self.adapter_factory = adapter_factory
        self.budget, self.registry = BudgetLedger(store), ProfileRegistry(store)
        self._lock = asyncio.Lock()

    def submit(
        self,
        task_id,
        route,
        request,
        *,
        operation,
        version,
        evidence_hash,
        evidence_count,
        holds,
        task_limit=None,
        attempts_per_profile=2,
    ):
        if any(
            not isinstance(v, str) or not _ID.fullmatch(v) for v in (task_id, operation, version)
        ):
            raise RunnerError("invalid_identity")
        if (
            not isinstance(evidence_hash, str)
            or not re.fullmatch(r"[a-f0-9]{64}", evidence_hash)
            or type(evidence_count) is not int
            or not 0 <= evidence_count <= 10000
            or type(attempts_per_profile) is not int
            or not 1 <= attempts_per_profile <= 3
            or (
                task_limit is not None
                and (type(task_limit) is not int or not 0 <= task_limit <= 2**53)
            )
        ):
            raise RunnerError("invalid_task_policy")
        if not self.db.execute("SELECT 1 FROM model_tasks WHERE id=?", (task_id,)).fetchone():
            self.store.revalidate_route(route)
        effective = route.effective
        if request.partition != effective["partition"]:
            raise RunnerError("partition_mismatch")
        profiles = [effective[role] for role in ("primary", "backup")]
        if (
            not isinstance(holds, dict)
            or set(holds) != {p["id"] for p in profiles}
            or any(type(v) is not int or not 1 <= v <= 2**53 for v in holds.values())
        ):
            raise RunnerError("invalid_hold")
        # Validate protocol/input shape without reading credentials or making a client.
        for profile in profiles:
            adapter = object.__new__(ProviderAdapter)
            adapter.profile = profile
            adapter.payload(request)
        fields = {key: value for key, value in asdict(request).items() if key != "validator"}
        if request.image is not None:
            fields["image"] = base64.b64encode(request.image).decode("ascii")
        payload = dict(
            route=asdict(route),
            request=fields,
            operation=operation,
            version=version,
            evidence_hash=evidence_hash,
            evidence_count=evidence_count,
            holds=holds,
            task_limit=task_limit,
            attempts_per_profile=attempts_per_profile,
        )
        serialized = _json(payload)
        if len(serialized.encode()) > 16 * 1024 * 1024:
            raise RunnerError("task_too_large")
        with self.store._write():
            old = self.db.execute(
                "SELECT payload FROM model_tasks WHERE id=?", (task_id,)
            ).fetchone()
            if old:
                frozen = json.loads(old[0])
                frozen.pop("generations")
                if _json(frozen) != serialized:
                    raise RunnerError("task_id_conflict")
            else:
                self.store.revalidate_route(route)
                payload["generations"] = {
                    p["id"]: self.registry.profile(p["id"])[1] for p in profiles
                }
                serialized = _json(payload)
                self.db.execute(
                    "INSERT INTO model_tasks VALUES (?,?,?,NULL,NULL,NULL)",
                    (task_id, serialized, "pending" if evidence_count else "no_news"),
                )
        return self.status(task_id)

    def _task(self, task_id):
        self.store.load_config()
        row = self.db.execute(
            "SELECT payload,state,next_at,result_json,error_kind FROM model_tasks WHERE id=?",
            (task_id,),
        ).fetchone()
        if row is None:
            raise RunnerError("missing_task")
        return dict(
            payload=json.loads(row[0]),
            state=row[1],
            next_at=row[2],
            result=json.loads(row[3]) if row[3] else None,
            error_kind=row[4],
        )

    def _attempts(self, task_id):
        cur = self.db.execute(
            "SELECT id,profile_id,generation,budget_id,repair,state,started_at,finished_at,error_kind FROM model_attempts WHERE task_id=? ORDER BY ordinal",
            (task_id,),
        )
        return [
            dict(zip([c[0] for c in cur.description], row, strict=True)) for row in cur.fetchall()
        ]

    def status(self, task_id):
        task = self._task(task_id)
        return dict(
            task_id=task_id,
            state=task["state"],
            next_at=task["next_at"],
            error_kind=task["error_kind"],
            result=task["result"] if task["state"] == "completed" else None,
            attempts=self._attempts(task_id),
        )

    def health(self):
        cur = self.db.execute("SELECT * FROM model_health ORDER BY profile_id,generation")
        return [
            dict(zip([c[0] for c in cur.description], row, strict=True)) for row in cur.fetchall()
        ]

    def _preflight(self, payload, profile=None):
        route = RouteSnapshot(**payload["route"])
        self.store.revalidate_route(route)
        if profile is not None:
            current, generation = self.registry.profile(profile["id"])
            if generation != payload["generations"][profile["id"]] or identity(current) != identity(
                profile
            ):
                raise RouteStale("profile_changed")
            capability = "vision" if payload["request"]["image"] is not None else "text"
            if self.registry.status(profile["id"])[capability]["state"] != "verified":
                raise RunnerError("capability_unverified")

    def _health_block(self, profile, generation, now):
        row = self.db.execute(
            "SELECT failures,cooldown_until,error_kind,checked_at FROM model_health WHERE profile_id=? AND generation=?",
            (profile["id"], generation),
        ).fetchone()
        if row is None:
            return None
        if row[2] in CONFIGURATION:
            states = self.registry.status(profile["id"])
            if not any(
                s["state"] == "verified" and s.get("checked_at", "") > row[3]
                for s in states.values()
            ):
                return "profile_configuration_failed"
        if row[1] and now < datetime.fromisoformat(row[1]):
            return "profile_cooldown"
        if (
            row[0] >= 3
            and self.db.execute(
                "SELECT 1 FROM model_attempts WHERE profile_id=? AND generation=? AND state='inflight'",
                (profile["id"], generation),
            ).fetchone()
        ):
            return "profile_half_open_busy"
        return None

    def _select(self, task_id, payload, now):
        attempts = self._attempts(task_id)
        route = RouteSnapshot(**payload["route"]).effective
        reasons = []
        for role in ("primary", "backup"):
            profile = route[role]
            previous = [a for a in attempts if a["profile_id"] == profile["id"]]
            last = previous[-1] if previous else None
            if len(previous) >= payload["attempts_per_profile"] or (
                last
                and (
                    last["error_kind"] in CONFIGURATION
                    or (last["error_kind"] in FORMAT and last["repair"])
                )
            ):
                reasons.append("attempts_exhausted")
                continue
            try:
                self._preflight(payload, profile)
            except RunnerError as exc:
                reasons.append(str(exc))
                continue
            blocked = self._health_block(profile, payload["generations"][profile["id"]], now)
            if blocked:
                reasons.append(blocked)
                continue
            return profile, bool(last and last["error_kind"] in FORMAT), None
        waiting = next(
            (r for r in reasons if r in {"profile_cooldown", "profile_half_open_busy"}), None
        )
        return None, False, waiting or (reasons[-1] if reasons else "profiles_exhausted")

    def _state(self, task_id, state, error=None, next_at=None, result=None):
        self.db.execute(
            "UPDATE model_tasks SET state=?,error_kind=?,next_at=?,result_json=? WHERE id=?",
            (
                state,
                error,
                next_at.isoformat() if next_at else None,
                _json(result) if result else None,
                task_id,
            ),
        )

    def _request(self, payload, validator, repair=False):
        fields = dict(payload["request"])
        if fields["image"] is not None:
            fields["image"] = base64.b64decode(fields["image"], validate=True)
        if repair:
            fields["instructions"] += (
                "\nThe previous response failed validation. Produce a complete valid result using only the same evidence and required schema/citations."
            )
        return ModelRequest(**fields, validator=validator)

    def _quote(self, profile, request, hold):
        bound = (
            len((request.text + request.instructions).encode())
            + len(_json(request.tool_schema or request.json_schema or {}).encode())
            + len(request.image or b"") * 2
            + 4096
        )
        try:
            quote = self.budget.quote(
                profile["provider"],
                profile["model"],
                input_max=bound,
                output_max=request.max_output_tokens,
            )
        except BudgetError as exc:
            if str(exc) != "pricing_unknown":
                raise
            return {"known": False, "source": "manual_hold"}
        if quote["max_units"] > hold:
            raise BudgetError("authorized_hold_insufficient")
        return quote

    async def advance(self, task_id, validator, *, operation="brief", version="1", now=None):
        try:
            return await self._advance(
                task_id, validator, operation=operation, version=version, now=now
            )
        except (sqlite3.Error, OSError):
            raise RunnerError("storage_failed") from None

    async def _advance(self, task_id, validator, *, operation, version, now):
        realtime = now is None
        now = _time(now)
        async with self._lock:
            task = self._task(task_id)
            payload = task["payload"]
            if not callable(validator) or (operation, version) != (
                payload["operation"],
                payload["version"],
            ):
                raise RunnerError("validator_contract_mismatch")
            if task["state"] not in {"pending", "waiting"} or (
                task["next_at"] and now < datetime.fromisoformat(task["next_at"])
            ):
                return self.status(task_id)
            adapter = None
            dispatched = False
            attempt_id = None
            try:
                self._preflight(payload)
                profile, repair, blocked = self._select(task_id, payload, now)
                if profile is None:
                    with self.store._write():
                        if blocked in {"profile_cooldown", "profile_half_open_busy"}:
                            dates = [
                                datetime.fromisoformat(h["cooldown_until"])
                                for h in self.health()
                                if h["profile_id"] in payload["generations"]
                                and h["cooldown_until"]
                                and datetime.fromisoformat(h["cooldown_until"]) > now
                            ]
                            self._state(
                                task_id,
                                "waiting",
                                blocked,
                                min(dates) if dates else now + timedelta(seconds=5),
                            )
                        else:
                            self._state(task_id, "blocked", blocked)
                    return self.status(task_id)
                generation = payload["generations"][profile["id"]]
                key = await asyncio.to_thread(self.backend.read, profile["credential_ref"])
                if realtime:
                    now = _time()
                self._preflight(payload, profile)
                request = self._request(payload, validator, repair)
                adapter = self.adapter_factory(profile, key)
                adapter.payload(request)
                with self.store._write():
                    # A second runner may have finished while this caller awaited Keychain.
                    current = self._task(task_id)
                    if current["state"] not in {"pending", "waiting"}:
                        return self.status(task_id)
                    if current["next_at"] and now < datetime.fromisoformat(current["next_at"]):
                        return self.status(task_id)
                    self._preflight(payload, profile)
                    chosen, chosen_repair, reason = self._select(task_id, payload, now)
                    if chosen is None or chosen["id"] != profile["id"] or chosen_repair != repair:
                        self._state(task_id, "waiting", reason or "selection_changed", now)
                        return self.status(task_id)
                    ordinal = len(self._attempts(task_id)) + 1
                    attempt_id = (
                        "model." + hashlib.sha256(task_id.encode()).hexdigest() + f".{ordinal}"
                    )
                    quote = self._quote(profile, request, payload["holds"][profile["id"]])
                    self.budget._reserve(
                        attempt_id,
                        task_id,
                        max_units=payload["holds"][profile["id"]],
                        quote=quote,
                        provider=profile["provider"],
                        partition=request.partition,
                        image=request.image is not None,
                        task_limit=payload["task_limit"],
                        now=now,
                    )
                    self.budget._begin_attempt(attempt_id, now=now)
                    self.db.execute(
                        "INSERT INTO model_attempts VALUES (?,?,?,?,?,?,?,?, 'inflight',?,NULL,NULL,NULL)",
                        (
                            attempt_id,
                            task_id,
                            ordinal,
                            profile["id"],
                            generation,
                            identity(profile),
                            attempt_id,
                            int(repair),
                            now.isoformat(),
                        ),
                    )
                    self._state(task_id, "inflight")
                dispatched = True
                result = await adapter.generate(request)
                if realtime:
                    now = _time()
                self._complete(task_id, attempt_id, payload, result, None, now)
            except (RouteBlocked, RouteStale):
                if dispatched:
                    self._complete(
                        task_id,
                        attempt_id,
                        payload,
                        None,
                        ProviderError("configuration_changed", outcome="unknown"),
                        now,
                    )
                else:
                    with self.store._write():
                        if self._task(task_id)["state"] in {"pending", "waiting"}:
                            self._state(task_id, "stale", "configuration_changed")
            except (BudgetError, CredentialError, RunnerError) as exc:
                with self.store._write():
                    if self._task(task_id)["state"] in {"pending", "waiting"}:
                        self._state(task_id, "blocked", str(exc))
            except ProviderError as exc:
                if realtime:
                    now = _time()
                if dispatched:
                    self._complete(task_id, attempt_id, payload, None, exc, now)
                else:
                    with self.store._write():
                        if self._task(task_id)["state"] in {"pending", "waiting"}:
                            self._state(task_id, "blocked", exc.code)
            except asyncio.CancelledError:
                if realtime:
                    now = _time()
                with self.store._write():
                    if dispatched:
                        self._unknown(task_id, attempt_id, "cancelled", now)
                    elif self._task(task_id)["state"] in {"pending", "waiting"}:
                        self._state(task_id, "cancelled", "cancelled")
                raise
            except (sqlite3.Error, OSError):
                raise RunnerError("storage_failed") from None
            finally:
                if adapter is not None:
                    await adapter.close()
            return self.status(task_id)

    def _unknown(self, task_id, attempt_id, code, now):
        self.budget._mark_unknown(attempt_id)
        self.db.execute(
            "UPDATE model_attempts SET state='outcome_unknown',error_kind=?,finished_at=? WHERE id=?",
            (code, now.isoformat(), attempt_id),
        )
        self._state(task_id, "outcome_unknown", code)

    @staticmethod
    def _cost(record, usage):
        quote = record["quote"]
        if quote["source"] != "configured" or not all(
            k in usage for k in ("input_tokens", "output_tokens")
        ):
            return None
        rate = quote["rate"]
        return (
            usage["input_tokens"] * rate["input_per_million"]
            + usage["output_tokens"] * rate["output_per_million"]
            + 999999
        ) // 1000000

    def _complete(self, task_id, attempt_id, payload, result, error, now):
        with self.store._write():
            if error and error.outcome == "unknown":
                self._unknown(task_id, attempt_id, error.code, now)
                return
            record = self.budget.get(attempt_id)
            usage = result["usage"] if result else error.usage
            if error and error.outcome == "not_sent":
                self.budget._mark_unknown(attempt_id)
                self.budget._reconcile(attempt_id, units=0, reason="provider_confirmation")
            else:
                units = self._cost(record, usage)
                self.budget._settle(
                    attempt_id,
                    units=units,
                    usage=usage,
                    cost_source="usage_derived" if units is not None else "unknown",
                )
            code = error.code if error else None
            self.db.execute(
                "UPDATE model_attempts SET state=?,finished_at=?,result_json=?,error_kind=? WHERE id=?",
                (
                    "failed" if error else "completed",
                    now.isoformat(),
                    _json(result) if result else None,
                    code,
                    attempt_id,
                ),
            )
            attempt = next(a for a in self._attempts(task_id) if a["id"] == attempt_id)
            self._update_health(attempt, error, now)
            try:
                effective = RouteSnapshot(**payload["route"]).effective
                profile = next(
                    effective[role]
                    for role in ("primary", "backup")
                    if effective[role]["id"] == attempt["profile_id"]
                )
                self._preflight(payload, profile)
            except (RouteBlocked, RouteStale, RunnerError):
                self._state(task_id, "stale", "configuration_changed")
                return
            if result is not None:
                self._state(task_id, "completed", result=result)
            elif code == "policy_refused":
                self._state(task_id, "refused", code)
            else:
                delay = (
                    (
                        error.retry_after_seconds
                        if error.retry_after_seconds is not None
                        else 5 * (2 ** (len(self._attempts(task_id)) - 1))
                    )
                    if code in TRANSIENT
                    else 0
                )
                self._state(task_id, "waiting", code, now + timedelta(seconds=delay))

    def _update_health(self, attempt, error, now):
        row = self.db.execute(
            "SELECT failures FROM model_health WHERE profile_id=? AND generation=?",
            (attempt["profile_id"], attempt["generation"]),
        ).fetchone()
        code = error.code if error else None
        failures = (row[0] if row else 0) + 1 if code in TRANSIENT else 0
        cooldown = (
            now + timedelta(seconds=max(300, error.retry_after_seconds or 0))
            if failures >= 3
            else None
        )
        self.db.execute(
            "INSERT INTO model_health VALUES (?,?,?,?,?,?) ON CONFLICT(profile_id,generation) DO UPDATE SET failures=excluded.failures,cooldown_until=excluded.cooldown_until,error_kind=excluded.error_kind,checked_at=excluded.checked_at",
            (
                attempt["profile_id"],
                attempt["generation"],
                failures,
                cooldown.isoformat() if cooldown else None,
                code,
                now.isoformat(),
            ),
        )

    def recover_interrupted(self):
        with self.store._write():
            rows = self.db.execute(
                "SELECT id,task_id FROM model_attempts WHERE state='inflight'"
            ).fetchall()
            for attempt_id, task_id in rows:
                self._unknown(task_id, attempt_id, "interrupted", _time())
            return len(rows)

    def resume(self, task_id, *, acknowledge_duplicate_charge=False):
        with self.store._write():
            task = self._task(task_id)
            if task["state"] == "outcome_unknown":
                if acknowledge_duplicate_charge is not True:
                    raise RunnerError("duplicate_charge_ack_required")
            elif task["state"] != "blocked":
                raise RunnerError("task_not_resumable")
            self._preflight(task["payload"])
            self._state(task_id, "pending")
        return self.status(task_id)

    async def recover_result(self, task_id, validator, *, operation="brief", version="1", now=None):
        """Only a trusted adapter with a verified non-billable lookup may recover."""
        now = _time(now)
        async with self._lock:
            task = self._task(task_id)
            payload = task["payload"]
            if task["state"] != "outcome_unknown":
                return self.status(task_id)
            if not callable(validator) or (operation, version) != (
                payload["operation"],
                payload["version"],
            ):
                raise RunnerError("validator_contract_mismatch")
            self._preflight(payload)
            attempt = self._attempts(task_id)[-1]
            route = RouteSnapshot(**payload["route"]).effective
            profile = next(
                route[r] for r in ("primary", "backup") if route[r]["id"] == attempt["profile_id"]
            )
            self._preflight(payload, profile)
            key = await asyncio.to_thread(self.backend.read, profile["credential_ref"])
            self._preflight(payload, profile)
            adapter = self.adapter_factory(profile, key)
            try:
                if getattr(adapter, "verified_nonbillable_lookup", False) is not True:
                    return self.status(task_id)
                try:
                    found = await adapter.lookup(attempt["id"])
                except (ProviderError, httpx.RequestError, TimeoutError):
                    return self.status(task_id)
                if not isinstance(found, dict) or found.get("state") not in {
                    "completed",
                    "definitely_unsent",
                }:
                    return self.status(task_id)
                result = None
                if found["state"] == "completed":
                    try:
                        result = adapter.normalize(
                            found.get("response"), self._request(payload, validator)
                        )
                    except ProviderError:
                        return self.status(task_id)
                with self.store._write():
                    if self._task(task_id)["state"] != "outcome_unknown":
                        return self.status(task_id)
                    self._preflight(payload, profile)
                    units = (
                        self._cost(self.budget.get(attempt["budget_id"]), result["usage"])
                        if result
                        else 0
                    )
                    self.budget._reconcile(
                        attempt["budget_id"], units=units, reason="provider_confirmation"
                    )
                    if result is not None:
                        self.db.execute(
                            "UPDATE budget_attempts SET usage_json=?,cost_source=? WHERE id=?",
                            (
                                _json(result["usage"]),
                                "usage_derived" if units is not None else "unknown",
                                attempt["budget_id"],
                            ),
                        )
                    self.db.execute(
                        "UPDATE model_attempts SET state=?,result_json=?,error_kind=NULL,finished_at=? WHERE id=?",
                        (
                            "completed" if result else "not_sent",
                            _json(result) if result else None,
                            now.isoformat(),
                            attempt["id"],
                        ),
                    )
                    self._state(task_id, "completed" if result else "pending", result=result)
                return self.status(task_id)
            finally:
                await adapter.close()
