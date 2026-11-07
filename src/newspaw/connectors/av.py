"""An exact, adult-only connector for the known AV industry publisher."""

from __future__ import annotations

import asyncio
import re
from datetime import UTC, datetime
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

import httpx

from ..av_rules import AV_PUBLISHER, industry_fact
from ..evidence import EvidenceError, _content_status, _selection, _time
from ..news import MAX_FEED_BYTES, Article, plain_text
from ..transport import source_client

AV_ORIGIN = "https://fiu758.com/"
_ARTICLE = re.compile(r"post-([1-9][0-9]{0,17})")
_QUERY = re.compile(r"p=([1-9][0-9]{0,17})")
_VOID = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}


class _Held(RuntimeError):
    pass


def av_supported(source):
    return (
        source["kind"] == "web"
        and source["partition"] == "adult"
        and source["url"] == AV_ORIGIN
        and source["category_ids"] == ["av"]
    )


def av_scopes(config, subscriptions, source_id=None):
    allowed = {source["id"] for source in config["sources"] if av_supported(source)}
    selected = [
        row
        for row in _selection(config, subscriptions, source_id, {"web"})
        if row["source"]["id"] in allowed and row["association"]["category_id"] in {"", "av"}
    ]
    if not selected:
        return []
    return [
        dict(
            partition="adult",
            url=AV_ORIGIN,
            selected=selected,
            kinds=["web"],
            subscriptions=subscriptions,
            source_id=source_id,
        )
    ]


