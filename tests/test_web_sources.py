import json
from contextlib import closing

import httpx
import pytest
from test_credentials import FakeKeychain
from test_evidence import NOW

from newspaw.connectors.web import WEB_SITES, WebCollector
from newspaw.credentials import CredentialManager
from newspaw.evidence import EvidenceStore
from newspaw.source_manager import SourceError, SourceManager
from newspaw.store import Store

ZAOBAO = "https://www.zaobao.com.sg/news/china"
CNN = "https://edition.cnn.com/sitemap/news.xml"
STORY = ZAOBAO + "/story20261107-1"
ARTICLE = {
    "@type": "NewsArticle",
    "headline": "Public headline",
    "description": "Public metadata only",
    "articleBody": "Never retained",
    "datePublished": NOW.isoformat(),
    "isAccessibleForFree": True,
    "inLanguage": "zh-Hans",
    "url": STORY,
}
HTML_HEADERS = {"Content-Type": "text/html; charset=utf-8"}
XML_HEADERS = {"Content-Type": "application/xml"}


def source(url=ZAOBAO, *, partition="normal", categories=("china",)):
    return {
        "id": "website",
        "name": "Public source",
        "url": url,
        "kind": "web",
        "partition": partition,
        "category_ids": list(categories),
        "enabled": False,
    }


def mock_client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def article_response(**overrides):
    return httpx.Response(
        200,
        headers=HTML_HEADERS,
        text=(
            '<html><head><script type="application/ld+json">'
            + json.dumps({**ARTICLE, **overrides})
            + "</script></head></html>"
        ),
    )


async def test_preview_enable_and_publisher_excerpt(tmp_path):
    requests = []

    def handler(request):
        requests.append(str(request.url))
        assert "cookie" not in request.headers and "authorization" not in request.headers
        if str(request.url) == ZAOBAO:
            return httpx.Response(
                200,
                headers={**HTML_HEADERS, "Set-Cookie": "session=blocked; Path=/"},
                text=f'<a href="{STORY}">story</a><a href="https://other.example/news">other</a>',
            )
        assert str(request.url) == STORY
        return article_response()

    with closing(Store(tmp_path / "state.db")) as store:
        manager = SourceManager(
            CredentialManager(store, FakeKeychain()), client_factory=lambda: mock_client(handler)
        )
        saved = source()
        await manager.save(saved, store.config_revision())
        with pytest.raises(SourceError, match="preview_required"):
            await manager.save({**saved, "enabled": True}, store.config_revision())
        preview = await manager.preview(saved["id"], now=NOW)
        assert preview["preview_ready"] and preview["health"]["latest_publication"]
        assert preview["attempt"]["coverage_complete"] is False
        evidence = preview["entries"][0]
        assert evidence["summary"] == "Public metadata only"
        assert (
            evidence["source"] == "联合早报"
            and evidence["evidence_scope"] == "public_metadata_excerpt"
        )
        assert evidence["eligible"] and "Never retained" not in json.dumps(preview)
        await manager.save({**saved, "enabled": True}, store.config_revision())
        assert requests == [ZAOBAO, STORY]


@pytest.mark.parametrize(
    "case,reason",
    [
        ("paywall", "access_restricted"),
        ("redirect", "redirect_rejected"),
        ("layout", "layout_changed"),
    ],
)
async def test_partial_or_restricted_page_is_visible(tmp_path, case, reason):
    requests = []

    def handler(request):
        requests.append(str(request.url))
        if str(request.url) == ZAOBAO:
            return httpx.Response(200, headers=HTML_HEADERS, text=f'<a href="{STORY}">story</a>')
        if case == "paywall":
            return article_response(isAccessibleForFree=False)
        if case == "redirect":
            return httpx.Response(302, headers={"Location": "https://outside.example/story"})
        return httpx.Response(200, headers=HTML_HEADERS, text="<h1>Unrecognized layout</h1>")

    with closing(Store(tmp_path / "state.db")) as store:
        rev, config = store.load_config()
        config["sources"] = [source()]
        store.save_config(config, expected_revision=rev)
        collector = WebCollector(EvidenceStore(store), client=mock_client(handler))
        try:
            attempt = (await collector.preview("website", now=NOW))[0]
        finally:
            await collector.close()
        assert reason in attempt["coverage_gaps"]
        assert not attempt["accepted_count"] and attempt["status"] == "failed"
        assert requests == [ZAOBAO, STORY]


