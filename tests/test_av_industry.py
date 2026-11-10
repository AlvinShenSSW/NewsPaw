import httpx
import pytest
from test_evidence import NOW
from test_outbox import system as outbox_system
from test_routing import configured

from newspaw.evidence import feed_scopes
from newspaw.newsparse import Article

legacy_edition = outbox_system


def test_known_publisher_never_enters_the_generic_rss_scope():
    config, sub = configured()
    config["sources"][0]["url"] = "https://fiu758.com/?feed=rss2"
    assert feed_scopes(config, [sub["id"]]) == []


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
async def test_av_brief_dispatch_uses_only_adult_provider_and_model_summary(
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
    summaries = {
        "zh-Hans": ("FANZA 公布新的发售消息", "据来源报道，FANZA 公布了一项发售消息。"),
        "en": ("FANZA announces a release", "FANZA announced a release, the source reports."),
        "ja": ("FANZA が発売を発表", "FANZA の発売が発表されたと報じられました。"),
    }
    overviews = {
        "zh-Hans": "本期最值得关注的是 FANZA 的发售消息。",
        "en": "The notable item today is a release announced by FANZA.",
        "ja": "本日は FANZA の発売発表が注目されます。",
    }
    headings = {"zh-Hans": "今日概览", "en": "Today at a glance", "ja": "本日の概要"}

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
        assert "allowed_copy" not in evidence
        title, copy = summaries[locale]
        identity = evidence["id"]
        result = dict(
            locale=locale,
            overview=overviews[locale],
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
                    entities=[dict(source="FANZA", translated="FANZA")],
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
        assert text.startswith(headings[locale] + "\n" + overviews[locale] + "\n\n1. ")
        assert summaries[locale][0] in text and summaries[locale][1] in text
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


def _av_evidence():
    return [
        dict(
            id="e1",
            title="浅野こころ 活動を一部休止",
            excerpt="浅野こころ が腰椎骨折のため活動を一部休止すると発表しました。",
            source="Feed",
            url="https://example.com/a",
        ),
        dict(
            id="e2",
            title="エスワン キャンペーン第2弾 最大35%OFF",
            excerpt="",
            source="Feed",
            url="https://example.com/b",
        ),
    ]


def _av_brief(**changes):
    brief = dict(
        locale="zh-Hans",
        overview="本期关注浅野こころ因伤暂停部分活动。",
        conflicts=[],
        items=[
            dict(
                anchor="e1",
                evidence_ids=["e1"],
                title="浅野こころ暂停部分活动",
                body="据来源报道，浅野こころ因腰椎骨折宣布暂停部分活动。",
                kind="report",
                stage="unknown",
                support=[
                    dict(
                        evidence_id="e1",
                        quote="浅野こころ が腰椎骨折のため活動を一部休止すると発表しました。",
                    )
                ],
                entities=[dict(source="浅野こころ", translated="浅野こころ")],
            )
        ],
    )
    brief.update(changes)
    return brief


def test_av_validator_accepts_a_grounded_summary_with_names_kept_in_the_original():
    from newspaw.editorial import BriefValidator

    validator = BriefValidator(_av_evidence(), "zh-Hans", 5, av_industry=True)
    assert validator.validate(_av_brief())
    assert "overview" in validator.schema()["required"]


@pytest.mark.parametrize(
    ("changes", "error"),
    [
        # A name left in kana is only excused when the model declared it as kept.
        (dict(overview="本期关注エスワン的动态。"), "wrong_output_language"),
        (dict(overview=""), "invalid_prose"),
        (dict(overview="本期有 35 条值得关注的动态。"), "unsupported_number"),
        (dict(overview="本期动态已获多家媒体证实。"), "unverified_corroboration"),
        (dict(overview="概" * 601), "invalid_prose"),
        (dict(items=[]), "invalid_brief"),
    ],
)
def test_av_validator_checks_the_overview_like_the_items(changes, error):
    from newspaw.editorial import BriefValidator, EditorialError

    validator = BriefValidator(_av_evidence(), "zh-Hans", 5, av_industry=True)
    with pytest.raises(EditorialError, match=error):
        validator.validate(_av_brief(**changes))
    assert validator.validate(_av_brief(items=[], overview=""))


def test_av_validator_requires_the_overview_field():
    from newspaw.editorial import BriefValidator, EditorialError

    brief = _av_brief()
    del brief["overview"]
    with pytest.raises(EditorialError, match="invalid_fields"):
        BriefValidator(_av_evidence(), "zh-Hans", 5, av_industry=True).validate(brief)


def test_an_undeclared_original_name_still_fails_the_language_check_in_an_av_brief():
    from newspaw.editorial import BriefValidator, EditorialError

    brief = _av_brief()
    brief["items"][0]["entities"] = []
    with pytest.raises(EditorialError, match="wrong_output_language"):
        BriefValidator(_av_evidence(), "zh-Hans", 5, av_industry=True).validate(brief)


def test_a_kept_name_must_come_from_the_cited_evidence():
    from newspaw.editorial import BriefValidator, EditorialError

    brief = _av_brief()
    brief["items"][0]["title"] = "エスワン暂停部分活动"
    brief["items"][0]["entities"] = [dict(source="エスワン", translated="エスワン")]
    with pytest.raises(EditorialError, match="unsupported_entity"):
        BriefValidator(_av_evidence(), "zh-Hans", 5, av_industry=True).validate(brief)


def test_a_disagreement_note_may_name_someone_in_the_original_script():
    from newspaw.editorial import BriefValidator, EditorialError

    evidence = _av_evidence()
    evidence[1].update(
        title="浅野こころ 活動継続", excerpt="浅野こころ は活動を継続すると発表しました。"
    )
    conflict = dict(
        evidence_ids=["e1", "e2"],
        note="两家来源对浅野こころ是否暂停活动说法不一。",
        support=[
            dict(
                evidence_id="e1",
                quote="浅野こころ が腰椎骨折のため活動を一部休止すると発表しました。",
            ),
            dict(evidence_id="e2", quote="浅野こころ は活動を継続すると発表しました。"),
        ],
    )
    validator = BriefValidator(evidence, "zh-Hans", 5, av_industry=True)
    assert validator.validate(_av_brief(conflicts=[conflict]))
    undeclared = dict(conflict, note="两家来源对エスワン的说法不一。")
    with pytest.raises(EditorialError, match="wrong_output_language"):
        validator.validate(_av_brief(conflicts=[undeclared]))


def test_a_japanese_overview_must_be_written_in_japanese():
    from newspaw.editorial import BriefValidator, EditorialError

    item = dict(
        _av_brief()["items"][0],
        title="浅野こころ が活動を一部休止",
        body="浅野こころ が活動を一部休止すると発表したと報じられました。",
    )
    validator = BriefValidator(_av_evidence(), "ja", 5, av_industry=True)
    brief = _av_brief(locale="ja", items=[item], overview="本日は活動休止の発表が注目されます。")
    assert validator.validate(brief)
    with pytest.raises(EditorialError, match="wrong_output_language"):
        validator.validate(dict(brief, overview="本期最值得关注的是一位演员暂停部分活动。"))


def test_other_briefs_keep_the_strict_language_check_and_have_no_overview():
    from newspaw.editorial import BriefValidator, EditorialError

    validator = BriefValidator(_av_evidence(), "zh-Hans", 5)
    with pytest.raises(EditorialError, match="invalid_fields"):
        validator.validate(_av_brief())
    brief = _av_brief()
    del brief["overview"]
    with pytest.raises(EditorialError, match="wrong_output_language"):
        validator.validate(brief)
    assert "overview" not in validator.schema()["required"]


async def test_an_av_digest_with_only_rss_sources_is_written_by_the_adult_model(tmp_path):
    import json
    from contextlib import closing

    from test_model_runner import response
    from test_pipeline import prepare, run_to_terminal

    from newspaw.providers import ProfileRegistry
    from newspaw.store import Store

    feed = """<rss version="2.0"><channel><title>Feed</title><item>
<title>浅野こころ 活動を一部休止</title><link>https://example.com/a</link>
<pubDate>Sat, 07 Nov 2026 02:00:00 +0000</pubDate>
<description>浅野こころ が腰椎骨折のため活動を一部休止すると発表しました。</description>
</item></channel></rss>""".encode()

    async def read(request):
        return httpx.Response(200, content=feed)

    def model(request):
        assert request.url.host == "api.deepseek.com"
        body = json.loads(request.content)
        assert "overview" in body["text"]["format"]["schema"]["required"]
        inputs = json.loads(body["input"][0]["content"][0]["text"])
        identity = inputs["evidence"][0]["id"]
        brief = _av_brief()
        brief["items"][0].update(anchor=identity, evidence_ids=[identity])
        brief["items"][0]["support"][0]["evidence_id"] = identity
        return httpx.Response(200, json=response(json.dumps(brief, ensure_ascii=False)))

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        store.save_config(config, expected_revision=1)
        registry = ProfileRegistry(store)
        holds = {"adult_primary": 100, "adult_backup": 100}
        for profile in holds:
            registry.begin("verify." + profile, profile, "text", 1)
            registry.finish("verify." + profile, {"status": "verified"})
        pipeline, reads, calls = prepare(store, feed=read, model=model)
        job = pipeline.create(sub["id"], "daily", holds=holds, task_limit=500, now=NOW)["job_id"]
        result = await run_to_terminal(pipeline, job)
        assert result["stage"] == "awaiting_delivery", result
        assert reads == ["https://example.com/rss"] and len(calls) == 1
        _, text, media = pipeline.delivery_input(job)
        assert text.startswith(
            "今日概览\n本期关注浅野こころ因伤暂停部分活动。\n\n1. 浅野こころ暂停部分活动"
        )
        assert "https://example.com/a" in text and media["style"] == "text"
        assert pipeline.delivery_scope(job)

        edition = pipeline.editorial.get(result["edition_id"])["result"]
        for marker, allowed in (("industry-v1", True), (None, False)):
            edition["av_contract"] = marker
            if marker is None:
                del edition["av_contract"]
            with store._write():
                store._db.execute(
                    "UPDATE editorial_editions SET result_json=? WHERE id=?",
                    (json.dumps(edition, ensure_ascii=False), result["edition_id"]),
                )
            assert (
                pipeline.editorial.delivery_allowed(
                    result["edition_id"], store.preview_route(sub["id"])
                )
                is allowed
            )


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
        if str(request.url) == AV_ORIGIN + "?feed=rss2":
            return httpx.Response(404)
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


@pytest.mark.parametrize(
    ("scenario", "accepted", "gaps", "requests"),
    [
        ("bound", 2, [], ["landing", "p=123", "feed", "p=124"]),
        ("aware_page", 2, [], ["landing", "p=123", "p=124"]),
        ("absent", 1, ["invalid_publication_date"], ["landing", "p=123", "feed", "p=124"]),
        ("other_clock", 1, ["conflicting_publication_date"], ["landing", "p=123", "feed", "p=124"]),
        ("naive_feed", 1, ["invalid_publication_date"], ["landing", "p=123", "feed", "p=124"]),
        ("repeated", 1, ["invalid_publication_date"], ["landing", "p=123", "feed", "p=124"]),
        (
            "feed_down",
            0,
            ["date_feed_unavailable", "invalid_publication_date"],
            ["landing", "p=123", "feed", "p=124"],
        ),
        (
            "not_a_feed",
            0,
            ["date_feed_unavailable", "invalid_publication_date"],
            ["landing", "p=123", "feed", "p=124"],
        ),
        ("held", None, [], ["landing", "p=123"]),
    ],
)
async def test_a_timezone_less_page_date_is_bound_by_the_publishers_feed(
    tmp_path, scenario, accepted, gaps, requests
):
    from contextlib import closing
    from datetime import timedelta
    from email.utils import format_datetime

    from newspaw.connectors.av import AV_ORIGIN, AVCollector
    from newspaw.evidence import EvidenceStore
    from newspaw.store import Store

    feed_url = AV_ORIGIN + "?feed=rss2"
    # The site prints local wall-clock times without a zone; its feed carries the instant.
    posted = {"123": NOW - timedelta(hours=1), "124": NOW - timedelta(hours=2)}
    seen = []

    def wall(moment):
        local = (moment + timedelta(hours=9)).replace(tzinfo=None).isoformat(sep=" ")
        return moment.isoformat() if scenario == "aware_page" else local

    def item(post, moment, *, zone=True):
        date = format_datetime(moment) if zone else moment.replace(tzinfo=None).isoformat()
        return (
            f"<item><title>feed title {post}</title><link>{AV_ORIGIN}?p={post}</link>"
            f"<pubDate>{date}</pubDate><description>feed body must stay out</description></item>"
        )

    def respond(request):
        url = str(request.url)
        if url == AV_ORIGIN:
            seen.append("landing")
            articles = "".join(
                f'''<article id="post-{post}"><h2 class="post-title">
                <a href="{AV_ORIGIN}?p={post}">FANZA の発売情報 {post}</a></h2>
                <div class="post-meta"><time class="published updated"
                datetime="{wall(moment)}"></time></div></article>'''
                for post, moment in posted.items()
            )
            return httpx.Response(200, headers={"Content-Type": "text/html"}, text=articles)
        if url == feed_url:
            seen.append("feed")
            if scenario == "feed_down":
                return httpx.Response(503)
            if scenario == "not_a_feed":
                return httpx.Response(
                    200, headers={"Content-Type": "text/html"}, text="<html></html>"
                )
            items = item("123", posted["123"])
            if scenario == "bound":
                items += item("124", posted["124"])
            elif scenario == "other_clock":
                items += item("124", posted["124"] + timedelta(minutes=7))
            elif scenario == "naive_feed":
                items += item("124", posted["124"], zone=False)
            elif scenario == "repeated":
                items += item("124", posted["124"]) + item(
                    "124", posted["124"] + timedelta(hours=1)
                )
            return httpx.Response(
                200,
                headers={"Content-Type": "application/rss+xml; charset=UTF-8"},
                text=f'<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>{items}</channel></rss>',
            )
        post = url.removeprefix(AV_ORIGIN + "?p=")
        seen.append("p=" + post)
        return httpx.Response(
            200,
            headers={"Content-Type": "text/html"},
            text=f'''<link rel="canonical" href="{url}"><article id="post-{post}">
            <div class="post-meta"><time class="published updated"
            datetime="{wall(posted[post])}"></time></div></article>''',
        )

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured("adult")
        config["sources"][0].update(url=AV_ORIGIN, kind="web", name="AV研究所")
        store.save_config(config, expected_revision=1)
        evidence = EvidenceStore(store)
        collector = AVCollector(
            evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(respond))
        )
        try:
            result = await collector.collect(
                [sub["id"]],
                now=NOW,
                before_request=lambda: False if scenario == "held" and len(seen) == 2 else None,
            )
        finally:
            await collector.close()
        assert seen == requests
        if scenario == "held":
            assert result is None
            return
        assert result["accepted_count"] == accepted
        assert result["coverage_gaps"] == gaps and result["error_kind"] is None
        assert result["status"] == ("fresh" if accepted else "no_eligible")
        if accepted:
            rows = evidence.articles(result["id"], partition="adult", source_id="feed1", now=NOW)
            assert [row.published_at for row in rows][0] == posted["123"]
            if scenario == "bound":
                assert rows[0].published_raw == format_datetime(posted["123"])
        stored = "\n".join(store._db.iterdump())
        assert "feed body must stay out" not in stored and "feed title" not in stored
