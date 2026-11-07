import pytest
from test_credentials import FakeKeychain
from test_routing import configured
from test_telegram_registry import API, NOW, Keys, bind, update

from newspaw.credentials import CredentialManager
from newspaw.store import Store
from newspaw.telegram.registry import Binding, BotRegistry
from newspaw.telegram.targets import TargetError, TargetManager


@pytest.fixture
async def setup(tmp_path):
    store = Store(tmp_path / "state.db")
    config, _ = configured()
    config["bots"].append(
        {
            **config["bots"][0],
            "id": "bot2",
            "name": "Second",
            "verified": False,
            "paired": False,
            "telegram_id": None,
            "chat_id": None,
        }
    )
    store.save_config(config, expected_revision=1)
    api = API()
    registry = BotRegistry(store, Keys(), client_factory=lambda token: api)
    await bind(registry, api)
    second = API()
    second.remote_id = 1000
    registry.client_factory = lambda token: second
    await registry.verify("bot2", now=NOW)
    code = registry.pair_code("bot2", now=NOW)["code"]
    second.updates = [update("/pair " + code)]
    await registry.poll_once("bot2", now=NOW)
    manager = TargetManager(CredentialManager(store, FakeKeychain()), registry)
    yield manager, registry, store
    await registry.close()
    store.close()


async def test_two_ready_then_paused_does_not_block_healthy(setup):
    manager, registry, store = setup
    await manager.set_subscription("sub_world", ["bot1", "bot2"], store.config_revision())
    preview = manager.preview("sub_world")
    assert preview["ready_bot_ids"] == ["bot1", "bot2"]
    bindings = {b["bot_id"]: Binding(**b) for b in preview["bindings"]}
    registry.action("bot1", "pause", now=NOW)
    preview = manager.preview("sub_world")
    assert preview["ready_bot_ids"] == ["bot2"] and preview["target_status"]["bot1"] == "paused"
    manager.revalidate_target("sub_world", "bot2", bindings["bot2"])
    with pytest.raises(TargetError):
        manager.revalidate_target("sub_world", "bot1", bindings["bot1"])


async def test_target_only_edit_preserves_other_news_settings(setup):
    manager, _, store = setup
    before = store.load_config()[1]
    await manager.set_subscription("sub_world", ["bot2"], store.config_revision())
    after = store.load_config()[1]
    before["subscriptions"][0]["bot_ids"] = ["bot2"]
    assert after == before
    with pytest.raises(TargetError, match="duplicate_target"):
        await manager.set_subscription("sub_world", ["bot2", "bot2"], store.config_revision())


async def test_special_inherit_empty_override_and_ordinary_scope(setup):
    manager, registry, store = setup
    rev, config = store.load_config()
    config["accounts"] = [
        dict(
            id="a",
            remote_id="12345",
            handle="fixture",
            partition="normal",
            priority="special",
            subscription_id="sub_x",
            bot_ids=None,
            times=None,
            style=None,
        )
    ]
    store.save_config(config, expected_revision=rev)
    await manager.set_subscription("sub_x", ["bot1"], store.config_revision())
    assert manager.preview("sub_x", account_id="a")["ready_bot_ids"] == ["bot1"]
    await manager.set_account("a", [], store.config_revision())
    assert manager.preview("sub_x", account_id="a")["target_status"] == {}
    await manager.set_account("a", ["bot2"], store.config_revision())
    assert manager.preview("sub_x", account_id="a")["ready_bot_ids"] == ["bot2"]
    assert manager.preview("sub_x")["ready_bot_ids"] == ["bot1"]
    with pytest.raises(TargetError):
        manager.revalidate_target("sub_x", "bot2", registry.snapshot("bot2"))
    await manager.set_account("a", None, store.config_revision())
    assert manager.preview("sub_x", account_id="a")["target_origin"] == "subscription"
    rev, config = store.load_config()
    config["accounts"][0]["priority"] = "normal"
    store.save_config(config, expected_revision=rev)
    with pytest.raises(TargetError, match="special_account_required"):
        await manager.set_account("a", ["bot2"], store.config_revision())


async def test_adult_requires_explicit_choice_and_optout_removes_only_adult(setup):
    manager, _, store = setup
    with pytest.raises(TargetError, match="adult_permission_required"):
        await manager.set_subscription("sub_av", ["bot1"], store.config_revision())
    await manager.adult_permission("bot1", True, store.config_revision())
    assert manager.preview("sub_av")["ready_bot_ids"] == []
    await manager.set_subscription("sub_av", ["bot1"], store.config_revision())
    assert manager.preview("sub_av")["ready_bot_ids"] == ["bot1"]
    result = await manager.adult_permission("bot1", False, store.config_revision())
    assert "sub_av" in result["affected_subscriptions"]
    assert manager.preview("sub_av")["ready_bot_ids"] == []
    assert manager.preview("sub_world")["ready_bot_ids"] == ["bot1"]


async def test_partition_change_clears_overrides_until_explicit_rebinding(setup):
    manager, _, store = setup
    rev, config = store.load_config()
    config["accounts"] = [
        dict(
            id="a",
            remote_id="12345",
            handle="fixture",
            partition="normal",
            priority="special",
            subscription_id="sub_x",
            bot_ids=["bot1"],
            times=["09:00"],
            style="newspaper",
        )
    ]
    store.save_config(config, expected_revision=rev)
    await manager.account_partition("a", "adult", store.config_revision())
    a = store.load_config()[1]["accounts"][0]
    assert (
        a["subscription_id"] is None
        and a["bot_ids"] == []
        and a["times"] is None
        and a["style"] is None
    )
    assert a["remote_id"] == "12345" and a["priority"] == "special"
    with pytest.raises(TargetError, match="account_subscription_required"):
        await manager.set_account("a", None, store.config_revision())
    await manager.account_partition("a", "normal", store.config_revision())
    assert store.load_config()[1]["accounts"][0]["bot_ids"] == []


