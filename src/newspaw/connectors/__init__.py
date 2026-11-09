"""Public AI-source evidence; remote documents are data, never executable plugins."""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import replace
from datetime import UTC, datetime
from urllib.parse import parse_qs, urljoin, urlsplit

import httpx

from ..evidence import _content_status, _retry_after, _selection, _time
from ..newsparse import Article, eligible_articles, plain_text
from ..transport import SafeHTTPError, source_client

KINDS = {"github", "huggingface"}


class APIError(ValueError):
    def __init__(self, kind, retry_after=None):
        super().__init__(kind)
        self.kind, self.retry_after = kind, retry_after


def text(value, limit=500):
    return value[:limit] if isinstance(value, str) else ""


def object_(value):
    if not isinstance(value, dict):
        raise APIError("invalid_response")
    return value


def identifier(value, *, path=False):
    if not isinstance(value, str) or len(value) > 500:
        raise APIError("invalid_identifier")
    parts = value.split("/") if path else [value]
    if not parts or any(
        not re.fullmatch(r"[A-Za-z0-9_.-]{1,150}", p) or p in {".", ".."} for p in parts
    ):
        raise APIError("invalid_identifier")
    return value


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-fA-F0-9]{40,64}", value):
        raise APIError("invalid_revision")
    return value


def date(value):
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return _time(result)
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None


def source_url(url, kind):
    try:
        parts = urlsplit(url)
        if (
            parts.scheme != "https"
            or parts.hostname != {"github": "github.com", "huggingface": "huggingface.co"}[kind]
            or parts.port not in {None, 443}
            or parts.username is not None
            or parts.password is not None
            or parts.fragment
        ):
            raise APIError("unsupported_source_url")
        path = parts.path.strip("/").split("/")
        if kind == "huggingface" and path == ["models"]:
            query = parse_qs(parts.query, strict_parsing=True)
            if set(query) != {"author"} or len(query["author"]) != 1:
                raise APIError("unsupported_source_url")
            return {"author": identifier(query["author"][0])}
        if parts.query or len(path) < 2:
            raise APIError("unsupported_source_url")
        repo = identifier("/".join(path[:2]), path=True)
        if kind == "github" and len(path) >= 5 and path[2] == "blob":
            return dict(
                repo=repo,
                ref=identifier(path[3]),
                paths=[identifier("/".join(path[4:]), path=True)],
                releases=False,
            )
        if len(path) != 2:
            raise APIError("unsupported_source_url")
        return dict(repo=repo, paths=["README.md", "SKILL.md"], releases=True)
    except (ValueError, KeyError) as exc:
        if isinstance(exc, APIError):
            raise
        raise APIError("unsupported_source_url") from None


