import json
from contextlib import closing

import httpx
import pytest
from test_credentials import FakeKeychain

from newspaw.budget import BudgetLedger
from newspaw.credentials import CredentialManager
from newspaw.store import Store
from newspaw.telegram.registry import BotRegistry
from newspaw.telegram.targets import TargetManager
from newspaw.x.accounts import XDirectory, XError
from newspaw.x.client import XClient


@pytest.fixture
async def system(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        keys = FakeKeychain()
        credentials = CredentialManager(store, keys)
        await credentials.set("x_api", "x", "fixture-bearer-value", store.config_revision())
        targets = TargetManager(credentials, BotRegistry(store, keys))
        yield store, credentials, targets
        await targets.registry.close()


def directory(system, responder):
    store, credentials, targets = system
    requests = []

    async def handler(request):
        requests.append(request)
        assert request.url.host == "api.x.com" and request.method == "GET"
        return await responder(request, len(requests))

    def factory(token):
        return XClient(token, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))

    return XDirectory(credentials, targets, client_factory=factory), requests


def user(identity, name, protected=False):
    return dict(id=identity, username=name, protected=protected)


async def test_verified_rename_keeps_identity_and_repeated_operation_does_not_read(system):
    store, _, _ = system

    async def response(request, ordinal):
        expected = "/2/users/by/username/fixture" if ordinal == 1 else "/2/users/12345"
        assert request.url.path == expected
        return httpx.Response(
            200, json={"data": user("12345", "fixture" if ordinal == 1 else "renamed")}
        )

    x, requests = directory(system, response)
    account = (await x.add_account("@fixture", store.config_revision()))["account"]
    assert (await x.add_account("FiXtUrE", store.config_revision()))["account"]["id"] == account[
        "id"
    ]
    revision = store.config_revision()
    result = await x.verify(account["id"], "read.1", revision)
    assert result["state"] == "ready"
    assert await x.verify(account["id"], "read.1", revision) == result
    assert len(requests) == 1
    renamed = await x.verify(account["id"], "read.2", store.config_revision())
    assert renamed["account"]["id"] == account["id"]
    assert renamed["account"]["handle"] == "renamed"
    assert renamed["account"]["remote_id"] == "12345"
    assert len(store.load_config()[1]["accounts"]) == 1
    assert "fixture-bearer-value" not in "\n".join(store._db.iterdump())


async def test_complete_list_updates_only_membership_partial_preserves_it(system):
    store, _, _ = system
    members = [user("12345", "original")]
    next_token = None

    async def response(request, ordinal):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        assert request.url.path == "/2/lists/456/members"
        meta = {"result_count": len(members)}
        if next_token:
            meta["next_token"] = next_token
        return httpx.Response(200, json={"data": members, "meta": meta})

    x, requests = directory(system, response)
    entry = x.add_list("https://x.com/i/lists/456", "normal", store.config_revision())
    assert entry["id"] == "456"
    first = await x.refresh_list("456", "list.1", store.config_revision(), page_size=5)
    assert first["state"] == "ready"
    config = store.load_config()[1]
    original = config["accounts"][0]
    assert original["partition"] is None and original["subscription_id"] is None
    members = [user("56789", "replacement")]
    next_token = "page-2"
    partial = await x.refresh_list(
        "456", "list.2", store.config_revision(), page_size=5, max_pages=1
    )
    assert partial["state"] == "partial"
    assert [row["id"] for row in store.load_config()[1]["accounts"]] == [original["id"]]
    next_token = None
    complete = await x.refresh_list("456", "list.3", store.config_revision(), page_size=5)
    assert complete["state"] == "ready"
    assert x.account_status(original["id"])["member_active"] is False
    assert len(requests) == 6


async def test_exact_account_delete_readd_does_not_revive_old_observation(system):
    store, _, _ = system

    async def response(request, ordinal):
        return httpx.Response(200, json={"data": user("12345", "fixture")})

    x, _ = directory(system, response)
    item = (await x.add_account("fixture", store.config_revision()))["account"]
    await x.verify(item["id"], "read.1", store.config_revision())
    revision, config = store.load_config()
    original = config["accounts"].pop()
    revision = store.save_config(config, expected_revision=revision)
    config["accounts"].append(original)
    store.save_config(config, expected_revision=revision)
    assert x.account_status(item["id"])["state"] != "ready"


