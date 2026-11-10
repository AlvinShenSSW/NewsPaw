import asyncio

import httpx
import pytest
from test_credentials import FakeKeychain
from test_evidence import NOW, URL, rss

from newspaw.credentials import CredentialManager
from newspaw.source_manager import SourceError, SourceManager
from newspaw.store import Store


@pytest.fixture
def setup(tmp_path):
    store = Store(tmp_path / "state.db")
    manager = SourceManager(
        CredentialManager(store, FakeKeychain()),
        client_factory=lambda: httpx.AsyncClient(
            transport=httpx.MockTransport(lambda r: httpx.Response(200, content=rss()))
        ),
    )
    yield manager, store
    store.close()


def source(**changes):
    return dict(
        id="s",
        name="Nickname",
        url=URL,
        kind="rss",
        partition="normal",
        category_ids=["world"],
        enabled=False,
        **changes,
    )


async def test_preview_then_enable_real_metadata(setup):
    manager, store = setup
    s = source()
    await manager.save(s, store.config_revision())
    with pytest.raises(SourceError, match="preview_required"):
        await manager.save({**s, "enabled": True}, store.config_revision())
    result = await manager.preview("s", now=NOW)
    article = result["entries"][0]
    assert article["source"] == "Publisher" and article["language"] == "ja"
    assert article["published_at"] and article["fetched_at"] and article["content_sha256"]
    assert article["evidence_scope"] == "rss_excerpt"
    await manager.save({**s, "enabled": True}, store.config_revision())
    assert store.load_config()[1]["sources"][0]["enabled"]


async def test_identity_aba_restart_and_old_history_not_readiness(setup):
    manager, store = setup
    s = source()
    await manager.save(s, store.config_revision())
    await manager.preview("s", now=NOW)
    for url in ("https://example.com/b", URL):
        await manager.save({**s, "url": url}, store.config_revision())
    restarted = SourceManager(manager.credentials, client_factory=manager.client_factory)
    with pytest.raises(SourceError, match="preview_required"):
        await restarted.save({**s, "enabled": True}, store.config_revision())
    assert restarted.evidence.history("s")
    await restarted.preview("s", now=NOW)
    await restarted.save({**s, "enabled": True}, store.config_revision())


async def test_unknown_and_unclassified_cannot_enable(setup):
    manager, store = setup
    for overrides in [dict(kind="draft"), dict(kind="web"), dict(partition=None, category_ids=[])]:
        with pytest.raises((SourceError, ValueError)):
            await manager.save({**source(), **overrides, "enabled": True}, store.config_revision())
    await manager.save({**source(), "partition": None, "category_ids": []}, store.config_revision())
    with pytest.raises(SourceError, match="unclassified_source"):
        await manager.preview("s", now=NOW)


async def test_assignment_preserves_inherited_and_delete_never_broadens(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    await manager.save(
        {**source(), "id": "other", "url": "https://example.com/other"}, store.config_revision()
    )
    await manager.assign("s", ["sub_world", "sub_japan"], store.config_revision())
    cfg = store.load_config()[1]
    assert set(next(s for s in cfg["subscriptions"] if s["id"] == "sub_world")["source_ids"]) == {
        "s",
        "other",
    }
    assert next(s for s in cfg["subscriptions"] if s["id"] == "sub_japan")["source_ids"] == ["s"]
    result = await manager.delete("s", store.config_revision())
    cfg = store.load_config()[1]
    assert "sub_japan" in result["disabled_subscriptions"]
    assert not next(s for s in cfg["subscriptions"] if s["id"] == "sub_japan")["enabled"]
    assert next(s for s in cfg["subscriptions"] if s["id"] == "sub_world")["source_ids"] == [
        "other"
    ]


async def test_discovery_multi_feed_and_draft(setup):
    manager, _ = setup
    content = b'<html><head><base href="https://example.com/news/"><link rel="alternate" type="application/rss+xml" href="one" title="One"><link rel="alternate" type="application/atom+xml" href="two"><link rel="alternate" type="application/rss+xml" href="http://127.0.0.1/private"></head><body><link rel="alternate" type="application/rss+xml" href="body"></body></html>'
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(200, content=content, headers={"content-type": "text/html"})
        )
    )
    result = await manager.discover("https://example.com/")
    assert [c["url"] for c in result["choices"]] == [
        "https://example.com/news/one",
        "https://example.com/news/two",
    ]
    assert all(c["validation"] == "preview_required" for c in result["choices"])
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(200, text="<html><head></head><body>News</body></html>")
        )
    )
    assert (await manager.discover("https://example.com/"))["kind"] == "draft"
    assert (await manager.discover("https://x.com/fixture"))["destination"] == "x_accounts"
    assert (await manager.discover("https://huggingface.co/org"))["choices"][0][
        "url"
    ] == "https://huggingface.co/models?author=org"