async def test_cnn_sitemap_keeps_only_world_and_never_requests_article(tmp_path):
    def row(section):
        return f"""<url><loc>https://www.cnn.com/2026/11/07/{section}/story</loc>
        <news:news><news:publication><news:language>en</news:language></news:publication>
        <news:publication_date>{NOW.isoformat()}</news:publication_date>
        <news:title>Headline</news:title></news:news></url>"""

    data = (
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">'
        + row("world")
        + row("us")
        + row("europe")
        + "</urlset>"
    )

    def handler(request):
        assert str(request.url) == CNN
        return httpx.Response(200, headers=XML_HEADERS, text=data)

    with closing(Store(tmp_path / "state.db")) as store:
        rev, config = store.load_config()
        config["sources"] = [source(CNN, categories=("world",))]
        store.save_config(config, expected_revision=rev)
        collector = WebCollector(EvidenceStore(store), client=mock_client(handler))
        try:
            result = (await collector.preview("website", now=NOW))[0]
        finally:
            await collector.close()
        assert CNN in WEB_SITES and result["accepted_count"] == 2
        assert result["coverage_complete"] is False


async def test_pipeline_collects_supported_web_scope_before_editor(tmp_path):
    from test_routing import configured

    from newspaw.pipeline import Pipeline

    def handler(request):
        if str(request.url) == ZAOBAO:
            return httpx.Response(200, headers=HTML_HEADERS, text=f'<a href="{STORY}">story</a>')
        return article_response()

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        config["sources"] = [{**source(categories=("world",)), "enabled": True}]
        store.save_config(config, expected_revision=1)
        pipeline = Pipeline(
            store,
            FakeKeychain(),
            web_factory=lambda evidence: WebCollector(evidence, client=mock_client(handler)),
        )
        result = pipeline.create(
            sub["id"],
            "web",
            holds={"normal_primary": 100, "normal_backup": 100},
            now=NOW,
        )
        result = await pipeline.advance(result["job_id"], now=NOW)
        assert result["stage"] == "editing"
        assert len(result["attempt_ids"]) == 1
        attempt = EvidenceStore(store).attempt(result["attempt_ids"][0], partition="normal")
        assert attempt["evidence_scope"] == "public_metadata" and attempt["accepted_count"] == 1


async def test_web_cannot_be_previewed_after_adult_reclassification(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        manager = SourceManager(
            CredentialManager(store, FakeKeychain()),
            client_factory=lambda: pytest.fail("no ordinary web fetch for adult scope"),
        )
        await manager.save(source(partition="adult", categories=("av",)), store.config_revision())
        with pytest.raises(SourceError, match="unsupported_source"):
            await manager.preview("website", now=NOW)


@pytest.mark.parametrize("hold_before_landing", [True, False])
async def test_schedule_hold_stops_next_public_web_request(tmp_path, hold_before_landing):
    from test_routing import configured

    from newspaw.pipeline import Pipeline

    requests = []

    def handler(request):
        requests.append(str(request.url))
        assert str(request.url) == ZAOBAO
        return httpx.Response(200, headers=HTML_HEADERS, text=f'<a href="{STORY}">story</a>')

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        config["sources"] = [{**source(categories=("world",)), "enabled": True}]
        store.save_config(config, expected_revision=1)
        pipeline = Pipeline(
            store,
            FakeKeychain(),
            web_factory=lambda evidence: WebCollector(evidence, client=mock_client(handler)),
        )
        job = pipeline.create(
            sub["id"], "web", holds={"normal_primary": 100, "normal_backup": 100}, now=NOW
        )

        result = await pipeline.advance(
            job["job_id"],
            now=NOW,
            effect_guard=lambda: False if hold_before_landing or requests else None,
        )

        assert result["stage"] == "collecting" and not result["attempt_ids"]
        rows = store._db.execute("SELECT status,snapshot_id FROM feed_attempts").fetchall()
        assert rows == ([] if hold_before_landing else [("interrupted", None)])
        assert requests == ([] if hold_before_landing else [ZAOBAO])


def test_web_discovery_upgrade_preserves_x_directory_and_schedule(tmp_path):
    from newspaw.control import ControlServer
    from newspaw.migrations import DATABASE_VERSION

    path = tmp_path / "state.db"
    keys = FakeKeychain()
    with closing(Store(path)) as store:
        server = ControlServer(tmp_path, CredentialManager(store, keys))
        server.x.add_list("456", "normal", store.config_revision())
        policy = server.scheduler.policy()
        policy["settings"].update(enabled=True, holds={"normal": 100, "adult": None})
        expected = server.scheduler.configure(policy["settings"], policy["revision"], now=NOW)
        with store._write():
            store._db.execute("DROP TABLE web_search_requests")
            store._db.execute("DROP TABLE web_search_policy")
            store._db.execute("PRAGMA user_version=15")

    with closing(Store(path)) as store:
        server = ControlServer(tmp_path, CredentialManager(store, keys))
        assert store._db.execute("PRAGMA user_version").fetchone() == (DATABASE_VERSION,)
        assert server.x.list_status("456")["id"] == "456"
        assert server.scheduler.policy() == expected
        assert server.web_search.policy()["profile_id"] is None