async def test_unknown_lookup_keeps_budget_and_repeated_request_has_no_io(system):
    store, _, _ = system

    async def response(request, ordinal):
        raise httpx.ReadTimeout("fixture X read lost")

    x, requests = directory(system, response)
    item = (await x.add_account("fixture", store.config_revision()))["account"]
    revision = store.config_revision()
    result = await x.verify(item["id"], "read.1", revision)
    assert result["state"] == "outcome_unknown"
    assert await x.verify(item["id"], "read.1", revision) == result
    assert len(requests) == 1
    assert store._db.execute(
        "SELECT state,reserved_units FROM budget_attempts WHERE meter='x'"
    ).fetchall() == [
        ("outcome_unknown", 1),
    ]


async def test_budget_prevents_request_before_dispatch(system):
    store, _, _ = system

    async def response(request, ordinal):
        pytest.fail("request must be blocked by the budget")

    x, requests = directory(system, response)
    item = (await x.add_account("fixture", store.config_revision()))["account"]
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["x"]["daily_limit"] = 0
    ledger.configure(policy, revision)
    result = await x.verify(item["id"], "read.1", store.config_revision())
    assert result["state"] == "budget_blocked"
    assert not requests


async def test_rotation_requires_current_credential_observation(system):
    store, credentials, _ = system

    async def response(request, ordinal):
        return httpx.Response(200, json={"data": user("12345", "fixture")})

    x, _ = directory(system, response)
    item = (await x.add_account("fixture", store.config_revision()))["account"]
    assert (await x.verify(item["id"], "read.1", store.config_revision()))["state"] == "ready"
    await credentials.set("x_api", "x", "fixture-new-bearer", store.config_revision())
    assert x.account_status(item["id"])["state"] == "credential_changed"


def test_config_v2_upgrade_preserves_existing_route_fingerprint(tmp_path):
    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        revision, config = store.load_config()
        before = store.preview_route("sub_world")
        config["schema_version"] = 2
        config.pop("x_api")
        with store._write():
            store._db.execute(
                "UPDATE app_configuration SET document=? WHERE id=1",
                (json.dumps(config),),
            )
            store._db.execute("PRAGMA user_version=12")
    with closing(Store(path)) as upgraded:
        revision, actual = upgraded.load_config()
        assert actual["schema_version"] == 3 and actual["x_api"]["credential_ref"] is None
        assert upgraded.preview_route("sub_world").fingerprint == before.fingerprint
        actual["news_output_locale"] = "ja"
        upgraded.save_config(actual, expected_revision=revision)
        assert upgraded.preview_route("sub_world").fingerprint != before.fingerprint


async def test_adult_list_classification_does_not_create_route_and_private_stops_first_read(system):
    store, _, _ = system

    async def response(request, ordinal):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        if request.url.path == "/2/lists/789":
            return httpx.Response(
                200, json={"data": {"id": "789", "name": "Fixture Private", "private": True}}
            )
        assert request.url.path == "/2/lists/456/members"
        return httpx.Response(
            200, json={"data": [user("12345", "fixture")], "meta": {"result_count": 1}}
        )

    x, requests = directory(system, response)
    x.add_list("456", "adult", store.config_revision(), default_adult=True)
    result = await x.refresh_list("456", "list.1", store.config_revision())
    assert result["state"] == "ready"
    account = x.accounts()["accounts"][0]
    assert account["partition"] == "adult" and account["subscription_id"] is None
    assert account["bot_ids"] == [] and account["can_collect"] is False
    x.add_list("789", "adult", store.config_revision())
    result = await x.refresh_list("789", "list.2", store.config_revision())
    assert result["state"] == "private" and not result["list"]["current"]
    assert len(requests) == 3


@pytest.mark.parametrize(
    "status,state",
    [
        (200, "protected"),
        (401, "authentication_failed"),
        (403, "permission_denied"),
        (404, "unavailable"),
    ],
)
async def test_distinguishes_unavailable_private_and_permission(system, status, state):
    store, _, _ = system

    async def response(request, ordinal):
        return httpx.Response(status, json={"data": user("12345", "fixture", protected=True)})

    x, _ = directory(system, response)
    account = (await x.add_account("fixture", store.config_revision()))["account"]
    result = await x.verify(account["id"], "lookup.1", store.config_revision())
    assert result["state"] == state
    assert x.account_status(account["id"])["state"] == state
    assert not x.account_status(account["id"])["can_collect"]


