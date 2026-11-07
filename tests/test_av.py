import asyncio
import json
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from xml.sax.saxutils import escape

import httpx
import pytest

from newspaw.av import DEFAULT_AV_FEEDS, AVNewsService
from newspaw.news import NewsError


def rss(items: list[dict]) -> bytes:
    entries = []
    for item in items:
        publication = item.get("published", format_datetime(datetime.now(UTC) - timedelta(hours=1)))
        publication_tag = f"<pubDate>{escape(publication)}</pubDate>" if publication else ""
        entries.append(
            "<item>"
            f"<title>{escape(item.get('title', 'Industry platform announcement'))}</title>"
            f"<link>{escape(item.get('url', 'https://industry.example/announcement'))}</link>"
            f"<description>{escape(item.get('summary', 'A publisher announced a distribution agreement.'))}</description>"
            f"{publication_tag}"
            "</item>"
        )
    return (
        '<rss version="2.0"><channel><title>Industry publisher</title>'
        + "".join(entries)
        + "</channel></rss>"
    ).encode()


def service_with_transport(monkeypatch, handler, feeds=None, **kwargs):
    factory = httpx.AsyncClient
    transport = httpx.MockTransport(handler)
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda **options: factory(transport=transport, **options)
    )
    return AVNewsService(feeds, **kwargs)


def test_dedicated_service_has_no_network_effect_until_invoked(monkeypatch):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, content=rss([{}]))

    async def scenario():
        service = service_with_transport(monkeypatch, handler)
        try:
            assert requests == []
            assert service.feeds == list(DEFAULT_AV_FEEDS)
            assert service.last_report is None
            await service.latest()
            assert [str(request.url) for request in requests] == list(DEFAULT_AV_FEEDS)
        finally:
            await service.close()

    asyncio.run(scenario())


def test_av_evidence_strips_images_and_marks_unverified_separate_pipeline(monkeypatch):
    body = rss(
        [
            {
                "summary": '<p>Industry platform update.</p><img src="https://industry.example/image.jpg">'
            }
        ]
    )

    async def scenario():
        service = service_with_transport(
            monkeypatch,
            lambda _: httpx.Response(200, content=body),
            ["https://industry.example/rss"],
        )
        try:
            articles = await service.latest(["发行动态"])
            assert len(articles) == 1
            assert articles[0].image_url is None
            assert articles[0].summary == "Industry platform update."
            report = service.last_report.to_dict()
            assert report["pipeline"] == "av"
            assert report["media_policy"] == "text_only"
            assert report["source_claims_verified"] is False
            assert report["requested_topics"] == ["发行动态"]
            assert report["topic_filter_applied"] is False
            assert report["accepted_articles"][0]["image_url"] is None
            assert "image.jpg" not in json.dumps(report)
            assert report["accepted_articles"][0]["published_raw"]
            assert len(report["accepted_articles"][0]["content_sha256"]) == 64
        finally:
            await service.close()

    asyncio.run(scenario())


def test_av_rejects_missing_naive_stale_future_dates(monkeypatch):
    now = datetime.now(UTC)
    body = rss(
        [
            {"title": "Undated announcement", "published": ""},
            {"title": "Naive date", "published": now.replace(tzinfo=None).isoformat()},
            {
                "title": "Older announcement",
                "published": format_datetime(now - timedelta(hours=25)),
            },
            {
                "title": "Future announcement",
                "published": format_datetime(now + timedelta(hours=1)),
            },
            {
                "title": "Current announcement",
                "published": format_datetime(now - timedelta(hours=2)),
            },
        ]
    )

    async def scenario():
        service = service_with_transport(
            monkeypatch,
            lambda _: httpx.Response(200, content=body),
            ["https://industry.example/rss"],
        )
        try:
            articles = await service.latest()
            assert [article.title for article in articles] == ["Current announcement"]
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


def test_source_failure_preserves_report_and_never_invokes_generic_search(monkeypatch):
    requests = []

    def handler(request):
        requests.append(str(request.url))
        return httpx.Response(503)

    async def scenario():
        feeds = ["https://industry.example/rss", "https://publisher.example/rss"]
        service = service_with_transport(monkeypatch, handler, feeds)
        try:
            with pytest.raises(NewsError):
                await service.latest(["industry news"])
            assert requests == feeds
            assert service.last_failed_sources == 2
            report = service.last_report.to_dict()
            assert report["pipeline"] == "av"
            assert len(report["attempts"]) == 2
            assert all(attempt["status"] == "error" for attempt in report["attempts"])
            assert all(attempt["retrieval_method"] == "rss" for attempt in report["attempts"])
            assert report["accepted_articles"] == []
        finally:
            await service.close()

    asyncio.run(scenario())


def test_default_and_maximum_result_limits(monkeypatch):
    body = rss(
        [
            {"title": f"Industry announcement {index}", "url": f"https://industry.example/{index}"}
            for index in range(15)
        ]
    )

    async def scenario():
        service = service_with_transport(
            monkeypatch,
            lambda _: httpx.Response(200, content=body),
            ["https://industry.example/rss"],
        )
        try:
            assert len(await service.latest()) == 6
            assert service.last_report.limited_count == 9
            assert len(await service.latest(limit=10)) == 10
            for invalid in (0, 11):
                with pytest.raises(ValueError, match="AV limit"):
                    await service.latest(limit=invalid)
        finally:
            await service.close()

    asyncio.run(scenario())


def test_explicitly_empty_sources_are_not_replaced_with_general_news():
    with pytest.raises(ValueError, match="explicitly configured RSS"):
        AVNewsService([])
