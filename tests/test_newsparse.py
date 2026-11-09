from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from xml.sax.saxutils import escape

import pytest

from newspaw.newsparse import Article, NewsError, eligible_articles, parse_evidence, public_url


def parse_feed(data: bytes, feed_url: str, max_age_hours: int = 24) -> list[Article]:
    now = datetime.now(UTC)
    articles, _ = parse_evidence(data, feed_url, now)
    return eligible_articles(articles, now, max_age_hours)[0]


def rss(items: list[dict]) -> bytes:
    entries = []
    for item in items:
        date = item.get("date", datetime.now(UTC) - timedelta(minutes=1))
        published_raw = item.get("published_raw", format_datetime(date) if date else "")
        date_element = f"<pubDate>{escape(published_raw)}</pubDate>" if published_raw else ""
        entries.append(
            "<item>"
            f"<title>{escape(item.get('title', 'New launch'))}</title>"
            f"<link>{escape(item.get('url', 'https://example.com/article'))}</link>"
            f"<description>{escape(item.get('summary', 'Short summary'))}</description>"
            f"<source>{escape(item.get('source', 'Original publisher'))}</source>"
            f"{date_element}"
            "</item>"
        )
    return (
        '<?xml version="1.0"?><rss version="2.0"><channel><title>My feed</title>'
        + "".join(entries)
        + "</channel></rss>"
    ).encode()


def test_feed_preserves_source_dates_and_safe_image():
    articles = parse_feed(
        rss(
            [
                {
                    "title": "<b>New & useful</b>",
                    "url": "https://example.com/article?utm_source=email&id=7#top",
                    "summary": '<p>Useful summary</p><img src="https://images.example.com/a.jpg">',
                },
                {
                    "title": "Old item",
                    "url": "https://example.com/old",
                    "date": datetime.now(UTC) - timedelta(days=10),
                },
            ]
        ),
        "https://example.com/feed",
        48,
    )
    assert len(articles) == 1
    article = articles[0]
    assert article.title == "New & useful"
    assert article.url == "https://example.com/article?id=7"
    assert article.source == "Original publisher"
    assert article.summary == "Useful summary"
    assert article.published_at.tzinfo == UTC
    assert article.image_url == "https://images.example.com/a.jpg"
    assert article.feed_url == "https://example.com/feed"
    assert article.fetched_at.tzinfo == UTC
    assert article.published_raw


@pytest.mark.parametrize(
    "url",
    [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "https://localhost/a",
        "https://127.0.0.1/a",
        "https://127.1/a",
        "https://0x7f.0.0.1/a",
        "https://[::1]/a",
        "https://10.0.0.3/a",
        "https://foo.internal/a",
        "https://user:password@example.com/a",
        "https://example.com:9999/a",
    ],
)
def test_rejects_local_and_unsafe_urls(url):
    assert public_url(url, https_only=True) is None


@pytest.mark.parametrize("published_raw", ["", "not a date", "2026-11-07T12:00:00"])
def test_missing_invalid_or_timezone_free_publication_dates_are_rejected(published_raw):
    assert parse_feed(rss([{"published_raw": published_raw}]), "https://example.com/feed") == []


def test_original_publication_never_falls_back_to_atom_updated():
    updated = datetime.now(UTC).isoformat()
    atom = (
        '<feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>'
        '<entry><title>Updated but undated</title><link href="https://example.com/1"/>'
        f"<updated>{updated}</updated></entry>"
        '<entry><title>Naive publication plus update</title><link href="https://example.com/2"/>'
        f"<published>{updated[:19]}</published><updated>{updated}</updated></entry></feed>"
    ).encode()
    assert parse_feed(atom, "https://example.com/feed") == []


def test_excerpt_hash_tracks_retained_evidence_and_truncation():
    article = parse_feed(rss([{"summary": "x" * 1700}]), "https://example.com/feed")[0]
    assert len(article.summary) == 1500
    assert article.excerpt_truncated is True
    assert len(article.content_sha256) == 64
    same = Article(article.title, article.url, article.source, summary=article.summary)
    changed = Article(article.title, article.url, article.source, summary="changed")
    assert article.content_sha256 == same.content_sha256
    assert article.content_sha256 != changed.content_sha256


def test_feed_bytes_are_never_interpreted_as_local_file_path(tmp_path):
    private = tmp_path / "private-feed.xml"
    private.write_bytes(rss([{"title": "must-not-read"}]))
    with pytest.raises(NewsError):
        parse_feed(str(private).encode(), "https://example.com/rss")


def test_feed_parser_rejects_doctype_in_utf16_and_excessive_nesting():
    payload = '<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE rss [<!ENTITY x "private">]><rss version="2.0"><channel><title>&x;</title></channel></rss>'
    with pytest.raises(NewsError):
        parse_feed(payload.encode("utf-16"), "https://example.com/rss")
    with pytest.raises(NewsError):
        parse_feed(b"<rss>" + b"<x>" * 70 + b"</x>" * 70 + b"</rss>", "https://example.com/rss")
