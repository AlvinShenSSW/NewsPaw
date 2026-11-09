from copy import deepcopy
from dataclasses import FrozenInstanceError

import pytest

from newspaw.app_config import default_config, validate_config
from newspaw.routing import RouteBlocked, RouteStale, resolve_route
from newspaw.store import Store

REF = "keychain:00000000-0000-0000-0000-000000000001"


def configured(partition="normal"):
    config = default_config()
    config["owner_id"] = 123
    for profile in config["model_profiles"]:
        profile["credential_ref"] = REF
    config["bots"] = [
        dict(
            id="bot1",
            name="Personal",
            credential_ref=REF,
            telegram_id=999,
            chat_id=123,
            verified=True,
            paired=True,
            adult_allowed=partition == "adult",
        )
    ]
    category = "world" if partition == "normal" else "av"
    config["sources"] = [
        dict(
            id="feed1",
            name="Feed",
            url="https://example.com/rss",
            kind="rss",
            partition=partition,
            category_ids=[category],
            enabled=True,
        )
    ]
    sub = next(s for s in config["subscriptions"] if s["category_id"] == category)
    sub.update(enabled=True, bot_ids=["bot1"])
    return config, sub


def account(config, sub, *, priority="special"):
    entry = dict(
        id="account1",
        remote_id="100",
        handle="example",
        partition="normal",
        priority=priority,
        subscription_id=sub["id"],
        bot_ids=None,
        times=None,
        style=None,
    )
    config["accounts"].append(entry)
    return entry


def test_precedence_does_not_mutate_config():
    config, sub = configured()
    item = account(config, sub)
    sub["style"] = "newspaper"
    before = deepcopy(config)
    route = resolve_route(config, 1, sub["id"], account_id=item["id"])
    assert route.effective["style"] == "newspaper"
    assert route.explanation["style"] == "subscription"
    assert config == before
    sub["style"] = "text"
    item["style"] = "source_image"
    route = resolve_route(config, 1, sub["id"], account_id=item["id"], style="newspaper")
    assert route.effective["style"] == "newspaper"
    assert route.explanation["style"] == "request"
    item["priority"] = "normal"
    assert resolve_route(config, 1, sub["id"], account_id=item["id"]).effective["style"] == "text"


@pytest.mark.parametrize("partition", ["normal", "adult"])
def test_partition_slots_and_adult_explicit_target(partition):
    config, sub = configured(partition)
    route = resolve_route(config, 1, sub["id"])
    assert not route.blockers
    assert route.effective["primary"]["id"] == partition + "_primary"
    assert route.effective["backup"]["partition"] == partition
    sub["primary_profile_id"] = "adult_primary" if partition == "normal" else "normal_primary"
    with pytest.raises(ValueError, match="Cross-partition"):
        validate_config(config)
    sub["primary_profile_id"] = None
    if partition == "adult":
        config["bots"][0]["adult_allowed"] = False
        with pytest.raises(ValueError, match="Adult"):
            validate_config(config)


def test_unclassified_drafts_and_wrong_account_binding():
    config, sub = configured()
    draft = account(config, sub)
    draft.update(partition=None, subscription_id=None)
    config["sources"].append(
        dict(
            id="draft",
            name="Draft",
            url="https://example.com",
            kind="draft",
            partition=None,
            category_ids=[],
            enabled=False,
        )
    )
    validate_config(config)
    route = resolve_route(config, 1, sub["id"], account_id="account1")
    assert "unclassified_account" in route.blockers
    assert route.effective.get("primary") is None
    draft.update(partition="adult", subscription_id=sub["id"])
    with pytest.raises(ValueError, match="Cross-partition"):
        validate_config(config)


def test_account_empty_overrides_and_snapshot_immutable():
    config, sub = configured()
    item = account(config, sub)
    route = resolve_route(config, 1, sub["id"], account_id=item["id"])
    assert route.effective["bots"][0]["id"] == "bot1"
    route.effective["bots"].clear()
    assert route.effective["bots"]
    with pytest.raises(FrozenInstanceError):
        route.fingerprint = "different"
    item.update(bot_ids=[], times=[])
    route = resolve_route(config, 1, sub["id"], account_id=item["id"])
    assert "no_target" in route.blockers
    assert route.effective["times"] == []


def test_route_revalidation_and_ui_only_change(tmp_path):
    config, sub = configured()
    store = Store(tmp_path / "state.db")
    store.save_config(config, expected_revision=1)
    route = store.preview_route(sub["id"])
    config["ui_locale"] = "ja"
    config["bots"][0]["name"] = "Renamed"
    store.save_config(config, expected_revision=2)
    assert store.config_revision() == 3
    assert store.revalidate_route(route).revision == 3
    config["news_output_locale"] = "en"
    store.save_config(config, expected_revision=3)
    with pytest.raises(RouteStale):
        store.revalidate_route(route)
    current = store.preview_route(sub["id"])
    sub["enabled"] = False
    store.save_config(config, expected_revision=4)
    with pytest.raises(RouteBlocked):
        store.revalidate_route(current)
    store.close()


