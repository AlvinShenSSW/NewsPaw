"""Opt-in alerts derived from already verified X editions."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from datetime import UTC, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from ..credentials import CredentialError
from ..pipeline import PipelineError
from ..telegram.outbox import OutboxError

_ID = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,79}")
_POST = re.compile(r"[1-9][0-9]{0,29}")
_TIME = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]")
_HEADINGS = {"zh-Hans": "X 重大事件提醒", "en": "Major event on X", "ja": "X 重要イベント通知"}
_DEFAULT = dict(
    enabled=False,
    timezone="Asia/Tokyo",
    daily_limit=0,
    cooldown_minutes=120,
    quiet_start=None,
    quiet_end=None,
    max_age_minutes=180,
    rules=[],
)
_OPEN = ("pending", "deferred", "claimed")


class AlertError(CredentialError):
    pass


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value):
    return hashlib.sha256(_json(value).encode()).hexdigest()


def _phrase(value):
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def _valid(settings):
    if not isinstance(settings, dict) or settings.keys() != _DEFAULT.keys():
        raise AlertError("invalid_alert_settings")
    if type(settings["enabled"]) is not bool:
        raise AlertError("invalid_alert_settings")
    try:
        ZoneInfo(settings["timezone"])
    except (TypeError, ValueError, ZoneInfoNotFoundError):
        raise AlertError("invalid_alert_timezone") from None
    for key, low, high in (
        ("daily_limit", 0, 30),
        ("cooldown_minutes", 15, 1440),
        ("max_age_minutes", 15, 360),
    ):
        if type(settings[key]) is not int or not low <= settings[key] <= high:
            raise AlertError("invalid_alert_settings")
    quiet = settings["quiet_start"], settings["quiet_end"]
    if quiet != (None, None) and (
        not all(isinstance(item, str) and _TIME.fullmatch(item) for item in quiet)
        or quiet[0] == quiet[1]
    ):
        raise AlertError("invalid_alert_quiet_hours")
    rules = settings["rules"]
    if (
        not isinstance(rules, list)
        or len(rules) > 20
        or (settings["enabled"] and (not rules or settings["daily_limit"] == 0))
    ):
        raise AlertError("invalid_alert_rules")
    seen = set()
    for rule in rules:
        if not isinstance(rule, dict) or rule.keys() != {"subscription_id", "account_id", "phrase"}:
            raise AlertError("invalid_alert_rules")
        sub, account, phrase = rule["subscription_id"], rule["account_id"], rule["phrase"]
        if (
            not isinstance(sub, str)
            or not _ID.fullmatch(sub)
            or account is not None
            and (not isinstance(account, str) or not _ID.fullmatch(account))
            or not isinstance(phrase, str)
            or len(phrase) > 100
            or len(_phrase(phrase)) < 2
        ):
            raise AlertError("invalid_alert_rules")
        key = (sub, account, _phrase(phrase))
        if key in seen:
            raise AlertError("duplicate_alert_rule")
        seen.add(key)


def in_alert_scope(route, account_id):
    """A rule watches an X subscription, and names only a special account of it."""
    shape = route.effective
    return shape.get("category_id") in {"x", "x_adult"} and (
        account_id is None or shape.get("account", {}).get("priority") == "special"
    )


def initialize(db, timezone="Asia/Tokyo"):
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_alert_policy (
           id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
           settings TEXT NOT NULL, activated_at TEXT)"""
    )
    db.execute(
        "INSERT OR IGNORE INTO x_alert_policy VALUES (1,1,?,NULL)",
        (_json(dict(_DEFAULT, timezone=timezone)),),
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_alerts (
           job_id TEXT PRIMARY KEY REFERENCES pipeline_jobs(id), rule_key TEXT NOT NULL,
           policy_revision INTEGER NOT NULL, expires_at TEXT NOT NULL, claimed_at TEXT,
           state TEXT NOT NULL, reason TEXT)"""
    )
    db.execute("CREATE INDEX IF NOT EXISTS x_alerts_claimed ON x_alerts(claimed_at)")
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_alert_posts (
           scope_key TEXT NOT NULL, post_id TEXT NOT NULL,
           PRIMARY KEY(scope_key,post_id))"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_alert_checked (
           job_id TEXT NOT NULL REFERENCES pipeline_jobs(id), revision INTEGER NOT NULL,
           PRIMARY KEY(job_id,revision))"""
    )


