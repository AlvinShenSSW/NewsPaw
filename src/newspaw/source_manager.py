"""Explicit source setup in the existing single-owner configuration service."""

from __future__ import annotations

import asyncio
import io
import json
import re
from contextlib import suppress
from copy import deepcopy
from dataclasses import asdict
from datetime import UTC, datetime
from html.parser import HTMLParser
from urllib.parse import urlencode, urljoin, urlsplit, urlunsplit
from uuid import uuid4

import feedparser
import httpx

from .app_config import _url, source_in_subscription, uses_category_sources, validate_config
from .connectors import AICollector, APIError, source_url
from .connectors.av import AV_ORIGIN, AVCollector, av_supported
from .connectors.web import WEB_ALIASES, WEB_SITES, WebCollector, web_supported
from .credentials import CredentialError
from .evidence import EvidenceError, EvidenceStore, FeedCollector
from .news import (
    MAX_FEED_BYTES,
    NewsError,
    eligible_articles,
    known_av_origin,
    parse_evidence,
    plain_text,
    public_url,
)
from .routing import resolve_route
from .transport import SafeHTTPError, source_client


class SourceError(CredentialError):
    pass


def normalize_url(value):
    try:
        _url(value)
        if not public_url(value, https_only=True):
            raise ValueError()
        p = urlsplit(value)
        if p.username is not None or p.password is not None:
            raise ValueError()
        host = p.hostname.lower()
        if ":" in host:
            host = "[" + host + "]"
        netloc = host if p.port in {None, 443} else f"{host}:{p.port}"
        return urlunsplit(("https", netloc, p.path or "/", p.query, ""))
    except (ValueError, TypeError):
        raise SourceError("unsafe_url") from None


def initialize(db):
    db.execute(
        "CREATE TABLE IF NOT EXISTS source_readiness (id TEXT PRIMARY KEY,epoch INTEGER NOT NULL,attempt_id TEXT)"
    )
    config = json.loads(
        db.execute("SELECT document FROM app_configuration WHERE id=1").fetchone()[0]
    )
    db.executemany(
        "INSERT OR IGNORE INTO source_readiness VALUES (?,1,NULL)",
        [(s["id"],) for s in config["sources"]],
    )


def invalidate_sources(db, current, document):
    result = deepcopy(document)
    old = {s["id"]: s for s in current["sources"]}
    new = {s["id"]: s for s in result["sources"]}
    for identity in old.keys() | new.keys():
        before, after = old.get(identity), new.get(identity)
        changed = (
            before is None
            or after is None
            or any(before[k] != after[k] for k in ("url", "kind", "partition"))
        )
        row = db.execute("SELECT epoch FROM source_readiness WHERE id=?", (identity,)).fetchone()
        if row is None:
            db.execute("INSERT INTO source_readiness VALUES (?,1,NULL)", (identity,))
        elif changed:
            db.execute(
                "UPDATE source_readiness SET epoch=epoch+1,attempt_id=NULL WHERE id=?", (identity,)
            )
    return result


class _Links(HTMLParser):
    def __init__(self, url):
        super().__init__(convert_charrefs=True)
        self.url, self.base = url, None
        self.head = False
        self.choices = []
        self.seen = set()

    def handle_starttag(self, tag, attrs):
        if tag == "head":
            self.head = True
        if not self.head:
            return
        attrs = dict(attrs)
        if tag == "base" and self.base is None and attrs.get("href"):
            with suppress(SourceError):
                self.base = normalize_url(urljoin(self.url, attrs["href"]))
        if tag != "link" or len(self.choices) >= 20:
            return
        kind = {"application/rss+xml": "rss", "application/atom+xml": "atom"}.get(
            str(attrs.get("type", "")).lower()
        )
        if str(attrs.get("rel", "")).lower() != "alternate" or not kind or not attrs.get("href"):
            return
        try:
            url = normalize_url(urljoin(self.base or self.url, attrs["href"]))
        except (SourceError, ValueError):
            return
        if url not in self.seen:
            self.seen.add(url)
            self.choices.append(
                dict(
                    url=url,
                    kind=kind,
                    name=plain_text(attrs.get("title", ""), 150) or urlsplit(url).hostname,
                    validation="preview_required",
                )
            )

    def handle_endtag(self, tag):
        if tag == "head":
            self.head = False


