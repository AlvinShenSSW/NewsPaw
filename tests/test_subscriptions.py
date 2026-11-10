import pytest
from test_routing import configured

from newspaw.app_config import validate_config
from newspaw.evidence import feed_scopes
from newspaw.routing import resolve_route


def regional_config():
    config, _ = configured()
    sources = [
        dict(
            id=focus,
            name=focus,
            url=f"https://example.com/{focus}",
            kind="rss",
            partition="normal",
            category_ids=["japan"],
            enabled=True,
        )
        for focus in ("domestic", "entertainment")
    ]
    config["sources"].extend(sources)
    sub = next(row for row in config["subscriptions"] if row["category_id"] == "japan")
    sub.update(enabled=True, bot_ids=["bot1"])
    return config, sub


def test_explicit_empty_never_inherits_category_sources_and_cannot_be_enabled():
    config, sub = regional_config()
    sub.update(source_ids=["entertainment"])
    assert [row["id"] for row in resolve_route(config, 1, sub["id"]).effective["sources"]] == [
        "entertainment"
    ]
    sub.update(enabled=False, source_ids=[], source_mode="explicit")
    validate_config(config)
    assert not resolve_route(config, 2, sub["id"]).effective["sources"]
    assert not feed_scopes(config, [sub["id"]])
    sub["enabled"] = True
    with pytest.raises(ValueError, match="explicit source selection"):
        validate_config(config)
    sub["source_ids"] = ["domestic"]
    validate_config(config)
    assert [row["id"] for row in resolve_route(config, 3, sub["id"]).effective["sources"]] == [
        "domestic"
    ]
    sub.update(source_mode="category", source_ids=[])
    validate_config(config)
    assert [row["id"] for row in resolve_route(config, 4, sub["id"]).effective["sources"]] == [
        "domestic",
        "entertainment",
    ]


def test_regional_focus_zero_excludes_only_the_configured_facet():
    config, sub = regional_config()
    for source in config["sources"]:
        if source["id"] in {"domestic", "entertainment"}:
            source["focus"] = source["id"]
    sub["focus_weights"] = {"domestic": 100, "entertainment": 0}
    validate_config(config)
    route = resolve_route(config, 1, sub["id"])
    assert [row["id"] for row in route.effective["sources"]] == ["domestic"]
    assert [row["url"] for row in feed_scopes(config, [sub["id"]])] == [
        "https://example.com/domestic"
    ]
    sub["focus_weights"] = {"domestic": 30, "entertainment": 70}
    updated = resolve_route(config, 2, sub["id"])
    assert route.fingerprint != updated.fingerprint
    assert [row["id"] for row in updated.effective["sources"]] == ["domestic", "entertainment"]


async def test_save_incomplete_explicit_empty_draft_and_reject_activation_or_old_revision(tmp_path):
    from contextlib import closing

    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialError, CredentialManager
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store
    from newspaw.subscriptions import SubscriptionError, Subscriptions
    from newspaw.telegram.registry import BotRegistry

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = regional_config()
        sub["source_ids"] = ["entertainment"]
        revision = store.save_config(config, expected_revision=1)
        keychain = FakeKeychain()
        manager = CredentialManager(store, keychain)
        service = Subscriptions(manager, SourceManager(manager), BotRegistry(store, keychain))
        draft = {key: value for key, value in sub.items() if key != "enabled"}
        draft.update(source_ids=[], source_mode="explicit", bot_ids=[], times=[])
        status = service.preview(draft, revision)
        assert {"no_sources", "no_target", "schedule_missing"} <= set(status["blockers"])
        with pytest.raises(SubscriptionError, match="subscription_not_ready"):
            await service.save(draft, revision, enable=True)
        assert store.config_revision() == revision
        result = await service.save(draft, revision)
        assert not result["enabled"] and result["revision"] == revision + 1
        assert not feed_scopes(store.load_config()[1], [draft["id"]])
        with pytest.raises(CredentialError, match="config_conflict"):
            await service.save({**draft, "source_mode": "category"}, revision)
        assert not feed_scopes(store.load_config()[1], [draft["id"]])


