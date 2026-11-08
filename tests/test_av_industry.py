from types import SimpleNamespace

import httpx
import pytest
from test_evidence import NOW
from test_outbox import system as outbox_system
from test_routing import configured

from newspaw.bot import NewsBot
from newspaw.evidence import feed_scopes
from newspaw.news import Article, NewsService

legacy_edition = outbox_system


def test_known_publisher_never_enters_the_generic_rss_scope():
    config, sub = configured()
    config["sources"][0]["url"] = "https://fiu758.com/?feed=rss2"
    assert feed_scopes(config, [sub["id"]]) == []


async def test_legacy_fetch_does_not_access_known_adult_origin():
    observed = []

    def handler(request):
        observed.append(request)
        return httpx.Response(200, content=b"fixture")

    news = NewsService(["https://fiu758.com/?feed=rss2"])
    await news._client.aclose()
    news._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        articles, attempt = await news._fetch("https://fiu758.com/?feed=rss2", NOW)
    finally:
        await news.close()
    assert not articles and not observed
    assert attempt.error_kind == "adult_source_requires_adapter"


async def test_legacy_delivery_excludes_known_origin_before_model_or_raw_card():
    effects = []

    async def summarize(*args, **kwargs):
        effects.append("ordinary_model")
        return ""

    async def send_message(*args, **kwargs):
        effects.append("raw_card")

    legacy = SimpleNamespace(
        ai=SimpleNamespace(enabled=True, summarize=summarize),
        settings=SimpleNamespace(timezone="UTC"),
        voice_enabled=False,
    )
    bot = SimpleNamespace(send_message=send_message)
    article = Article("Synthetic industry announcement", "https://fiu758.com/?p=123", "Fixture")
    await NewsBot.deliver(legacy, bot, 123, [article])
    assert not effects


@pytest.mark.parametrize("hold", [False, True])
async def test_av_parser_uses_exact_adult_source_no_media_and_respects_hold(tmp_path, hold):
    from contextlib import closing

    from newspaw.connectors.av import AVCollector
    from newspaw.evidence import EvidenceStore
    from newspaw.store import Store

    url = "https://fiu758.com/"
    detail = url + "?p=123"
    seen = []

    def respond(request):
        seen.append(str(request.url))
        if str(request.url) == url:
            return httpx.Response(
                200,
                headers={"Content-Type": "text/html"},
                text=f'''<article id="post-123"><h2 class="post-title">
                    <a href="{detail}">FANZA の発売情報</a></h2>
                    <div class="entry excerpt"><p>FANZA の発売が発表されました。</p></div>
                    <div class="post-meta"><time datetime="{NOW.isoformat()}"></time></div>
                    <img src="https://fiu758.com/photo.jpg"></article>''',
            )
        assert str(request.url) == detail
        return httpx.Response(
            200,
            headers={"Content-Type": "text/html"},
            text=f'''<html><head><link rel="canonical" href="{detail}">
            <meta property="article:published_time" content="{NOW.isoformat()}">
            </head><body><article id="post-123"><p>Do not collect this body.</p></article></body></html>''',
        )

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        config["sources"][0].update(url=url, kind="web", name="AV研究所")
        store.save_config(config, expected_revision=1)
        evidence = EvidenceStore(store)
        collector = AVCollector(
            evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(respond))
        )
        try:
            result = await collector.collect(
                [sub["id"]], now=NOW, before_request=lambda: False if hold and seen else None
            )
        finally:
            await collector.close()
        if hold:
            assert result is None and seen == [url]
        else:
            assert seen == [url, detail] and result["accepted_count"] == 1
            rows = evidence.articles(result["id"], partition="adult", source_id="feed1", now=NOW)
            assert rows[0].metadata["av_industry"]["topic"] == "release"
            assert rows[0].image_url is None
            assert "Do not collect this body" not in "\n".join(store._db.iterdump())