async def test_delete_impact_cas_and_binding_revocation(setup):
    manager, registry, store = setup
    binding = registry.snapshot("bot1")
    impact = manager.bot_impact("bot1")
    assert (
        "sub_world" in impact["subscriptions"]
        and "sub_world" in impact["last_target_subscriptions"]
    )
    before = store.load_config()
    with pytest.raises(ValueError):
        await manager.delete_bot("bot1", before[0] - 1)
    assert store.load_config() == before
    result = await manager.delete_bot("bot1", store.config_revision())
    assert result["impact"]["subscriptions"] == impact["subscriptions"]
    with pytest.raises(TargetError):
        manager.revalidate_target("sub_world", "bot1", binding)


async def test_readonly_matrix_distinguishes_unverified_unpaired_and_no_target(setup):
    manager, registry, store = setup
    await manager.set_subscription("sub_world", ["bot1", "bot2"], store.config_revision())
    registry.action("bot2", "unbind", now=NOW)
    assert manager.preview("sub_world")["target_status"] == {"bot1": "ready", "bot2": "unpaired"}
    rev, config = store.load_config()
    config["bots"][1]["credential_ref"] = "keychain:00000000-0000-0000-0000-000000000002"
    config["bots"][1].update(verified=True, paired=True, telegram_id=1000, chat_id=123)
    store.save_config(config, expected_revision=rev)
    registry.backend.read = lambda ref: pytest.fail("Readonly preview cannot read credentials")
    assert manager.preview("sub_world")["target_status"]["bot2"] == "unverified"
    assert [b["id"] for b in manager.preview("sub_world")["effective"]["bots"]] == ["bot1"]
    await manager.set_subscription("sub_world", [], store.config_revision())
    assert "no_target" in manager.preview("sub_world")["blockers"]


async def test_category_bulk_preserves_special_overrides_and_other_fields(setup):
    manager, _, store = setup
    rev, config = store.load_config()
    sub = next(s for s in config["subscriptions"] if s["id"] == "sub_world")
    config["subscriptions"].append(
        {**sub, "id": "extra", "name": "Extra", "times": ["10:00"], "style": "newspaper"}
    )
    config["accounts"] = [
        dict(
            id="a",
            remote_id="12345",
            handle="fixture",
            partition="normal",
            priority="special",
            subscription_id="sub_world",
            bot_ids=["bot1"],
            times=["08:00"],
            style="source_image",
        )
    ]
    store.save_config(config, expected_revision=rev)
    before = store.load_config()[1]
    result = await manager.set_category("world", ["bot2"], store.config_revision())
    assert (
        result["affected_subscriptions"] == ["extra", "sub_world"]
        and result["affected_accounts"] == []
    )
    after = store.load_config()[1]
    for s in before["subscriptions"]:
        if s["category_id"] == "world":
            s["bot_ids"] = ["bot2"]
    assert before == after
    assert manager.preview("sub_world", account_id="a")["ready_bot_ids"] == ["bot1"]
    rev = store.config_revision()
    await manager.set_category("world", ["bot2"], rev)
    assert store.config_revision() == rev


async def test_impact_tracks_inherited_and_explicit_specials_only(setup):
    manager, _, store = setup
    rev, config = store.load_config()
    template = dict(
        remote_id="12345",
        handle="fixture",
        partition="normal",
        priority="special",
        subscription_id="sub_world",
        bot_ids=None,
        times=None,
        style=None,
    )
    config["accounts"] = [
        dict(template, id="inherited"),
        dict(template, id="explicit", bot_ids=["bot1", "bot2"]),
        dict(template, id="ordinary", priority="normal", bot_ids=["bot1"]),
    ]
    store.save_config(config, expected_revision=rev)
    impact = manager.bot_impact("bot1")
    assert impact["accounts"] == [
        dict(id="inherited", inherited=True, last_target=True),
        dict(id="explicit", inherited=False, last_target=False),
    ]
    result = await manager.set_subscription("sub_world", ["bot2"], store.config_revision())
    assert result["affected_accounts"] == ["inherited"]


async def test_removed_target_disabled_subscription_and_stale_binding_deny(setup):
    manager, registry, store = setup
    binding = registry.snapshot("bot1")
    await manager.set_subscription("sub_world", ["bot2"], store.config_revision())
    with pytest.raises(TargetError, match="target_not_ready"):
        manager.revalidate_target("sub_world", "bot1", binding)
    await manager.set_subscription("sub_world", ["bot1"], store.config_revision())
    rev, config = store.load_config()
    next(s for s in config["subscriptions"] if s["id"] == "sub_world")["enabled"] = False
    store.save_config(config, expected_revision=rev)
    with pytest.raises(TargetError, match="subscription_disabled"):
        manager.revalidate_target("sub_world", "bot1", binding)


async def test_subscription_assignment_cas_and_unknown_target_atomic(setup):
    manager, _, store = setup
    before = store.load_config()
    with pytest.raises(ValueError):
        await manager.set_subscription("sub_world", ["bot2"], before[0] - 1)
    with pytest.raises(TargetError):
        await manager.set_subscription("sub_world", ["missing"], before[0])
    assert store.load_config() == before
