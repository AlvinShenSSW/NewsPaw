from copy import deepcopy

import pytest

from newspaw.editorial import BriefValidator, EditorialError


def pool():
    return [
        dict(
            id="e1",
            title="OpenAI releases GPT-6",
            excerpt="OpenAI released GPT-6.",
            source="Example",
            url="https://example.com/a",
            scope="rss_excerpt",
            content_hash="a" * 64,
        )
    ]


def output(locale="en"):
    titles = {
        "en": "OpenAI releases GPT-6",
        "zh-Hans": "模型 GPT-6 已发布",
        "ja": "GPT-6 が公開されました",
    }
    bodies = {
        "en": "OpenAI released GPT-6 according to the source.",
        "zh-Hans": "据来源报道，OpenAI 发布了模型 GPT-6。",
        "ja": "報道によると OpenAI は GPT-6 を公開しました。",
    }
    return dict(
        locale=locale,
        items=[
            dict(
                anchor="e1",
                evidence_ids=["e1"],
                title=titles[locale],
                body=bodies[locale],
                kind="report",
                stage="model_release",
                support=[dict(evidence_id="e1", quote="OpenAI released GPT-6.")],
                entities=[dict(source="OpenAI", translated="OpenAI")],
            )
        ],
        conflicts=[],
    )


@pytest.mark.parametrize("locale", ["en", "zh-Hans", "ja"])
def test_gold_translated_title_body_and_names(locale):
    validator = BriefValidator(pool(), locale, 6)
    assert validator.validate(output(locale)) == output(locale)


@pytest.mark.parametrize("split", [False, True])
def test_model_entities_cannot_exempt_untranslated_sentences(split):
    sentence = "The central bank has kept interest rates unchanged."
    records = pool()
    records[0]["excerpt"] = sentence
    data = output("zh-Hans")
    item = data["items"][0]
    item.update(title="利率报道", body=sentence + " 报道。", stage="unknown")
    item["support"][0]["quote"] = sentence
    spans = sentence.rstrip(".").split() if split else [sentence]
    item["entities"] = [dict(source=word, translated=word) for word in spans]
    with pytest.raises(EditorialError, match="language"):
        BriefValidator(records, "zh-Hans", 6).validate(data)


@pytest.mark.parametrize("change", ["citation", "quote", "number", "entity", "extra", "language"])
def test_unsupported_or_wrong_language_output_is_not_publishable(change):
    data = output("zh-Hans")
    item = data["items"][0]
    if change == "citation":
        item["evidence_ids"] = ["outside"]
    if change == "quote":
        item["support"][0]["quote"] = "An unsupported assertion."
    if change == "number":
        item["body"] = "来源说发布了 999 个模型。"
    if change == "entity":
        item["entities"] = [dict(source="Invented company", translated="虚构公司")]
    if change == "extra":
        item["shell"] = "not an allowed field"
    if change == "language":
        item["body"] = "This entire paragraph remains untranslated."
    with pytest.raises(EditorialError):
        BriefValidator(pool(), "zh-Hans", 6).validate(data)


def test_duplicate_event_and_reprint_is_not_independent_confirmation():
    data = output()
    data["items"].append(deepcopy(data["items"][0]))
    with pytest.raises(EditorialError):
        BriefValidator(pool(), "en", 6).validate(data)
    data = output()
    data["items"][0]["body"] = "Multiple sources independently confirmed GPT-6."
    with pytest.raises(EditorialError):
        BriefValidator(pool(), "en", 6).validate(data)


@pytest.fixture
async def environment(tmp_path):
    import httpx
    from test_model_runner import NOW
    from test_routing import configured

    from newspaw.evidence import EvidenceStore, FeedCollector
    from newspaw.providers import ProfileRegistry
    from newspaw.store import Store

    store = Store(tmp_path / "state.db")
    config, sub = configured()
    store.save_config(config, expected_revision=1)
    registry = ProfileRegistry(store)
    for profile in ("normal_primary", "normal_backup"):
        registry.begin("verify." + profile, profile, "text", 1)
        registry.finish("verify." + profile, {"status": "verified"})
    xml = b'<rss version="2.0"><channel><title>Example</title><item><title>OpenAI releases GPT-6</title><link>https://example.com/a</link><pubDate>Sat, 07 Nov 2026 02:00:00 +0000</pubDate><description>OpenAI released GPT-6.</description></item></channel></rss>'
    collector = FeedCollector(
        EvidenceStore(store),
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(lambda req: httpx.Response(200, content=xml))
        ),
    )
    attempts = await collector.collect([sub["id"]], now=NOW)
    await collector.close()
    yield store, sub["id"], [a["id"] for a in attempts]
    store.close()