async def test_opml_import_preserves_classified_preferences(setup):
    manager, store = setup
    opml = '<opml version="2.0"><body><outline text="Folder"><outline type="rss" text="Feed" xmlUrl="https://example.com/feed"/></outline></body></opml>'
    result = await manager.import_opml(opml, store.config_revision())
    identity = result["added"][0]
    s = store.load_config()[1]["sources"][0]
    assert s["partition"] is None and not s["enabled"] and not s["category_ids"]
    await manager.save(
        {**s, "partition": "normal", "category_ids": ["world"], "name": "My name"},
        store.config_revision(),
    )
    revision = store.config_revision()
    again = await manager.import_opml(opml, revision)
    assert again["existing"] == [identity] and not again["added"]
    assert store.config_revision() == revision
    assert store.load_config()[1]["sources"][0]["name"] == "My name"


async def test_inflight_aba_and_delete_readd_reject_old_preview(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    entered, release = asyncio.Event(), asyncio.Event()

    async def handler(request):
        entered.set()
        await release.wait()
        return httpx.Response(200, content=rss())

    manager.client_factory = lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler))
    pending = asyncio.create_task(manager.preview("s", now=NOW))
    await entered.wait()
    await manager.save({**source(), "url": "https://example.com/b"}, store.config_revision())
    await manager.save(source(), store.config_revision())
    release.set()
    with pytest.raises(SourceError, match="configuration_changed"):
        await pending
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(200, content=rss()))
    )
    await manager.preview("s", now=NOW)
    prior = manager._epoch("s")[0]
    await manager.delete("s", store.config_revision())
    await manager.save(source(), store.config_revision())
    assert manager._epoch("s")[0] > prior
    with pytest.raises(SourceError, match="preview_required"):
        await manager.save({**source(), "enabled": True}, store.config_revision())


async def test_readiness_cas_rollback_and_all_write_hooks(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    await manager.preview("s", now=NOW)
    old = manager._epoch("s")
    revision, config = store.load_config()
    config["sources"][0]["url"] = "https://example.com/new"
    with pytest.raises(ValueError):
        store.save_config(config, expected_revision=revision - 1)
    assert manager._epoch("s") == old
    store.save_config(config, expected_revision=revision)
    assert manager._epoch("s")[0] > old[0] and manager._epoch("s")[1] is None
    # CredentialManager mutations reach the distinct commit_credentials hook.
    revision, config = store.load_config()
    config["sources"][0]["url"] = URL
    await manager.credentials.save_config(config, revision)
    assert manager._epoch("s")[0] > old[0] + 1


async def test_failure_after_success_and_unzoned_preview(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    await manager.preview("s", now=NOW)
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(503))
    )
    failed = await manager.preview("s", now=NOW)
    assert (
        failed["attempt"]["status"] == "failed"
        and not failed["entries"]
        and not failed["preview_ready"]
    )
    with pytest.raises(SourceError, match="preview_required"):
        await manager.save({**source(), "enabled": True}, store.config_revision())
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(200, content=rss("2026-11-07T03:00:00"))
        )
    )
    result = await manager.preview("s", now=NOW)
    assert result["entries"][0]["published_at"] is None and not result["entries"][0]["eligible"]
    assert result["entries"][0]["published_error"] == "publication_timezone_missing"
    assert result["preview_ready"]  # Connected and parsed, not fresh news.


async def test_cross_partition_assignment_and_edit_atomic(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    original = store.load_config()
    with pytest.raises(SourceError, match="incompatible_subscription"):
        await manager.assign("s", ["sub_world", "sub_av"], store.config_revision())
    assert store.load_config() == original
    await manager.assign("s", ["sub_world"], store.config_revision())
    original = store.load_config()
    with pytest.raises(ValueError):
        await manager.save(
            {**source(), "partition": "adult", "category_ids": ["av"]}, store.config_revision()
        )
    assert store.load_config() == original
    routes = manager.routes("s")
    assert routes[0]["effective"]["partition"] == "normal" and routes[0]["blockers"]


async def test_opml_capacity_rollback_and_duplicate_batch(setup):
    manager, store = setup
    revision, config = store.load_config()
    config["sources"] = [
        {**source(), "id": f"s{i}", "url": f"https://example.com/{i}"} for i in range(200)
    ]
    store.save_config(config, expected_revision=revision)
    before = store.load_config()
    with pytest.raises(ValueError):
        await manager.import_opml(
            '<opml><body><outline xmlUrl="https://example.com/extra"/></body></opml>',
            store.config_revision(),
        )
    assert store.load_config() == before
    result = await manager.import_opml(
        '<opml><body><outline xmlUrl="https://example.com/1"/><outline xmlUrl="https://EXAMPLE.com:443/1"/></body></opml>',
        store.config_revision(),
    )
    assert result["existing"] == ["s1"] and not result["added"] and store.load_config() == before


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com/",
        "https://127.0.0.1/",
        "https://localhost/",
        "https://example.com/?api_key=fixture",
        "https://user:pass@example.com/",
    ],
)
async def test_discovery_unsafe_url_before_request(setup, url):
    manager, _ = setup
    manager.client_factory = lambda: pytest.fail("No unsafe request")
    with pytest.raises(SourceError, match="unsafe_url"):
        await manager.discover(url)


