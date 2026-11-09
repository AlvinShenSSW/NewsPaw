"""Public article metadata from a small set of publisher-owned entrances."""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit
from xml.etree import ElementTree

import httpx

from ..evidence import EvidenceError, _content_status, _selection, _time
from ..newsparse import MAX_FEED_BYTES, Article, NewsError, _published, check_news_xml, plain_text
from ..transport import SafeHTTPError, checked_url, source_client

CNN = "https://edition.cnn.com/sitemap/news.xml"
SITE_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
NEWS_NS = "{http://www.google.com/schemas/sitemap-news/0.9}"
WEB_KINDS = frozenset({"web"})
_DETAIL_LIMIT = 6


class WebError(ValueError):
    pass


@dataclass(frozen=True)
class WebSite:
    publisher: str
    article_host: str
    article_path: str
    sitemap: bool = False


WEB_SITES = {
    CNN: WebSite(
        "CNN",
        "www.cnn.com",
        r"/20\d{2}/\d{2}/\d{2}/(?:world|africa|americas|asia|europe|middleeast|uk)/[A-Za-z0-9_-]+/?",
        sitemap=True,
    ),
    "https://www.zaobao.com.sg/news/china": WebSite(
        "联合早报", "www.zaobao.com.sg", r"/news/china/story\d{8}-\d+"
    ),
    "https://www.zaobao.com.sg/entertainment": WebSite(
        "联合早报", "www.zaobao.com.sg", r"/entertainment/story\d{8}-\d+"
    ),
    "https://www.abc.net.au/news/entertainment": WebSite(
        "ABC News",
        "www.abc.net.au",
        r"/news/20\d{2}-\d{2}-\d{2}/[A-Za-z0-9_-]+/\d+",
    ),
}
WEB_ALIASES = {"https://edition.cnn.com/world": CNN, "https://www.cnn.com/world": CNN}


def _article_url(value, base, site):
    if not isinstance(value, str) or not 1 <= len(value) <= 2048:
        return None
    try:
        target = urljoin(base, value)
        parts = urlsplit(target)
        checked_url(target)
        if (
            parts.hostname == site.article_host
            and parts.port in {None, 443}
            and not (parts.query or parts.fragment)
            and re.fullmatch(site.article_path, parts.path)
        ):
            return f"https://{site.article_host}{parts.path}"
    except (SafeHTTPError, ValueError):
        pass
    return None


class _Page(HTMLParser):
    def __init__(self, url, site, *, landing=False):
        super().__init__(convert_charrefs=True)
        self.url, self.site, self.landing = url, site, landing
        self.links, self.records = [], []
        self.script, self.scripts = False, 0
        self.canonical = None

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if self.landing and tag == "a" and len(self.links) < _DETAIL_LIMIT:
            target = _article_url(values.get("href"), self.url, self.site)
            if target and target not in self.links:
                self.links.append(target)
        if not self.landing:
            if tag == "link" and (values.get("rel") or "").lower() == "canonical":
                value = _article_url(values.get("href"), self.url, self.site)
                if value is None or self.canonical not in {None, value}:
                    raise WebError("canonical_mismatch")
                self.canonical = value
            if tag == "script":
                self.script = (
                    self.scripts < 16
                    and (values.get("type") or "").lower() == "application/ld+json"
                )
                if self.script:
                    self.scripts += 1

    def handle_endtag(self, tag):
        if tag == "script":
            self.script = False

    def handle_data(self, data):
        if not self.script or len(data) > 128 * 1024:
            return
        try:
            root = json.loads(data)
        except (ValueError, RecursionError):
            return
        if isinstance(root, dict):
            root = root.get("@graph", [root])
        if not isinstance(root, list):
            return
        for row in root[:64]:
            if isinstance(row, dict):
                kind = row.get("@type")
                if kind in ("Article", "NewsArticle") or (
                    isinstance(kind, list) and any(k in kind for k in ("Article", "NewsArticle"))
                ):
                    self.records.append(row)