async def test_rotation_while_read_inflight_records_cost_but_never_updates_identity(system):
    store, credentials, _ = system

    async def response(request, ordinal):
        await credentials.set("x_api", "x", "fixture-new-bearer", store.config_revision())
        return httpx.Response(200, json={"data": user("12345", "fixture")})

    x, requests = directory(system, response)
    account = (await x.add_account("fixture", store.config_revision()))["account"]
    result = await x.verify(account["id"], "lookup.1", store.config_revision())
    assert result["state"] == "configuration_changed"
    assert x.account_status(account["id"])["remote_id"] is None
    assert len(requests) == 1
    assert store._db.execute(
        "SELECT state,settled_units FROM budget_attempts WHERE meter='x'"
    ).fetchall() == [
        ("settled", 1),
    ]


async def test_duplicate_alias_reuses_original_classification_and_stable_route(system):
    store, _, _ = system

    async def response(request, ordinal):
        name = "original" if ordinal == 1 else "alias"
        return httpx.Response(200, json={"data": user("12345", name)})

    x, _ = directory(system, response)
    original = (await x.add_account("original", store.config_revision(), partition="adult"))[
        "account"
    ]
    await x.verify(original["id"], "lookup.1", store.config_revision())
    alias = (await x.add_account("alias", store.config_revision()))["account"]
    result = await x.verify(alias["id"], "lookup.2", store.config_revision())
    assert result["state"] == "duplicate" and result["canonical_account_id"] == original["id"]
    assert result["account"]["partition"] == "adult"
    assert [row["id"] for row in x.accounts()["accounts"]] == [original["id"]]


async def test_classification_clears_old_special_overrides_and_requires_reassignment(system):
    store, _, _ = system

    async def response(request, ordinal):
        return httpx.Response(200, json={"data": user("12345", "fixture")})

    x, _ = directory(system, response)
    account = (await x.add_account("fixture", store.config_revision(), partition="normal"))[
        "account"
    ]
    await x.verify(account["id"], "lookup.1", store.config_revision())
    await x.set_route(account["id"], "sub_x", "special", store.config_revision())
    revision, config = store.load_config()
    next(s for s in config["subscriptions"] if s["id"] == "sub_x")["enabled"] = True
    configured = next(a for a in config["accounts"] if a["id"] == account["id"])
    configured.update(times=["21:30"], style="newspaper")
    revision = store.save_config(config, expected_revision=revision)
    assert x.binding(account["id"])["remote_id"] == "12345"
    before = store.preview_route("sub_x", account_id=account["id"]).fingerprint
    update = await x.classify(account["id"], "adult", revision)
    assert update["affected_accounts"] == [account["id"]]
    saved = x.account_status(account["id"])
    assert saved["remote_id"] == "12345" and saved["state"] == "ready"
    assert saved["subscription_id"] is None and saved["bot_ids"] == []
    assert saved["times"] is None and saved["style"] is None and not saved["can_collect"]
    assert store.preview_route("sub_x", account_id=account["id"]).fingerprint != before


async def test_attempt_intent_storage_failure_prevents_x_request(system):
    import sqlite3

    store, _, _ = system

    async def response(request, ordinal):
        pytest.fail("the intent did not commit")

    x, calls = directory(system, response)
    account = (await x.add_account("fixture", store.config_revision()))["account"]
    store._db.set_authorizer(
        lambda op, table, *args: (
            sqlite3.SQLITE_DENY
            if (op, table) == (sqlite3.SQLITE_INSERT, "budget_attempts")
            else sqlite3.SQLITE_OK
        )
    )
    try:
        with pytest.raises(XError, match="storage_failed"):
            await x.verify(account["id"], "lookup.1", store.config_revision())
    finally:
        store._db.set_authorizer(None)
    assert not calls
    assert x.recover_interrupted() == 1
    assert x.operation("lookup.1")["state"] == "interrupted"


@pytest.mark.parametrize("marker", [False, True])
def test_v2_upgrade_keeps_untouched_legacy_preferences(tmp_path, marker):
    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        _, config = store.load_config()
        config["schema_version"] = 2
        config.pop("x_api")
        revision = 3 if marker else 1
        with store._write():
            store._db.execute(
                "UPDATE app_configuration SET document=?,revision=?", (json.dumps(config), revision)
            )
            if marker:
                store._db.execute(
                    "INSERT INTO migration_info VALUES ('untouched_import_revision','3')"
                )
            store._db.execute("PRAGMA user_version=12")
    with closing(Store(path)) as upgraded:
        upgraded.import_legacy_config(values={"NEWS_LANGUAGE": "English"})
        assert upgraded.load_config()[1]["news_output_locale"] == "en"
        assert upgraded.load_config()[1]["x_api"]["credential_ref"] is None