async def test_discovery_direct_atom_limit_redirect_and_xml_guard(setup):
    manager, _ = setup

    async def run(content, status=200, headers=None):
        manager.client_factory = lambda: httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda r: httpx.Response(status, content=content, headers=headers)
            )
        )
        return await manager.discover(URL)

    assert (await run(rss()))["kind"] == "rss"
    assert (await run(b'<feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title></feed>'))[
        "kind"
    ] == "atom"
    with pytest.raises(SourceError, match="redirect_rejected"):
        await run(b"", 302, {"location": "https://other.example/feed"})
    with pytest.raises(SourceError, match="response_too_large"):
        await run(b"x" * (2 * 1024 * 1024 + 1))
    with pytest.raises(SourceError, match="unsafe_xml"):
        await run(b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///tmp/private">]><rss>&x;</rss>')
    assert (await run(b"<!DOCTYPE html><html><head></head></html>"))["kind"] == "draft"


async def test_preview_cancellation_closes_client_and_does_not_qualify(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    entered = asyncio.Event()

    async def handler(request):
        entered.set()
        await asyncio.Event().wait()

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    manager.client_factory = lambda: client
    pending = asyncio.create_task(manager.preview("s", now=NOW))
    await entered.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert client.is_closed and not manager._ready(source())


def test_catalog_has_user_choices_without_demo_health():
    from newspaw.source_catalog import catalog

    rows = catalog()
    assert {"cnn", "yahoo-jp", "zaobao", "cns", "skills-oai", "av-reference"} <= {
        r["id"] for r in rows
    }
    assert all(r["availability"] == "not_verified" for r in rows)
    assert all(r["partition"] == "adult" for r in rows if r["id"] == "av-reference")


async def test_enable_change_during_preview_reports_configuration_change(setup):
    manager, store = setup
    await manager.save(source(), store.config_revision())
    entered, release = asyncio.Event(), asyncio.Event()

    async def handler(request):
        entered.set()
        await release.wait()
        return httpx.Response(200, content=rss())

    manager.client_factory = lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler))
    pending = asyncio.create_task(manager.preview("s", now=NOW))
    await entered.wait()
    revision, config = store.load_config()
    config["sources"][0]["enabled"] = True
    store.save_config(config, expected_revision=revision)
    release.set()
    with pytest.raises(SourceError, match="configuration_changed"):
        await pending


def test_legacy_import_initializes_unpreviewed_source_markers(tmp_path):
    store = Store(tmp_path / "legacy.db")
    try:
        store.import_legacy_config(
            values={"NEWS_TOPICS": "World", "NEWS_FEEDS": "https://example.com/feed"}
        )
        sources = store.load_config()[1]["sources"]
        assert sources
        assert store._db.execute("SELECT id,epoch,attempt_id FROM source_readiness").fetchall() == [
            (sources[0]["id"], 1, None)
        ]
    finally:
        store.close()


@pytest.mark.parametrize(
    "content",
    [
        b"<rss><channel>",
        b"<root/>",
        b'<root><head><link rel="alternate" type="application/rss+xml" href="https://example.com/feed"/></head></root>',
    ],
)
async def test_xml_failure_is_not_website_discovery(setup, content):
    manager, _ = setup
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(200, content=content))
    )
    with pytest.raises(SourceError, match="invalid_feed"):
        await manager.discover(URL)


async def test_reading_a_previewed_source_again_does_not_make_it_unready(setup):
    from datetime import timedelta

    from newspaw.evidence import FeedCollector

    manager, store = setup
    s = source()
    await manager.save(s, store.config_revision())
    await manager.preview("s", now=NOW)
    enabled = {**s, "enabled": True}
    await manager.save(enabled, store.config_revision())
    previewed = manager._epoch("s")[1]

    async def collect(status, minutes):
        client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda r: httpx.Response(status, content=rss()))
        )
        collector = FeedCollector(manager.evidence, client=client)
        try:
            await collector.collect(["sub_world"], now=NOW + timedelta(minutes=minutes))
        finally:
            await collector.close()
        return manager.evidence.history("s")[-1]

    # A digest's own collection reads the source after the preview: it stays ready (R17 F1),
    # so a turned-on digest can still be edited and the source saved again.
    later = await collect(200, 5)
    assert later["id"] != previewed and later["status"] in {"fresh", "not_modified"}
    assert manager._ready(enabled) and manager.list()[0]["preview_ready"]
    await manager.save({**enabled, "name": "Renamed"}, store.config_revision())
    # A read that failed since still takes it back (#17: no later failure) ...
    failed = await collect(500, 10)
    assert failed["status"] == "failed" and not manager._ready(enabled)
    # ... until the source is read successfully again; the recorded preview is the same one.
    await collect(200, 15)
    assert manager._ready(enabled) and manager._epoch("s")[1] == previewed

    # A new preview replaces the record, so one that fails takes the source back (F2).
    manager.client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(500))
    )
    assert not (await manager.preview("s", now=NOW + timedelta(minutes=20)))["preview_ready"]
    assert not manager._ready(enabled)