def service(store, handler=None):
    import json

    import httpx
    from test_model_runner import Keys, response

    from newspaw.editorial import EditorialService
    from newspaw.model_runner import ModelRunner
    from newspaw.providers import ProviderAdapter

    calls = []

    def valid(request):
        calls.append(request)
        if handler:
            return handler(request)
        body = json.loads(request.content)
        inputs = json.loads(body["input"][0]["content"][0]["text"])
        result = output(inputs["locale"])
        item = result["items"][0]
        identity = inputs["evidence"][0]["id"]
        item.update(anchor=identity, evidence_ids=[identity])
        item["support"][0]["evidence_id"] = identity
        return httpx.Response(200, json=response(json.dumps(result, ensure_ascii=False)))

    def factory(p, k):
        return ProviderAdapter(p, k, client=httpx.AsyncClient(transport=httpx.MockTransport(valid)))

    return EditorialService(store, ModelRunner(store, Keys(), adapter_factory=factory)), calls


def prepare(editor, sub, attempts, identity="edition", now=None):
    from test_model_runner import NOW

    return editor.prepare(
        identity,
        editor.store.preview_route(sub),
        attempts,
        {"normal_primary": 100, "normal_backup": 100},
        task_limit=500,
        now=now or NOW,
    )


@pytest.mark.parametrize("locale", ["zh-Hans", "en", "ja"])
async def test_real_evidence_to_frozen_edition_and_localized_render(environment, locale):
    from test_model_runner import NOW

    store, sub, attempts = environment
    revision, config = store.load_config()
    config["news_output_locale"] = locale
    store.save_config(config, expected_revision=revision)
    editor, calls = service(store)
    assert prepare(editor, sub, attempts)["state"] == "pending"
    assert not calls
    result = await editor.advance("edition", now=NOW)
    assert result["state"] == "ready" and result["result"]["locale"] == locale
    assert result["result"]["items"][0]["sources"][0]["url"] == "https://example.com/a"
    rendered = editor.render("edition")
    assert output(locale)["items"][0]["title"] in rendered
    assert len(calls) == 1
    assert (await editor.advance("edition", now=NOW)) == result
    prepare(editor, sub, attempts)
    assert len(calls) == 1
    if locale != "en":
        assert "OpenAI releases GPT-6" not in rendered
        assert "OpenAI released GPT-6." not in rendered


async def test_crash_after_model_success_reuses_result_without_paid_replay(environment):
    import sqlite3

    from test_model_runner import NOW

    store, sub, attempts = environment
    editor, calls = service(store)
    prepare(editor, sub, attempts)
    original = editor._decorate

    def fail(payload, data):
        store._db.set_authorizer(
            lambda action, table, *args: (
                sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_UPDATE and table == "editorial_editions"
                else sqlite3.SQLITE_OK
            )
        )
        return original(payload, data)

    editor._decorate = fail
    try:
        with pytest.raises(sqlite3.DatabaseError):
            await editor.advance("edition", now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert len(calls) == 1
    editor._decorate = original
    assert (await editor.advance("edition", now=NOW))["state"] == "ready"
    assert len(calls) == 1


async def test_unknown_never_renders_original_or_repeats_paid_call(environment):
    import httpx
    from test_model_runner import NOW

    store, sub, attempts = environment

    def lost(req):
        raise httpx.ReadTimeout("lost")

    editor, calls = service(store, lost)
    prepare(editor, sub, attempts)
    for _ in range(2):
        result = await editor.advance("edition", now=NOW)
    assert result["state"] == "outcome_unknown" and result["result"] is None and len(calls) == 1
    with pytest.raises(EditorialError, match="not_ready"):
        editor.render("edition")


async def test_changed_locale_and_expired_evidence_block_before_model(environment):
    from datetime import timedelta

    from test_model_runner import NOW

    store, sub, attempts = environment
    editor, calls = service(store)
    prepare(editor, sub, attempts)
    assert (await editor.advance("edition", now=NOW + timedelta(days=2)))["state"] == "stale"
    prepare(editor, sub, attempts, "locale")
    revision, config = store.load_config()
    config["news_output_locale"] = "ja"
    store.save_config(config, expected_revision=revision)
    assert (await editor.advance("locale", now=NOW))["state"] == "stale"
    assert not calls


async def test_empty_evidence_localizes_no_news_without_call(environment):
    from test_model_runner import NOW

    store, sub, _ = environment
    editor, calls = service(store)
    result = prepare(editor, sub, [])
    assert result["state"] == "no_news" and not calls
    assert "未获得" in editor.render("edition")
    assert (await editor.advance("edition", now=NOW))["state"] == "no_news"


async def test_prepare_crash_before_submit_can_resume(environment, monkeypatch):
    from test_model_runner import NOW

    store, sub, attempts = environment
    editor, calls = service(store)
    submit = editor.runner.submit

    def fail(*args, **kwargs):
        raise OSError("injected")

    monkeypatch.setattr(editor.runner, "submit", fail)
    with pytest.raises(OSError):
        prepare(editor, sub, attempts)
    assert editor.get("edition")["state"] == "pending" and not calls
    monkeypatch.setattr(editor.runner, "submit", submit)
    prepare(editor, sub, attempts)
    assert (await editor.advance("edition", now=NOW))["state"] == "ready" and len(calls) == 1


async def collect_xml(store, subscriptions, xml, now):
    import httpx

    from newspaw.evidence import EvidenceStore, FeedCollector

    collector = FeedCollector(
        EvidenceStore(store),
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(lambda req: httpx.Response(200, content=xml))
        ),
    )
    try:
        return [a["id"] for a in await collector.collect(subscriptions, now=now)]
    finally:
        await collector.close()