class Alerts:
    def __init__(self, pipeline, outbox, *, clock=None):
        self.pipeline, self.outbox = pipeline, outbox
        self.store, self.db = pipeline.store, pipeline.db
        self.clock = clock or (lambda: datetime.now(UTC))

    def _policy(self):
        revision, settings, active = self.db.execute(
            "SELECT revision,settings,activated_at FROM x_alert_policy WHERE id=1"
        ).fetchone()
        return revision, json.loads(settings), active

    def status(self):
        revision, settings, _ = self._policy()
        records = self.db.execute(
            """SELECT job_id,expires_at,claimed_at,state,reason FROM x_alerts
               ORDER BY rowid DESC LIMIT 30"""
        )
        return dict(
            revision=revision,
            settings=settings,
            occurrences=[
                dict(job_id=job, expires_at=expires, claimed_at=claimed, state=state, reason=reason)
                for job, expires, claimed, state, reason in records
            ],
        )

    def configure(self, settings, revision):
        _valid(settings)
        with self.store._write():
            current, prior, _ = self._policy()
            if type(revision) is not int or current != revision:
                raise AlertError("alert_policy_changed")
            for rule in settings["rules"]:
                route = self.store.preview_route(
                    rule["subscription_id"], account_id=rule["account_id"]
                )
                if not in_alert_scope(route, rule["account_id"]):
                    raise AlertError("invalid_alert_scope")
            if settings != prior:
                self.db.execute(
                    "UPDATE x_alert_policy SET revision=revision+1,settings=?,activated_at=? WHERE id=1",
                    (_json(settings), self.clock().isoformat() if settings["enabled"] else None),
                )
        return self.status()

    def _discover(self, revision, settings, active, now):
        lower = max(
            datetime.fromisoformat(active), now - timedelta(minutes=settings["max_age_minutes"])
        )
        candidates = self.db.execute(
            """SELECT j.id FROM pipeline_jobs j
               WHERE j.stage='awaiting_delivery' AND j.cancelled=0 AND j.paused=0 AND j.created_at>=?
                 AND json_extract(j.payload,'$.alert') IS NULL
                 AND json_extract(j.payload,'$.scopes[0].x_digest') IS NOT NULL
                 AND NOT EXISTS(SELECT 1 FROM x_alert_checked c WHERE c.job_id=j.id AND c.revision=?)
               ORDER BY j.created_at,j.rowid LIMIT 8""",
            (lower.isoformat(), revision),
        ).fetchall()
        for (parent,) in candidates:
            with self.store._write():
                self.db.execute(
                    "INSERT OR IGNORE INTO x_alert_checked VALUES (?,?)", (parent, revision)
                )
                try:
                    route = self.pipeline.delivery_scope(parent)
                except PipelineError:
                    continue
                rules = [
                    rule
                    for rule in settings["rules"]
                    if (rule["subscription_id"], rule["account_id"])
                    == (route.subscription_id, route.account_id)
                ]
                if not rules:
                    continue
                bindings = self.outbox.targets.preview(
                    route.subscription_id, account_id=route.account_id
                )["bindings"]
                if not bindings:
                    continue
                parent_row = self.pipeline._row(parent)
                created = datetime.fromisoformat(parent_row["created_at"])
                result = self.pipeline.editorial.get(self.pipeline._edition_id(parent))["result"]
                if not result:
                    continue
                for item in result["items"]:
                    haystack = _phrase(item["title"] + " " + item["body"])
                    rule = next(
                        (rule for rule in rules if _phrase(rule["phrase"]) in haystack), None
                    )
                    if rule:
                        self._derive(
                            parent_row,
                            route,
                            item,
                            rule,
                            bindings,
                            revision,
                            settings,
                            created,
                            now,
                        )

    def _derive(self, parent, route, item, rule, bindings, revision, settings, created, now):
        sources = [
            source
            for source in item["sources"]
            if _POST.fullmatch(str(source.get("metadata", {}).get("x_post", {}).get("id", "")))
            and source["url"] == "https://x.com/i/web/status/" + source["metadata"]["x_post"]["id"]
        ]
        if not sources:
            return
        post_ids = sorted({source["metadata"]["x_post"]["id"] for source in sources}, key=int)
        scope_key = _digest([route.subscription_id, route.account_id])
        if self.db.execute(
            """SELECT 1 FROM x_alert_posts WHERE scope_key=?
               AND post_id IN (SELECT value FROM json_each(?)) LIMIT 1""",
            (scope_key, _json(post_ids)),
        ).fetchone():
            return
        job = "alert." + _digest([scope_key, post_ids[0]])
        heading = _HEADINGS[route.effective["locale"]]
        citations = "\n".join(sorted({source["url"] for source in sources}))
        text = f"{heading}\n{item['title']}\n{item['body']}\n{citations}"
        original = parent["payload"]
        payload = dict(
            route=original["route"],
            scopes=[],
            attempt_ids=[],
            unsupported_source_ids=[],
            media=None,
            alert=dict(
                parent=parent["id"],
                item=item["event_key"],
                item_hash=_digest(item),
                text=text,
                bindings=bindings,
            ),
        )
        if self.db.execute(
            """INSERT OR IGNORE INTO pipeline_jobs (
               id,subscription_id,account_key,edition_key,partition,payload,stage,created_at,updated_at
               ) VALUES (?,?,?,?,?,?,'awaiting_delivery',?,?)""",
            (
                job,
                route.subscription_id,
                route.account_id or "",
                job,
                route.effective["partition"],
                _json(payload),
                now.isoformat(),
                now.isoformat(),
            ),
        ).rowcount:
            self.db.executemany(
                "INSERT INTO x_alert_posts VALUES (?,?)",
                ((scope_key, post) for post in post_ids),
            )
            expires = created + timedelta(minutes=settings["max_age_minutes"])
            rule_key = _digest([route.subscription_id, route.account_id, _phrase(rule["phrase"])])
            self.db.execute(
                "INSERT INTO x_alerts VALUES (?,?,?,?,NULL,'pending',NULL)",
                (job, rule_key, revision, expires.isoformat()),
            )

    def _set(self, job, state, reason=None):
        self.db.execute("UPDATE x_alerts SET state=?,reason=? WHERE job_id=?", (state, reason, job))

    @staticmethod
    def _quiet(settings, local):
        if settings["quiet_start"] is None:
            return False
        start, end = (time.fromisoformat(settings[key]) for key in ("quiet_start", "quiet_end"))
        wall = local.time()
        return start <= wall < end if start < end else wall >= start or wall < end

    def _preflight(self, job, now):
        row = self.db.execute(
            "SELECT rule_key,policy_revision,expires_at,claimed_at,state FROM x_alerts WHERE job_id=?",
            (job,),
        ).fetchone()
        if row is None or row[4] not in _OPEN:
            return None
        rule, generation, expires, claimed, _ = row
        revision, settings, _ = self._policy()
        if revision != generation or not settings["enabled"]:
            self._set(job, "stopped", "alert_policy_changed")
            return None
        if now >= datetime.fromisoformat(expires):
            self._set(job, "expired", "alert_expired")
            return None
        local = now.astimezone(ZoneInfo(settings["timezone"]))
        if self._quiet(settings, local):
            self._set(job, "deferred", "quiet_hours")
            return None
        return rule, claimed, settings, local

    def guard(self, job):
        """Called inside the same SQLite write as each Q02 send intent."""
        now = self.clock()
        allowed = self._preflight(job, now)
        if allowed is None:
            return False
        rule, claimed, settings, local = allowed
        if claimed is None:
            midnight = datetime.combine(local.date(), time(), tzinfo=local.tzinfo)
            next_midnight = midnight + timedelta(days=1)
            used = self.db.execute(
                "SELECT count(*) FROM x_alerts WHERE claimed_at>=? AND claimed_at<?",
                (midnight.astimezone(UTC).isoformat(), next_midnight.astimezone(UTC).isoformat()),
            ).fetchone()[0]
            if used >= settings["daily_limit"]:
                self._set(job, "capped", "alert_daily_limit")
                return False
            recent = now - timedelta(minutes=settings["cooldown_minutes"])
            if self.db.execute(
                "SELECT 1 FROM x_alerts WHERE rule_key=? AND claimed_at>? LIMIT 1",
                (rule, recent.isoformat()),
            ).fetchone():
                self._set(job, "suppressed", "alert_cooldown")
                return False
            self.db.execute(
                "UPDATE x_alerts SET claimed_at=? WHERE job_id=?", (now.isoformat(), job)
            )
        self._set(job, "claimed")
        return True

    async def tick(self):
        now = self.clock()
        revision, settings, active = self._policy()
        if settings["enabled"] and active:
            self._discover(revision, settings, active, now)
        jobs = self.db.execute(
            """SELECT job_id FROM x_alerts WHERE state IN ('pending','deferred','claimed')
               ORDER BY rowid LIMIT 30"""
        ).fetchall()
        for (job,) in jobs:
            with self.store._write():
                allowed = self._preflight(job, self.clock())
            if allowed is None:
                continue
            try:
                status = self.outbox.enqueue(job, now=now)
                for bot, view in status["targets"].items():
                    if view["status"] in {"pending", "partial"} and not view["reason"]:
                        status = await self.outbox.advance(job, bot)
                status = self.outbox.status(job)
            except OutboxError as exc:
                if str(exc) == "job_paused":
                    continue
                with self.store._write():
                    self._set(job, "stopped", str(exc))
                continue
            with self.store._write():
                views = list(status["targets"].values())
                if any(view["status"] in {"inflight", "outcome_unknown"} for view in views):
                    self._set(job, "outcome_unknown", "delivery_outcome_unknown")
                elif status["reason"]:
                    self._set(job, "stopped", status["reason"])
                elif views and all(view["status"] == "delivered" for view in views):
                    self._set(job, "delivered")
                elif not any(
                    view["status"] in {"pending", "partial"} and not view["reason"]
                    for view in views
                ):
                    self._set(
                        job, "partial" if any(view["delivered"] for view in views) else "stopped"
                    )
