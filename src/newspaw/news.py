"""Bounded RSS retrieval with source attribution and no article-page scraping."""

from __future__ import annotations

import asyncio
import hashlib
import io
import ipaddress
import json
import re
import socket
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
from xml.parsers import expat

import feedparser
import httpx

from .transport import SafeHTTPError, source_client

MAX_FEED_BYTES = 2 * 1024 * 1024
MAX_ITEMS = 200
TRACKING_PARAMETERS = {"fbclid", "gclid", "mc_cid", "mc_eid"}


class NewsError(RuntimeError):
    """The requested news could not be retrieved."""

    def __init__(self, message: str, kind: str = "news_error") -> None:
        super().__init__(message)
        self.kind = kind


@dataclass(frozen=True)
class Article:
    title: str
    url: str
    source: str
    published_at: datetime | None = None
    summary: str = ""
    image_url: str | None = None
    fetched_at: datetime | None = None
    feed_url: str = ""
    published_raw: str = ""
    excerpt_truncated: bool = False
    updated_at: datetime | None = None
    updated_raw: str = ""
    language: str = ""
    published_error: str = ""
    evidence_scope: str = "rss_excerpt"
    metadata: dict = field(default_factory=dict)

    @property
    def content_sha256(self) -> str:
        """Hash the retained title/excerpt snapshot, not a proof of truth."""
        values = [self.title, self.summary]
        if self.metadata:
            values.append(self.metadata)
        payload = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class SourceAttempt:
    url: str
    retrieval_method: str
    status: str
    fetched_at: datetime | None
    error_kind: str | None
    accepted_count: int
    rejected_counts: dict[str, int]
    http_status: int | None = None

    def to_dict(self) -> dict:
        return {
            "url": self.url,
            "retrieval_method": self.retrieval_method,
            "status": self.status,
            "fetched_at": self.fetched_at.isoformat() if self.fetched_at else None,
            "error_kind": self.error_kind,
            "accepted_count": self.accepted_count,
            "rejected_counts": dict(self.rejected_counts),
            "http_status": self.http_status,
        }


@dataclass(frozen=True)
class RetrievalReport:
    started_at: datetime
    finished_at: datetime
    attempts: list[SourceAttempt]
    accepted_articles: list[Article]
    returned_urls: list[str]
    deduplicated_count: int
    limited_count: int
    max_age_hours: int
    topic_buckets: dict[str, list[str]]

    def to_dict(self) -> dict:
        return {
            "schema_version": 1,
            "started_at": self.started_at.isoformat(),
            "finished_at": self.finished_at.isoformat(),
            "max_age_hours": self.max_age_hours,
            "window_start": (self.started_at - timedelta(hours=self.max_age_hours)).isoformat(),
            "window_end": self.started_at.isoformat(),
            "attempts": [attempt.to_dict() for attempt in self.attempts],
            "accepted_articles": [
                {
                    "title": article.title,
                    "url": article.url,
                    "source": article.source,
                    "published_at": article.published_at.isoformat()
                    if article.published_at
                    else None,
                    "published_raw": article.published_raw,
                    "fetched_at": article.fetched_at.isoformat() if article.fetched_at else None,
                    "feed_url": article.feed_url,
                    "summary": article.summary,
                    "image_url": article.image_url,
                    "content_sha256": article.content_sha256,
                    "excerpt_truncated": article.excerpt_truncated,
                }
                for article in self.accepted_articles
            ],
            "returned_urls": list(self.returned_urls),
            "deduplicated_count": self.deduplicated_count,
            "limited_count": self.limited_count,
            "topic_buckets": {topic: list(urls) for topic, urls in self.topic_buckets.items()},
        }


class _PlainText(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.images: list[str] = []
        self.hidden = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style"}:
            self.hidden += 1
        elif tag == "img":
            self.images.extend(value for key, value in attrs if key == "src" and value)
        elif tag in {"p", "br", "li", "div"}:
            self.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"}:
            self.hidden = max(0, self.hidden - 1)
        elif tag in {"p", "li", "div"}:
            self.parts.append(" ")

    def handle_data(self, data: str) -> None:
        if not self.hidden:
            self.parts.append(data)


def plain_text(value: str, limit: int = 1500) -> str:
    parser = _PlainText()
    parser.feed(str(value)[:20000])
    return " ".join("".join(parser.parts).split())[:limit]


def public_url(value: str, *, https_only: bool = False) -> str | None:
    """Syntactic display/link filter; actual fetches also use the guarded transport."""
    try:
        if not isinstance(value, str) or len(value) > 2048:
            return None
        parsed = urlsplit(str(value).strip())
        host = (parsed.hostname or "").rstrip(".").lower()
        port = parsed.port
        if parsed.scheme not in ({"https"} if https_only else {"http", "https"}):
            return None
        if parsed.username or parsed.password or not host or port not in {None, 80, 443}:
            return None
        if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
            return None
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            try:
                address = ipaddress.IPv4Address(socket.inet_aton(host))
            except OSError:
                address = None
            if address is not None and not address.is_global:
                return None
            if "." not in host or not re.fullmatch(r"[a-z0-9.-]+", host):
                return None
        else:
            if not address.is_global:
                return None
        if any(ord(character) < 32 for character in value):
            return None
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, parsed.query, ""))
    except (ValueError, TypeError):
        return None