class SourceManager:
    def __init__(self, credentials, *, client_factory=None):
        self.credentials = credentials
        self.store = credentials.store
        self.evidence = EvidenceStore(self.store)
        self.client_factory = client_factory or (
            lambda: source_client(max_bytes=MAX_FEED_BYTES, deadline=30)
        )

    def _source(self, identity, config=None):
        config = self.store.load_config()[1] if config is None else config
        s = next((s for s in config["sources"] if s["id"] == identity), None)
        if s is None:
            raise SourceError("missing_source")
        return s

    def _epoch(self, identity):
        row = self.store._db.execute(
            "SELECT epoch,attempt_id FROM source_readiness WHERE id=?", (identity,)
        ).fetchone()
        if row is None:
            raise SourceError("preview_required")
        return row

    def _ready(self, source):
        try:
            _, attempt = self._epoch(source["id"])
            latest = next(
                (
                    a
                    for a in reversed(self.evidence.history(source["id"]))
                    if a["checked_at"] is not None
                ),
                None,
            )
            if (
                latest is None
                or latest["id"] != attempt
                or not latest["snapshot_id"]
                or latest["status"]
                not in {"fresh", "stale", "empty", "no_eligible", "not_modified"}
                or (source["kind"] == "web" and latest["status"] not in {"fresh", "stale"})
            ):
                return False
            scope = json.loads(
                self.store._db.execute(
                    "SELECT scope_json FROM feed_attempts WHERE id=?", (attempt,)
                ).fetchone()[0]
            )
            return any(
                r["source"]["id"] == source["id"] and r["source"]["kind"] == source["kind"]
                for r in scope["selected"]
            )
        except (SourceError, EvidenceError):
            return False

    def list(self):
        result = []
        for s in self.store.load_config()[1]["sources"]:
            try:
                health = self.evidence.health(s["id"])
            except EvidenceError:
                health = None
            result.append(dict(source=s, health=health, preview_ready=self._ready(s)))
        return result

    async def _mutate(self, revision, change):
        async def operation():
            config = self.credentials._current(revision)
            before = deepcopy(config)
            result = change(config) or {}
            validate_config(config)
            saved = (
                await self.credentials._commit(config, revision)
                if config != before
                else {"revision": revision}
            )
            return {**saved, **result}

        return await self.credentials._submit(operation)

    async def save(self, source, revision):
        def change(config):
            s = deepcopy(source)
            if not isinstance(s, dict):
                raise SourceError("invalid_source")
            s["url"] = normalize_url(s.get("url"))
            existing = next((v for v in config["sources"] if v["id"] == s.get("id")), None)
            for entry in config["sources"]:
                if entry["id"] != s.get("id") and (
                    normalize_url(entry["url"]),
                    entry["kind"],
                    entry["partition"],
                ) == (s["url"], s.get("kind"), s.get("partition")):
                    raise SourceError("duplicate_source")
            if existing and any(existing[k] != s.get(k) for k in ("url", "kind", "partition")):
                s["enabled"] = False
            config["sources"] = [v for v in config["sources"] if v["id"] != s.get("id")] + [s]
            validate_config(config)
            if s["enabled"]:
                supported = s["kind"] in {
                    "rss",
                    "atom",
                    "github",
                    "huggingface",
                } or (s["kind"] == "web" and (web_supported(s) or av_supported(s)))
                if s["kind"] in {"rss", "atom"} and known_av_origin(s["url"]):
                    raise SourceError("adult_source_requires_adapter")
                if not s["category_ids"] or not supported:
                    raise SourceError("unsupported_source")
                if not self._ready(s):
                    raise SourceError("preview_required")
            return {"source_id": s["id"]}

        return await self._mutate(revision, change)

    async def assign(self, identity, subscriptions, revision):
        def change(config):
            if (
                not isinstance(subscriptions, list)
                or not 1 <= len(subscriptions) <= 200
                or any(not isinstance(v, str) for v in subscriptions)
            ):
                raise SourceError("invalid_subscriptions")
            s = self._source(identity, config)
            if s["partition"] is None:
                raise SourceError("unclassified_source")
            selected = []
            for key in dict.fromkeys(subscriptions):
                sub = next((v for v in config["subscriptions"] if v["id"] == key), None)
                if sub is None:
                    raise SourceError("missing_subscription")
                cat = next(c for c in config["categories"] if c["id"] == sub["category_id"])
                if cat["partition"] != s["partition"]:
                    raise SourceError("incompatible_subscription")
                # Materialize inherited selection before modifying category membership.
                if uses_category_sources(sub):
                    sub["source_ids"] = [
                        v["id"] for v in config["sources"] if cat["id"] in v["category_ids"]
                    ]
                sub["source_mode"] = "explicit"
                if identity not in sub["source_ids"]:
                    sub["source_ids"].append(identity)
                selected.append(cat["id"])
            s["category_ids"] = list(dict.fromkeys([*s["category_ids"], *selected]))

        return await self._mutate(revision, change)

    @staticmethod
    def _remove(config, identity):
        config["sources"] = [source for source in config["sources"] if source["id"] != identity]
        disabled = []
        for sub in config["subscriptions"]:
            if identity in sub["source_ids"]:
                sub["source_ids"].remove(identity)
                sub["source_mode"] = "explicit"
                if not sub["source_ids"]:
                    sub["enabled"] = False
                    disabled.append(sub["id"])
        return disabled

    async def delete(self, identity, revision):
        def change(config):
            self._source(identity, config)
            return {"disabled_subscriptions": self._remove(config, identity)}

        return await self._mutate(revision, change)

    def impact(self, identity, action):
        if action not in {"pause", "delete"}:
            raise SourceError("invalid_source_action")
        revision, config = self.store.load_config()
        source = self._source(identity, config)
        affected = [
            sub
            for sub in config["subscriptions"]
            if source_in_subscription(source, sub, include_muted=True)
        ]
        active = {sub["id"]: sub["enabled"] for sub in affected}
        if action == "delete":
            self._remove(config, identity)
        else:
            source["enabled"] = False
        subscriptions = []
        for sub in affected:
            route = resolve_route(config, revision, sub["id"])
            subscriptions.append(
                dict(
                    id=sub["id"],
                    name=sub["name"],
                    was_enabled=active[sub["id"]],
                    enabled=sub["enabled"],
                    blockers=list(route.blockers),
                )
            )
        return dict(
            revision=revision, source_id=identity, action=action, subscriptions=subscriptions
        )

    def routes(self, identity):
        revision, config = self.store.load_config()
        source = self._source(identity, config)
        result = []
        for sub in config["subscriptions"]:
            if source_in_subscription(source, sub, include_muted=True):
                route = resolve_route(config, revision, sub["id"])
                result.append(
                    dict(
                        subscription_id=sub["id"],
                        effective=route.effective,
                        explanation=route.explanation,
                        blockers=list(route.blockers),
                        fingerprint=route.fingerprint,
                        revision=revision,
                    )
                )
        return result

    async def preview(self, identity, *, now=None):
        source = self._source(identity)
        if source["partition"] is None:
            raise SourceError("unclassified_source")
        if source["kind"] in {"rss", "atom"} and known_av_origin(source["url"]):
            raise SourceError("adult_source_requires_adapter")
        factory = {
            "rss": FeedCollector,
            "atom": FeedCollector,
            "github": AICollector,
            "huggingface": AICollector,
            "web": AVCollector
            if av_supported(source)
            else WebCollector
            if web_supported(source)
            else None,
        }.get(source["kind"])
        if factory is None:
            raise SourceError("unsupported_source")
        epoch = self._epoch(identity)[0]
        collector = factory(self.evidence, client=self.client_factory())
        try:
            result = (await collector.preview(identity, now=now))[0]
        finally:
            await collector.close()
        with self.store._write():
            if result["status"] == "configuration_changed" or self._epoch(identity)[0] != epoch:
                raise SourceError("configuration_changed")
            self._source(identity)
            self.store._db.execute(
                "UPDATE source_readiness SET attempt_id=? WHERE id=?", (result["id"], identity)
            )
        articles = self.evidence.articles(
            result["id"],
            partition=source["partition"],
            source_id=identity,
            now=now,
            fresh_only=False,
        )
        entries = []
        for a in articles[:10]:
            entry = asdict(a)
            for key in ("published_at", "updated_at", "fetched_at"):
                entry[key] = entry[key].isoformat() if entry[key] else None
            entry.update(
                content_sha256=a.content_sha256,
                eligible=bool(eligible_articles([a], now or datetime.now(UTC), 24)[0]),
            )
            entries.append(entry)
        return {
            "attempt": result,
            "entries": entries,
            "health": self.evidence.health(identity, now=now),
            "preview_ready": self._ready(source),
        }

    async def import_opml(self, content, revision):
        from .importers.opml import parse_opml

        parsed = parse_opml(content)

        def change(config):
            existing = {normalize_url(s["url"]): s["id"] for s in reversed(config["sources"])}
            added, found = [], []
            for feed in parsed["feeds"]:
                if feed["url"] in existing:
                    found.append(existing[feed["url"]])
                    continue
                identity = "source_" + uuid4().hex
                config["sources"].append(
                    dict(
                        id=identity,
                        name=feed["name"],
                        url=feed["url"],
                        kind="rss",
                        partition=None,
                        category_ids=[],
                        enabled=False,
                    )
                )
                existing[feed["url"]] = identity
                added.append(identity)
            return dict(
                added=added, existing=list(dict.fromkeys(found)), rejected=parsed["rejected"]
            )

        return await self._mutate(revision, change)

    async def discover(self, value):
        url = normalize_url(value)
        if known_av_origin(url):
            return dict(
                kind="web",
                choices=[
                    dict(
                        url=AV_ORIGIN,
                        kind="web",
                        name="AV研究所",
                        partition="adult",
                        category_ids=["av"],
                        validation="preview_required",
                    )
                ],
            )
        entry = WEB_ALIASES.get(url, url)
        if entry in WEB_SITES:
            return dict(
                kind="web",
                choices=[
                    dict(
                        url=entry,
                        kind="web",
                        name=WEB_SITES[entry].publisher,
                        validation="preview_required",
                    )
                ],
            )
        parts = urlsplit(url)
        if parts.hostname in {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}:
            return dict(kind="x", destination="x_accounts", choices=[])
        if parts.hostname in {"github.com", "huggingface.co"}:
            kind = "github" if parts.hostname == "github.com" else "huggingface"
            if (
                kind == "huggingface"
                and len(parts.path.strip("/").split("/")) == 1
                and parts.path.strip("/")
                and not parts.query
            ):
                url = "https://huggingface.co/models?" + urlencode(
                    {"author": parts.path.strip("/")}
                )
            try:
                source_url(url, kind)
            except APIError:
                return dict(kind="draft", choices=[], reason="unsupported_source_url")
            return dict(
                kind=kind,
                choices=[
                    dict(
                        url=url,
                        kind=kind,
                        name=parts.path.strip("/"),
                        validation="preview_required",
                    )
                ],
            )
        client = self.client_factory()
        try:
            async with asyncio.timeout(30):
                for hop in range(4):
                    response = await client.get(url, follow_redirects=False)
                    if response.is_redirect:
                        target = normalize_url(urljoin(url, response.headers.get("location", "")))
                        if (
                            hop == 3
                            or urlsplit(target).netloc != urlsplit(url).netloc
                            or target == url
                        ):
                            raise SourceError("redirect_rejected")
                        url = target
                        continue
                    if response.status_code != 200:
                        raise SourceError("http_error")
                    if len(response.content) > MAX_FEED_BYTES:
                        raise SourceError("response_too_large")
                    data = response.content
                    try:
                        await asyncio.to_thread(parse_evidence, data, url, datetime.now(UTC))
                    except NewsError as exc:
                        if exc.kind == "unsafe_xml" and not data.lstrip().lower().startswith(
                            b"<!doctype html>"
                        ):
                            raise SourceError("unsafe_xml") from None
                        html = response.headers.get("content-type", "").split(";", 1)[
                            0
                        ].strip().lower() in {"text/html", "application/xhtml+xml"} or re.match(
                            rb"\s*(?:<!doctype\s+html>\s*)?<html(?:\s|>)", data[:1024], re.I
                        )
                        if not html or exc.kind not in {"invalid_feed", "unsafe_xml"}:
                            raise SourceError(exc.kind) from None
                        parser = _Links(url)
                        parser.feed(response.text)
                        return dict(
                            kind="feeds" if parser.choices else "draft",
                            choices=parser.choices,
                            final_url=url,
                        )
                    version = feedparser.parse(io.BytesIO(data)).get("version", "")
                    kind = "atom" if version.startswith("atom") else "rss"
                    return dict(
                        kind=kind,
                        choices=[
                            dict(
                                url=url,
                                kind=kind,
                                name=urlsplit(url).hostname,
                                validation="preview_required",
                            )
                        ],
                        final_url=url,
                    )
        except (SafeHTTPError, httpx.HTTPError, TimeoutError, ValueError) as exc:
            if isinstance(exc, SourceError):
                raise
            raise SourceError(
                exc.kind if isinstance(exc, SafeHTTPError) else "discovery_failed"
            ) from None
        finally:
            await client.aclose()
