"""Partitioned RSS evidence and conditional retrieval in the one local database."""

from __future__ import annotations

import asyncio
import json
from contextlib import suppress
from dataclasses import asdict
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from urllib.parse import urljoin, urlsplit
from uuid import uuid4

import httpx

from .migrations import check_version
from .news import MAX_FEED_BYTES, Article, NewsError, eligible_articles, parse_evidence
from .transport import SafeHTTPError, source_client


class EvidenceError(ValueError):
    pass


def _time(value):
    value = datetime.now(UTC) if value is None else value
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise EvidenceError("aware_time_required")
    return value.astimezone(UTC)


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def initialize(db):
    statements = [
        "CREATE TABLE IF NOT EXISTS feed_snapshots (id TEXT PRIMARY KEY, partition TEXT NOT NULL, url TEXT NOT NULL, fetched_at TEXT NOT NULL, articles_json TEXT NOT NULL, rejected_json TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS feed_attempts (id TEXT PRIMARY KEY, partition TEXT NOT NULL, url TEXT NOT NULL, started_at TEXT NOT NULL, completed_at TEXT, status TEXT NOT NULL, scope_json TEXT NOT NULL, outcome_json TEXT NOT NULL, snapshot_id TEXT REFERENCES feed_snapshots(id))",
        "CREATE TABLE IF NOT EXISTS feed_associations (attempt_id TEXT NOT NULL REFERENCES feed_attempts(id), source_id TEXT NOT NULL, subscription_id TEXT NOT NULL, category_id TEXT NOT NULL, PRIMARY KEY(attempt_id,source_id,subscription_id))",
        "CREATE INDEX IF NOT EXISTS feed_associations_source ON feed_associations(source_id,attempt_id)",
        "CREATE TABLE IF NOT EXISTS feed_cache (partition TEXT NOT NULL, url TEXT NOT NULL, snapshot_id TEXT NOT NULL REFERENCES feed_snapshots(id), final_url TEXT NOT NULL, etag TEXT, modified TEXT, PRIMARY KEY(partition,url))",
        "CREATE TABLE IF NOT EXISTS feed_health_policy (partition TEXT NOT NULL, url TEXT NOT NULL, stale_hours INTEGER NOT NULL, PRIMARY KEY(partition,url))",
    ]
    for statement in statements:
        db.execute(statement)


def _source(config, identity, kinds=frozenset({"rss", "atom"})):
    source = next((s for s in config["sources"] if s["id"] == identity), None)
    if source is None:
        raise EvidenceError("missing_source")
    if source["partition"] not in {"normal", "adult"}:
        raise EvidenceError("unclassified_source")
    if source["kind"] not in kinds:
        raise EvidenceError("unsupported_source")
    return source


def _selection(config, subscriptions, source_id, kinds=frozenset({"rss", "atom"})):
    selected = []

    def append(source, subscription="", category=""):
        selected.append(
            {
                "source": {k: source[k] for k in ("id", "url", "partition", "kind", "enabled")},
                "association": {
                    "source_id": source["id"],
                    "subscription_id": subscription,
                    "category_id": category,
                },
            }
        )

    if source_id is not None:
        source = _source(config, source_id, kinds)
        append(source)
    else:
        if not isinstance(subscriptions, list) or not 1 <= len(subscriptions) <= 200:
            raise EvidenceError("invalid_subscriptions")
        for identity in sorted(set(subscriptions)):
            sub = next((s for s in config["subscriptions"] if s["id"] == identity), None)
            if sub is None:
                raise EvidenceError("missing_subscription")
            category = next(c for c in config["categories"] if c["id"] == sub["category_id"])
            for source in config["sources"]:
                if (
                    source["id"] in sub["source_ids"]
                    if sub["source_ids"]
                    else category["id"] in source["category_ids"]
                ):
                    if not source["enabled"] or source["kind"] not in kinds:
                        continue
                    source = _source(config, source["id"], kinds)
                    if (
                        source["partition"] != category["partition"]
                        or category["id"] not in source["category_ids"]
                    ):
                        raise EvidenceError("incompatible_source")
                    append(source, identity, category["id"])
    return sorted(
        selected, key=lambda row: (row["association"]["subscription_id"], row["source"]["id"])
    )