def canonical_url(value: str) -> str:
    parsed = urlsplit(value)
    query = [
        (key, val)
        for key, val in parse_qsl(parsed.query, keep_blank_values=True)
        if not key.lower().startswith("utm_") and key.lower() not in TRACKING_PARAMETERS
    ]
    return urlunsplit(
        (parsed.scheme.lower(), parsed.netloc.lower(), parsed.path or "/", urlencode(query), "")
    )


def _published(entry: dict) -> tuple[datetime | None, str, str | None]:
    # Read the original publication string only. Feedparser's *_parsed tuples
    # lose timezone evidence and can silently interpret naive dates as UTC.
    raw = dict.get(entry, "published", "")
    if not isinstance(raw, str) or not raw.strip():
        return None, "", "missing_publication_date"
    raw = raw.strip()
    if len(raw) > 128:
        return None, raw[:128], "invalid_publication_date"
    date = None
    try:
        date = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        try:
            date = parsedate_to_datetime(raw)
        except (ValueError, OverflowError, TypeError):
            return None, raw, "invalid_publication_date"
    if date.tzinfo is None or date.utcoffset() is None:
        return None, raw, "publication_timezone_missing"
    try:
        return date.astimezone(UTC), raw, None
    except (ValueError, OverflowError):
        return None, raw, "invalid_publication_date"


def _image(entry: dict) -> str | None:
    candidates: list[str] = []
    for key in ("media_thumbnail", "media_content"):
        for media in entry.get(key, []):
            if media.get("medium", "image") == "image" and not str(
                media.get("type", "image/")
            ).startswith(("audio/", "video/")):
                candidates.append(media.get("url", ""))
    for enclosure in entry.get("enclosures", []):
        if str(enclosure.get("type", "")).startswith("image/"):
            candidates.append(enclosure.get("href", ""))
    parser = _PlainText()
    parser.feed(str(entry.get("summary", ""))[:20000])
    candidates.extend(parser.images)
    return next((safe for item in candidates if (safe := public_url(item, https_only=True))), None)


def check_news_xml(data: bytes) -> None:
    if not isinstance(data, bytes) or len(data) > MAX_FEED_BYTES:
        raise NewsError("新闻源内容过大或格式无效。", "oversized_feed")
    parser = expat.ParserCreate()
    depth = count = 0

    def start_element(name, attrs):
        nonlocal depth, count
        depth += 1
        count += 1
        if depth > 64 or count > 50_000:
            raise NewsError("新闻源结构超过解析上限。", "parse_limit")

    def end_element(name):
        nonlocal depth
        depth -= 1

    def reject_doctype(*args):
        raise NewsError("新闻源不支持 DTD 或自定义实体。", "unsafe_xml")

    parser.StartElementHandler = start_element
    parser.EndElementHandler = end_element
    parser.StartDoctypeDeclHandler = reject_doctype
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    try:
        parser.Parse(data, True)
    except expat.ExpatError:
        raise NewsError("新闻源没有返回有效的 XML。", "invalid_feed") from None


def parse_evidence(
    data: bytes,
    feed_url: str,
    fetched_at: datetime,
) -> tuple[list[Article], dict[str, int]]:
    check_news_xml(data)
    # feedparser treats even bytes as possible filenames; a stream is data only.
    parsed = feedparser.parse(io.BytesIO(data))
    if not parsed.get("version"):
        raise NewsError("新闻源没有返回有效的 RSS 或 Atom 内容。", "invalid_feed")
    fallback_source = plain_text(parsed.feed.get("title", ""), 200) or urlsplit(feed_url).hostname
    articles = []
    rejected: dict[str, int] = {}

    def reject(reason: str, count: int = 1) -> None:
        rejected[reason] = rejected.get(reason, 0) + count

    if len(parsed.entries) > MAX_ITEMS:
        reject("entry_limit", len(parsed.entries) - MAX_ITEMS)
    for entry in parsed.entries[:MAX_ITEMS]:
        title = plain_text(entry.get("title", ""), 500)
        url = public_url(urljoin(feed_url, entry.get("link", "")))
        if not title or not entry.get("link") or not url:
            reject("invalid_title_or_url")
            continue
        published, published_raw, date_error = _published(entry)
        # feedparser aliases .get("updated") to published on RSS. Only real
        # raw fields can establish an independent update timestamp.
        updated_raw = str(dict.get(entry, "updated", ""))[:200]
        updated, _, _ = _published({"published": updated_raw})
        raw_summary = str(entry.get("summary", ""))
        full_excerpt = plain_text(raw_summary, 20000)
        summary = full_excerpt[:1500]
        source_data = entry.get("source", {})
        source = plain_text(source_data.get("title", ""), 200) or fallback_source
        articles.append(
            Article(
                title=title,
                url=canonical_url(url),
                source=str(source),
                published_at=published,
                summary=summary,
                image_url=_image(entry),
                fetched_at=fetched_at,
                feed_url=feed_url,
                published_raw=published_raw,
                excerpt_truncated=len(raw_summary) > 20000 or len(full_excerpt) > len(summary),
                updated_at=updated,
                updated_raw=updated_raw,
                language=plain_text(entry.get("language") or parsed.feed.get("language", ""), 80),
                published_error=date_error or "",
            )
        )
    return articles, rejected