def _post_id(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parts = urlsplit(urljoin(AV_ORIGIN, value))
    except ValueError:
        return None
    match = _QUERY.fullmatch(parts.query)
    if (
        parts.scheme == "https"
        and parts.netloc == "fiu758.com"
        and parts.path == "/"
        and not parts.fragment
        and match
    ):
        return match[1]
    return None


def _published(values):
    if not values:
        return None
    result = set()
    for value in values:
        if not value or len(value) > 64:
            raise EvidenceError("invalid_publication_date")
        try:
            published = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if published.tzinfo is None or published.utcoffset() is None:
                raise ValueError()
            result.add((published.astimezone(UTC), value))
        except (ValueError, OverflowError):
            raise EvidenceError("invalid_publication_date") from None
    if len({entry[0] for entry in result}) != 1:
        raise EvidenceError("conflicting_publication_date")
    return min(result)


class _Page(HTMLParser):
    def __init__(self, *, landing):
        super().__init__(convert_charrefs=True)
        self.landing = landing
        self.stack = []
        self.candidates = []
        self.current = None
        self.nodes = 0
        self.ids = set()
        self.canonicals = set()
        self.dates = []

    def handle_starttag(self, tag, pairs):
        self.nodes += 1
        if self.nodes > 40_000 or len(self.stack) >= 64:
            raise EvidenceError("parse_limit")
        attrs = dict(pairs)
        classes = set((attrs.get("class") or "").split())
        if tag == "article":
            match = _ARTICLE.fullmatch(attrs.get("id") or "")
            if match:
                self.ids.add(match[1])
            if self.landing:
                self.current = (
                    dict(id=match[1], urls=[], dates=[], title="", excerpt="") if match else None
                )
        if not self.landing:
            if tag == "link" and "canonical" in (attrs.get("rel") or "").lower().split():
                self.canonicals.add(_post_id(attrs.get("href")))
            if tag == "meta" and attrs.get("property") == "article:published_time":
                self.dates.append(attrs.get("content"))
        section = None
        if tag == "h2" and "post-title" in classes:
            section = "title"
        elif "entry" in classes and "excerpt" in classes:
            section = "excerpt"
        elif "post-meta" in classes:
            section = "date"
        elif tag in {"script", "style", "noscript"}:
            section = "ignore"
        current_sections = {item[1] for item in self.stack}
        if self.current is not None and "ignore" not in current_sections:
            if tag == "a" and "title" in current_sections:
                self.current["urls"].append(_post_id(attrs.get("href")))
            if (
                tag == "time"
                and "date" in current_sections
                and (
                    attrs.get("itemprop") == "datePublished"
                    or "published" in classes
                    or ("entry-date" in classes and "updated" not in classes)
                )
            ):
                self.current["dates"].append(attrs.get("datetime"))
        if tag not in _VOID:
            self.stack.append((tag, section))

    def handle_startendtag(self, tag, pairs):
        self.handle_starttag(tag, pairs)
        if tag not in _VOID:
            self.handle_endtag(tag)

    def handle_data(self, data):
        if self.current is None:
            return
        sections = {item[1] for item in self.stack}
        if "ignore" in sections:
            return
        for field, maximum in (("title", 500), ("excerpt", 1500)):
            if field in sections:
                self.current[field] = (self.current[field] + data)[:maximum]

    def handle_endtag(self, tag):
        index = next(
            (i for i in range(len(self.stack) - 1, -1, -1) if self.stack[i][0] == tag), None
        )
        if index is not None:
            del self.stack[index:]
        if tag == "article" and self.current is not None:
            if self.current["urls"] == [self.current["id"]]:
                self.candidates.append(self.current)
            self.current = None


class AVCollector:
    def __init__(self, evidence, *, client=None):
        self.evidence = evidence
        self.client = client or source_client(max_bytes=MAX_FEED_BYTES, deadline=15)

    async def close(self):
        await self.client.aclose()

    async def preview(self, source_id, *, now=None):
        scopes = av_scopes(self.evidence.store.load_config()[1], None, source_id)
        if not scopes:
            raise EvidenceError("unsupported_source")
        return [await self.fetch_scope(scopes[0], 24, now)]

    async def collect(self, subscriptions, *, now=None, before_request=None):
        scopes = av_scopes(self.evidence.store.load_config()[1], subscriptions)
        if not scopes:
            raise EvidenceError("unsupported_source")
        return await self.fetch_scope(scopes[0], 24, now, before_request=before_request)

    async def _get(self, scope, url, before_request, *, identity=None):
        if before_request is not None and before_request() is False:
            raise _Held
        if not self.evidence.current(scope):
            raise EvidenceError("configuration_changed")
        request = self.client.build_request("GET", url)
        request.headers.pop("cookie", None)
        request.headers.pop("authorization", None)
        response = await self.client.send(request, auth=None, follow_redirects=False)
        if response.is_redirect:
            raise EvidenceError("redirect_rejected")
        if response.status_code in {401, 402, 403, 451}:
            raise EvidenceError("access_restricted")
        if response.status_code != 200:
            raise EvidenceError("http_error")
        media_type = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if len(response.content) > MAX_FEED_BYTES or media_type not in {
            "text/html",
            "application/xhtml+xml",
        }:
            raise EvidenceError("invalid_html")
        parser = _Page(landing=identity is None)
        parser.feed(response.text)
        parser.close()
        if identity is not None and (
            (parser.canonicals and parser.canonicals != {identity})
            or (parser.ids and identity not in parser.ids)
            or (not parser.canonicals and parser.ids != {identity})
        ):
            raise EvidenceError("article_identity_mismatch")
        return parser

    async def fetch_scope(self, scope, hours, fixed, *, before_request=None):
        if scope["partition"] != "adult" or scope["url"] != AV_ORIGIN:
            raise EvidenceError("unsupported_source")
        allowed = av_scopes(
            self.evidence.store.load_config()[1], scope["subscriptions"], scope["source_id"]
        )
        if not allowed or scope["selected"] != allowed[0]["selected"]:
            raise EvidenceError("unsupported_source")
        identity = self.evidence.begin(scope, _time(fixed))
        if identity is None:
            return None
        articles, gaps = [], set()
        error = None
        try:
            async with asyncio.timeout(45):
                landing = await self._get(scope, AV_ORIGIN, before_request)
                if not landing.candidates:
                    gaps.add("no_matching_candidates")
                seen = set()
                for candidate in landing.candidates:
                    post_id = candidate["id"]
                    if post_id in seen:
                        gaps.add("duplicate_candidate")
                        continue
                    if len(seen) == 6:
                        gaps.add("candidate_limit")
                        break
                    seen.add(post_id)
                    url = AV_ORIGIN + "?p=" + post_id
                    try:
                        title = plain_text(candidate["title"], 300)
                        excerpt = plain_text(candidate["excerpt"], 600)
                        fact = industry_fact(title, excerpt)
                        if fact is None:
                            gaps.add("no_industry_fact")
                            continue
                        detail = await self._get(scope, url, before_request, identity=post_id)
                        published = _published([*candidate["dates"], *detail.dates])
                        if published is None:
                            raise EvidenceError("missing_publication_date")
                        now = _time(fixed)
                        accepted, rejected = _content_status(
                            [Article(title, url, AV_PUBLISHER, published[0])], {}, now, hours
                        )[1:]
                        if not accepted:
                            gaps.update(rejected)
                            continue
                        articles.append(
                            Article(
                                title,
                                url,
                                AV_PUBLISHER,
                                published[0],
                                excerpt,
                                fetched_at=now,
                                feed_url=AV_ORIGIN,
                                published_raw=published[1],
                                language="ja",
                                evidence_scope="av_industry_excerpt",
                                metadata={"av_industry": fact},
                            )
                        )
                    except (EvidenceError, httpx.HTTPError) as exc:
                        reason = str(exc) if isinstance(exc, EvidenceError) else "network_error"
                        gaps.add(reason)
                        if reason == "configuration_changed":
                            raise
        except _Held:
            self.evidence.finish(
                identity,
                scope,
                dict(status="interrupted", error_kind="collection_held"),
                _time(fixed),
            )
            return None
        except asyncio.CancelledError:
            self.evidence.finish(
                identity, scope, dict(status="interrupted", error_kind="interrupted"), _time(fixed)
            )
            raise
        except (EvidenceError, httpx.HTTPError, TimeoutError) as exc:
            error = str(exc) if isinstance(exc, EvidenceError) else "network_error"
            gaps.add(error)
        return self.evidence.finish(
            identity,
            scope,
            dict(
                status="failed" if error else "fresh" if articles else "no_eligible",
                accepted_count=len(articles),
                error_kind=error,
                coverage_complete=False,
                coverage_gaps=sorted(gaps),
                evidence_scope="av_industry",
            ),
            _time(fixed),
            articles=articles if not error else None,
            rejected={},
            cache=False,
        )
