import asyncio
import json
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from xml.sax.saxutils import escape

import httpx
import pytest

from newspaw.news import MAX_FEED_BYTES, Article, NewsError, NewsService, parse_feed, public_url


def rss(items: list[dict]) -> bytes:
    entries = []
    for item in items:
        date = item.get("date", datetime.now(UTC))
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


def mock_service(monkeypatch, feeds, handler, **kwargs):
    factory = httpx.AsyncClient
    transport = httpx.MockTransport(handler)
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda **kwargs: factory(**(kwargs | {"transport": transport}))
    )
    return NewsService(feeds, **kwargs)


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


def test_search_encodes_query_and_deduplicates_results(monkeypatch):
    requested = []

    def handler(request):
        requested.append(request)
        return httpx.Response(
            200,
            content=rss(
                [
                    {"url": "https://example.com/article?utm_source=one"},
                    {"url": "https://example.com/article?utm_source=two"},
                    {"title": "Another story", "url": "https://example.com/second"},
                ]
            ),
        )

    async def scenario():
        service = mock_service(monkeypatch, [], handler)
        try:
            result = await service.search("AI & 安全", 5)
            assert len(result) == 2
            assert requested[0].url.host == "news.google.com"
            assert requested[0].url.params["q"] == "AI & 安全 when:24h"
            report = service.last_report.to_dict()
            assert report["attempts"][0]["retrieval_method"] == "google_news_rss"
            assert report["deduplicated_count"] == 1
            assert len(report["accepted_articles"]) == 3
            assert len(report["returned_urls"]) == 2
            json.dumps(report)
        finally:
            await service.close()

    asyncio.run(scenario())


def test_one_failed_source_does_not_hide_successful_source(monkeypatch):
    def handler(request):
        return (
            httpx.Response(500)
            if request.url.host == "broken.example.com"
            else httpx.Response(200, content=rss([{}]))
        )

    async def scenario():
        service = mock_service(
            monkeypatch,
            ["https://broken.example.com/rss", "https://working.example.com/rss"],
            handler,
        )
        try:
            assert len(await service.latest([])) == 1
            assert service.last_failed_sources == 1
            attempts = service.last_report.attempts
            assert [attempt.status for attempt in attempts] == ["error", "ok"]
            assert attempts[0].http_status == 500
            assert attempts[0].error_kind == "http_error"
            assert attempts[1].accepted_count == 1
            assert attempts[1].fetched_at is not None
        finally:
            await service.close()

    asyncio.run(scenario())


@pytest.mark.parametrize("kind", ["http_error", "invalid_xml", "too_large", "private_redirect"])
def test_all_sources_failed_is_distinct_from_no_news(monkeypatch, kind):
    requests = []

    def handler(request):
        requests.append(request)
        if kind == "http_error":
            return httpx.Response(503)
        if kind == "invalid_xml":
            return httpx.Response(200, content=b"<html>Not a feed</html>")
        if kind == "too_large":
            return httpx.Response(200, content=b"x" * (MAX_FEED_BYTES + 1))
        return httpx.Response(302, headers={"Location": "https://127.0.0.1/private"})

    async def scenario():
        service = mock_service(monkeypatch, ["https://feed.example.com/rss"], handler)
        try:
            with pytest.raises(NewsError, match="所有新闻源"):
                await service.latest([])
            assert len(requests) == 1
            report = service.last_report.to_dict()
            attempt = report["attempts"][0]
            assert attempt["status"] == "error"
            assert (
                attempt["error_kind"]
                == {
                    "http_error": "http_error",
                    "invalid_xml": "invalid_feed",
                    "too_large": "oversized_feed",
                    "private_redirect": "redirect_rejected",
                }[kind]
            )
            if kind == "invalid_xml":
                assert attempt["fetched_at"] is not None
            assert report["accepted_articles"] == []
            json.dumps(report)
        finally:
            await service.close()

    asyncio.run(scenario())


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


def test_date_rejections_are_auditable(monkeypatch):
    now = datetime.now(UTC)
    body = rss(
        [
            {"title": "Missing", "published_raw": ""},
            {"title": "Naive", "published_raw": now.replace(tzinfo=None).isoformat()},
            {"title": "Old", "date": now - timedelta(hours=25)},
            {"title": "Future", "date": now + timedelta(seconds=30)},
            {"title": "Valid", "date": now - timedelta(hours=1)},
        ]
    )

    async def scenario():
        service = mock_service(
            monkeypatch, ["https://example.com/feed"], lambda _: httpx.Response(200, content=body)
        )
        try:
            result = await service.latest([])
            assert [article.title for article in result] == ["Valid"]
            assert service.last_report.attempts[0].rejected_counts == {
                "missing_publication_date": 1,
                "publication_timezone_missing": 1,
                "outside_time_window": 1,
                "future_publication_date": 1,
            }
            assert service.last_report.max_age_hours == 24
        finally:
            await service.close()

    asyncio.run(scenario())