@pytest.mark.parametrize("prior_version", [12, 14])
async def test_v2_upgrade_reuses_confirmed_paid_edition(tmp_path, prior_version):
    from test_model_runner import NOW
    from test_pipeline import create, prepare
    from test_routing import configured

    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        config, sub = configured()
        store.save_config(config, expected_revision=1)
        from newspaw.providers import ProfileRegistry

        registry = ProfileRegistry(store)
        for role in ("normal_primary", "normal_backup"):
            registry.begin("verify." + role, role, "text", 1)
            registry.finish("verify." + role, {"status": "verified"})
        pipe, _, model_calls = prepare(store)
        job = create(pipe, sub["id"])
        await pipe.advance(job, now=NOW)
        assert (await pipe.advance(job, now=NOW))["stage"] == "preparing_media"
        assert len(model_calls) == 1
        _, config = store.load_config()
        config["schema_version"] = 2
        config.pop("x_api")
        with store._write():
            store._db.execute("UPDATE app_configuration SET document=?", (json.dumps(config),))
            if prior_version == 14:
                store._db.execute(
                    "UPDATE schedule_policy SET revision=7,settings=json_set(settings,'$.catchup_minutes',45)"
                )
                for table in ("x_operations", "x_lists", "x_identities"):
                    store._db.execute(f"DROP TABLE {table}")
            store._db.execute(f"PRAGMA user_version={prior_version}")
    with closing(Store(path)) as upgraded:
        if prior_version == 14:
            revision, settings = upgraded._db.execute(
                "SELECT revision,settings FROM schedule_policy WHERE id=1"
            ).fetchone()
            assert revision == 7 and json.loads(settings)["catchup_minutes"] == 45
        pipe, reads, calls = prepare(upgraded)
        assert (await pipe.advance(job, now=NOW))["stage"] == "awaiting_delivery"
        assert not reads and not calls


async def test_identity_aba_and_rollback_use_shared_configuration_transaction(system):
    import sqlite3

    store, credentials, _ = system

    async def response(request, ordinal):
        return httpx.Response(200, json={"data": user("12345", "fixture")})

    x, _ = directory(system, response)
    account = (await x.add_account("fixture", store.config_revision()))["account"]
    await x.verify(account["id"], "read.1", store.config_revision())
    revision, config = store.load_config()
    config["accounts"][0]["handle"] = "another"
    store._db.execute(
        """CREATE TRIGGER fail_config BEFORE UPDATE ON app_configuration
           BEGIN SELECT RAISE(ABORT,'fixture rollback'); END"""
    )
    try:
        with pytest.raises(sqlite3.IntegrityError):
            store.save_config(config, expected_revision=revision)
    finally:
        store._db.execute("DROP TRIGGER fail_config")
    assert x.account_status(account["id"])["state"] == "ready"
    result = await credentials.save_config(config, revision)
    config["accounts"][0]["handle"] = "fixture"
    await credentials.save_config(config, result["revision"])
    assert x.account_status(account["id"])["state"] == "invalidated"


async def test_list_membership_cannot_authorize_new_identity_using_old_local_id(system):
    store, _, _ = system

    async def response(request, ordinal):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        if request.url.path == "/2/lists/456/members":
            return httpx.Response(
                200, json={"data": [user("12345", "original")], "meta": {"result_count": 1}}
            )
        return httpx.Response(200, json={"data": user("56789", "reused")})

    x, _ = directory(system, response)
    x.add_list("456", "normal", store.config_revision())
    await x.refresh_list("456", "list.1", store.config_revision())
    revision, config = store.load_config()
    item = config["accounts"][0]
    identity = item["id"]
    assert x.account_status(identity)["member_active"]
    item.update(remote_id=None, handle="reused", partition="normal", subscription_id="sub_x")
    next(s for s in config["subscriptions"] if s["id"] == "sub_x")["enabled"] = True
    store.save_config(config, expected_revision=revision)
    await x.verify(identity, "lookup.reused", store.config_revision())
    current = x.account_status(identity)
    assert current["remote_id"] == "56789" and current["state"] == "ready"
    assert not current["member_active"] and not current["can_collect"]