def feed_scopes(config, subscriptions, source_id=None):
    groups = {}
    for row in _selection(config, subscriptions, source_id):
        source = row["source"]
        groups.setdefault((source["partition"], source["url"]), []).append(row)
    return [
        dict(
            partition=partition,
            url=url,
            selected=rows,
            subscriptions=subscriptions,
            source_id=source_id,
        )
        for (partition, url), rows in groups.items()
    ]


def _encode_articles(articles):
    result = []
    for article in articles:
        row = asdict(article)
        for key in ("published_at", "updated_at", "fetched_at"):
            row[key] = row[key].isoformat() if row[key] else None
        result.append(row)
    return _json(result)


def _decode_articles(payload):
    result = []
    for row in json.loads(payload):
        for key in ("published_at", "updated_at", "fetched_at"):
            row[key] = datetime.fromisoformat(row[key]) if row[key] else None
        result.append(Article(**row))
    return result


def _content_status(articles, rejected, now, hours):
    accepted, date_rejections = eligible_articles(articles, now, hours)
    counts = dict(rejected)
    for key, value in date_rejections.items():
        counts[key] = counts.get(key, 0) + value
    if accepted:
        status = "fresh"
    elif not articles and not rejected:
        status = "empty"
    elif articles and all(
        a.published_at and a.published_at <= now and not a.published_error for a in articles
    ):
        status = "stale"
    else:
        status = "no_eligible"
    return status, len(accepted), counts