def test_identical_titles_from_distinct_publishers_remain_evidence(monkeypatch):
    body = rss(
        [
            {"title": "Same headline", "url": "https://first.example/story", "source": "First"},
            {"title": "Same headline", "url": "https://second.example/story", "source": "Second"},
        ]
    )

    async def scenario():
        service = mock_service(monkeypatch, [], lambda _: httpx.Response(200, content=body))
        try:
            result = await service.search("headline")
            assert {article.source for article in result} == {"First", "Second"}
            assert service.last_report.deduplicated_count == 0
        finally:
            await service.close()

    asyncio.run(scenario())


def test_topic_source_mapping_balances_results_without_language_filter(monkeypatch):
    now = datetime.now(UTC)
    requested = []

    def handler(request):
        requested.append(request.url.host)
        if request.url.host == "world.example":
            body = rss(
                [
                    {
                        "title": f"World story {i}",
                        "url": f"https://world.example/{i}",
                        "date": now - timedelta(minutes=i + 1),
                    }
                    for i in range(6)
                ]
            )
        else:
            body = rss(
                [
                    {
                        "title": f"Japan story {i}",
                        "url": f"https://japan.example/{i}",
                        "date": now - timedelta(hours=i + 1),
                    }
                    for i in range(3)
                ]
            )
        return httpx.Response(200, content=body)

    async def scenario():
        service = mock_service(
            monkeypatch,
            [],
            handler,
            topic_feeds={
                "国际": ["https://world.example/feed"],
                "日本": ["https://japan.example/feed"],
            },
        )
        try:
            result = await service.latest(["国际", "日本"], limit=4)
            assert [article.title for article in result] == [
                "World story 0",
                "Japan story 0",
                "World story 1",
                "Japan story 1",
            ]
            assert set(requested) == {"world.example", "japan.example"}
            assert service.last_report.limited_count == 5
            assert all(
                attempt.retrieval_method == "rss" for attempt in service.last_report.attempts
            )
        finally:
            await service.close()

    asyncio.run(scenario())


def test_excerpt_hash_tracks_retained_evidence_and_truncation():
    article = parse_feed(rss([{"summary": "x" * 1700}]), "https://example.com/feed")[0]
    assert len(article.summary) == 1500
    assert article.excerpt_truncated is True
    assert len(article.content_sha256) == 64
    same = Article(article.title, article.url, article.source, summary=article.summary)
    changed = Article(article.title, article.url, article.source, summary="changed")
    assert article.content_sha256 == same.content_sha256
    assert article.content_sha256 != changed.content_sha256


def test_all_failed_attempts_preserved_without_exception_secrets(monkeypatch):
    def handler(request):
        if request.url.host == "first.example":
            raise httpx.ConnectError("token=do-not-store-this", request=request)
        return httpx.Response(403)

    async def scenario():
        service = mock_service(
            monkeypatch, ["https://first.example/rss", "https://second.example/rss"], handler
        )
        try:
            with pytest.raises(NewsError):
                await service.latest([])
            report = service.last_report.to_dict()
            assert [attempt["error_kind"] for attempt in report["attempts"]] == [
                "network_error",
                "http_error",
            ]
            assert service.last_failed_sources == 2
            assert "do-not-store-this" not in json.dumps(report)
            assert report["finished_at"] >= report["started_at"]
        finally:
            await service.close()

    asyncio.run(scenario())


def test_unmapped_topic_uses_labelled_google_rss_and_generic_feed_stays_explicit(monkeypatch):
    def handler(request):
        return httpx.Response(
            200,
            content=rss(
                [
                    {
                        "title": "Different language headline",
                        "url": f"https://{request.url.host}/article",
                    }
                ]
            ),
        )

    async def scenario():
        service = mock_service(monkeypatch, ["https://selected.example/rss"], handler)
        try:
            result = await service.latest(["国际"], limit=5)
            assert len(result) == 2
            methods = {attempt.retrieval_method for attempt in service.last_report.attempts}
            assert methods == {"rss", "google_news_rss"}
            assert service.last_report.topic_buckets["configured_rss"] == [
                "https://selected.example/rss"
            ]
        finally:
            await service.close()

    asyncio.run(scenario())


def test_empty_valid_feed_returns_no_news(monkeypatch):
    async def scenario():
        service = mock_service(
            monkeypatch,
            ["https://feed.example.com/rss"],
            lambda _: httpx.Response(200, content=rss([])),
        )
        try:
            assert await service.latest([]) == []
            assert service.last_failed_sources == 0
        finally:
            await service.close()

    asyncio.run(scenario())


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