def test_pause_delete_impact_uses_shared_scope_and_never_mutates(tmp_path):
    from contextlib import closing

    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialManager
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = regional_config()
        sub.update(source_mode="explicit", source_ids=["entertainment"])
        revision = store.save_config(config, expected_revision=1)
        manager = SourceManager(CredentialManager(store, FakeKeychain()))
        pause = manager.impact("entertainment", "pause")
        delete = manager.impact("entertainment", "delete")
        assert pause["revision"] == delete["revision"] == revision
        assert pause["subscriptions"][0]["enabled"]
        assert "source_disabled" in pause["subscriptions"][0]["blockers"]
        assert not delete["subscriptions"][0]["enabled"]
        assert "no_sources" in delete["subscriptions"][0]["blockers"]
        assert manager.impact("domestic", "delete")["subscriptions"] == []
        assert store.load_config() == (revision, config)


async def test_pause_category_is_revision_checked_and_preserves_other_subscriptions(tmp_path):
    from contextlib import closing

    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialError, CredentialManager
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store
    from newspaw.subscriptions import SubscriptionError, Subscriptions
    from newspaw.telegram.registry import BotRegistry

    with closing(Store(tmp_path / "state.db")) as store:
        config, regional = regional_config()
        split = {**regional, "id": "regional_entertainment", "times": ["21:00"]}
        inactive = {**regional, "id": "regional_draft", "enabled": False}
        foreign = next(row for row in config["subscriptions"] if row["category_id"] == "world")
        foreign["enabled"] = True
        config["subscriptions"].extend((split, inactive))
        revision = store.save_config(config, expected_revision=1)
        keychain = FakeKeychain()
        manager = CredentialManager(store, keychain)
        service = Subscriptions(manager, SourceManager(manager), BotRegistry(store, keychain))

        with pytest.raises(CredentialError, match="config_conflict"):
            await service.pause_category("japan", revision - 1)
        with pytest.raises(SubscriptionError, match="unknown_category"):
            await service.pause_category("unrecognized", revision)
        assert store.load_config() == (revision, config)

        assert await service.pause_category("japan", revision) == {
            "revision": revision + 1,
            "paused": 2,
        }
        for row in (regional, split):
            row["enabled"] = False
        assert store.load_config() == (revision + 1, config)
        assert await service.pause_category("japan", revision + 1) == {
            "revision": revision + 1,
            "paused": 0,
        }


def test_weighted_order_prioritizes_existing_evidence_without_filling_gaps():
    from newspaw.editorial import _focus_order

    items = [
        {"id": "d1", "coverage_focus": "domestic"},
        {"id": "d2", "coverage_focus": "domestic"},
        {"id": "e1", "coverage_focus": "entertainment"},
        {"id": "e2", "coverage_focus": "entertainment"},
    ]
    result = _focus_order(items, {"domestic": 30, "entertainment": 70})
    assert [row["id"] for row in result] == ["e1", "e2", "d1", "d2"]
    assert _focus_order(items[:2], {"domestic": 30, "entertainment": 70}) == items[:2]


async def test_drafts_without_model_overrides_keep_the_saved_ones(tmp_path):
    from contextlib import closing

    from test_credentials import FakeKeychain
    from test_routing import configured

    from newspaw.credentials import CredentialManager
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store
    from newspaw.subscriptions import Subscriptions
    from newspaw.telegram.registry import BotRegistry

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        sub["backup_profile_id"] = "normal_backup"
        revision = store.save_config(config, expected_revision=1)
        keychain = FakeKeychain()
        manager = CredentialManager(store, keychain)
        service = Subscriptions(manager, SourceManager(manager), BotRegistry(store, keychain))
        draft = {
            key: value
            for key, value in sub.items()
            if key not in {"enabled", "primary_profile_id", "backup_profile_id"}
        }
        draft.update(max_items=3, source_mode="category")
        await service.save(draft, revision)
        saved = next(s for s in store.load_config()[1]["subscriptions"] if s["id"] == sub["id"])
        assert saved["max_items"] == 3 and saved["backup_profile_id"] == "normal_backup"
        assert saved["primary_profile_id"] is None


def test_a_backup_without_a_key_does_not_block_the_route():
    config, sub = configured()
    for profile in config["model_profiles"]:
        if profile["id"] == "normal_backup":
            profile["credential_ref"] = None
    route = resolve_route(config, 1, sub["id"])
    assert "missing_backup_credential" not in route.blockers
    assert route.effective["backup"]["id"] == "normal_backup"
    for profile in config["model_profiles"]:
        if profile["id"] == "normal_primary":
            profile["credential_ref"] = None
    assert "missing_primary_credential" in resolve_route(config, 1, sub["id"]).blockers