class EvidenceStore:
    def __init__(self, store, *, collection_guard=None):
        self.store = store
        self.db = store._db
        self.collection_guard = collection_guard

    def current(self, scope):
        _, config = self.store.load_config()
        try:
            selected = _selection(
                config,
                scope["subscriptions"],
                scope["source_id"],
                scope.get("kinds", {"rss", "atom"}),
            )
        except EvidenceError:
            return False
        matching = [
            row
            for row in selected
            if (row["source"]["partition"], row["source"]["url"])
            == (scope["partition"], scope["url"])
        ]
        return matching == scope["selected"]

    def begin(self, scope, now):
        identity = "fetch_" + uuid4().hex
        with self.store._write():
            if (
                self.collection_guard is not None
                and self.collection_guard(scope, starting=True) is False
            ):
                return None
            if not self.current(scope):
                raise EvidenceError("configuration_changed")
            self.db.execute(
                "INSERT INTO feed_attempts VALUES (?,?,?,?,NULL,'running',?,'{}',NULL)",
                (identity, scope["partition"], scope["url"], now.isoformat(), _json(scope)),
            )
            for row in scope["selected"]:
                assoc = row["association"]
                self.db.execute(
                    "INSERT INTO feed_associations VALUES (?,?,?,?)",
                    (identity, assoc["source_id"], assoc["subscription_id"], assoc["category_id"]),
                )
        return identity

    def cache(self, partition, url):
        check_version(self.db)
        row = self.db.execute(
            "SELECT snapshot_id,final_url,etag,modified FROM feed_cache WHERE partition=? AND url=?",
            (partition, url),
        ).fetchone()
        return (
            dict(zip(("snapshot_id", "final_url", "etag", "modified"), row, strict=True))
            if row
            else None
        )

    def snapshot(self, identity, partition):
        check_version(self.db)
        row = self.db.execute(
            "SELECT articles_json,rejected_json FROM feed_snapshots WHERE id=? AND partition=?",
            (identity, partition),
        ).fetchone()
        if row is None:
            raise EvidenceError("cache_missing")
        return _decode_articles(row[0]), json.loads(row[1])

    def finish(
        self,
        identity,
        scope,
        outcome,
        now,
        *,
        articles=None,
        rejected=None,
        validators=None,
        snapshot_id=None,
        cache=True,
        connector_identity=None,
    ):
        with self.store._write():
            if self.collection_guard is not None:
                self.collection_guard(scope, starting=False)
            if articles is not None:
                snapshot_id = "evidence_" + uuid4().hex
                self.db.execute(
                    "INSERT INTO feed_snapshots VALUES (?,?,?,?,?,?)",
                    (
                        snapshot_id,
                        scope["partition"],
                        scope["url"],
                        now.isoformat(),
                        _encode_articles(articles),
                        _json(rejected),
                    ),
                )
                if cache:
                    self.db.execute(
                        "INSERT INTO feed_cache VALUES (?,?,?,?,?,?) ON CONFLICT(partition,url) DO UPDATE SET snapshot_id=excluded.snapshot_id,final_url=excluded.final_url,etag=excluded.etag,modified=excluded.modified",
                        (scope["partition"], scope["url"], snapshot_id, *validators),
                    )
            if not self.current(scope):
                outcome = {
                    **outcome,
                    "status": "configuration_changed",
                    "error_kind": "configuration_changed",
                }
            elif connector_identity is not None:
                kind, remote_id, canonical = connector_identity
                prior = self.db.execute(
                    "SELECT remote_id FROM connector_identity WHERE partition=? AND kind=? AND url=?",
                    (scope["partition"], kind, scope["url"]),
                ).fetchone()
                if prior and prior[0] != remote_id:
                    outcome = {
                        **outcome,
                        "status": "identity_changed",
                        "error_kind": "identity_changed",
                    }
                else:
                    self.db.execute(
                        "INSERT INTO connector_identity VALUES (?,?,?,?,?) ON CONFLICT(partition,kind,url) DO UPDATE SET canonical=excluded.canonical",
                        (scope["partition"], kind, scope["url"], remote_id, canonical),
                    )
            changed = self.db.execute(
                "UPDATE feed_attempts SET completed_at=?,status=?,outcome_json=?,snapshot_id=? WHERE id=? AND status='running'",
                (now.isoformat(), outcome["status"], _json(outcome), snapshot_id, identity),
            ).rowcount
            if changed != 1:
                raise EvidenceError("attempt_already_finished")
        return self.attempt(identity, partition=scope["partition"])

    def recover_interrupted(self):
        with self.store._write():
            return self.db.execute(
                "UPDATE feed_attempts SET status='interrupted',outcome_json=?,completed_at=? WHERE status='running'",
                (
                    _json({"status": "interrupted", "error_kind": "interrupted"}),
                    _time(None).isoformat(),
                ),
            ).rowcount

    def attempt(self, identity, *, partition):
        check_version(self.db)
        row = self.db.execute(
            "SELECT started_at,completed_at,status,outcome_json,snapshot_id,scope_json FROM feed_attempts WHERE id=? AND partition=?",
            (identity, partition),
        ).fetchone()
        if row is None:
            raise EvidenceError("missing_attempt")
        return {
            **json.loads(row[3]),
            "id": identity,
            "partition": partition,
            "started_at": row[0],
            "checked_at": row[1],
            "status": row[2],
            "snapshot_id": row[4],
            "associations": [r["association"] for r in json.loads(row[5])["selected"]],
            "evidence_scope": json.loads(row[5]).get("evidence_scope", "rss_excerpt"),
        }

    def articles(
        self,
        identity,
        *,
        partition,
        subscription_id=None,
        source_id=None,
        now=None,
        max_age_hours=24,
        fresh_only=True,
    ):
        result = self.attempt(identity, partition=partition)
        if (subscription_id is None) == (source_id is None):
            raise EvidenceError("one_evidence_scope_required")
        scope = json.loads(
            self.db.execute(
                "SELECT scope_json FROM feed_attempts WHERE id=?", (identity,)
            ).fetchone()[0]
        )
        key, value = (
            ("subscription_id", subscription_id)
            if subscription_id is not None
            else ("source_id", source_id)
        )
        if not any(a[key] == value for a in result["associations"]) or not self.current(scope):
            raise EvidenceError("evidence_scope_changed")
        if (
            result["status"] not in {"fresh", "stale", "empty", "no_eligible", "not_modified"}
            or result["snapshot_id"] is None
        ):
            return []
        articles, _ = self.snapshot(result["snapshot_id"], partition)
        return eligible_articles(articles, _time(now), max_age_hours)[0] if fresh_only else articles

    def _configured_source(self, identity):
        return _source(
            self.store.load_config()[1], identity, {"rss", "atom", "github", "huggingface", "web"}
        )

    def set_health_threshold(self, source_id, hours):
        if type(hours) is not int or not 1 <= hours <= 8760:
            raise EvidenceError("invalid_health_threshold")
        with self.store._write():
            source = self._configured_source(source_id)
            self.db.execute(
                "INSERT INTO feed_health_policy VALUES (?,?,?) ON CONFLICT(partition,url) DO UPDATE SET stale_hours=excluded.stale_hours",
                (source["partition"], source["url"], hours),
            )

    def history(self, source_id, limit=50):
        if type(limit) is not int or not 1 <= limit <= 200:
            raise EvidenceError("invalid_history_limit")
        source = self._configured_source(source_id)
        rows = self.db.execute(
            "SELECT DISTINCT a.id,a.rowid FROM feed_attempts a JOIN feed_associations s ON s.attempt_id=a.id WHERE s.source_id=? AND a.partition=? AND a.url=? ORDER BY a.rowid DESC LIMIT ?",
            (source_id, source["partition"], source["url"], limit),
        ).fetchall()
        return [self.attempt(row[0], partition=source["partition"]) for row in reversed(rows)]

    def health(self, source_id, *, now=None):
        now = _time(now)
        source = self._configured_source(source_id)
        row = self.db.execute(
            "SELECT stale_hours FROM feed_health_policy WHERE partition=? AND url=?",
            (source["partition"], source["url"]),
        ).fetchone()
        hours = row[0] if row else 72
        cache = self.cache(source["partition"], source["url"])
        articles = self.snapshot(cache["snapshot_id"], source["partition"])[0] if cache else []
        if source["kind"] in {"github", "huggingface", "web"}:
            articles = []
            for attempt in reversed(self.history(source_id)):
                if attempt["snapshot_id"] and attempt["status"] in {
                    "fresh",
                    "stale",
                    "empty",
                    "no_eligible",
                }:
                    with suppress(EvidenceError):
                        articles = self.articles(
                            attempt["id"],
                            partition=source["partition"],
                            source_id=source_id,
                            now=now,
                            fresh_only=False,
                        )
                    break
        dates = [
            a.published_at
            for a in articles
            if a.published_at and a.published_at <= now and not a.published_error
        ]
        latest = max(dates) if dates else None
        freshness = (
            "unknown"
            if latest is None
            else ("current" if (now - latest).total_seconds() <= hours * 3600 else "stale")
        )
        history = self.history(source_id, 1)
        return {
            "source_id": source_id,
            "partition": source["partition"],
            "stale_hours": hours,
            "freshness": freshness,
            "latest_publication": latest.isoformat() if latest else None,
            "last_attempt": history[0] if history else None,
        }