@pytest.mark.parametrize(
    ("locale", "scenario"),
    [
        ("zh-Hans", "ok"),
        ("en", "ok"),
        ("ja", "ok"),
        ("en", "backup"),
        ("en", "refusal"),
        ("en", "unknown"),
        ("en", "all_failed"),
    ],
)
async def test_av_brief_dispatch_uses_only_adult_provider_and_controlled_copy(
    tmp_path, locale, scenario
):
    import json
    from contextlib import closing

    from test_editorial import service
    from test_model_runner import response

    from newspaw.connectors.av import AV_ORIGIN, AVCollector
    from newspaw.pipeline import Pipeline, PipelineError
    from newspaw.providers import ProfileRegistry
    from newspaw.store import Store

    detail = AV_ORIGIN + "?p=123"
    excerpt = "FANZA の発売が発表されました。"

    def website(request):
        if str(request.url) == AV_ORIGIN:
            html = (
                f'<article id="post-123"><h2 class="post-title"><a href="{detail}">'
                'FANZA の発売情報</a></h2><div class="entry excerpt"><p>'
                + excerpt
                + "</p></div></article>"
            )
        else:
            assert str(request.url) == detail
            html = (
                f'<link rel="canonical" href="{detail}">'
                f'<meta property="article:published_time" content="{NOW.isoformat()}">'
            )
        return httpx.Response(200, headers={"Content-Type": "text/html"}, text=html)

    def model(request):
        host = request.url.host
        assert host in {"api.deepseek.com", "api.x.ai"}
        if scenario in {"backup", "all_failed"} and (
            host == "api.deepseek.com" or scenario == "all_failed"
        ):
            return httpx.Response(401, json={"error": {"code": "fixture"}})
        if scenario == "refusal":
            return httpx.Response(
                200,
                json={
                    **response(),
                    "output": [{"type": "message", "content": [{"type": "refusal"}]}],
                },
            )
        if scenario == "unknown":
            raise httpx.ReadTimeout("fixture response lost")
        body = json.loads(request.content)
        inputs = json.loads(body["input"][0]["content"][0]["text"])
        evidence = inputs["evidence"][0]
        assert evidence["excerpt"] == excerpt and inputs["locale"] == locale
        title, copy = evidence["allowed_copy"]
        identity = evidence["id"]
        result = dict(
            locale=locale,
            conflicts=[],
            items=[
                dict(
                    anchor=identity,
                    evidence_ids=[identity],
                    title=title,
                    body=copy,
                    kind="report",
                    stage="unknown",
                    support=[dict(evidence_id=identity, quote=excerpt)],
                    entities=[],
                )
            ],
        )
        return httpx.Response(200, json=response(json.dumps(result, ensure_ascii=False)))

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        config["news_output_locale"] = locale
        config["sources"][0].update(url=AV_ORIGIN, kind="web", name="Renamed local publisher")
        store.save_config(config, expected_revision=1)
        registry = ProfileRegistry(store)
        holds = {"adult_primary": 100, "adult_backup": 100}
        for profile in holds:
            registry.begin("verify." + profile, profile, "text", 1)
            registry.finish("verify." + profile, {"status": "verified"})
        editor, calls = service(store, handler=model)
        pipeline = Pipeline(
            store,
            editor.runner.backend,
            runner=editor.runner,
            av_factory=lambda evidence: AVCollector(
                evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(website))
            ),
        )
        job = pipeline.create(sub["id"], "daily", holds=holds, task_limit=500, now=NOW)["job_id"]
        for _ in range(6):
            result = await pipeline.advance(job, now=NOW)
        hosts = [call.url.host for call in calls]
        if scenario in {"refusal", "unknown", "all_failed"}:
            expected = {
                "refusal": "refused",
                "unknown": "outcome_unknown",
                "all_failed": "blocked",
            }
            assert result["status"] == expected[scenario]
            assert hosts == ["api.deepseek.com"] + (
                ["api.x.ai"] if scenario == "all_failed" else []
            )
            with pytest.raises(PipelineError, match="edition_not_ready"):
                pipeline.delivery_input(job)
            return
        assert result["stage"] == "awaiting_delivery", result
        assert hosts == ["api.deepseek.com"] + (["api.x.ai"] if scenario == "backup" else [])
        _, text, media = pipeline.delivery_input(job)
        assert detail in text and excerpt not in text and media["style"] == "text"
        if locale == "en":
            assert "API and downloads" not in text

        edition = pipeline.editorial.get(result["edition_id"])["result"]
        edition.pop("av_contract")
        with store._write():
            store._db.execute(
                "UPDATE editorial_editions SET result_json=? WHERE id=?",
                (json.dumps(edition, ensure_ascii=False), result["edition_id"]),
            )
        with pytest.raises(PipelineError, match="edition_changed"):
            pipeline.delivery_scope(job)