async def test_verify_list_only_identity_never_promotes_direct_follow(system):
    store, _, _ = system
    members = [user("12345", "list_only")]

    async def response(request, _):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        if request.url.path == "/2/lists/456/members":
            return httpx.Response(
                200, json={"data": members, "meta": {"result_count": len(members)}}
            )
        assert request.url.path == "/2/users/12345"
        return httpx.Response(200, json={"data": user("12345", "list_only")})

    x, _ = directory(system, response)
    x.add_list("456", "normal", store.config_revision())
    await x.refresh_list("456", "list.initial", store.config_revision(), page_size=5)
    revision, config = store.load_config()
    identity = config["accounts"][0]["id"]
    subscription = next(sub for sub in config["subscriptions"] if sub["category_id"] == "x")
    subscription["enabled"] = True
    store.save_config(config, expected_revision=revision)
    await x.classify(identity, "normal", store.config_revision())
    await x.set_route(identity, subscription["id"], "normal", store.config_revision())
    assert x.account_status(identity)["can_collect"] is True
    verified = await x.verify(identity, "verify.member", store.config_revision())
    assert verified["state"] == "ready"
    assert verified["account"]["direct"] is False
    members.clear()
    await x.refresh_list("456", "list.removed", store.config_revision(), page_size=5)
    status = x.account_status(identity)
    assert not status["member_active"] and not status["can_collect"]
    explicitly_followed = await x.add_account("list_only", store.config_revision())
    assert explicitly_followed["account"]["can_collect"] is True


@pytest.mark.parametrize(
    ("status", "body", "reason"),
    [
        (500, b"{}", "http_error"),
        (200, b"invalid json", "malformed_response"),
        (200, b"[]", "malformed_response"),
        (200, b'{"data":{},"meta":{"result_count":0}}', "partial_response"),
    ],
)
async def test_received_x_page_error_settles_known_units(system, status, body, reason):
    store, _, _ = system

    async def response(request, _):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        return httpx.Response(status, content=body)

    x, requests = directory(system, response)
    x.add_list("456", "normal", store.config_revision())
    revision = store.config_revision()
    operation = await x.refresh_list("456", "list.received", revision, page_size=100)

    assert operation["state"] == reason
    assert operation["attempts"][-1]["reads"] == 1
    assert store._db.execute(
        "SELECT state,reserved_units,settled_units FROM budget_attempts WHERE meter='x' AND reserved_units=100"
    ).fetchall() == [("settled", 100, 1)]
    assert await x.refresh_list("456", "list.received", revision, page_size=100) == operation
    assert len(requests) == 2


async def test_explicit_alias_follows_canonical_list_account_after_deduplication(system):
    store, _, _ = system
    members = [user("12345", "previous_name")]

    async def response(request, _):
        if request.url.path == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        if request.url.path == "/2/lists/456/members":
            return httpx.Response(
                200, json={"data": members, "meta": {"result_count": len(members)}}
            )
        assert request.url.path == "/2/users/by/username/renamed"
        return httpx.Response(200, json={"data": user("12345", "renamed")})

    x, _ = directory(system, response)
    x.add_list("456", "normal", store.config_revision())
    await x.refresh_list("456", "list.initial", store.config_revision())
    revision, config = store.load_config()
    canonical = config["accounts"][0]["id"]
    subscription = next(sub for sub in config["subscriptions"] if sub["category_id"] == "x")
    subscription["enabled"] = True
    store.save_config(config, expected_revision=revision)
    await x.classify(canonical, "normal", store.config_revision())
    await x.set_route(canonical, subscription["id"], "normal", store.config_revision())
    assert x.account_status(canonical)["direct"] is False
    alias = (await x.add_account("renamed", store.config_revision()))["account"]["id"]
    verified = await x.verify(alias, "verify.alias", store.config_revision())
    assert verified["state"] == "duplicate" and verified["canonical_account_id"] == canonical
    assert [row["id"] for row in store.load_config()[1]["accounts"]] == [canonical]
    assert verified["account"]["direct"] is True

    members.clear()
    await x.refresh_list("456", "list.removed", store.config_revision())
    status = x.account_status(canonical)
    assert not status["member_active"] and status["can_collect"]
