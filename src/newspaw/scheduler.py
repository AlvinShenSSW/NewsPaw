"""Durable, bounded wall-clock scheduling for the single local backend."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import sqlite3
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from .credentials import CredentialError
from .pipeline import PipelineError
from .telegram.outbox import _FINISHED_PARTS, OutboxError

_TERMINAL = {
    "cancelled",
    "delivered",
    "no_news",
    "skipped",
    "superseded",
    "partial",
    "outcome_unknown",
    "held",
}
_LEASE_STATES = {"planned", "preparing", "waiting", "blocked", "late", "delivering"}
_OPEN = "('planned','preparing','waiting','blocked','late','delivering','rescheduled')"
_MAX_WORKERS = 4
_LOG = logging.getLogger(__name__)


class ScheduleError(CredentialError):
    pass


def _time(value=None):
    if value is None:
        return datetime.now(UTC)
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ScheduleError("invalid_schedule_time")
    return value.astimezone(UTC)


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _key(prefix, *parts):
    return prefix + "." + hashlib.sha256(_json(parts).encode()).hexdigest()


def resolve_wall_time(day, value, timezone):
    """Resolve a civil slot to earliest fold or the first valid minute after a gap."""
    local = datetime.combine(day, time.fromisoformat(value))
    zone = ZoneInfo(timezone)
    while local.date() == day:
        valid = {
            instant
            for fold in (0, 1)
            if (instant := local.replace(tzinfo=zone, fold=fold).astimezone(UTC))
            .astimezone(zone)
            .replace(tzinfo=None)
            == local
        }
        if valid:
            return min(valid)
        local += timedelta(minutes=1)
    return None


def _policy():
    return dict(
        enabled=False,
        catchup_minutes=360,
        preparation_lead_minutes=15,
        holds={"normal": None, "adult": None},
    )


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS schedule_policy (
            id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
            settings TEXT NOT NULL, activated_at TEXT, last_scan TEXT
        )"""
    )
    db.execute(
        "INSERT OR IGNORE INTO schedule_policy VALUES (1,1,?,NULL,NULL)", (_json(_policy()),)
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS schedule_scopes (
            id TEXT PRIMARY KEY, subscription_id TEXT NOT NULL, account_id TEXT,
            shape TEXT NOT NULL, slots TEXT NOT NULL, serial INTEGER NOT NULL,
            cutover_at TEXT NOT NULL, last_tick TEXT, active INTEGER NOT NULL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS schedule_occurrences (
            id TEXT PRIMARY KEY, scope_id TEXT NOT NULL REFERENCES schedule_scopes(id),
            slot INTEGER NOT NULL, civil_date TEXT NOT NULL, target_at TEXT, prepare_at TEXT,
            cutoff_at TEXT, status TEXT NOT NULL, reason TEXT, generation INTEGER NOT NULL,
            job_id TEXT, assignment TEXT, approved_assignment TEXT, updated_at TEXT NOT NULL,
            UNIQUE(scope_id,slot,civil_date)
        )"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS schedule_work
           ON schedule_occurrences(status,prepare_at,target_at)"""
    )


def _check_policy(settings):
    if not isinstance(settings, dict) or set(settings) != set(_policy()):
        raise ScheduleError("invalid_schedule_policy")
    lead = settings["preparation_lead_minutes"]
    catchup = settings["catchup_minutes"]
    holds = settings["holds"]
    if (
        type(settings["enabled"]) is not bool
        or type(lead) is not int
        or not 1 <= lead <= 120
        or type(catchup) is not int
        or not 0 <= catchup <= 1440
        or not isinstance(holds, dict)
        or set(holds) != {"normal", "adult"}
        or any(
            v is not None and (type(v) is not int or not 1 <= v <= 2**53) for v in holds.values()
        )
    ):
        raise ScheduleError("invalid_schedule_policy")


def _scopes(config):
    enabled = {row["id"]: row for row in config["subscriptions"] if row["enabled"]}
    for sub in enabled.values():
        if sub["times"]:
            yield sub["id"], None, dict(times=sorted(sub["times"]), zone=sub["timezone"])
    for account in config["accounts"]:
        sub = enabled.get(account["subscription_id"])
        if account["priority"] != "special" or sub is None or not account["remote_id"]:
            continue
        times = sub["times"] if account["times"] is None else account["times"]
        if times:
            yield (
                sub["id"],
                account["id"],
                dict(
                    times=sorted(times),
                    zone=sub["timezone"],
                    remote_id=account["remote_id"],
                ),
            )


def _slots(previous, times, serial):
    """Keep exact and re-added slots; deterministically pair remaining active retimes."""
    selected = {}
    active = {value: int(slot) for slot, (value, enabled) in previous.items() if enabled}
    retired = {value: int(slot) for slot, (value, enabled) in previous.items() if not enabled}
    for value in times:
        slot = active.get(value, retired.get(value))
        if slot is not None:
            selected[value] = slot
    remaining = [value for value in times if value not in selected]
    old = [active[value] for value in sorted(active) if value not in selected]
    for value, slot in zip(remaining, old, strict=False):
        selected[value] = slot
    for value in remaining[len(old) :]:
        serial += 1
        selected[value] = serial
    slots = {str(slot): [value, False] for slot, (value, _) in previous.items()}
    slots.update({str(slot): [value, True] for value, slot in selected.items()})
    return slots, serial


def _window(settings, target):
    lead = timedelta(minutes=settings["preparation_lead_minutes"])
    minutes = settings["catchup_minutes"]
    cutoff = timedelta(minutes=minutes) if minutes else timedelta(seconds=60, microseconds=-1)
    return target - lead, target + cutoff


class Scheduler:
    def __init__(self, pipeline, outbox, *, clock=None):
        self.pipeline, self.outbox = pipeline, outbox
        self.store, self.db = pipeline.store, pipeline.db
        self.clock = clock or _time
        self._fixed_clock = clock is not None
        self._loop = None
        self._tasks = {}

    def policy(self):
        self.store.load_config()
        revision, settings, activated = self.db.execute(
            "SELECT revision,settings,activated_at FROM schedule_policy WHERE id=1"
        ).fetchone()
        return dict(revision=revision, settings=json.loads(settings), activated_at=activated)

    def configure(self, settings, revision, *, now=None):
        _check_policy(settings)
        if type(revision) is not int or revision < 1:
            raise ScheduleError("invalid_revision")
        now = _time(now) if now is not None else self.clock()
        with self.store._write():
            current = self.policy()
            if current["revision"] != revision:
                raise ScheduleError("schedule_policy_changed")
            if current["settings"] != settings:
                activated = current["activated_at"]
                if settings["enabled"] and not current["settings"]["enabled"]:
                    activated = now.isoformat()
                self.db.execute(
                    "UPDATE schedule_policy SET revision=revision+1,settings=?,activated_at=? WHERE id=1",
                    (_json(settings), activated),
                )
        return self.policy()

    def _rows(self, query, args=()):
        cursor = self.db.execute(query, args)
        keys = [field[0] for field in cursor.description]
        return [dict(zip(keys, row, strict=True)) for row in cursor.fetchall()]

    def _occurrence(self, identity):
        if (
            not isinstance(identity, str)
            or len(identity) != 73
            or not identity.startswith("schedule.")
        ):
            raise ScheduleError("invalid_occurrence")
        rows = self._rows("SELECT * FROM schedule_occurrences WHERE id=?", (identity,))
        if not rows:
            raise ScheduleError("missing_occurrence")
        return rows[0]

    @staticmethod
    def _view(row):
        return {
            key: value
            for key, value in row.items()
            if key not in {"assignment", "approved_assignment"}
        }

    def status(self, *, limit=25):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ScheduleError("invalid_limit")
        rows = self._rows(
            """SELECT o.*,s.subscription_id,s.account_id FROM schedule_occurrences o
               JOIN schedule_scopes s ON s.id=o.scope_id
               ORDER BY o.updated_at DESC, o.civil_date DESC, o.target_at DESC LIMIT ?""",
            (limit,),
        )
        return {**self.policy(), "occurrences": [self._view(row) for row in rows]}

    def _scope(self, identity, sub, account, shape, policy, now, *, first_scan):
        rows = self._rows("SELECT * FROM schedule_scopes WHERE id=?", (identity,))
        previous = rows[0] if rows else None
        active_at = datetime.fromisoformat(policy["activated_at"])
        changed = previous and (not previous["active"] or previous["shape"] != _json(shape))
        if not previous:
            slots, serial = _slots({}, shape["times"], 0)
            cutover, last = (active_at if first_scan else now), None
        elif changed:
            slots, serial = _slots(
                json.loads(previous["slots"]), shape["times"], previous["serial"]
            )
            cutover, last = now, None
        else:
            slots, serial = json.loads(previous["slots"]), previous["serial"]
            cutover = max(active_at, datetime.fromisoformat(previous["cutover_at"]))
            last = datetime.fromisoformat(previous["last_tick"]) if previous["last_tick"] else None
        self.db.execute(
            """INSERT INTO schedule_scopes VALUES (?,?,?,?,?,?,?,?,1)
               ON CONFLICT(id) DO UPDATE SET shape=excluded.shape,slots=excluded.slots,
               serial=excluded.serial,cutover_at=excluded.cutover_at,last_tick=excluded.last_tick,active=1""",
            (
                identity,
                sub,
                account,
                _json(shape),
                _json(slots),
                serial,
                cutover.isoformat(),
                now.isoformat(),
            ),
        )
        return slots, cutover, last, bool(changed)

    def _scheduled(self, scope, slots, zone, cutover, last, settings, now, *, changed):
        local_day = now.astimezone(ZoneInfo(zone)).date()
        recovery = last is None or (now - last).total_seconds() > 90
        candidates = []
        for slot, (value, enabled) in slots.items():
            if not enabled:
                continue
            for day in (local_day - timedelta(days=1), local_day, local_day + timedelta(days=1)):
                target = resolve_wall_time(day, value, zone)
                if target is None:
                    if day < local_day:
                        candidates.append((int(slot), day, None, None, None))
                    continue
                prepare, deadline = _window(settings, target)
                if target >= cutover and prepare <= now and now - target <= timedelta(days=1):
                    candidates.append((int(slot), day, target, prepare, deadline))
        latest = max(
            (item[2] for item in candidates if item[2] and item[2] <= now <= item[4]),
            default=None,
        )
        active = set()
        for slot, day, target, prepare, deadline in candidates:
            identity = _key("schedule", scope, slot, day.isoformat())
            active.add(identity)
            state, reason = "planned", None
            if target is None:
                state, reason = "skipped", "nonexistent_local_date"
            elif now > deadline:
                state, reason = "skipped", "catchup_expired"
            elif recovery and latest and target < latest:
                state, reason = "superseded", "newer_elapsed_slot"
            dates = tuple(
                value.isoformat() if value is not None else None
                for value in (target, prepare, deadline)
            )
            self.db.execute(
                """INSERT OR IGNORE INTO schedule_occurrences VALUES
                   (?,?,?,?,?,?,?,?,?,1,NULL,NULL,NULL,?)""",
                (identity, scope, slot, day.isoformat(), *dates, state, reason, now.isoformat()),
            )
            existing = self._occurrence(identity)
            if existing["status"] in _TERMINAL:
                continue
            if state != "planned":
                self._expire(existing, state, reason, now)
            elif (
                dates != tuple(existing[key] for key in ("target_at", "prepare_at", "cutoff_at"))
                or existing["status"] == "rescheduled"
            ):
                self.db.execute(
                    """UPDATE schedule_occurrences SET target_at=?,prepare_at=?,cutoff_at=?,
                           status=CASE WHEN status='rescheduled' THEN 'planned' ELSE status END,
                           reason=CASE WHEN status='rescheduled' THEN NULL ELSE reason END
                       WHERE id=?""",
                    (*dates, identity),
                )
        for row in self._rows(
            f"SELECT * FROM schedule_occurrences WHERE scope_id=? AND status IN {_OPEN}", (scope,)
        ):
            if row["id"] in active:
                continue
            if changed:
                value, enabled = slots[str(row["slot"])]
                desired = (
                    resolve_wall_time(date.fromisoformat(row["civil_date"]), value, zone)
                    if enabled
                    else None
                )
                if desired and desired >= cutover:
                    prepare, deadline = _window(settings, desired)
                    self.db.execute(
                        "UPDATE schedule_occurrences SET target_at=?,prepare_at=?,cutoff_at=? WHERE id=?",
                        (desired.isoformat(), prepare.isoformat(), deadline.isoformat(), row["id"]),
                    )
                    self._expire(row, "rescheduled", "schedule_changed", now)
                else:
                    self._expire(row, "skipped", "schedule_changed", now)
            elif row["target_at"] and datetime.fromisoformat(row["target_at"]) < cutover:
                self._expire(row, "skipped", "schedule_changed", now)
            elif row["cutoff_at"] and now > datetime.fromisoformat(row["cutoff_at"]):
                self._expire(row, "skipped", "catchup_expired", now)

    def _receipt(self, row):
        if row["job_id"] is None:
            return None
        try:
            return self.outbox.status(row["job_id"])
        except OutboxError as exc:
            if str(exc) != "missing_delivery":
                raise
            return None

    def _expire(self, row, state, reason, now):
        delivery = self._receipt(row)
        if delivery and delivery["started"]:
            statuses = {target["status"] for target in delivery["targets"].values()}
            if statuses == {"delivered"}:
                state, reason = "delivered", None
            else:
                state = (
                    "outcome_unknown" if statuses & {"outcome_unknown", "inflight"} else "partial"
                )
        elif row["job_id"] and self.pipeline.get(row["job_id"])["status"] in {
            "inflight",
            "outcome_unknown",
        }:
            state, reason = "outcome_unknown", "model_outcome_unknown"
        self.db.execute(
            "UPDATE schedule_occurrences SET status=?,reason=?,updated_at=? WHERE id=?",
            (state, reason, now.isoformat(), row["id"]),
        )

    def plan(self, now=None):
        now = _time(now) if now is not None else self.clock()
        with self.store._write():
            policy = self.policy()
            settings = policy["settings"]
            if not settings["enabled"]:
                return []
            first_scan = (
                self.db.execute("SELECT last_scan FROM schedule_policy WHERE id=1").fetchone()[0]
                is None
            )
            _, config = self.store.load_config()
            active_scopes = set()
            for sub, account, shape in _scopes(config):
                identity = _key("scope", sub, account)
                active_scopes.add(identity)
                slots, cutover, last, changed = self._scope(
                    identity, sub, account, shape, policy, now, first_scan=first_scan
                )
                self._scheduled(
                    identity, slots, shape["zone"], cutover, last, settings, now, changed=changed
                )
            for (identity,) in self.db.execute(
                "SELECT id FROM schedule_scopes WHERE active=1"
            ).fetchall():
                if identity not in active_scopes:
                    self.db.execute("UPDATE schedule_scopes SET active=0 WHERE id=?", (identity,))
                    for row in self._rows(
                        f"SELECT * FROM schedule_occurrences WHERE scope_id=? AND status IN {_OPEN}",
                        (identity,),
                    ):
                        self._expire(row, "skipped", "scope_disabled", now)
            self.db.execute("UPDATE schedule_policy SET last_scan=? WHERE id=1", (now.isoformat(),))
            self.db.execute(
                """UPDATE schedule_occurrences
                   SET status='late',reason='preparation_late',updated_at=?
                   WHERE status='preparing' AND target_at<=? AND cutoff_at>=?
                   AND NOT EXISTS(SELECT 1 FROM pipeline_jobs j
                                  WHERE j.id=schedule_occurrences.job_id
                                  AND j.stage='awaiting_delivery')""",
                (now.isoformat(), now.isoformat(), now.isoformat()),
            )
            return self._rows(
                """SELECT o.*,s.subscription_id,s.account_id FROM schedule_occurrences o
                   JOIN schedule_scopes s ON s.id=o.scope_id
                   WHERE s.active=1 AND o.status IN ('planned','preparing','waiting','blocked','late','delivering')
                   AND o.prepare_at<=? AND o.cutoff_at>=?
                   ORDER BY o.updated_at,o.target_at,o.id LIMIT 200""",
                (now.isoformat(), now.isoformat()),
            )

    def _set(self, row, state, reason, now):
        self.db.execute(
            f"""UPDATE schedule_occurrences SET status=?,reason=?,updated_at=?
                WHERE id=? AND generation=? AND status IN {_OPEN}""",
            (state, reason, now.isoformat(), row["id"], row["generation"]),
        )

    def _state(self, row, state, reason, now):
        with self.store._write():
            self._set(row, state, reason, now)

    def _assigned(self, row, config):
        scope = self.db.execute(
            "SELECT subscription_id,account_id FROM schedule_scopes WHERE id=?", (row["scope_id"],)
        ).fetchone()
        preview = self.outbox.targets.preview(scope[0], account_id=scope[1])
        return set(preview["target_status"]), {bot["id"] for bot in config["bots"]}

    def _assignment_allowed(self, row, config, now, *, claim=False):
        current, existing = self._assigned(row, config)
        saved = row["approved_assignment"] or row["assignment"]
        if saved is not None:
            if current != set(json.loads(saved)) & existing:
                self._set(row, "held", "partial_assignment_changed", now)
                return False
        elif claim:
            self.db.execute(
                "UPDATE schedule_occurrences SET assignment=? WHERE id=? AND generation=?",
                (_json(sorted(current)), row["id"], row["generation"]),
            )
        return True

    def _scope_current(self, row, config):
        record = self.db.execute(
            "SELECT subscription_id,account_id,shape,active FROM schedule_scopes WHERE id=?",
            (row["scope_id"],),
        ).fetchone()
        if not record or not record[3]:
            return False
        sub, account, shape, _ = record
        return any(
            current_sub == sub and current_account == account and _json(current_shape) == shape
            for current_sub, current_account, current_shape in _scopes(config)
        )

    def _guard(self, row, *, sending=False):
        """Called inside the existing transaction that would create the effect intent."""
        now = _time(self.clock())
        current = self._occurrence(row["id"])
        if (
            current["generation"] != row["generation"]
            or current["job_id"] != row["job_id"]
            or current["status"] not in _LEASE_STATES
        ):
            return False
        policy = self.policy()
        settings = policy["settings"]
        if not settings["enabled"]:
            self._set(current, "waiting", "schedule_disabled", now)
            return False
        target = datetime.fromisoformat(current["target_at"])
        prepare, deadline = _window(settings, target)
        if target < datetime.fromisoformat(policy["activated_at"]) or now > deadline:
            self._expire(current, "skipped", "catchup_expired", now)
            return False
        if now < (target if sending else prepare):
            return False
        _, config = self.store.load_config()
        if not self._scope_current(current, config):
            self._set(current, "waiting", "schedule_changed", now)
            return False
        if not sending:
            job = self.pipeline._row(row["job_id"])
            hold = settings["holds"][job["partition"]]
            if hold is None or set(job["payload"]["holds"].values()) != {hold}:
                self._set(current, "waiting", "schedule_budget_changed", now)
                return False
        return not sending or self._assignment_allowed(current, config, now, claim=True)

    def _rebuild(self, row, job, now, reason):
        delivery = self._receipt(row)
        if delivery and delivery["started"]:
            with self.store._write():
                self._expire(row, "partial", reason, now)
            return
        if job["status"] in {"inflight", "outcome_unknown"}:
            self._state(row, "waiting", "model_outcome_unknown", now)
            return
        with self.store._write():
            self.db.execute(
                f"""UPDATE schedule_occurrences SET generation=generation+1,job_id=NULL,status='planned',
                       reason=?,updated_at=? WHERE id=? AND generation=? AND status IN {_OPEN}""",
                (reason, now.isoformat(), row["id"], row["generation"]),
            )

    def _attach(self, row, settings, now):
        edition = f"{row['id']}.{row['generation']}"
        saved = self.db.execute(
            "SELECT id FROM pipeline_jobs WHERE subscription_id=? AND account_key=? AND edition_key=?",
            (row["subscription_id"], row["account_id"] or "", edition),
        ).fetchone()
        if saved:
            job_id = saved[0]
        else:
            route = self.store.preview_route(row["subscription_id"], account_id=row["account_id"])
            if route.blockers:
                self._state(row, "blocked", route.blockers[0], now)
                return None
            effective = route.effective
            hold = settings["holds"][effective["partition"]]
            if hold is None:
                self._state(row, "blocked", "schedule_budget_required", now)
                return None
            job_id = self.pipeline.create(
                row["subscription_id"],
                edition,
                account_id=row["account_id"],
                holds={effective[role]["id"]: hold for role in ("primary", "backup")},
                now=now,
            )["job_id"]
        with self.store._write():
            changed = self.db.execute(
                f"""UPDATE schedule_occurrences SET job_id=?,updated_at=?
                   WHERE id=? AND generation=? AND job_id IS NULL AND status IN {_OPEN}""",
                (job_id, now.isoformat(), row["id"], row["generation"]),
            ).rowcount
        return {**row, "job_id": job_id} if changed else None

    async def _delivery(self, row, job, now):
        try:
            self.pipeline.delivery_scope(job["job_id"])
        except PipelineError as exc:
            if str(exc) == "job_paused":
                self._state(row, "waiting", "job_paused", now)
            else:
                self._rebuild(row, job, now, str(exc))
            return
        if now < datetime.fromisoformat(row["target_at"]):
            self._state(row, "waiting", "awaiting_target_time", now)
            return
        with self.store._write():
            current = self._occurrence(row["id"])
            if current["status"] not in _LEASE_STATES:
                return
            if not self._assignment_allowed(current, self.store.load_config()[1], now):
                return
        delivery = self.outbox.enqueue(job["job_id"], now=now)
        if delivery["reason"]:
            self._rebuild(row, job, now, delivery["reason"])
            return
        self._state(row, "delivering", None, now)
        targets = []
        for item in self.outbox._rows(job["job_id"]):
            view = delivery["targets"][item["bot_id"]]
            if view["reason"] or (
                view["backoff_until"] and view["backoff_until"] > now.isoformat()
            ):
                continue
            part = next(
                (p for p in item["parts"] if p["state"] not in _FINISHED_PARTS),
                None,
            )
            if part and part["state"] == "pending":
                targets.append(item["bot_id"])
            if len(targets) == _MAX_WORKERS:
                break
        failed_checks = False
        if targets:
            outcomes = await asyncio.gather(
                *(
                    self.outbox.advance(
                        job["job_id"],
                        bot,
                        now=now if self._fixed_clock else None,
                        effect_guard=lambda: self._guard(row, sending=True),
                    )
                    for bot in targets
                ),
                return_exceptions=True,
            )
            failed_checks = any(isinstance(result, Exception) for result in outcomes)
        status = self.outbox.status(job["job_id"])
        results = list(status["targets"].values())
        now = _time(self.clock())
        complete = bool(results) and all(item["status"] == "delivered" for item in results)
        uncertain = any(item["status"] in {"outcome_unknown", "inflight"} for item in results)
        if not uncertain and status["started"]:
            final_state = "delivered" if complete else "partial"
            with self.store._write():
                self.db.execute(
                    """UPDATE schedule_occurrences SET status=?,
                       reason=CASE WHEN ?='delivered' THEN NULL ELSE reason END,updated_at=?
                       WHERE id=? AND generation=? AND status='outcome_unknown'
                       AND reason!='model_outcome_unknown'""",
                    (
                        final_state,
                        final_state,
                        now.isoformat(),
                        row["id"],
                        row["generation"],
                    ),
                )
        if complete:
            self._state(row, "delivered", None, now)
        elif uncertain:
            self._state(row, "waiting", "delivery_outcome_unknown", now)
        elif failed_checks:
            self._state(row, "waiting", "delivery_target_check_failed", now)
        elif not targets and not any(
            item["status"] in {"pending", "partial"} and not item["reason"] for item in results
        ):
            delivered = any(item["delivered"] for item in results)
            self._state(row, "partial" if delivered else "blocked", "targets_unavailable", now)

    async def step(self, row):
        now = _time(self.clock())
        current = self._occurrence(row["id"])
        if current["generation"] != row["generation"] or current["status"] not in _LEASE_STATES:
            return
        settings = self.policy()["settings"]
        if not settings["enabled"]:
            return
        target = datetime.fromisoformat(current["target_at"])
        prepare, deadline = _window(settings, target)
        if not prepare <= now <= deadline:
            return
        row = {**row, **current}
        if not self._scope_current(row, self.store.load_config()[1]):
            return
        if row["job_id"] is None:
            row = self._attach(row, settings, now)
            if row is None:
                return
        job = self.pipeline.get(row["job_id"])
        stage = job["stage"]
        if job["cancelled"] or stage == "cancelled":
            self._state(row, "cancelled", "job_cancelled", now)
        elif job["paused"]:
            self._state(row, "waiting", "job_paused", now)
        elif stage == "awaiting_delivery":
            await self._delivery(row, job, now)
        elif stage == "stale":
            self._rebuild(row, job, now, "edition_changed")
        elif stage == "no_news":
            self._state(row, "no_news", None, now)
        elif stage in {"refused", "collection_failed", "blocked"}:
            self._state(row, "blocked", job["error_kind"] or stage, now)
        elif job["status"] in {"inflight", "outcome_unknown"}:
            self._state(row, "waiting", "model_outcome_unknown", now)
        else:
            hold = settings["holds"][job["partition"]]
            old = self.pipeline._row(job["job_id"])["payload"]["holds"]
            if hold is None:
                self._state(row, "blocked", "schedule_budget_required", now)
            elif set(old.values()) != {hold}:
                self._rebuild(row, job, now, "schedule_budget_changed")
            else:
                if job["status"] in {"blocked", "waiting"}:
                    self._state(row, job["status"], job["model"]["error_kind"], now)
                else:
                    self._state(row, "late" if now >= target else "preparing", None, now)
                result = await self.pipeline.advance(
                    job["job_id"],
                    now=now if self._fixed_clock else None,
                    effect_guard=lambda: self._guard(row),
                )
                if result["status"] not in {"inflight", "outcome_unknown"}:
                    with self.store._write():
                        self.db.execute(
                            """UPDATE schedule_occurrences
                               SET status='skipped',reason='stopped_after_model_result',updated_at=?
                               WHERE id=? AND generation=? AND status='outcome_unknown'
                               AND reason='model_outcome_unknown'""",
                            (_time(self.clock()).isoformat(), row["id"], row["generation"]),
                        )

    def resolve(self, identity, action):
        if action not in {"stop", "continue"}:
            raise ScheduleError("invalid_schedule_resolution")
        now = _time(self.clock())
        with self.store._write():
            row = self._occurrence(identity)
            if row["status"] != "held" or row["reason"] != "partial_assignment_changed":
                raise ScheduleError("schedule_not_held")
            if action == "stop":
                state, reason, approval = "partial", "owner_stopped_remaining", None
            else:
                policy = self.policy()
                target = datetime.fromisoformat(row["target_at"])
                _, deadline = _window(policy["settings"], target)
                _, config = self.store.load_config()
                if (
                    not policy["settings"]["enabled"]
                    or target < datetime.fromisoformat(policy["activated_at"])
                    or not target <= now <= deadline
                    or not self._scope_current(row, config)
                ):
                    raise ScheduleError("schedule_not_current")
                self.pipeline.delivery_scope(row["job_id"])
                assigned, _ = self._assigned(row, config)
                state, reason, approval = "delivering", None, _json(sorted(assigned))
            self.db.execute(
                """UPDATE schedule_occurrences SET status=?,reason=?,approved_assignment=?,updated_at=?
                   WHERE id=?""",
                (state, reason, approval, now.isoformat(), identity),
            )
        return self._view(self._occurrence(identity))

    def start(self):
        if self._loop is None:
            self._loop = asyncio.create_task(self._run())

    async def _work(self, row):
        try:
            await self.step(row)
        except CredentialError as exc:
            self._state(row, "blocked", str(exc), _time(self.clock()))

    async def _run(self):
        while True:
            for identity, task in tuple(self._tasks.items()):
                if task.done():
                    self._tasks.pop(identity)
                    try:
                        await task
                    except Exception as exc:
                        _LOG.warning("Schedule worker failed (%s)", type(exc).__name__)
            try:
                ready = self.plan()
            except (sqlite3.Error, OSError, CredentialError):
                _LOG.warning("Schedule planning failed")
                ready = []
            for row in ready:
                if len(self._tasks) >= _MAX_WORKERS:
                    break
                if row["id"] not in self._tasks:
                    self._tasks[row["id"]] = asyncio.create_task(self._work(row))
            await asyncio.sleep(2)

    async def close(self):
        if self._loop is not None:
            self._loop.cancel()
            await asyncio.gather(self._loop, return_exceptions=True)
            self._loop = None
        tasks = list(self._tasks.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._tasks.clear()