def test_av_validator_rejects_non_template_even_when_the_quote_is_grounded():
    from newspaw.editorial import BriefValidator, EditorialError

    evidence = [
        dict(
            id="e1",
            title="発売ニュース",
            excerpt="発売が発表されました。",
            source="AV研究所",
            url="https://fiu758.com/?p=123",
            metadata={"av_industry": {"topic": "release", "brand": None}},
        ),
    ]
    invalid = dict(
        locale="en",
        conflicts=[],
        items=[
            dict(
                anchor="e1",
                evidence_ids=["e1"],
                title="News about a publisher",
                body="This is a fluent but unrestricted model summary.",
                kind="report",
                stage="unknown",
                support=[dict(evidence_id="e1", quote="発売が発表されました。")],
                entities=[],
            )
        ],
    )
    with pytest.raises(EditorialError, match="av_industry_template_required"):
        BriefValidator(evidence, "en", 5, av_industry=True).validate(invalid)


def test_old_known_origin_article_is_excluded_from_non_av_adult_pool(tmp_path):
    from contextlib import closing

    from test_editorial import service

    from newspaw.evidence import EvidenceStore
    from newspaw.store import Store

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        category = next(row for row in config["categories"] if row["id"] == "av")
        category["id"] = sub["category_id"] = "adult_fixture"
        config["sources"][0]["category_ids"] = ["adult_fixture"]
        store.save_config(config, expected_revision=1)
        scope = feed_scopes(config, [sub["id"]])[0]
        evidence = EvidenceStore(store)
        attempt = evidence.begin(scope, NOW)
        article = Article(
            "Synthetic old AV title",
            "https://fiu758.com/?p=123",
            "AV研究所",
            NOW,
            "Synthetic original",
            fetched_at=NOW,
            feed_url="https://fiu758.com/?feed=rss2",
        )
        evidence.finish(
            attempt,
            scope,
            {"status": "fresh", "accepted_count": 1},
            NOW,
            articles=[article],
            rejected={},
            cache=False,
        )
        editor, _ = service(store)
        pool, _, _ = editor._pool(store.preview_route(sub["id"]), [attempt], NOW)
        assert pool == []


@pytest.mark.parametrize("legacy_edition", ["adult"], indirect=True)
@pytest.mark.parametrize("path", ["model", "delivery"])
async def test_old_deduplicated_alias_denies_both_model_submit_and_delivery(
    legacy_edition, path, monkeypatch
):
    import json

    from newspaw.editorial import EditorialError
    from newspaw.pipeline import PipelineError

    pipeline, _, job, model_calls, _ = legacy_edition
    edition = pipeline._edition_id(job)
    row = pipeline.editorial._row(edition)
    anchor = row["payload"]["pool"][0]
    assert not anchor["url"].startswith("https://fiu758.com")
    anchor["sources"].append(
        dict(source="AV研究所", url="https://fiu758.com/?p=123", published_at=NOW.isoformat())
    )
    with pipeline.store._write():
        pipeline.db.execute(
            "UPDATE editorial_editions SET payload=? WHERE id=?",
            (json.dumps(row["payload"], ensure_ascii=False), edition),
        )
    if path == "model":
        submits = []
        monkeypatch.setattr(
            pipeline.editorial.runner, "submit", lambda *args, **kwargs: submits.append(args)
        )
        with pytest.raises(EditorialError, match="av_edition_requires_rebuild"):
            pipeline.editorial._submit(pipeline.editorial._row(edition))
        assert not submits
    else:
        with pytest.raises(PipelineError, match="edition_changed"):
            pipeline.delivery_scope(job)
    assert len(model_calls) == 1