@pytest.mark.parametrize("field", ["model", "source", "bot", "schedule", "style", "credential"])
def test_execution_changes_invalidate_route(tmp_path, field):
    config, sub = configured()
    with_store = Store(tmp_path / "state.db")
    with_store.save_config(config, expected_revision=1)
    route = with_store.preview_route(sub["id"])
    if field == "model":
        config["model_profiles"][0]["model"] = "new-model"
    elif field == "source":
        config["sources"][0]["url"] = "https://example.com/new"
    elif field == "bot":
        config["bots"][0]["telegram_id"] = 998
    elif field == "schedule":
        sub["times"] = ["12:00"]
    elif field == "style":
        sub["style"] = "newspaper"
    else:
        config["model_profiles"][0]["credential_ref"] = REF[:-1] + "2"
    with_store.save_config(config, expected_revision=2)
    with pytest.raises(RouteStale):
        with_store.revalidate_route(route)
    with_store.close()


@pytest.mark.parametrize("change", ["remove", "move", "priority", "partition"])
def test_x_aggregate_member_changes_invalidate(tmp_path, change):
    config, _ = configured()
    sub = next(s for s in config["subscriptions"] if s["category_id"] == "x")
    sub.update(enabled=True, bot_ids=["bot1"])
    item = account(config, sub, priority="normal")
    second = deepcopy(item)
    second.update(id="account2", remote_id="101")
    config["accounts"].append(second)
    store = Store(tmp_path / "state.db")
    store.save_config(config, expected_revision=1)
    route = store.preview_route(sub["id"])
    assert len(route.effective["accounts"]) == 2
    if change == "remove":
        config["accounts"].remove(item)
    elif change == "move":
        item["subscription_id"] = None
    elif change == "priority":
        item["priority"] = "special"
    else:
        item.update(partition="adult", subscription_id="sub_x_adult")
    store.save_config(config, expected_revision=2)
    with pytest.raises(RouteStale):
        store.revalidate_route(route)
    store.close()


def test_missing_deleted_and_disabled_refs_fail_closed():
    config, sub = configured()
    sub["source_ids"] = ["feed1"]
    config["sources"][0]["enabled"] = False
    assert "source_disabled" in resolve_route(config, 1, sub["id"]).blockers
    config["sources"] = []
    with pytest.raises(ValueError):
        resolve_route(config, 1, sub["id"])
    sub["source_ids"] = []
    config["model_profiles"] = []
    route = resolve_route(config, 1, sub["id"])
    assert "missing_primary" in route.blockers
    assert "no_sources" in route.blockers


def test_same_group_override_and_wrong_role_rejected():
    config, sub = configured()
    custom = deepcopy(config["model_profiles"][0])
    custom.update(id="custom", model="custom-model")
    config["model_profiles"].append(custom)
    sub["primary_profile_id"] = "custom"
    route = resolve_route(config, 1, sub["id"])
    assert route.effective["primary"]["model"] == "custom-model"
    assert route.explanation["primary"] == "subscription"
    sub["backup_profile_id"] = "custom"
    with pytest.raises(ValueError, match="role"):
        validate_config(config)


def test_unpair_or_delete_subscription_blocks_old_route(tmp_path):
    config, sub = configured()
    store = Store(tmp_path / "state.db")
    store.save_config(config, expected_revision=1)
    route = store.preview_route(sub["id"])
    config["bots"][0]["paired"] = False
    store.save_config(config, expected_revision=2)
    with pytest.raises(RouteBlocked, match="target_unpaired"):
        store.revalidate_route(route)
    config["subscriptions"].remove(sub)
    store.save_config(config, expected_revision=3)
    with pytest.raises(RouteBlocked, match="missing_subscription"):
        store.revalidate_route(route)
    store.close()


def test_source_must_belong_to_category_and_drafts_cannot_run():
    config, sub = configured()
    sub["source_ids"] = ["feed1"]
    config["sources"][0]["category_ids"] = ["japan"]
    with pytest.raises(ValueError, match="assigned"):
        validate_config(config)
    config["sources"][0]["category_ids"] = ["world"]
    config["sources"][0]["kind"] = "draft"
    assert "source_unadapted" in resolve_route(config, 1, sub["id"]).blockers


def test_inherited_default_slot_cannot_be_saved_in_wrong_partition():
    config, _ = configured()
    config["model_profiles"][0]["partition"] = "adult"
    with pytest.raises(ValueError, match="Cross-partition"):
        validate_config(config)


def test_unpaired_target_does_not_block_healthy_selected_bot(tmp_path):
    config, sub = configured()
    unavailable = deepcopy(config["bots"][0])
    unavailable.update(id="bot2", telegram_id=1000, paired=False)
    config["bots"].append(unavailable)
    sub["bot_ids"].append("bot2")
    store = Store(tmp_path / "state.db")
    store.save_config(config, expected_revision=1)
    route = store.preview_route(sub["id"])
    assert not route.blockers
    assert [b["id"] for b in route.effective["bots"]] == ["bot1"]
    assert route.effective["target_diagnostics"] == {"bot2": "target_unpaired"}
    assert store.revalidate_route(route) == route
    unavailable["paired"] = True
    store.save_config(config, expected_revision=2)
    with pytest.raises(RouteStale):
        store.revalidate_route(route)
    assert len(store.preview_route(sub["id"]).effective["bots"]) == 2
    store.close()
