"""Bounded RSS/Atom parsing with source attribution and no article-page scraping.

Pure parsing helpers shared by the collectors; this module performs no network I/O.
"""

from __future__ import annotations

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
from xml.etree import ElementTree
from xml.parsers import expat

import feedparser

MAX_FEED_BYTES = 2 * 1024 * 1024
MAX_ITEMS = 200
TRACKING_PARAMETERS = {"fbclid", "gclid", "mc_cid", "mc_eid"}


def known_av_origin(url):
    if not isinstance(url, str):
        return False
    try:
        host = (urlsplit(url).hostname or "").rstrip(".").lower()
    except ValueError:
        return False
    return host == "fiu758.com" or host.endswith(".fiu758.com")


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
    image_credit: str = ""

    @property
    def content_sha256(self) -> str:
        """Hash the retained title/excerpt snapshot, not a proof of truth."""
        values = [self.title, self.summary]
        if self.metadata:
            values.append(self.metadata)
        payload = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


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


def _media_credits(data):
    """Keep a credit only when the publisher attaches it directly to the image URL."""
    namespace = "{http://search.yahoo.com/mrss/}"
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        return {}
    by_url = {}
    for content in root.iter(namespace + "content"):
        declared = content.get("type")
        if content.get("medium", "image") != "image" or (
            declared and not declared.startswith("image/")
        ):
            continue
        image_url = public_url(content.get("url", ""), https_only=True)
        if image_url is None:
            continue
        if image_url in by_url:
            by_url[image_url] = []
            continue
        by_url[image_url] = [
            text
            for credit in content.findall(namespace + "credit")
            if (text := plain_text("".join(credit.itertext()), 150))
        ]
    return {url: names[0] for url, names in by_url.items() if len(names) == 1}


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
    data: bytes, feed_url: str, fetched_at: datetime
) -> tuple[list[Article], dict[str, int]]:
    if known_av_origin(feed_url):
        raise NewsError("此来源需要成人产业采集适配器。", "adult_source_requires_adapter")
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
    entries = parsed.entries[:MAX_ITEMS]
    credits = _media_credits(data) if any(entry.get("media_credit") for entry in entries) else {}
    for entry in entries:
        title = plain_text(entry.get("title", ""), 500)
        url = public_url(urljoin(feed_url, entry.get("link", "")))
        if not title or not entry.get("link") or not url:
            reject("invalid_title_or_url")
            continue
        if known_av_origin(url):
            reject("adult_source_requires_adapter")
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
        image_url = _image(entry)
        if known_av_origin(image_url):
            image_url = None
        articles.append(
            Article(
                title=title,
                url=canonical_url(url),
                source=str(source),
                published_at=published,
                summary=summary,
                image_url=image_url,
                image_credit=credits.get(image_url, ""),
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