def eligible_articles(articles, now, max_age_hours=24):
    if type(max_age_hours) is not int or not 1 <= max_age_hours <= 720:
        raise ValueError("Invalid news time window")
    oldest = now - timedelta(hours=max_age_hours)
    accepted, rejected = [], {}
    for article in articles:
        reason = article.published_error
        if article.published_at is None:
            reason = reason or "missing_publication_date"
        elif article.published_at < oldest:
            reason = "outside_time_window"
        elif article.published_at > now:
            reason = "future_publication_date"
        if reason:
            rejected[reason] = rejected.get(reason, 0) + 1
        else:
            accepted.append(article)
    return accepted, rejected


def _parse_feed(data, feed_url, max_age_hours, now, fetched_at):
    articles, rejected = parse_evidence(data, feed_url, fetched_at)
    accepted, date_rejections = eligible_articles(articles, now, max_age_hours)
    for reason, count in date_rejections.items():
        rejected[reason] = rejected.get(reason, 0) + count
    return accepted, rejected


def parse_feed(data: bytes, feed_url: str, max_age_hours: int = 24) -> list[Article]:
    now = datetime.now(UTC)
    return _parse_feed(data, feed_url, max_age_hours, now, now)[0]


def _deduplicate(articles: list[Article], limit: int) -> list[Article]:
    seen_urls: set[str] = set()
    result = []
    minimum = datetime.min.replace(tzinfo=UTC)
    for article in sorted(articles, key=lambda item: item.published_at or minimum, reverse=True):
        url_key = canonical_url(article.url)
        if url_key in seen_urls:
            continue
        seen_urls.add(url_key)
        result.append(article)
        if len(result) >= limit:
            break
    return result