def _header(value):
    return (
        value if value and len(value) <= 1024 and all(32 <= ord(c) < 127 for c in value) else None
    )


def _retry_after(value, now):
    if not value or len(value) > 128:
        return None
    if value.isascii() and value.isdigit():
        return min(int(value), 7 * 86400)
    try:
        date = parsedate_to_datetime(value)
        if date.tzinfo is not None:
            return max(0, min(int((date - now).total_seconds()), 7 * 86400))
    except (ValueError, TypeError, OverflowError):
        pass
    return None


class FeedCollector:
    def __init__(self, evidence, *, client=None):
        self.evidence = evidence
        self.client = (
            client if client is not None else source_client(max_bytes=MAX_FEED_BYTES, deadline=30)
        )
        self._lock = asyncio.Lock()

    async def close(self):
        await self.client.aclose()

    async def collect(self, subscriptions, *, now=None, max_age_hours=24):
        return await self._collect(subscriptions, None, now, max_age_hours)

    async def preview(self, source_id, *, now=None, max_age_hours=24):
        return await self._collect(None, source_id, now, max_age_hours)

    async def _collect(self, subscriptions, source_id, now, hours):
        # Validate before any I/O. An explicit timestamp is a test/replay clock.
        fixed_now = _time(now) if now is not None else None
        eligible_articles([], _time(now), hours)
        async with self._lock:
            scopes = feed_scopes(self.evidence.store.load_config()[1], subscriptions, source_id)
            if not scopes:
                raise EvidenceError("no_sources")
            return [await self.fetch_scope(scope, hours, fixed_now) for scope in scopes]

    async def fetch_scope(self, scope, hours, fixed_now):
        def clock():
            return fixed_now if fixed_now is not None else datetime.now(UTC)

        repo = self.evidence
        identity = repo.begin(scope, clock())
        if identity is None:
            return None
        cache = repo.cache(scope["partition"], scope["url"])
        url = scope["url"]
        status_code = None
        try:
            async with asyncio.timeout(30):
                headers = {}
                if cache and cache["final_url"] == url:
                    headers = {
                        k: v
                        for k, v in (
                            ("If-None-Match", cache["etag"]),
                            ("If-Modified-Since", cache["modified"]),
                        )
                        if v
                    }
                for _ in range(4):
                    async with self.client.stream("GET", url, headers=headers) as response:
                        status_code = response.status_code
                        if status_code == 304:
                            if cache is None or cache["final_url"] != url:
                                raise EvidenceError("cache_missing")
                            articles, rejected = repo.snapshot(
                                cache["snapshot_id"], scope["partition"]
                            )
                            status, count, counts = _content_status(
                                articles, rejected, clock(), hours
                            )
                            return repo.finish(
                                identity,
                                scope,
                                dict(
                                    status="not_modified",
                                    content_status=status,
                                    accepted_count=count,
                                    rejected_counts=counts,
                                    http_status=304,
                                ),
                                clock(),
                                snapshot_id=cache["snapshot_id"],
                            )
                        if response.is_redirect:
                            try:
                                target = urljoin(url, response.headers.get("location", ""))
                                old, new = urlsplit(url), urlsplit(target)
                            except ValueError:
                                raise EvidenceError("redirect_rejected") from None
                            if (old.scheme, old.netloc) != (
                                new.scheme,
                                new.netloc,
                            ) or target == url:
                                raise EvidenceError("redirect_rejected")
                            url, headers = target, {}
                            continue
                        if status_code == 429:
                            return repo.finish(
                                identity,
                                scope,
                                dict(
                                    status="rate_limited",
                                    error_kind="rate_limited",
                                    http_status=429,
                                    retry_after_seconds=_retry_after(
                                        response.headers.get("retry-after"), clock()
                                    ),
                                ),
                                clock(),
                            )
                        if status_code != 200:
                            raise EvidenceError("http_error")
                        data = bytearray()
                        async for chunk in response.aiter_bytes(65536):
                            data.extend(chunk)
                            if len(data) > MAX_FEED_BYTES:
                                raise EvidenceError("oversized_feed")
                        fetched = clock()
                        articles, rejected = await asyncio.to_thread(
                            parse_evidence, bytes(data), url, fetched
                        )
                        status, count, counts = _content_status(articles, rejected, fetched, hours)
                        validators = (
                            url,
                            _header(response.headers.get("etag")),
                            _header(response.headers.get("last-modified")),
                        )
                        return repo.finish(
                            identity,
                            scope,
                            dict(
                                status=status,
                                content_status=status,
                                accepted_count=count,
                                rejected_counts=counts,
                                http_status=200,
                            ),
                            fetched,
                            articles=articles,
                            rejected=rejected,
                            validators=validators,
                        )
                raise EvidenceError("too_many_redirects")
        except asyncio.CancelledError:
            repo.finish(
                identity,
                scope,
                dict(status="cancelled", error_kind="cancelled", http_status=status_code),
                clock(),
            )
            raise
        except (NewsError, SafeHTTPError) as exc:
            kind = exc.kind
        except EvidenceError as exc:
            kind = str(exc)
        except (TimeoutError, httpx.TimeoutException):
            kind = "timeout"
        except httpx.RequestError:
            kind = "network_error"
        return repo.finish(
            identity,
            scope,
            dict(status="failed", error_kind=kind, http_status=status_code),
            clock(),
        )