class PublicAPI:
    def __init__(self, client, kind, now):
        self.client, self.kind, self.now = client, kind, now
        self.host = "api.github.com" if kind == "github" else "huggingface.co"
        self.requests = 0
        self.gaps = []
        self.articles = []
        self.identity = None

    def gap(self, reason):
        if reason not in self.gaps:
            self.gaps.append(reason)

    async def get(self, url, *, missing=False):
        for hop in range(4):
            try:
                p = urlsplit(url)
                valid = (
                    p.scheme == "https"
                    and p.hostname == self.host
                    and p.port in {None, 443}
                    and p.username is None
                    and p.password is None
                    and not p.fragment
                )
            except ValueError:
                valid = False
            if not valid:
                raise APIError("unsafe_api_url")
            if self.requests >= 60:
                raise APIError("request_limit")
            self.requests += 1
            headers = (
                {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"}
                if self.kind == "github"
                else {}
            )
            response = await self.client.get(url, headers=headers, follow_redirects=False)
            if len(response.content) > 2 * 1024 * 1024:
                raise APIError("response_too_large")
            if response.status_code in {301, 302, 303, 307, 308}:
                if hop == 3 or not response.headers.get("location"):
                    raise APIError("redirect_limit")
                try:
                    url = urljoin(url, response.headers["location"])
                except ValueError:
                    raise APIError("unsafe_api_url") from None
                continue
            if response.status_code == 404 and missing:
                return None
            if response.status_code in {403, 429}:
                raise APIError(
                    "rate_limited", _retry_after(response.headers.get("retry-after"), self.now)
                )
            if response.status_code == 404:
                raise APIError("not_found_or_private")
            if response.status_code != 200:
                raise APIError("http_error")
            return response
        raise APIError("redirect_limit")

    def json(self, response):
        try:
            data = json.loads(
                response.content, parse_constant=lambda _: (_ for _ in ()).throw(ValueError())
            )
            stack = [(data, 0)]
            count = 0
            while stack:
                value, depth = stack.pop()
                count += 1
                if depth > 32 or count > 50000:
                    raise ValueError()
                if isinstance(value, dict):
                    stack.extend((v, depth + 1) for v in value.values())
                elif isinstance(value, list):
                    stack.extend((v, depth + 1) for v in value)
            return data
        except (ValueError, RecursionError):
            raise APIError("invalid_response") from None

    async def pages(self, url):
        seen = set()
        expected = urlsplit(url).path
        for _ in range(3):
            if url in seen or urlsplit(url).path != expected:
                raise APIError("invalid_pagination")
            seen.add(url)
            response = await self.get(url)
            data = self.json(response)
            if not isinstance(data, list) or len(data) > 100:
                raise APIError("invalid_response")
            for item in data:
                yield object_(item)
            next_ = response.links.get("next", {}).get("url")
            if not next_:
                return
            try:
                url = urljoin(str(response.url), next_)
            except ValueError:
                raise APIError("invalid_pagination") from None
        self.gap("page_limit")

    def article(self, *, title, url, body, published, metadata, feed_url, updated=""):
        if len(self.articles) >= 200:
            self.gap("candidate_limit")
            return
        self.articles.append(
            Article(
                title=plain_text(text(title), 500),
                url=url,
                source=metadata.get("repository", self.host),
                summary=plain_text(text(body, 256 * 1024), 1500),
                published_at=date(published),
                published_raw=text(published),
                published_error="" if date(published) else "missing_or_invalid_date",
                updated_at=date(updated),
                updated_raw=text(updated),
                fetched_at=self.now,
                feed_url=feed_url,
                evidence_scope="api_metadata_excerpt",
                metadata=metadata,
            )
        )


def api_scopes(config, subscriptions, source_id=None):
    groups = {}
    for row in _selection(config, subscriptions, source_id, KINDS):
        source = row["source"]
        groups.setdefault((source["partition"], source["url"], source["kind"]), []).append(row)
    return [
        dict(
            partition=partition,
            url=url,
            selected=rows,
            subscriptions=subscriptions,
            source_id=source_id,
            kinds=[kind],
            evidence_scope="api_metadata_excerpt",
        )
        for (partition, url, kind), rows in groups.items()
    ]


class AICollector:
    def __init__(self, evidence, *, client=None):
        self.evidence = evidence
        self.client = (
            client if client is not None else source_client(max_bytes=2 * 1024 * 1024, deadline=30)
        )
        self._lock = asyncio.Lock()

    async def close(self):
        await self.client.aclose()

    async def collect(self, subscriptions, *, now=None, max_age_hours=24):
        return await self._collect(subscriptions, None, now, max_age_hours)

    async def preview(self, source_id, *, now=None, max_age_hours=24):
        return await self._collect(None, source_id, now, max_age_hours)

    async def _collect(self, subscriptions, source_id, now, hours):
        fixed = _time(now) if now is not None else None
        eligible_articles([], _time(now), hours)
        async with self._lock:
            scopes = api_scopes(self.evidence.store.load_config()[1], subscriptions, source_id)
            return [await self.fetch_scope(scope, hours, fixed) for scope in scopes]

    async def fetch_scope(self, scope, hours, fixed):
        from .github import fetch as github
        from .huggingface import fetch as huggingface

        kind = scope["kinds"][0]
        repo = self.evidence
        now = fixed or datetime.now(UTC)
        identity = repo.begin(scope, now)
        if identity is None:
            return None
        api = PublicAPI(self.client, kind, now)
        error = None
        retry = None
        try:
            options = source_url(scope["url"], kind)
            old = repo.db.execute(
                "SELECT remote_id,canonical FROM connector_identity WHERE partition=? AND kind=? AND url=?",
                (scope["partition"], kind, scope["url"]),
            ).fetchone()
            async with asyncio.timeout(60):
                await (github if kind == "github" else huggingface)(
                    api, scope["url"], options, old, hours
                )
        except asyncio.CancelledError:
            repo.finish(
                identity,
                scope,
                dict(status="cancelled", error_kind="cancelled"),
                fixed or datetime.now(UTC),
            )
            raise
        except (APIError, SafeHTTPError, httpx.HTTPError, TimeoutError) as exc:
            error = (
                exc.kind
                if isinstance(exc, (APIError, SafeHTTPError))
                else "timeout"
                if isinstance(exc, TimeoutError)
                else "transport_error"
            )
            retry = exc.retry_after if isinstance(exc, APIError) else None
            api.gap(error)
        end = fixed or datetime.now(UTC)
        api.articles = [replace(article, fetched_at=end) for article in api.articles]
        status, count, rejected = _content_status(api.articles, {}, end, hours)
        if error and not api.articles:
            status = "failed"
        return repo.finish(
            identity,
            scope,
            dict(
                status=status,
                error_kind=error,
                accepted_count=count,
                rejected_counts=rejected,
                coverage_complete=not api.gaps,
                coverage_gaps=api.gaps,
                retry_after=retry,
                request_count=api.requests,
            ),
            end,
            articles=api.articles,
            rejected=rejected,
            cache=False,
            connector_identity=(kind, *api.identity) if api.identity else None,
        )