def _text(value, limit):
    return plain_text(value, limit) if isinstance(value, str) else ""


def _article(site, url, source_url, title, published, now, *, summary="", updated="", language=""):
    date, raw, error = _published({"published": published})
    updated_date, updated_raw, _ = _published({"published": updated})
    return Article(
        title=_text(title, 500),
        url=url,
        source=site.publisher,
        summary=_text(summary, 600),
        published_at=date,
        published_raw=raw,
        published_error=error or "",
        updated_at=updated_date,
        updated_raw=updated_raw,
        fetched_at=now,
        feed_url=source_url,
        language=_text(language, 32),
        evidence_scope="public_metadata_excerpt" if summary else "public_metadata_title",
    )


def _detail(page, url, source_url, site, now):
    if not page.records:
        raise WebError("layout_changed")
    if page.canonical is not None and page.canonical != url:
        raise WebError("canonical_mismatch")
    if any(row.get("isAccessibleForFree") is False for row in page.records):
        raise WebError("access_restricted")
    candidates = []
    for row in page.records:
        canonical = row.get("url")
        entity = row.get("mainEntityOfPage")
        if canonical is None and isinstance(entity, dict):
            canonical = entity.get("@id")
        elif canonical is None and isinstance(entity, str):
            canonical = entity
        if canonical is not None and _article_url(canonical, url, site) != url:
            raise WebError("canonical_mismatch")
        if not _text(row.get("headline"), 500):
            continue
        candidates.append(
            _article(
                site,
                url,
                source_url,
                row.get("headline"),
                row.get("datePublished"),
                now,
                summary=row.get("description") if row.get("isAccessibleForFree") is True else "",
                updated=row.get("dateModified"),
                language=row.get("inLanguage"),
            )
        )
    if not candidates:
        raise WebError("layout_changed")
    if len({(a.title, a.published_raw) for a in candidates}) != 1:
        raise WebError("ambiguous_metadata")
    return candidates[0]


def _sitemap(data, source_url, site, now):
    check_news_xml(data)
    root = ElementTree.fromstring(data)
    if root.tag != SITE_NS + "urlset" or not 1 <= len(root) <= 1000:
        raise WebError("layout_changed")
    seen, articles = set(), []
    recognized = 0
    for row in root:
        news = row.find(NEWS_NS + "news")
        if news is None:
            continue
        recognized += 1
        url = _article_url(row.findtext(SITE_NS + "loc"), source_url, site)
        title = news.findtext(NEWS_NS + "title")
        if not url or url in seen or not _text(title, 500):
            continue
        seen.add(url)
        articles.append(
            _article(
                site,
                url,
                source_url,
                title,
                news.findtext(NEWS_NS + "publication_date"),
                now,
                language=news.findtext(NEWS_NS + "publication/" + NEWS_NS + "language"),
            )
        )
    if not recognized:
        raise WebError("layout_changed")
    return articles


def web_supported(source):
    return source["partition"] == "normal" and source["url"] in WEB_SITES


def web_scopes(config, subscriptions, source_id=None):
    groups = {}
    for row in _selection(config, subscriptions, source_id, WEB_KINDS):
        source = row["source"]
        if web_supported(source):
            groups.setdefault(source["url"], []).append(row)
    return [
        dict(
            partition="normal",
            url=url,
            selected=rows,
            subscriptions=subscriptions,
            source_id=source_id,
            kinds=["web"],
            evidence_scope="public_metadata",
        )
        for url, rows in groups.items()
    ]


class _CollectionHeld(RuntimeError):
    pass