def feed(*, mirror=False, summary="OpenAI released GPT-6."):
    from xml.sax.saxutils import escape

    def item(url):
        return f"<item><title>OpenAI releases GPT-6</title><link>{url}</link><pubDate>Sat, 07 Nov 2026 02:00:00 +0000</pubDate><description>{escape(summary)}</description></item>"

    return (
        '<rss version="2.0"><channel><title>Example</title>'
        + item("https://example.com/a")
        + (item("https://mirror.example.com/a") if mirror else "")
        + "</channel></rss>"
    ).encode()


async def test_reprints_collapse_without_independent_confirmation(environment):
    from test_model_runner import NOW

    store, sub, _ = environment
    attempts = await collect_xml(store, [sub], feed(mirror=True), NOW)
    editor, calls = service(store)
    prepare(editor, sub, attempts)
    result = await editor.advance("edition", now=NOW)
    assert result["state"] == "ready" and len(calls) == 1
    item = result["result"]["items"][0]
    assert len(item["sources"]) == 2 and item["reprint_or_duplicate"]
    assert item["independent_corroboration"] == "not_verified"


async def test_changed_snapshot_records_update_without_new_publication(environment):
    from datetime import timedelta

    from test_model_runner import NOW

    store, sub, attempts = environment
    editor, calls = service(store)
    prepare(editor, sub, attempts)
    old = (await editor.advance("edition", now=NOW))["result"]["items"][0]
    later = NOW + timedelta(minutes=2)
    new_attempts = await collect_xml(
        store, [sub], feed(summary="OpenAI released GPT-6. Version 2 is available."), later
    )
    prepare(editor, sub, new_attempts, "update", now=later)
    updated = (await editor.advance("update", now=later))["result"]["items"][0]
    assert updated["event_key"] == old["event_key"]
    assert updated["content_version"] != old["content_version"]
    assert updated["previous_version"] == old["content_version"]
    assert updated["sources"][0]["published_at"] == old["sources"][0]["published_at"]
    assert len(calls) == 2


async def test_same_event_can_appear_in_two_subscriptions(environment):
    from test_model_runner import NOW

    store, sub, _ = environment
    revision, config = store.load_config()
    config["sources"][0]["category_ids"].append("japan")
    japan = next(s for s in config["subscriptions"] if s["category_id"] == "japan")
    japan.update(enabled=True, bot_ids=["bot1"])
    store.save_config(config, expected_revision=revision)
    attempts = await collect_xml(store, [sub, japan["id"]], feed(), NOW)
    editor, calls = service(store)
    prepare(editor, sub, attempts, "world")
    prepare(editor, japan["id"], attempts, "japan")
    world = await editor.advance("world", now=NOW)
    local = await editor.advance("japan", now=NOW)
    assert world["state"] == local["state"] == "ready" and len(calls) == 2
    assert world["result"]["items"][0]["event_key"] == local["result"]["items"][0]["event_key"]


async def test_title_only_evidence_is_labelled_and_not_rendered_raw(environment):
    import json

    import httpx
    from test_model_runner import NOW, response

    store, sub, _ = environment
    attempts = await collect_xml(store, [sub], feed(summary=""), NOW)

    def answer(request):
        inputs = json.loads(json.loads(request.content)["input"][0]["content"][0]["text"])
        data = output("zh-Hans")
        key = inputs["evidence"][0]["id"]
        data["items"][0].update(
            anchor=key,
            evidence_ids=[key],
            support=[dict(evidence_id=key, quote="OpenAI releases GPT-6")],
        )
        return httpx.Response(200, json=response(json.dumps(data, ensure_ascii=False)))

    editor, calls = service(store, answer)
    prepare(editor, sub, attempts)
    assert (await editor.advance("edition", now=NOW))["state"] == "ready"
    assert "仅依据标题" in editor.render("edition")
    assert "OpenAI releases GPT-6" not in editor.render("edition")
    assert len(calls) == 1


