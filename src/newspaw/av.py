"""Opt-in AV industry metadata collection, isolated from general-news discovery.

This collector neither assesses publisher claims nor generates/publishes content.
It uses the same strict publication evidence rules as general news, retains only
text metadata, and never falls back to a general search provider.
"""

from __future__ import annotations

from dataclasses import dataclass, field, fields, replace

from newspaw.news import Article, NewsService, RetrievalReport

# The publisher's /feed/ URL returned 404 during integration. This standard
# WordPress RSS endpoint returned valid RSS 2.0; HTML scraping is unnecessary.
DEFAULT_AV_FEEDS = ("https://fiu758.com/?feed=rss2",)
MAX_AV_ITEMS = 10


@dataclass(frozen=True)
class AVRetrievalReport(RetrievalReport):
    requested_topics: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        report = super().to_dict()
        report.update(
            {
                "pipeline": "av",
                "content_scope": "publisher_industry_metadata",
                "source_claims_verified": False,
                "media_policy": "text_only",
                "requested_topics": list(self.requested_topics),
                "topic_filter_applied": False,
            }
        )
        return report


class AVNewsService:
    """Collect explicitly configured industry feeds only when invoked.

    ``topics`` is recorded as request context for the downstream editorial model;
    it does not broaden sources or claim a multilingual keyword search happened.
    The caller owns opt-in settings, separate delivery receipts, and publication.
    """

    def __init__(self, feeds: list[str] | None = None, max_age_hours: int = 24) -> None:
        selected_feeds = list(DEFAULT_AV_FEEDS) if feeds is None else list(feeds)
        if not selected_feeds:
            raise ValueError("AV collection requires at least one explicitly configured RSS feed")
        self.feeds = list(dict.fromkeys(selected_feeds))
        self.max_age_hours = max_age_hours
        self._news = NewsService(feeds=self.feeds, max_age_hours=max_age_hours)
        self.last_report: AVRetrievalReport | None = None
        self.last_failed_sources = 0

    async def latest(self, topics: list[str] | None = None, limit: int = 6) -> list[Article]:
        if not 1 <= limit <= MAX_AV_ITEMS:
            raise ValueError(f"AV limit must be between 1 and {MAX_AV_ITEMS}")
        requested_topics = list(
            dict.fromkeys(topic.strip()[:300] for topic in (topics or []) if topic.strip())
        )[:10]
        self.last_report = None
        try:
            # Nonempty configured feeds and no topics prevent Google's discovery
            # branch in NewsService.latest, including when publishers fail.
            articles = await self._news.latest([], limit=limit)
            return [replace(article, image_url=None) for article in articles]
        finally:
            self.last_failed_sources = self._news.last_failed_sources
            original = self._news.last_report
            if original is not None:
                text_only = replace(
                    original,
                    accepted_articles=[
                        replace(article, image_url=None) for article in original.accepted_articles
                    ],
                )
                self.last_report = AVRetrievalReport(
                    **{
                        item.name: getattr(text_only, item.name) for item in fields(RetrievalReport)
                    },
                    requested_topics=requested_topics,
                )

    async def close(self) -> None:
        await self._news.close()