class WebCollector:
    def __init__(self, evidence, *, client=None):
        self.evidence = evidence
        self.client = client if client is not None else source_client(deadline=12)

    async def close(self):
        await self.client.aclose()

    async def preview(self, source_id, *, now=None, max_age_hours=24):
        scopes = web_scopes(self.evidence.store.load_config()[1], None, source_id)
        if not scopes:
            raise EvidenceError("unsupported_source")
        return [await self.fetch_scope(scopes[0], max_age_hours, now)]

    async def _get(self, scope, target, *, article=False, before_request=None):
        site, origin = WEB_SITES[scope["url"]], urlsplit(scope["url"]).netloc
        for hop in range(3):
            if before_request is not None and before_request() is False:
                raise _CollectionHeld
            if not self.evidence.current(scope):
                raise WebError("configuration_changed")
            request = self.client.build_request("GET", target)
            # Never join the publisher's login/tracking session.
            request.headers.pop("cookie", None)
            response = await self.client.send(request, auth=None, follow_redirects=False)
            if response.is_redirect:
                location = response.headers.get("location")
                try:
                    redirected = urljoin(target, location) if location else None
                    valid = (
                        _article_url(redirected, target, site)
                        if article
                        else redirected in {scope["url"], scope["url"] + "/"}
                    )
                except ValueError:
                    raise WebError("redirect_rejected") from None
                if (
                    hop == 2
                    or not valid
                    or urlsplit(redirected).netloc != origin
                    or redirected == target
                ):
                    raise WebError("redirect_rejected")
                target = redirected
                continue
            if response.status_code in {401, 402, 403, 451}:
                raise WebError("access_restricted")
            if response.status_code != 200:
                raise WebError("http_error")
            if len(response.content) > MAX_FEED_BYTES:
                raise WebError("response_too_large")
            return response
        raise WebError("redirect_rejected")

    async def fetch_scope(self, scope, hours, fixed, *, before_request=None):
        url = scope["url"]
        site = WEB_SITES.get(url)
        if scope["partition"] != "normal" or site is None:
            raise EvidenceError("unsupported_source")
        start = _time(fixed)
        identity = self.evidence.begin(scope, start)
        if identity is None:
            return None
        articles = []
        gaps = {"sitemap_metadata_only" if site.sitemap else "bounded_metadata_sample"}
        error = None

        def reason(exc):
            return getattr(exc, "kind", str(exc) if isinstance(exc, WebError) else "network_error")

        try:
            async with asyncio.timeout(60):
                landing = await self._get(scope, url, before_request=before_request)
                if site.sitemap:
                    if "xml" not in landing.headers.get("content-type", "").lower():
                        raise WebError("layout_changed")
                    articles = _sitemap(landing.content, url, site, _time(fixed))
                else:
                    if "text/html" not in landing.headers.get("content-type", "").lower():
                        raise WebError("layout_changed")
                    links = _Page(str(landing.url), site, landing=True)
                    links.feed(landing.text)
                    if not links.links:
                        raise WebError("layout_changed")
                    for target in links.links:
                        try:
                            detail = await self._get(
                                scope, target, article=True, before_request=before_request
                            )
                            if "text/html" not in detail.headers.get("content-type", "").lower():
                                raise WebError("layout_changed")
                            page = _Page(str(detail.url), site)
                            page.feed(detail.text)
                            articles.append(_detail(page, str(detail.url), url, site, _time(fixed)))
                        except (WebError, httpx.RequestError) as exc:
                            error = reason(exc)
                            gaps.add(error)
                            if error == "configuration_changed":
                                break
        except _CollectionHeld:
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
        except (
            WebError,
            NewsError,
            httpx.RequestError,
            TimeoutError,
            ValueError,
            ElementTree.ParseError,
        ) as exc:
            error = reason(exc)
            gaps.add(error)
        end = _time(fixed)
        status, count, rejected = _content_status(articles, {}, end, hours)
        return self.evidence.finish(
            identity,
            scope,
            dict(
                status="failed" if error and not articles else status,
                error_kind=error,
                accepted_count=count,
                rejected_counts=rejected,
                coverage_complete=False,
                coverage_gaps=sorted(gaps),
            ),
            end,
            articles=articles if articles or not error else None,
            rejected=rejected,
            cache=False,
        )