@pytest.mark.parametrize(
    "locale,bad",
    [
        ("zh-Hans", "這個模型已經發佈。"),
        ("zh-Hans", "新しいモデルが公開されました。"),
        ("ja", "这个模型已经发布。"),
        ("en", "这个模型已经发布。"),
        ("ja", "This is an untranslated English report about a new model."),
    ],
)
def test_negative_language_gold(locale, bad):
    data = output(locale)
    data["items"][0].update(title=bad, body=bad, entities=[])
    with pytest.raises(EditorialError, match="language"):
        BriefValidator(pool(), locale, 6).validate(data)


@pytest.mark.parametrize(
    "locale,note",
    [
        ("zh-Hans", "来源甲说有 6 个模型，来源乙说有 7 个模型。"),
        ("en", "One source reports 6 models while another reports 7 models."),
        ("ja", "一方は 6 個と述べていますが、他方は 7 個と述べています。"),
    ],
)
def test_conflict_keeps_both_cited_claims_in_target_language(locale, note):
    records = pool() + [
        dict(
            id="e2",
            title="Other report",
            excerpt="The source reports 7 models.",
            source="Other",
            url="https://other.example/a",
            scope="rss_excerpt",
            content_hash="b" * 64,
        )
    ]
    data = output(locale)
    data["conflicts"] = [
        dict(
            evidence_ids=["e1", "e2"],
            note=note,
            support=[
                dict(evidence_id="e1", quote="OpenAI released GPT-6."),
                dict(evidence_id="e2", quote="The source reports 7 models."),
            ],
        )
    ]
    assert BriefValidator(records, locale, 6).validate(data)["conflicts"][0]["note"] == note


async def test_realtime_editorial_does_not_freeze_budget_dispatch_clock(environment, monkeypatch):
    store, sub, attempts = environment
    editor, _ = service(store)
    prepare(editor, sub, attempts)
    seen = []
    advance = editor.runner.advance

    async def capture(*args, **kwargs):
        seen.append(kwargs["now"])
        return await advance(*args, **kwargs)

    monkeypatch.setattr(editor.runner, "advance", capture)
    await editor.advance("edition")
    assert seen == [None]


async def test_uncollected_source_is_a_visible_coverage_gap(environment):
    store, sub, _ = environment
    editor, _ = service(store)
    result = prepare(editor, sub, [])
    assert result["result"]["coverage"][0]["status"] == "not_collected"
    assert "来源覆盖缺口: 1" in editor.render("edition")


async def test_empty_selection_does_not_claim_no_evidence_was_obtained(environment):
    import json

    import httpx
    from test_model_runner import NOW, response

    store, sub, attempts = environment
    editor, _ = service(
        store,
        lambda req: httpx.Response(
            200, json=response(json.dumps(dict(locale="zh-Hans", items=[], conflicts=[])))
        ),
    )
    prepare(editor, sub, attempts)
    assert (await editor.advance("edition", now=NOW))["state"] == "ready"
    assert "未形成可发布" in editor.render("edition")
    assert "未获得" not in editor.render("edition")


@pytest.mark.parametrize(
    "bad",
    [
        "Ｔｈｅ ｃｅｎｔｒａｌ ｂａｎｋ ｈａｓ ｋｅｐｔ ｉｎｔｅｒｅｓｔ ｒａｔｅｓ ｕｎｃｈａｎｇｅｄ． 报道。",
        "Это сообщение не переведено. 报道。",
    ],
)
def test_untranslated_unicode_prose_cannot_hide_behind_chinese_marker(bad):
    data = output("zh-Hans")
    data["items"][0].update(body=bad, entities=[])
    with pytest.raises(EditorialError, match="language"):
        BriefValidator(pool(), "zh-Hans", 6).validate(data)


async def test_cached_model_result_is_revalidated_after_waiting_for_runner(
    environment, monkeypatch
):
    import asyncio

    from test_model_runner import NOW

    store, sub, attempts = environment
    editor, calls = service(store)
    prepare(editor, sub, attempts)
    decorate = editor._decorate

    def crash(*args):
        raise OSError("edition result not saved")

    monkeypatch.setattr(editor, "_decorate", crash)
    with pytest.raises(OSError):
        await editor.advance("edition", now=NOW)
    monkeypatch.setattr(editor, "_decorate", decorate)
    await editor.runner._lock.acquire()
    pending = asyncio.create_task(editor.advance("edition", now=NOW))
    await asyncio.sleep(0)
    revision, config = store.load_config()
    config["news_output_locale"] = "ja"
    store.save_config(config, expected_revision=revision)
    editor.runner._lock.release()
    result = await pending
    assert result["state"] == "stale" and result["result"] is None
    assert len(calls) == 1
