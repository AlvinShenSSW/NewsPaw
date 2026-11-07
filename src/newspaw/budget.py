"""Single-database reservations. Currency and X reads are never interchangeable."""

from __future__ import annotations

import calendar
import json
import re
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


class BudgetError(ValueError):
    pass


SCHEMA = """
CREATE TABLE IF NOT EXISTS budget_policy (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, document TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS budget_periods (id INTEGER PRIMARY KEY, meter TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, timezone TEXT NOT NULL, cycle_day INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS budget_tasks (meter TEXT NOT NULL, task_id TEXT NOT NULL, limit_units INTEGER, PRIMARY KEY(meter, task_id));
CREATE TABLE IF NOT EXISTS budget_attempts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, meter TEXT NOT NULL, partition TEXT NOT NULL, provider TEXT NOT NULL, account_id TEXT, image INTEGER NOT NULL, period_id INTEGER NOT NULL REFERENCES budget_periods(id), reserved_units INTEGER NOT NULL, settled_units INTEGER, state TEXT NOT NULL, quote_json TEXT NOT NULL, usage_json TEXT NOT NULL, created_at TEXT NOT NULL, reason TEXT, cost_source TEXT NOT NULL DEFAULT 'reservation');
CREATE INDEX IF NOT EXISTS budget_period_attempts ON budget_attempts(period_id);
CREATE INDEX IF NOT EXISTS budget_task_attempts ON budget_attempts(meter,task_id);
"""


def default_policy():
    return {
        "model": {
            "monthly_limit": None,
            "image_limit": None,
            "provider_limits": {},
            "timezone": "Asia/Tokyo",
            "cycle_day": 1,
        },
        "x": {
            "daily_limit": None,
            "partition_limits": {"normal": None, "adult": None},
            "account_limits": {},
            "timezone": "Asia/Tokyo",
        },
        "prices": [],
        "openai_credit": {
            "amount": 100_000_000,
            "organization": None,
            "expires_at": None,
            "source": "user_declared",
            "verified": False,
        },
    }


def _units(value, optional=False):
    if optional and value is None:
        return
    if type(value) is not int or not 0 <= value <= 2**53:
        raise BudgetError("invalid_units")