async def test_a_digest_turns_on_with_a_checked_main_model_and_no_backup_key(tmp_path, monkeypatch):
    from contextlib import closing

    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialManager
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store
    from newspaw.subscriptions import Subscriptions
    from newspaw.telegram.registry import BotRegistry

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        for profile in config["model_profiles"]:
            if profile["id"] == "normal_backup":
                profile["credential_ref"] = None
        sub["enabled"] = False
        revision = store.save_config(config, expected_revision=1)
        keychain = FakeKeychain()
        manager = CredentialManager(store, keychain)
        registry = BotRegistry(store, keychain)
        service = Subscriptions(manager, SourceManager(manager), registry)
        states = {"normal_primary": "verified", "normal_backup": "untested"}
        monkeypatch.setattr(
            service.profiles, "status", lambda profile_id: {"text": {"state": states[profile_id]}}
        )
        monkeypatch.setattr(service.sources, "_ready", lambda source: True)
        monkeypatch.setattr(registry, "snapshot", lambda bot_id: type("B", (), {"owner_id": 123})())
        draft = {key: value for key, value in sub.items() if key != "enabled"}
        draft["source_mode"] = "category"
        preview = service.preview(draft, revision)
        assert preview["blockers"] == []
        assert preview["profiles"]["backup"]["status"] == "untested"
        result = await service.save(draft, revision, enable=True)
        assert result["enabled"]
        states["normal_primary"] = "failed"
        assert "primary_unverified" in service.preview(draft, result["revision"])["blockers"]


async def test_a_turned_on_digest_can_still_be_edited_after_it_collected(tmp_path, monkeypatch):
    """R17 F3: the digest's own collection must not leave its sources "not previewed"."""
    from contextlib import closing
    from datetime import timedelta

    import httpx
    from test_credentials import FakeKeychain
    from test_evidence import NOW, rss

    from newspaw.credentials import CredentialManager
    from newspaw.evidence import FeedCollector
    from newspaw.source_manager import SourceManager
    from newspaw.store import Store
    from newspaw.subscriptions import SubscriptionError, Subscriptions
    from newspaw.telegram.registry import BotRegistry

    def client(status=200):
        return httpx.AsyncClient(
            transport=httpx.MockTransport(lambda r: httpx.Response(status, content=rss()))
        )

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        config["sources"][0]["enabled"] = False
        sub["enabled"] = False
        store.save_config(config, expected_revision=1)
        keychain = FakeKeychain()
        manager = CredentialManager(store, keychain)
        registry = BotRegistry(store, keychain)
        sources = SourceManager(manager, client_factory=client)
        service = Subscriptions(manager, sources, registry)
        monkeypatch.setattr(service.profiles, "status", lambda p: {"text": {"state": "verified"}})
        monkeypatch.setattr(registry, "snapshot", lambda b: type("B", (), {"owner_id": 123})())

        async def collect(status, minutes):
            collector = FeedCollector(sources.evidence, client=client(status))
            try:
                await collector.collect([sub["id"]], now=NOW + timedelta(minutes=minutes))
            finally:
                await collector.close()

        draft = {key: value for key, value in sub.items() if key != "enabled"}
        draft["source_mode"] = "category"
        await sources.preview("feed1", now=NOW)
        await sources.save(
            {**store.load_config()[1]["sources"][0], "enabled": True}, store.config_revision()
        )
        assert (await service.save(draft, store.config_revision(), enable=True))["enabled"]

        await collect(200, 5)
        preview = service.preview(draft, store.config_revision())
        assert preview["blockers"] == [] and preview["sources"][0]["ready"]
        edited = await service.save(
            {**draft, "name": "Edited"}, store.config_revision(), enable=True
        )
        assert edited["enabled"]

        # A source whose latest read failed is still named as the thing to try again.
        await collect(500, 10)
        assert service.preview(draft, store.config_revision())["blockers"] == [
            "source_preview_required"
        ]
        with pytest.raises(SubscriptionError, match="subscription_not_ready"):
            await service.save({**draft, "name": "Again"}, store.config_revision(), enable=True)