@pytest.mark.parametrize(
    ("scenario", "status", "gap", "terminal"),
    [
        ("empty", "no_eligible", "no_matching_candidates", "no_news"),
        ("stale", "stale", "outside_time_window", "no_news"),
        ("missing", "no_eligible", "missing_publication_date", "no_news"),
        ("naive", "no_eligible", "invalid_publication_date", "no_news"),
        ("conflict", "no_eligible", "conflicting_publication_date", "no_news"),
        ("future", "no_eligible", "future_publication_date", "no_news"),
        ("unavailable", "failed", "http_error", "collection_failed"),
        ("wrong_identity", "failed", "article_identity_mismatch", "collection_failed"),
    ],
)
async def test_av_collection_distinguishes_empty_stale_and_detail_failure(
    tmp_path, scenario, status, gap, terminal
):
    from contextlib import closing
    from datetime import timedelta

    from test_credentials import FakeKeychain
    from test_editorial import service

    from newspaw.connectors.av import AV_ORIGIN, AVCollector
    from newspaw.credentials import CredentialManager
    from newspaw.pipeline import Pipeline
    from newspaw.providers import ProfileRegistry
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store

    url = AV_ORIGIN + "?p=123"
    headers = {"Content-Type": "text/html"}

    def website(request):
        if str(request.url) == AV_ORIGIN:
            if scenario == "empty":
                return httpx.Response(200, headers=headers, text="<html></html>")
            date = (
                f'<div class="post-meta"><time itemprop="datePublished" datetime="{NOW.isoformat()}"></time></div>'
                if scenario == "conflict"
                else ""
            )
            return httpx.Response(
                200,
                headers=headers,
                text=f'<article id="post-123"><h2 class="post-title"><a href="{url}">FANZA の発売情報</a></h2>{date}</article>',
            )
        assert str(request.url) == url
        if scenario == "unavailable":
            return httpx.Response(503)
        dates = {
            "stale": (NOW - timedelta(days=2)).isoformat(),
            "conflict": (NOW - timedelta(hours=1)).isoformat(),
            "naive": NOW.replace(tzinfo=None).isoformat(),
            "future": (NOW + timedelta(days=1)).isoformat(),
        }
        published = (
            f'<meta property="article:published_time" content="{dates[scenario]}">'
            if scenario in dates
            else ""
        )
        canonical = AV_ORIGIN + "?p=456" if scenario == "wrong_identity" else url
        return httpx.Response(
            200, headers=headers, text=f'<link rel="canonical" href="{canonical}">{published}'
        )

    def client():
        return httpx.AsyncClient(transport=httpx.MockTransport(website))

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        config["sources"][0].update(url=AV_ORIGIN, kind="web")
        store.save_config(config, expected_revision=1)
        profiles = ProfileRegistry(store)
        holds = {"adult_primary": 100, "adult_backup": 100}
        for profile in holds:
            profiles.begin("verify." + profile, profile, "text", 1)
            profiles.finish("verify." + profile, {"status": "verified"})
        editor, calls = service(store)
        pipeline = Pipeline(
            store,
            editor.runner.backend,
            runner=editor.runner,
            av_factory=lambda evidence: AVCollector(evidence, client=client()),
        )
        job = pipeline.create(sub["id"], "check", holds=holds, now=NOW)["job_id"]
        for _ in range(3):
            result = await pipeline.advance(job, now=NOW)
        assert result["stage"] == terminal
        assert not calls

        revision, document = store.load_config()
        source = document["sources"][0]
        source["enabled"] = False
        store.save_config(document, expected_revision=revision)
        manager = SourceManager(CredentialManager(store, FakeKeychain()), client_factory=client)
        preview = await manager.preview(source["id"], now=NOW)
        attempt = preview["attempt"]
        assert attempt["evidence_scope"] == "av_industry"
        assert attempt["status"] == status and gap in attempt["coverage_gaps"]
        assert (attempt["error_kind"] is not None) == (status == "failed")
        assert not attempt["accepted_count"]
        if scenario == "stale":
            assert preview["preview_ready"] and not preview["entries"][0]["eligible"]
            await manager.save(dict(source, enabled=True), store.config_revision())
            assert manager.list()[0]["source"]["enabled"]
        else:
            assert not preview["entries"] and not preview["preview_ready"]