def _identity(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", value):
        raise BudgetError("invalid_identifier")


def _time(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise BudgetError("aware_time_required")
    return value.astimezone(UTC)


def _json(value):
    return json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False
    )


def _fields(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields.split()):
        raise BudgetError("invalid_policy")


def validate_policy(policy):
    try:
        _fields(policy, "model x prices openai_credit")
        model, x = policy["model"], policy["x"]
        _fields(model, "monthly_limit image_limit provider_limits timezone cycle_day")
        _fields(x, "daily_limit partition_limits account_limits timezone")
        for field in (model["monthly_limit"], model["image_limit"], x["daily_limit"]):
            _units(field, optional=True)
        for table in (model["provider_limits"], x["partition_limits"], x["account_limits"]):
            if not isinstance(table, dict) or len(table) > 200:
                raise BudgetError("invalid_policy")
            for key, value in table.items():
                _identity(key)
                _units(value, optional=True)
        if set(x["partition_limits"]) != {"normal", "adult"}:
            raise BudgetError("invalid_policy")
        for zone in (model["timezone"], x["timezone"]):
            ZoneInfo(zone)
        if type(model["cycle_day"]) is not int or not 1 <= model["cycle_day"] <= 28:
            raise BudgetError("invalid_cycle_day")
        prices = policy["prices"]
        if not isinstance(prices, list) or len(prices) > 100:
            raise BudgetError("invalid_prices")
        ids, slots = set(), set()
        for rate in prices:
            _fields(rate, "id provider model input_per_million output_per_million updated_at")
            for key in ("id", "provider", "model"):
                _identity(rate[key])
            _units(rate["input_per_million"])
            _units(rate["output_per_million"])
            _time(datetime.fromisoformat(rate["updated_at"]))
            slot = (rate["provider"], rate["model"])
            if rate["id"] in ids or slot in slots:
                raise BudgetError("duplicate_price")
            ids.add(rate["id"])
            slots.add(slot)
        credit = policy["openai_credit"]
        _fields(credit, "amount organization expires_at source verified")
        _units(credit["amount"], optional=True)
        if credit["organization"] is not None:
            _identity(credit["organization"])
        if credit["expires_at"] is not None:
            _time(datetime.fromisoformat(credit["expires_at"]))
        if credit["source"] != "user_declared" or credit["verified"] is not False:
            raise BudgetError("credit_is_not_verified_balance")
    except (TypeError, KeyError, ValueError, ZoneInfoNotFoundError) as exc:
        if isinstance(exc, BudgetError):
            raise
        raise BudgetError("invalid_policy") from None


def initialize(db):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            db.execute(statement)
    db.execute("INSERT OR IGNORE INTO budget_policy VALUES (1,1,?)", (_json(default_policy()),))


def _calendar_window(now, meter, zone, cycle_day):
    local = now.astimezone(ZoneInfo(zone))
    start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    if meter == "x":
        end = start + timedelta(days=1)
    else:
        start = start.replace(day=cycle_day)
        if local < start:
            year, month = (
                (start.year - 1, 12) if start.month == 1 else (start.year, start.month - 1)
            )
            start = start.replace(year=year, month=month)
        year, month = (start.year + 1, 1) if start.month == 12 else (start.year, start.month + 1)
        end = start.replace(
            year=year, month=month, day=min(cycle_day, calendar.monthrange(year, month)[1])
        )
    return start.astimezone(UTC), end.astimezone(UTC)


class BudgetLedger:
    def __init__(self, store):
        self.store = store
        self.db = store._db

    def policy(self):
        from .migrations import check_version

        check_version(self.db)
        revision, document = self.db.execute(
            "SELECT revision,document FROM budget_policy WHERE id=1"
        ).fetchone()
        value = json.loads(document)
        validate_policy(value)
        return revision, value

    def configure(self, policy, expected_revision):
        validate_policy(policy)
        if type(expected_revision) is not int or expected_revision < 1:
            raise BudgetError("invalid_revision")
        with self.store._write():
            revision, previous = self.policy()
            if revision != expected_revision:
                raise BudgetError("budget_policy_conflict")
            old_prices = {p["id"]: p for p in previous["prices"]}
            for price in policy["prices"]:
                if price["id"] in old_prices and price != old_prices[price["id"]]:
                    raise BudgetError("price_version_reused")
            self.db.execute(
                "UPDATE budget_policy SET revision=revision+1,document=? WHERE id=1",
                (_json(policy),),
            )
        return revision + 1

    def quote(self, provider, model, *, input_max, output_max):
        _identity(provider)
        _identity(model)
        _units(input_max)
        _units(output_max)
        _, policy = self.policy()
        rate = next(
            (p for p in policy["prices"] if p["provider"] == provider and p["model"] == model), None
        )
        if rate is None:
            raise BudgetError("pricing_unknown")
        maximum = (
            input_max * rate["input_per_million"]
            + output_max * rate["output_per_million"]
            + 999_999
        ) // 1_000_000
        _units(maximum)
        return {
            "known": True,
            "source": "configured",
            "rate": rate,
            "input_max": input_max,
            "output_max": output_max,
            "max_units": maximum,
        }

    def _period(self, now, meter, policy):
        latest = self.db.execute(
            "SELECT id,start,end FROM budget_periods WHERE meter=? ORDER BY start DESC LIMIT 1",
            (meter,),
        ).fetchone()
        if latest:
            old_start, old_end = map(datetime.fromisoformat, latest[1:])
            if now < old_start:
                raise BudgetError("clock_before_current_period")
            if now < old_end:
                return latest[0]
        zone = policy[meter]["timezone"]
        cycle = policy[meter].get("cycle_day", 1)
        start, end = _calendar_window(now, meter, zone, cycle)
        if latest:
            start = max(start, old_end)
        return self.db.execute(
            "INSERT INTO budget_periods(meter,start,end,timezone,cycle_day) VALUES (?,?,?,?,?)",
            (meter, start.isoformat(), end.isoformat(), zone, cycle),
        ).lastrowid

    def _sum(self, where, args):
        return self.db.execute(
            "SELECT COALESCE(SUM(CASE WHEN state='released' THEN 0 ELSE COALESCE(settled_units,reserved_units) END),0) FROM budget_attempts WHERE "
            + where,
            args,
        ).fetchone()[0]

    @staticmethod
    def _cap(limit, used, amount, code):
        if limit is not None and used + amount > limit:
            raise BudgetError(code)

    def reserve(
        self,
        attempt_id,
        task_id,
        *,
        max_units,
        quote,
        meter="model",
        partition="normal",
        provider=None,
        account_id=None,
        image=False,
        task_limit=None,
        now=None,
    ):
        with self.store._write():
            return self._reserve(attempt_id, task_id, max_units=max_units, quote=quote, meter=meter, partition=partition, provider=provider, account_id=account_id, image=image, task_limit=task_limit, now=now)

    def _reserve(
        self,
        attempt_id,
        task_id,
        *,
        max_units,
        quote,
        meter="model",
        partition="normal",
        provider=None,
        account_id=None,
        image=False,
        task_limit=None,
        now=None,
    ):
        now = _time(datetime.now(UTC) if now is None else now)
        provider = provider if provider is not None else ("x" if meter == "x" else "openai")
        if meter == "x" and provider != "x":
            raise BudgetError("invalid_x_provider")
        for value in (attempt_id, task_id, provider):
            _identity(value)
        if account_id is not None:
            _identity(account_id)
        _units(max_units)
        _units(task_limit, optional=True)
        if (
            meter not in {"model", "x"}
            or partition not in {"normal", "adult"}
            or type(image) is not bool
            or (meter == "x" and image)
        ):
            raise BudgetError("invalid_meter")
        if not isinstance(quote, dict) or type(quote.get("known")) is not bool:
            raise BudgetError("invalid_quote")
        if quote == {"known": False, "source": "manual_hold"}:
            if meter != "model":
                raise BudgetError("invalid_quote")
            if max_units == 0:
                raise BudgetError("unpriced_hold_required")
        elif quote == {"known": True, "source": "x_read_cap"}:
            if meter != "x":
                raise BudgetError("invalid_quote")
        elif quote.get("source") == "configured" and quote["known"]:
            _fields(quote, "known source rate input_max output_max max_units")
            for key in ("input_max", "output_max", "max_units"):
                _units(quote[key])
            if meter != "model" or max_units < quote["max_units"]:
                raise BudgetError("invalid_quote_bound")
        else:
            raise BudgetError("invalid_quote")
        frozen = dict(
            task_id=task_id,
            meter=meter,
            partition=partition,
            provider=provider,
            account_id=account_id,
            image=int(image),
            reserved_units=max_units,
            quote=quote,
        )
        existing = self._get(attempt_id)
        if existing:
            if (
                any(existing[key] != value for key, value in frozen.items())
                or self._task_limit(meter, task_id) != task_limit
            ):
                raise BudgetError("idempotency_conflict")
            return existing
        _, policy = self.policy()
        if quote["known"] and quote["source"] == "configured":
            rate = quote["rate"]
            if rate not in policy["prices"] or rate["provider"] != provider:
                raise BudgetError("price_changed")
            expected = self.quote(
                provider,
                rate["model"],
                input_max=quote["input_max"],
                output_max=quote["output_max"],
            )
            if quote != expected:
                raise BudgetError("invalid_quote_bound")
        period = self._period(now, meter, policy)
        task = self.db.execute(
            "SELECT limit_units FROM budget_tasks WHERE meter=? AND task_id=?", (meter, task_id)
        ).fetchone()
        if task and task[0] != task_limit:
            raise BudgetError("task_policy_changed")
        frozen["period_id"] = period
        self._admit(policy, frozen, max_units, task_limit)
        self.db.execute(
            "INSERT OR IGNORE INTO budget_tasks VALUES (?,?,?)", (meter, task_id, task_limit)
        )
        self.db.execute(
            "INSERT INTO budget_attempts(id,task_id,meter,partition,provider,account_id,image,period_id,reserved_units,settled_units,state,quote_json,usage_json,created_at,reason) VALUES (?,?,?,?,?,?,?,?,?,NULL,'reserved',?,'{}',?,NULL)",
            (
                attempt_id,
                task_id,
                meter,
                partition,
                provider,
                account_id,
                int(image),
                period,
                max_units,
                _json(quote),
                now.isoformat(),
            ),
        )
        return self._get(attempt_id)

    def _admit(self, policy, record, max_units, task_limit):
        meter, task_id, period, provider, partition, account_id, image = (
            record[key]
            for key in (
                "meter",
                "task_id",
                "period_id",
                "provider",
                "partition",
                "account_id",
                "image",
            )
        )
        self._cap(
            task_limit,
            self._sum("meter=? AND task_id=?", (meter, task_id)),
            max_units,
            "task_limit",
        )
        policy_meter = policy[meter]
        self._cap(
            policy_meter["monthly_limit" if meter == "model" else "daily_limit"],
            self._sum("period_id=?", (period,)),
            max_units,
            f"{meter}_limit",
        )
        if meter == "model":
            if image:
                self._cap(
                    policy_meter["image_limit"],
                    self._sum("period_id=? AND image=1", (period,)),
                    max_units,
                    "image_limit",
                )
            self._cap(
                policy_meter["provider_limits"].get(provider),
                self._sum("period_id=? AND provider=?", (period, provider)),
                max_units,
                "provider_limit",
            )
        else:
            self._cap(
                policy_meter["partition_limits"][partition],
                self._sum("period_id=? AND partition=?", (period, partition)),
                max_units,
                "partition_limit",
            )
            if account_id is not None:
                self._cap(
                    policy_meter["account_limits"].get(account_id),
                    self._sum("period_id=? AND account_id=?", (period, account_id)),
                    max_units,
                    "account_limit",
                )

    def _task_limit(self, meter, task_id):
        return self.db.execute(
            "SELECT limit_units FROM budget_tasks WHERE meter=? AND task_id=?", (meter, task_id)
        ).fetchone()[0]

    def _get(self, attempt_id):
        cursor = self.db.execute("SELECT * FROM budget_attempts WHERE id=?", (attempt_id,))
        row = cursor.fetchone()
        if row is None:
            return None
        result = dict(zip([field[0] for field in cursor.description], row, strict=True))
        result["quote"] = json.loads(result.pop("quote_json"))
        result["usage"] = json.loads(result.pop("usage_json"))
        return result

    def get(self, attempt_id):
        self.policy()  # Version guard.
        record = self._get(attempt_id)
        if record is None:
            raise BudgetError("missing_attempt")
        return record

    def begin_attempt(self, attempt_id, *, now=None):
        with self.store._write():
            return self._begin_attempt(attempt_id, now=now)

    def _begin_attempt(self, attempt_id, *, now=None):
        now = _time(datetime.now(UTC) if now is None else now)
        record = self.get(attempt_id)
        if record["state"] != "reserved":
            raise BudgetError("attempt_not_dispatchable")
        latest_start = self.db.execute(
            "SELECT start FROM budget_periods WHERE meter=? ORDER BY start DESC LIMIT 1",
            (record["meter"],),
        ).fetchone()[0]
        if now < datetime.fromisoformat(latest_start):
            raise BudgetError("clock_before_current_period")
        start, end = self.db.execute(
            "SELECT start,end FROM budget_periods WHERE id=?", (record["period_id"],)
        ).fetchone()
        if not datetime.fromisoformat(start) <= now < datetime.fromisoformat(end):
            raise BudgetError("reservation_expired")
        _, policy = self.policy()
        if (
            record["quote"]["source"] == "configured"
            and record["quote"]["rate"] not in policy["prices"]
        ):
            raise BudgetError("price_changed")
        self._admit(policy, record, 0, self._task_limit(record["meter"], record["task_id"]))
        self.db.execute("UPDATE budget_attempts SET state='inflight' WHERE id=?", (attempt_id,))
        return self._get(attempt_id)

    def mark_unknown(self, attempt_id):
        with self.store._write():
            return self._mark_unknown(attempt_id)

    def _mark_unknown(self, attempt_id):
        record = self.get(attempt_id)
        if record["state"] not in {"inflight", "outcome_unknown"}:
            raise BudgetError("cannot_mark_unknown")
        self.db.execute(
            "UPDATE budget_attempts SET state='outcome_unknown' WHERE id=?", (attempt_id,)
        )

    def recover_inflight(self):
        with self.store._write():
            return self.db.execute(
                "UPDATE budget_attempts SET state='outcome_unknown' WHERE state='inflight'"
            ).rowcount

    def release(self, attempt_id):
        with self.store._write():
            record = self.get(attempt_id)
            if record["state"] not in {"reserved", "released"}:
                raise BudgetError("cannot_release_dispatched")
            self.db.execute("UPDATE budget_attempts SET state='released' WHERE id=?", (attempt_id,))

    @staticmethod
    def _usage(usage):
        if not isinstance(usage, dict) or set(usage) - {
            "input_tokens",
            "output_tokens",
            "cached_tokens",
            "images",
            "reads",
            "audio_seconds",
        }:
            raise BudgetError("invalid_usage")
        for value in usage.values():
            _units(value)

    def settle(self, attempt_id, *, units, usage=None, cost_source="reported"):
        if cost_source not in {"reported", "usage_derived"}:
            raise BudgetError("invalid_cost_source")
        if units is None:
            cost_source = "unknown"
        _units(units, optional=True)
        usage = {} if usage is None else usage
        self._usage(usage)
        with self.store._write():
            return self._settle(attempt_id, units=units, usage=usage, cost_source=cost_source)

    def _settle(self, attempt_id, *, units, usage, cost_source):
        """Validated internal settlement in the caller's existing transaction."""
        _units(units, optional=True)
        self._usage(usage)
        record = self.get(attempt_id)
        if (
            record["state"] == "settled"
            and record["settled_units"] == units
            and record["usage"] == usage
            and record["cost_source"] == cost_source
        ):
            return record
        if record["state"] != "inflight":
            raise BudgetError("cannot_settle_attempt")
        self.db.execute(
            "UPDATE budget_attempts SET state='settled',settled_units=?,usage_json=?,cost_source=? WHERE id=?",
            (units, _json(usage), cost_source, attempt_id),
        )
        return self._get(attempt_id)

    def reconcile(self, attempt_id, *, units, reason):
        with self.store._write():
            return self._reconcile(attempt_id, units=units, reason=reason)

    def _reconcile(self, attempt_id, *, units, reason):
        _units(units, optional=True)
        if reason not in {
            "provider_confirmation",
            "operator_confirmed_unsent",
            "operator_confirmed_cost",
        }:
            raise BudgetError("invalid_reconciliation_reason")
        if reason == "operator_confirmed_unsent" and units != 0:
            raise BudgetError("invalid_reconciliation_cost")
        record = self.get(attempt_id)
        if record["state"] != "outcome_unknown" and not (
            record["state"] == "settled" and record["settled_units"] is None
        ):
            raise BudgetError("cannot_reconcile_attempt")
        self.db.execute(
            "UPDATE budget_attempts SET state='settled',settled_units=?,reason=?,cost_source=? WHERE id=?",
            (
                units,
                reason,
                "unknown" if units is None else "operator_confirmation",
                attempt_id,
            ),
        )
        return self._get(attempt_id)

    def report(self):
        revision, policy = self.policy()
        periods = []

        def scope(limit, used):
            return {
                "limit": limit,
                "used": used,
                "remaining": None if limit is None else max(0, limit - used),
            }

        for row in self.db.execute(
            "SELECT id,meter,start,end,timezone,cycle_day FROM budget_periods ORDER BY id"
        ):
            identity, meter, start, end, zone, cycle = row
            groups = self.db.execute(
                """
                SELECT provider,partition,account_id,image,
                    COALESCE(SUM(settled_units),0),
                    COALESCE(SUM(CASE WHEN settled_units IS NULL THEN reserved_units ELSE 0 END),0),
                    SUM(state='outcome_unknown'),
                    SUM(state='settled' AND settled_units IS NULL),
                    SUM(json_extract(quote_json,'$.known')=0),
                    COALESCE(SUM(MAX(0,COALESCE(settled_units,0)-reserved_units)),0),cost_source
                FROM budget_attempts WHERE period_id=? AND state!='released'
                GROUP BY provider,partition,account_id,image,cost_source
                """,
                (identity,),
            ).fetchall()
            known = sum(g[4] for g in groups)
            held = sum(g[5] for g in groups)
            limits = policy[meter]
            total = scope(
                limits["monthly_limit" if meter == "model" else "daily_limit"], known + held
            )
            if meter == "model":
                scopes = {
                    "total": total,
                    "image": scope(limits["image_limit"], sum(g[4] + g[5] for g in groups if g[3])),
                    "providers": {
                        provider: scope(
                            limits["provider_limits"].get(provider),
                            sum(g[4] + g[5] for g in groups if g[0] == provider),
                        )
                        for provider in sorted(
                            set(limits["provider_limits"]) | {g[0] for g in groups}
                        )
                    },
                }
            else:
                scopes = {
                    "total": total,
                    "partitions": {
                        part: scope(
                            limits["partition_limits"][part],
                            sum(g[4] + g[5] for g in groups if g[1] == part),
                        )
                        for part in ("normal", "adult")
                    },
                    "accounts": {
                        account: scope(
                            limits["account_limits"].get(account),
                            sum(g[4] + g[5] for g in groups if g[2] == account),
                        )
                        for account in sorted(
                            set(limits["account_limits"])
                            | {g[2] for g in groups if g[2] is not None}
                        )
                    },
                }
            periods.append(
                dict(
                    id=identity,
                    meter=meter,
                    unit="micro_usd" if meter == "model" else "reads",
                    start=start,
                    end=end,
                    timezone=zone,
                    cycle_day=cycle,
                    known_settled=known,
                    known_by_source={
                        source: sum(g[4] for g in groups if g[10] == source)
                        for source in sorted({g[10] for g in groups})
                    },
                    held=held,
                    remaining=total["remaining"],
                    scopes=scopes,
                    unknown_outcomes=sum(g[6] for g in groups),
                    unknown_costs=sum(g[7] for g in groups),
                    unpriced=sum(g[8] for g in groups),
                    overrun=sum(g[9] for g in groups),
                )
            )
        return {
            "policy_revision": revision,
            "periods": periods,
            "openai_credit": policy["openai_credit"],
            "official_bill": False,
            "limit_basis": "current_policy",
            "figures": "reported_or_usage_derived_with_conservative_holds",
        }
