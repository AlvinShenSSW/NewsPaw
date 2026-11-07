"""Bounded official X timeline scans with one durable intent per page."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
from contextlib import suppress
from datetime import UTC, datetime, timedelta

import httpx

from ..budget import BudgetError, BudgetLedger
from ..credentials import CredentialError
from .accounts import XError
from .client import XReadError

_ID = re.compile(r"[A-Za-z0-9_.:-]{1,120}")
_TYPES = ("original", "quoted", "replied_to", "retweeted")
_ACTIVE = ("pending", "budget_blocked", "rate_limited", "http_error")
_MAX_PAGES = 12
_AGE = timedelta(hours=24)
_CHECKPOINT_AGE = timedelta(minutes=30)
_QUOTE = {"known": True, "source": "x_read_cap"}


class TimelineError(CredentialError):
    pass


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise TimelineError("invalid_request_id")
    return value


def _utc():
    return datetime.now(UTC)


def _api_time(value):
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_timeline_scans (
           id TEXT PRIMARY KEY,kind TEXT NOT NULL,scope TEXT NOT NULL,args TEXT NOT NULL,
           binding TEXT NOT NULL,state TEXT NOT NULL,progress TEXT NOT NULL,
           created_at TEXT NOT NULL,updated_at TEXT NOT NULL)"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS x_timeline_scope_history
           ON x_timeline_scans(kind,scope,created_at DESC)"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_timeline_steps (
           id TEXT PRIMARY KEY,scan_id TEXT NOT NULL REFERENCES x_timeline_scans(id),
           state TEXT NOT NULL,budget_id TEXT UNIQUE,units INTEGER,reason TEXT,started_at TEXT NOT NULL)"""
    )
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS x_timeline_one_inflight
           ON x_timeline_steps(scan_id) WHERE state='inflight'"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_timeline_cursors (
           scope TEXT NOT NULL,identity TEXT NOT NULL,partition TEXT NOT NULL,
           high TEXT,types TEXT NOT NULL,covered_end TEXT NOT NULL,covered_start TEXT,
           PRIMARY KEY(scope,identity,partition))"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_posts (
           partition TEXT NOT NULL,id TEXT NOT NULL,account_id TEXT NOT NULL,author_id TEXT NOT NULL,
           published_at TEXT NOT NULL,body TEXT,refs TEXT NOT NULL,tombstone INTEGER NOT NULL,
           PRIMARY KEY(partition,id))"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS x_post_observations (
           kind TEXT NOT NULL,scope TEXT NOT NULL,partition TEXT NOT NULL,post_id TEXT NOT NULL,
           observed_at TEXT,PRIMARY KEY(kind,scope,partition,post_id),
           FOREIGN KEY(partition,post_id) REFERENCES x_posts(partition,id))"""
    )

    for table, column in (
        ("x_timeline_cursors", "covered_start"),
        ("x_post_observations", "observed_at"),
    ):
        if (
            db.execute(
                "SELECT 1 FROM pragma_table_info(?) WHERE name=?", (table, column)
            ).fetchone()
            is None
        ):
            db.execute(f"ALTER TABLE {table} ADD COLUMN {column} TEXT")


class Timelines:
    def __init__(self, directory, *, clock=_utc):
        self.directory = directory
        self.store, self.db = directory.store, directory.db
        self.budget = BudgetLedger(self.store)
        self.clock = clock

    def _scope(self, kind, scope):
        revision, config = self.store.load_config()
        ref = config["x_api"]["credential_ref"]
        if ref is None:
            raise TimelineError("credential_missing")
        try:
            if kind == "account":
                row = self.directory.binding(scope)
                return dict(
                    revision=revision,
                    ref=ref,
                    remote=row["remote_id"],
                    partition=row["partition"],
                    authors={row["remote_id"]: [row["id"], row["subscription_id"]]},
                    stamp=None,
                )
            if kind != "list":
                raise TimelineError("invalid_timeline_kind")
            entry = self.directory.list_status(scope)
            if not entry["current"]:
                raise TimelineError("list_not_current")
            members = {(row["account_id"], row["remote_id"]) for row in entry["members"]}
            authors = {
                row["remote_id"]: [row["id"], row["subscription_id"]]
                for row in self.directory.accounts()["accounts"]
                if row["can_collect"]
                and row["partition"] == entry["partition"]
                and (row["id"], row["remote_id"]) in members
            }
            if not authors:
                raise TimelineError("list_no_classified_members")
            return dict(
                revision=revision,
                ref=ref,
                remote=entry["id"],
                partition=entry["partition"],
                authors=authors,
                stamp=entry["checked_at"],
            )
        except (XError, XReadError) as exc:
            raise TimelineError(str(exc)) from None

    def _current(self, row):
        if self._scope(row["kind"], row["scope"]) != row["binding"]:
            raise TimelineError("configuration_changed")

    def _cursor(self, scope, binding):
        row = self.db.execute(
            """SELECT high,types,covered_end,covered_start FROM x_timeline_cursors
               WHERE scope=? AND identity=? AND partition=?""",
            (scope, binding["remote"], binding["partition"]),
        ).fetchone()
        if row is None:
            return None
        return dict(high=row[0], types=json.loads(row[1]), end=row[2], start=row[3])

    def _scan(self, identity):
        cursor = self.db.execute("SELECT * FROM x_timeline_scans WHERE id=?", (_id(identity),))
        row = cursor.fetchone()
        if row is None:
            raise TimelineError("missing_scan")
        result = dict(zip((col[0] for col in cursor.description), row, strict=True))
        for key in ("args", "binding", "progress"):
            result[key] = json.loads(result[key])
        return result

    def status(self, identity):
        row = self._scan(identity)
        progress = row["progress"]
        cursor = self._cursor(row["scope"], row["binding"]) if row["kind"] == "account" else None
        return dict(
            scan_id=row["id"],
            kind=row["kind"],
            scope=row["scope"],
            state=row["state"],
            partition=row["binding"]["partition"],
            complete_cursor=cursor["high"] if cursor else None,
            completed_pages=progress["pages"],
            reason=progress.get("reason"),
            observed_rows=progress["rows"],
            retained_rows=progress["retained"],
            from_time=progress["floor"],
            through_time=progress["end"],
            history_gap=progress.get("history_gap"),
            retry_at=progress.get("retry_at"),
        )

    def _save_scan(self, row, state, **updates):
        row["progress"].update(updates)
        self.db.execute(
            "UPDATE x_timeline_scans SET state=?,progress=?,updated_at=? WHERE id=?",
            (state, _json(row["progress"]), self.clock().isoformat(), row["id"]),
        )

    def _last_scan(self, kind, scope):
        return self.db.execute(
            """SELECT id,state FROM x_timeline_scans WHERE kind=? AND scope=?
               ORDER BY created_at DESC,rowid DESC LIMIT 1""",
            (kind, scope),
        ).fetchone()

    def begin(
        self,
        scan_id,
        kind,
        scope,
        revision,
        *,
        page_size=10,
        include_original=True,
        include_quotes=True,
        include_replies=False,
        include_reposts=False,
        fresh=False,
        max_pages=None,
    ):
        _id(scan_id)
        _id(scope)
        switches = (include_original, include_quotes, include_replies, include_reposts)
        if (
            kind not in {"account", "list"}
            or type(page_size) is not int
            or not (5 if kind == "account" else 1) <= page_size <= 100
            or type(revision) is not int
            or not all(type(value) is bool for value in (*switches, fresh))
            or not any(switches)
            or (
                max_pages is not None
                and (type(max_pages) is not int or not 1 <= max_pages <= _MAX_PAGES)
            )
        ):
            raise TimelineError("invalid_timeline_arguments")
        types = [name for name, enabled in zip(_TYPES, switches, strict=True) if enabled]
        args = dict(revision=revision, page_size=page_size, types=types, fresh=fresh)
        if max_pages is not None:
            args["max_pages"] = max_pages
        with self.store._write():
            prior = self.db.execute(
                "SELECT kind,scope,args FROM x_timeline_scans WHERE id=?", (scan_id,)
            ).fetchone()
            if prior:
                if prior != (kind, scope, _json(args)):
                    raise TimelineError("request_id_conflict")
                return self.status(scan_id)
            binding = self._scope(kind, scope)
            if binding["revision"] != revision:
                raise TimelineError("configuration_changed")
            last = self._last_scan(kind, scope)
            if last:
                if last[1] in _ACTIVE:
                    raise TimelineError("scan_in_progress")
                if last[1] == "outcome_unknown":
                    raise TimelineError("prior_outcome_unknown")
            now = self.clock().replace(microsecond=0)
            cursor = self._cursor(scope, binding) if kind == "account" else None
            if cursor and not fresh and not set(types) <= set(cursor["types"]):
                raise TimelineError("fresh_window_required")
            floor = now - _AGE
            since = None
            covered_start = floor.isoformat()
            if cursor and not fresh:
                since = cursor["high"]
                # An older complete cursor is retained even after a long offline period.
                floor = min(floor, datetime.fromisoformat(cursor["end"]))
                if since is not None:
                    covered_start = cursor["start"] or cursor["end"]
            progress = dict(
                since=since,
                covered_start=covered_start,
                floor=floor.isoformat(),
                end=now.isoformat(),
                pages=0,
                rows=0,
                retained=0,
                token=None,
                tokens=[],
                ids=[],
                last=None,
                high=None,
                history_gap="fresh_window" if cursor and fresh else None,
            )
            self.db.execute(
                "INSERT INTO x_timeline_scans VALUES (?,?,?,?,?,'pending',?,?,?)",
                (
                    scan_id,
                    kind,
                    scope,
                    _json(args),
                    _json(binding),
                    _json(progress),
                    now.isoformat(),
                    now.isoformat(),
                ),
            )
        return self.status(scan_id)

    def _record(self, row, step, state, *, budget_id=None, reason=None):
        self.db.execute(
            "INSERT INTO x_timeline_steps VALUES (?,?,?,?,NULL,?,?)",
            (step, row["id"], state, budget_id, reason, self.clock().isoformat()),
        )

    def _available(self, row, step):
        prior = self.db.execute(
            "SELECT scan_id FROM x_timeline_steps WHERE id=?", (step,)
        ).fetchone()
        if prior:
            if prior[0] != row["id"]:
                raise TimelineError("request_id_conflict")
            return False
        if row["state"] not in _ACTIVE:
            return False
        if self.db.execute(
            "SELECT 1 FROM x_timeline_steps WHERE scan_id=? AND state='inflight'", (row["id"],)
        ).fetchone():
            return False
        now = self.clock()
        retry_at = row["progress"].get("retry_at")
        if retry_at and now < datetime.fromisoformat(retry_at):
            return False
        attempts = self.db.execute(
            "SELECT count(*) FROM x_timeline_steps WHERE scan_id=? AND budget_id IS NOT NULL",
            (row["id"],),
        ).fetchone()[0]
        if now > datetime.fromisoformat(row["created_at"]) + _CHECKPOINT_AGE or attempts >= 24:
            self._save_scan(row, "incomplete", reason="checkpoint_limit")
            return False
        try:
            self._current(row)
        except TimelineError:
            self._save_scan(row, "incomplete", reason="configuration_changed")
            return False
        return True

    def _intent(self, row, step, before_intent):
        if not self._available(row, step):
            return None
        if before_intent is not None and before_intent() is False:
            return None
        binding = row["binding"]
        _, policy = self.budget.policy()
        if row["kind"] == "list" and any(
            limit is not None for limit in policy["x"]["account_limits"].values()
        ):
            self._record(row, step, "blocked", reason="account_limit_requires_individual")
            self._save_scan(row, "budget_blocked", reason="account_limit_requires_individual")
            return None
        task_id = "xtimeline." + hashlib.sha256(row["id"].encode()).hexdigest()
        budget_id = "xstep." + hashlib.sha256(step.encode()).hexdigest()
        try:
            self.budget._reserve(
                budget_id,
                task_id,
                max_units=row["args"]["page_size"],
                quote=_QUOTE,
                meter="x",
                partition=binding["partition"],
                account_id=row["scope"] if row["kind"] == "account" else None,
                now=self.clock(),
            )
        except BudgetError as exc:
            self._record(row, step, "blocked", reason=str(exc))
            self._save_scan(
                row,
                "incomplete" if "max_pages" in row["args"] else "budget_blocked",
                reason=str(exc),
            )
            return None
        self.budget._begin_attempt(budget_id)
        self._record(row, step, "inflight", budget_id=budget_id)
        return budget_id

    async def advance(self, scan_id, step_id, *, before_intent=None):
        step_id = _id(step_id)
        with self.store._write():
            row = self._scan(scan_id)
            if row["args"].get("max_pages") is not None and before_intent is None:
                raise TimelineError("digest_scope_required")
            if not self._available(row, step_id):
                return self.status(scan_id)
            ref = row["binding"]["ref"]
        client = None
        try:
            try:
                token = await asyncio.to_thread(self.directory.credentials.backend.read, ref)
                client = self.directory.client_factory(token)
            except (CredentialError, XReadError, OSError):
                with self.store._write():
                    row = self._scan(scan_id)
                    if self._available(row, step_id):
                        self._record(row, step_id, "blocked", reason="credential_unavailable")
                        self._save_scan(row, "incomplete", reason="credential_unavailable")
                return self.status(scan_id)
            with self.store._write():
                row = self._scan(scan_id)
                if self._intent(row, step_id, before_intent) is None:
                    return self.status(scan_id)
            progress = row["progress"]
            params = {"token": progress["token"]}
            if row["kind"] == "account":
                params["end"] = _api_time(datetime.fromisoformat(progress["end"]))
                if progress["since"] is None:
                    params["start"] = _api_time(datetime.fromisoformat(progress["floor"]))
                else:
                    params["cursor"] = progress["since"]
            try:
                (posts, next_token), units = await client.timeline(
                    row["kind"], row["binding"]["remote"], row["args"]["page_size"], **params
                )
            except asyncio.CancelledError:
                self._finish(scan_id, step_id, error=XReadError("cancelled"))
                raise
            except XReadError as exc:
                self._finish(scan_id, step_id, error=exc)
            else:
                self._finish(scan_id, step_id, rows=posts, next_token=next_token, units=units)
            return self.status(scan_id)
        finally:
            if client is not None:
                with suppress(httpx.HTTPError, OSError):
                    await client.close()

    def _finish(self, scan, step, *, rows=None, next_token=None, units=None, error=None):
        with self.store._write():
            row = self._scan(scan)
            receipt = self.db.execute(
                "SELECT budget_id,state FROM x_timeline_steps WHERE id=? AND scan_id=?",
                (step, scan),
            ).fetchone()
            if receipt is None or receipt[1] != "inflight":
                raise TimelineError("step_changed")
            budget_id = receipt[0]
            reason = error.kind if error else None
            if error is not None:
                units = error.units
            if units is None:
                self.budget._mark_unknown(budget_id)
            else:
                self.budget._settle(
                    budget_id, units=units, usage={"reads": units}, cost_source="usage_derived"
                )
            self.db.execute(
                "UPDATE x_timeline_steps SET state=?,units=?,reason=? WHERE id=?",
                ("outcome_unknown" if units is None else "settled", units, reason, step),
            )
            if units is None:
                self._save_scan(row, "outcome_unknown", reason=reason)
                return
            try:
                self._current(row)
            except TimelineError:
                self._save_scan(row, "incomplete", reason="configuration_changed")
                return
            if error:
                if "max_pages" in row["args"]:
                    self._save_scan(row, "incomplete", reason=reason, retry_at=None)
                elif reason == "rate_limited":
                    retry = self.clock() + timedelta(seconds=max(1, error.retry_after or 60))
                    self._save_scan(row, "rate_limited", reason=reason, retry_at=retry.isoformat())
                else:
                    self._save_scan(
                        row,
                        "http_error" if reason == "http_error" else "incomplete",
                        reason=reason,
                        retry_at=None,
                    )
                return
            self._commit_page(row, rows, next_token)

    def _page_is_ordered(self, row, posts, next_token):
        progress = row["progress"]
        if next_token and (not posts or next_token in progress["tokens"]):
            return False
        seen = set(progress["ids"])
        prior = progress["last"]
        for post in posts:
            stamp = [post["published_at"], int(post["id"])]
            if post["id"] in seen or (prior is not None and stamp >= prior):
                return False
            if row["kind"] == "account" and (
                post["author_id"] != row["binding"]["remote"]
                or (progress["since"] is not None and int(post["id"]) <= int(progress["since"]))
                or not progress["floor"] <= post["published_at"] <= progress["end"]
            ):
                return False
            seen.add(post["id"])
            prior = stamp
        return True

    def _write_post(self, row, post):
        binding, progress = row["binding"], row["progress"]
        owner = binding["authors"].get(post["author_id"])
        if owner is None:
            return 0
        partition = binding["partition"]
        tombstone = post["withheld"] or (partition == "normal" and post["sensitive"] is not False)
        types = {ref["type"] for ref in post["references"]} or {"original"}
        if not tombstone and (
            not progress["floor"] <= post["published_at"] <= progress["end"]
            or not post["text"]
            or not types <= set(row["args"]["types"])
        ):
            return 0
        identity = (partition, post["id"])
        prior = self.db.execute(
            "SELECT account_id,author_id,tombstone FROM x_posts WHERE partition=? AND id=?",
            identity,
        ).fetchone()
        if prior is not None:
            prior_owner, prior_author, already_hidden = prior
            if prior_author != post["author_id"] or already_hidden:
                return 0
            if tombstone:
                self.db.execute(
                    "UPDATE x_posts SET body=NULL,refs='[]',tombstone=1 WHERE partition=? AND id=?",
                    identity,
                )
                return 0
            if prior_owner != owner[0]:
                return 0
        self.db.execute(
            """INSERT INTO x_posts VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(partition,id) DO UPDATE SET
                 body=excluded.body,refs=excluded.refs,tombstone=excluded.tombstone""",
            (
                *identity,
                owner[0],
                post["author_id"],
                post["published_at"],
                None if tombstone else post["text"],
                _json([] if tombstone else post["references"]),
                int(tombstone),
            ),
        )
        if not tombstone:
            self.db.execute(
                """INSERT INTO x_post_observations VALUES (?,?,?,?,?)
                   ON CONFLICT(kind,scope,partition,post_id) DO UPDATE SET
                     observed_at=excluded.observed_at""",
                (
                    row["kind"],
                    row["scope"],
                    *identity,
                    self.clock().isoformat(timespec="microseconds"),
                ),
            )
        return int(not tombstone)

    def _commit_page(self, row, posts, next_token):
        progress = row["progress"]
        if not self._page_is_ordered(row, posts, next_token):
            self._save_scan(row, "incomplete", reason="pagination_gap", retry_at=None)
            return
        retained = sum(self._write_post(row, post) for post in posts)
        ids = [post["id"] for post in posts]
        high = max(filter(None, [progress["high"], *ids]), key=int, default=None)
        updates = dict(
            pages=progress["pages"] + 1,
            rows=progress["rows"] + len(posts),
            retained=progress["retained"] + retained,
            high=high,
            token=next_token,
            tokens=[*progress["tokens"], next_token] if next_token else progress["tokens"],
            ids=[*progress["ids"], *ids],
            last=[posts[-1]["published_at"], int(ids[-1])] if ids else progress["last"],
            reason=None,
            retry_at=None,
        )
        if next_token is not None:
            floor_reached = row["kind"] == "list" and any(
                post["published_at"] < progress["floor"] for post in posts
            )
            if floor_reached or updates["pages"] >= row["args"].get("max_pages", _MAX_PAGES):
                updates["reason"] = "bounded_window" if floor_reached else "page_limit"
                self._save_scan(row, "incomplete", **updates)
            else:
                self._save_scan(row, "pending", **updates)
            return
        if row["kind"] == "account":
            binding = row["binding"]
            previous = self._cursor(row["scope"], binding)
            previous_high = previous["high"] if previous else None
            complete_high = max(filter(None, (high, previous_high)), key=int, default=None)
            self.db.execute(
                """INSERT INTO x_timeline_cursors VALUES (?,?,?,?,?,?,?)
                   ON CONFLICT(scope,identity,partition) DO UPDATE SET
                     high=excluded.high,types=excluded.types,covered_end=excluded.covered_end,
                     covered_start=excluded.covered_start""",
                (
                    row["scope"],
                    binding["remote"],
                    binding["partition"],
                    complete_high,
                    _json(row["args"]["types"]),
                    progress["end"],
                    progress.get("covered_start"),
                ),
            )
        self._save_scan(row, "complete", **updates)

    def stop(self, scan_id):
        with self.store._write():
            row = self._scan(scan_id)
            if self.db.execute(
                "SELECT 1 FROM x_timeline_steps WHERE scan_id=? AND state='inflight'", (scan_id,)
            ).fetchone():
                raise TimelineError("scan_busy")
            if row["state"] in _ACTIVE:
                self._save_scan(row, "incomplete", reason="stopped")
        return self.status(scan_id)

    def posts(self, kind, scope, *, limit=50):
        _id(scope)
        if type(limit) is not int or not 1 <= limit <= 200:
            raise TimelineError("invalid_limit")
        binding = self._scope(kind, scope)
        last = self._last_scan(kind, scope)
        if last is None:
            return []
        latest = self._scan(last[0])
        access = self.db.execute(
            """SELECT json_extract(progress,'$.reason') FROM x_timeline_scans
               WHERE kind=? AND scope=? AND (
                 json_extract(progress,'$.pages')>0 OR json_extract(progress,'$.reason')
                 IN ('unavailable','permission_denied','authentication_failed')
               ) ORDER BY updated_at DESC,rowid DESC LIMIT 1""",
            (kind, scope),
        ).fetchone()
        if access and access[0] in {"unavailable", "permission_denied", "authentication_failed"}:
            return []
        owners = _json([[owner[0], remote] for remote, owner in binding["authors"].items()])
        types = _json(latest["args"]["types"])
        rows = self.db.execute(
            """SELECT p.id,p.author_id,p.published_at,p.body,p.refs,p.account_id,o.observed_at FROM x_posts p
               JOIN x_post_observations o ON o.partition=p.partition AND o.post_id=p.id
               WHERE o.kind=? AND o.scope=? AND p.partition=? AND p.tombstone=0
               AND p.body IS NOT NULL AND p.published_at>=? AND p.published_at<=?
               AND EXISTS(SELECT 1 FROM json_each(?) a
                          WHERE json_extract(a.value,'$[0]')=p.account_id
                          AND json_extract(a.value,'$[1]')=p.author_id)
               AND ((json_array_length(p.refs)>0 AND NOT EXISTS(
                       SELECT 1 FROM json_each(p.refs) r WHERE NOT EXISTS(
                           SELECT 1 FROM json_each(?) t WHERE t.value=json_extract(r.value,'$.type')
                       ))) OR (json_array_length(p.refs)=0 AND EXISTS(
                       SELECT 1 FROM json_each(?) t WHERE t.value='original'
                   )))
               ORDER BY p.published_at DESC,length(p.id) DESC,p.id DESC LIMIT ?""",
            (
                kind,
                scope,
                binding["partition"],
                (self.clock() - _AGE).isoformat(),
                self.clock().isoformat(),
                owners,
                types,
                types,
                limit,
            ),
        ).fetchall()
        return [
            dict(
                id=identity,
                author_id=remote,
                account_id=account,
                published_at=published,
                text=text,
                references=json.loads(refs),
                observed_at=observed,
                partition=binding["partition"],
                url=f"https://x.com/i/web/status/{identity}",
            )
            for identity, remote, published, text, refs, account, observed in rows
        ]

    def purge_expired(self, *, limit=100):
        if type(limit) is not int or not 1 <= limit <= 1000:
            raise TimelineError("invalid_limit")
        with self.store._write():
            count = self.db.execute(
                """UPDATE x_posts SET body=NULL,refs='[]' WHERE rowid IN (
                   SELECT rowid FROM x_posts WHERE body IS NOT NULL AND published_at<?
                   ORDER BY published_at LIMIT ?)""",
                ((self.clock() - _AGE).isoformat(), limit),
            ).rowcount
        return {"purged": count}

    def recover_interrupted(self):
        with self.store._write():
            rows = self.db.execute(
                "SELECT id,scan_id,budget_id FROM x_timeline_steps WHERE state='inflight'"
            ).fetchall()
            for step, scan, attempt in rows:
                self.budget._mark_unknown(attempt)
                self.db.execute(
                    """UPDATE x_timeline_steps SET state='outcome_unknown',reason='interrupted'
                       WHERE id=?""",
                    (step,),
                )
                self._save_scan(self._scan(scan), "outcome_unknown", reason="interrupted")