class NewsService:
    def __init__(
        self,
        feeds: list[str],
        language: str = "zh-CN",
        region: str = "US",
        max_age_hours: int = 24,
        topic_feeds: dict[str, list[str]] | None = None,
    ) -> None:
        if not 1 <= max_age_hours <= 720:
            raise ValueError("max_age_hours must be between 1 and 720")
        mapped_feeds = topic_feeds or {}
        all_feeds = set(feeds).union(url for urls in mapped_feeds.values() for url in urls)
        if len(all_feeds) > 20:
            raise ValueError("At most 20 RSS feeds can be configured")
        if any(not public_url(url, https_only=True) for url in all_feeds):
            raise ValueError("RSS feeds must use public HTTPS URLs")
        self.feeds = list(dict.fromkeys(feeds))
        self.topic_feeds = {
            topic.strip().casefold(): list(dict.fromkeys(urls))
            for topic, urls in mapped_feeds.items()
        }
        self.language = language
        self.region = region.upper()
        self.max_age_hours = max_age_hours
        self.last_failed_sources = 0
        self.last_report: RetrievalReport | None = None
        self._client = source_client(max_bytes=MAX_FEED_BYTES, deadline=30)
        self._semaphore = asyncio.Semaphore(5)

    def _search_url(self, query: str) -> str:
        return "https://news.google.com/rss/search?" + urlencode(
            {
                "q": f"{query[:300]} when:{self.max_age_hours}h",
                "hl": self.language,
                "gl": self.region,
                "ceid": f"{self.region}:{self.language}",
            }
        )

    async def _fetch(self, url: str, now: datetime) -> tuple[list[Article], SourceAttempt]:
        original_url = url
        method = "google_news_rss" if urlsplit(url).hostname == "news.google.com" else "rss"
        fetched_at = None
        http_status = None
        try:
            async with self._semaphore, asyncio.timeout(30):
                for _ in range(4):
                    async with self._client.stream("GET", url) as response:
                        http_status = response.status_code
                        if response.is_redirect:
                            target = urljoin(url, response.headers.get("location", ""))
                            if (
                                not public_url(target, https_only=True)
                                or target == url
                                or urlsplit(target).hostname != urlsplit(url).hostname
                            ):
                                raise NewsError("新闻源返回了不支持的重定向。", "redirect_rejected")
                            url = target
                            continue
                        response.raise_for_status()
                        content_length = response.headers.get("content-length", "0")
                        if content_length.isdigit() and int(content_length) > MAX_FEED_BYTES:
                            raise NewsError("新闻源内容过大。", "oversized_feed")
                        data = bytearray()
                        async for chunk in response.aiter_bytes(chunk_size=65536):
                            data.extend(chunk)
                            if len(data) > MAX_FEED_BYTES:
                                raise NewsError("新闻源内容过大。", "oversized_feed")
                        fetched_at = datetime.now(UTC)
                        articles, rejected = await asyncio.to_thread(
                            _parse_feed, bytes(data), url, self.max_age_hours, now, fetched_at
                        )
                        return articles, SourceAttempt(
                            original_url,
                            method,
                            "ok",
                            fetched_at,
                            None,
                            len(articles),
                            rejected,
                            http_status,
                        )
                raise NewsError("新闻源重定向次数过多。", "too_many_redirects")
        except httpx.HTTPStatusError as exc:
            http_status = exc.response.status_code
            error_kind = "http_error"
        except (httpx.TimeoutException, TimeoutError):
            error_kind = "timeout"
        except SafeHTTPError as exc:
            error_kind = exc.kind
        except httpx.RequestError:
            error_kind = "network_error"
        except NewsError as exc:
            error_kind = exc.kind
        except Exception:
            error_kind = "unexpected_error"
        return [], SourceAttempt(
            original_url, method, "error", fetched_at, error_kind, 0, {}, http_status
        )

    async def _collect(self, buckets: dict[str, list[str]], limit: int) -> list[Article]:
        started_at = datetime.now(UTC)
        urls = list(dict.fromkeys(url for sources in buckets.values() for url in sources))
        results = await asyncio.gather(*(self._fetch(url, started_at) for url in urls))
        source_results = dict(zip(urls, results, strict=True))
        articles = [article for items, _ in results for article in items]
        attempts = [attempt for _, attempt in results]
        unique = _deduplicate(articles, max(len(articles), 1))
        # One newest article from each topic per round; a busy source/topic must
        # not crowd every other topic out of a size-limited digest.
        topic_candidates = [
            iter(
                _deduplicate(
                    [article for url in sources for article in source_results[url][0]],
                    max(len(articles), 1),
                )
            )
            for sources in buckets.values()
        ]
        returned: list[Article] = []
        returned_urls: set[str] = set()
        while len(returned) < limit:
            previous_count = len(returned)
            for candidates in topic_candidates:
                candidate = next(
                    (item for item in candidates if item.url not in returned_urls), None
                )
                if candidate:
                    returned.append(candidate)
                    returned_urls.add(candidate.url)
                if len(returned) == limit:
                    break
            if len(returned) == previous_count:
                break
        self.last_failed_sources = sum(attempt.status == "error" for attempt in attempts)
        self.last_report = RetrievalReport(
            started_at=started_at,
            finished_at=datetime.now(UTC),
            attempts=attempts,
            accepted_articles=articles,
            returned_urls=[article.url for article in returned],
            deduplicated_count=len(articles) - len(unique),
            limited_count=len(unique) - len(returned),
            max_age_hours=self.max_age_hours,
            topic_buckets=buckets,
        )
        if attempts and self.last_failed_sources == len(attempts):
            raise NewsError("所有新闻源暂时不可用，请检查网络或 RSS 配置。", "all_sources_failed")
        return returned

    async def search(self, query: str, limit: int = 5) -> list[Article]:
        query = query.strip()
        if not query:
            raise ValueError("Search query must not be empty")
        if not 1 <= limit <= 50:
            raise ValueError("limit must be between 1 and 50")
        return await self._collect({query: [self._search_url(query)]}, limit)

    async def latest(self, topics: list[str], limit: int = 5) -> list[Article]:
        if not 1 <= limit <= 50:
            raise ValueError("limit must be between 1 and 50")
        topics = list(dict.fromkeys(topic.strip() for topic in topics if topic.strip()))[:10]
        buckets = {
            topic: self.topic_feeds.get(topic.casefold()) or [self._search_url(topic)]
            for topic in topics
        }
        if self.feeds:
            buckets["configured_rss"] = self.feeds
        if not buckets:
            buckets = {"news": [self._search_url("news")]}
        return await self._collect(buckets, limit)

    async def close(self) -> None:
        await self._client.aclose()
