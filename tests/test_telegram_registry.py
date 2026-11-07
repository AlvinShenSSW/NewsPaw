import asyncio
from datetime import UTC, datetime, timedelta

import pytest
from test_routing import REF, configured

from newspaw.store import Store
from newspaw.telegram.registry import BotRegistry, TelegramError

NOW = datetime(2026, 11, 7, 15, tzinfo=UTC)
TOKEN = "999:fixture_credential_abcdefghijklmnop"


class Keys:
    def read(self, ref):
        return TOKEN


class API:
    def __init__(self):
        self.calls = []
        self.updates = []
        self.remote_id = 999
        self.webhook = ""
        self.error = None

    async def call(self, method, params=None):
        self.calls.append((method, params))
        if self.error:
            raise self.error
        if method == "getMe":
            return dict(
                id=self.remote_id, is_bot=True, username="fixture_bot", first_name="Fixture"
            )
        if method == "getWebhookInfo":
            return dict(url=self.webhook)
        if method == "getUpdates":
            return self.updates
        raise AssertionError(method)

    async def close(self):
        pass


@pytest.fixture
def system(tmp_path):
    store = Store(tmp_path / "state.db")
    config, sub = configured()
    store.save_config(config, expected_revision=1)
    api = API()
    registry = BotRegistry(store, Keys(), client_factory=lambda token: api)
    yield registry, api, store
    store.close()


def update(text, identity=1, owner=123, kind="private", when=NOW):
    return dict(
        update_id=identity,
        message=dict(
            message_id=identity,
            date=int(when.timestamp()),
            chat=dict(id=owner, type=kind),
            **{"from": dict(id=owner, is_bot=False)},
            text=text,
        ),
    )


async def bind(registry, api, *, now=NOW):
    await registry.verify("bot1", now=now)
    code = registry.pair_code("bot1", now=now)["code"]
    api.updates = [update("/pair " + code, when=now)]
    await registry.poll_once("bot1", now=now)
    return code


async def test_verification_readonly_and_config_claims_cannot_authorize(system):
    registry, api, _ = system
    assert registry.status("bot1")["verified"] is False
    with pytest.raises(TelegramError):
        registry.snapshot("bot1")
    result = await registry.verify("bot1", now=NOW)
    assert result["verified"] and not result["paired"]
    assert [m for m, p in api.calls] == ["getMe", "getWebhookInfo"]
    assert result["telegram_id"] == 999 and result["token_exclusive_required"]


async def test_pairing_one_time_private_numeric_owner_and_cursor(system):
    registry, api, store = system
    code = await bind(registry, api)
    status = registry.status("bot1")
    assert status["paired"] and status["chat_id"] == 123 and status["cursor"] == 1
    assert code not in "\n".join(store._db.iterdump())
    api.updates = [update("/pair " + code, 2)]
    await registry.poll_once("bot1", now=NOW)
    assert registry.status("bot1")["cursor"] == 2
    assert registry.status("bot1")["generation"] == status["generation"]
    assert not registry.inbox("bot1")


@pytest.mark.parametrize(
    "text,owner,kind",
    [
        ("/start", 123, "private"),
        ("/pair wrong", 123, "private"),
        ("/pair CODE", 456, "private"),
        ("/pair CODE", 123, "group"),
    ],
)
async def test_pairing_rejects_unauthorized_updates(system, text, owner, kind):
    registry, api, _ = system
    await registry.verify("bot1", now=NOW)
    code = registry.pair_code("bot1", now=NOW)["code"]
    api.updates = [update(text.replace("CODE", code), owner=owner, kind=kind)]
    await registry.poll_once("bot1", now=NOW)
    assert not registry.status("bot1")["paired"]
    assert not registry.inbox("bot1")


async def test_pair_expiry_and_attempt_limit(system):
    registry, api, _ = system
    await registry.verify("bot1", now=NOW)
    code = registry.pair_code("bot1", now=NOW)["code"]
    api.updates = [update("/pair wrong", i) for i in range(1, 6)]
    await registry.poll_once("bot1", now=NOW)
    api.updates = [update("/pair " + code, 6)]
    await registry.poll_once("bot1", now=NOW)
    assert not registry.status("bot1")["paired"]
    code = registry.pair_code("bot1", now=NOW)["code"]
    api.updates = [update("/pair " + code, 7, when=NOW + timedelta(minutes=11))]
    await registry.poll_once("bot1", now=NOW + timedelta(minutes=11))
    assert not registry.status("bot1")["paired"]


async def test_webhook_and_duplicate_identity_never_stolen(system):
    registry, api, store = system
    api.webhook = "https://example.com/private-secret"
    result = await registry.verify("bot1", now=NOW)
    assert result["status"] == "webhook_conflict" and not result["verified"]
    assert "private-secret" not in str(result)
    api.webhook = ""
    await registry.verify("bot1", now=NOW)
    revision, config = store.load_config()
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
    store.save_config(config, expected_revision=revision)
    assert (await registry.verify("bot2", now=NOW))["status"] == "duplicate_bot"
    assert registry.status("bot1")["verified"]
    assert all(m in {"getMe", "getWebhookInfo"} for m, p in api.calls)


async def test_first_owner_is_established_once_across_bots(system):
    registry, api, store = system
    revision, config = store.load_config()
    config["owner_id"] = None
    for bot in config["bots"]:
        bot.update(verified=False, paired=False, telegram_id=None, chat_id=None)
    config["bots"].append({**config["bots"][0], "id": "bot2", "name": "Second"})
    store.save_config(config, expected_revision=revision)
    await bind(registry, api)
    assert store.load_config()[1]["owner_id"] == 123
    api.remote_id = 1000
    await registry.verify("bot2", now=NOW)
    code = registry.pair_code("bot2", now=NOW)["code"]
    api.updates = [update("/pair " + code, 2, owner=456)]
    await registry.poll_once("bot2", now=NOW)
    assert not registry.status("bot2")["paired"]
    api.updates = [update("/pair " + code, 3)]
    await registry.poll_once("bot2", now=NOW)
    assert registry.snapshot("bot2").owner_id == registry.snapshot("bot1").owner_id == 123


async def test_pause_resume_unbind_invalidate_old_snapshots_and_inbox(system):
    registry, api, store = system
    await bind(registry, api)
    binding = registry.snapshot("bot1")
    api.updates = [update("news", 2)]
    await registry.poll_once("bot1", now=NOW)
    assert registry.inbox("bot1")[0]["state"] == "pending"
    registry.action("bot1", "pause", now=NOW)
    with pytest.raises(TelegramError):
        registry.revalidate(binding)
    calls = len(api.calls)
    await registry.poll_once("bot1", now=NOW)
    assert len(api.calls) == calls
    assert registry.inbox("bot1")[0]["state"] == "stale"
    registry.action("bot1", "resume", now=NOW + timedelta(minutes=1))
    assert registry.snapshot("bot1").generation > binding.generation
    api.updates = [update("old pending command", 3, when=NOW)]
    await registry.poll_once("bot1", now=NOW + timedelta(minutes=1))
    assert len(registry.inbox("bot1")) == 1
    registry.action("bot1", "unbind", now=NOW)
    assert not registry.status("bot1")["paired"]
    with pytest.raises(TelegramError):
        registry.snapshot("bot1")


async def test_token_rotation_config_forgery_and_aba_cannot_revive_binding(system):
    registry, api, store = system
    await bind(registry, api)
    original = registry.snapshot("bot1")
    for ref in ("keychain:00000000-0000-0000-0000-000000000002", REF):
        revision, config = store.load_config()
        config["bots"][0].update(
            credential_ref=ref, verified=True, paired=True, telegram_id=999, chat_id=123
        )
        store.save_config(config, expected_revision=revision)
        assert not registry.status("bot1")["verified"]
    with pytest.raises(TelegramError):
        registry.revalidate(original)
    await registry.verify("bot1", now=NOW)
    assert not registry.status("bot1")["paired"]
    assert registry.status("bot1")["cursor"] == 1  # Same confirmed remote identity.


async def test_rotating_to_different_remote_bot_resets_only_its_cursor(system):
    registry, api, store = system
    await bind(registry, api)
    revision, config = store.load_config()
    config["bots"][0]["credential_ref"] = "keychain:00000000-0000-0000-0000-000000000002"
    store.save_config(config, expected_revision=revision)
    api.remote_id = 1000
    await registry.verify("bot1", now=NOW)
    assert registry.status("bot1")["cursor"] is None


async def test_owner_change_and_delete_readd_are_immediate_revocations(system):
    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialManager

    registry, api, store = system
    await bind(registry, api)
    binding = registry.snapshot("bot1")
    revision, config = store.load_config()
    config["owner_id"] = 456
    config["bots"][0].update(paired=False, chat_id=None)
    store.save_config(config, expected_revision=revision)
    with pytest.raises(TelegramError):
        registry.revalidate(binding)
    revision, config = store.load_config()
    bot = config["bots"][0]
    manager = CredentialManager(store, FakeKeychain())
    await registry.delete("bot1", manager, revision)
    assert not store.load_config()[1]["bots"]
    assert store._db.execute("SELECT active FROM bot_registrations").fetchone()[0] == 0
    revision, config = store.load_config()
    config["bots"].append(bot)
    store.save_config(config, expected_revision=revision)
    assert not registry.status("bot1")["verified"]
    assert registry.status("bot1")["generation"] > binding.generation


async def test_binding_change_while_getme_pending_cannot_publish_stale_identity(system):
    registry, api, store = system
    started = asyncio.Event()
    release = asyncio.Event()
    original = api.call

    async def delayed(method, params=None):
        if method == "getMe":
            started.set()
            await release.wait()
        return await original(method, params)

    api.call = delayed
    task = asyncio.create_task(registry.verify("bot1", now=NOW))
    await started.wait()
    revision, config = store.load_config()
    config["bots"][0]["credential_ref"] = "keychain:00000000-0000-0000-0000-000000000002"
    store.save_config(config, expected_revision=revision)
    release.set()
    with pytest.raises(TelegramError, match="binding_changed"):
        await task
    assert not registry.status("bot1")["verified"]
    assert [m for m, p in api.calls] == ["getMe"]


async def test_pause_during_poll_keeps_cursor_and_rejects_update(system):
    registry, api, _ = system
    await bind(registry, api)
    started = asyncio.Event()
    release = asyncio.Event()
    original = api.call

    async def delayed(method, params=None):
        if method == "getUpdates":
            started.set()
            await release.wait()
        return await original(method, params)

    api.call = delayed
    api.updates = [update("news", 2)]
    task = asyncio.create_task(registry.poll_once("bot1", now=NOW))
    await started.wait()
    registry.action("bot1", "pause", now=NOW)
    release.set()
    with pytest.raises(TelegramError):
        await task
    assert registry.status("bot1")["cursor"] == 1 and not registry.inbox("bot1")


@pytest.mark.parametrize("kind", ["token_revoked", "consumer_conflict", "forbidden"])
async def test_poll_authorization_failures_revoke_without_advancing(system, kind):
    registry, api, _ = system
    await bind(registry, api)
    api.error = TelegramError(kind)
    result = await registry.poll_once("bot1", now=NOW)
    assert not result["verified"] and not result["paired"] and result["cursor"] == 1
    assert result["status"] == kind


async def test_rate_limit_is_persisted_and_no_early_retry(system):
    registry, api, _ = system
    await bind(registry, api)
    api.error = TelegramError("rate_limited", 90)
    result = await registry.poll_once("bot1", now=NOW)
    assert result["next_poll_at"] == NOW.timestamp() + 90
    count = len(api.calls)
    await registry.poll_once("bot1", now=NOW + timedelta(seconds=89))
    assert len(api.calls) == count


async def test_cursor_inbox_atomic_rollback_reopen_and_duplicate_batch(system):
    import sqlite3

    registry, api, store = system
    await bind(registry, api)
    api.updates = [update("news", 2), update("news", 2)]
    store._db.execute(
        "CREATE TRIGGER fail_bot BEFORE UPDATE ON bot_registrations BEGIN SELECT RAISE(ABORT,'fault'); END"
    )
    store._db.commit()
    with pytest.raises(sqlite3.IntegrityError):
        await registry.poll_once("bot1", now=NOW)
    assert registry.status("bot1")["cursor"] == 1 and not registry.inbox("bot1")
    store._db.execute("DROP TRIGGER fail_bot")
    store._db.commit()
    path = store._db.execute("PRAGMA database_list").fetchone()[2]
    other = Store(path)
    try:
        restored = BotRegistry(other, Keys(), client_factory=lambda token: api)
        await restored.poll_once("bot1", now=NOW)
        await restored.poll_once("bot1", now=NOW)
        assert restored.status("bot1")["cursor"] == 2
        assert len(restored.inbox("bot1")) == 1
        assert api.calls[-1][1]["offset"] == 3
    finally:
        other.close()


async def test_binding_and_pair_code_consumption_rollback_together(system):
    import sqlite3

    registry, api, store = system
    await registry.verify("bot1", now=NOW)
    code = registry.pair_code("bot1", now=NOW)["code"]
    api.updates = [update("/pair " + code)]
    store._db.execute(
        "CREATE TRIGGER fail_pair BEFORE UPDATE ON app_configuration BEGIN SELECT RAISE(ABORT,'fault'); END"
    )
    store._db.commit()
    with pytest.raises(sqlite3.IntegrityError):
        await registry.poll_once("bot1", now=NOW)
    assert not registry.status("bot1")["paired"] and registry.status("bot1")["cursor"] is None
    store._db.execute("DROP TRIGGER fail_pair")
    store._db.commit()
    await registry.poll_once("bot1", now=NOW)
    assert registry.status("bot1")["paired"]


async def test_unowned_edited_and_business_updates_never_enter_inbox(system):
    registry, api, _ = system
    await bind(registry, api)
    business = update("secret", 3)
    business["message"]["business_connection_id"] = "external"
    edited = update("secret", 4)
    edited["edited_message"] = edited.pop("message")
    api.updates = [update("stranger", 2, owner=456), business, edited]
    await registry.poll_once("bot1", now=NOW)
    assert not registry.inbox("bot1") and registry.status("bot1")["cursor"] == 4


async def test_same_bot_polls_are_serialized(system):
    registry, api, _ = system
    await bind(registry, api)
    active = 0
    maximum = 0
    original = api.call

    async def delayed(method, params=None):
        nonlocal active, maximum
        active += 1
        maximum = max(maximum, active)
        await asyncio.sleep(0.01)
        try:
            return await original(method, params)
        finally:
            active -= 1

    api.call = delayed
    api.updates = []
    await asyncio.gather(registry.poll_once("bot1", now=NOW), registry.poll_once("bot1", now=NOW))
    assert maximum == 1


async def test_inbox_capacity_is_visible_and_does_not_acknowledge_batch(system):
    import json

    registry, api, store = system
    await bind(registry, api)
    generation = registry.status("bot1")["generation"]
    with store._write():
        store._db.executemany(
            "INSERT INTO bot_inbox VALUES (?,?,?,?,?)",
            [
                ("bot1", generation, i, json.dumps({"message_id": i}), "pending")
                for i in range(1000, 1999)
            ],
        )
    api.updates = [update("one", 2), update("two", 3)]
    result = await registry.poll_once("bot1", now=NOW)
    assert result["status"] == "inbox_full" and result["cursor"] == 1
    assert (
        store._db.execute("SELECT count(*) FROM bot_inbox WHERE state='pending'").fetchone()[0]
        == 999
    )
    with store._write():
        store._db.execute("UPDATE bot_inbox SET state='done' WHERE update_id=1000")
    await registry.poll_once("bot1", now=NOW + timedelta(seconds=5))
    assert registry.status("bot1")["cursor"] == 3
    calls = len(api.calls)
    result = await registry.poll_once("bot1", now=NOW + timedelta(seconds=6))
    assert result["status"] == "inbox_full" and len(api.calls) == calls
    assert registry.status("bot1")["status"] == "inbox_full"


async def test_worker_close_cancels_long_poll_and_new_configs_do_not_poll(system):
    registry, api, _ = system
    await registry.start()
    await asyncio.sleep(0.01)
    assert not api.calls
    await registry.close()
    now = datetime.now(UTC)
    await registry.verify("bot1", now=now)
    registry.pair_code("bot1", now=now)
    started = asyncio.Event()
    cancelled = asyncio.Event()

    async def longpoll(method, params=None):
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    api.call = longpoll
    await registry.start()
    await asyncio.wait_for(started.wait(), 1)
    await registry.close()
    assert cancelled.is_set() and registry._supervisor is None and not registry._workers


async def test_cancelled_verification_recovers_as_interrupted_without_network(system):
    registry, api, store = system
    started = asyncio.Event()

    async def waiting(method, params=None):
        started.set()
        await asyncio.Event().wait()

    api.call = waiting
    task = asyncio.create_task(registry.verify("bot1", now=NOW))
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert registry.status("bot1")["status"] == "verifying"
    await registry.start()
    assert registry.status("bot1")["status"] == "verification_interrupted"
    await registry.close()


async def test_server_returned_lower_update_id_after_idle_is_accepted(system):
    registry, api, _ = system
    await bind(registry, api)
    api.updates = [update("high", 900000)]
    await registry.poll_once("bot1", now=NOW)
    api.updates = [update("new after idle", 100, when=NOW + timedelta(days=8))]
    await registry.poll_once("bot1", now=NOW + timedelta(days=8))
    assert registry.status("bot1")["cursor"] == 100
    assert len(registry.inbox("bot1")) == 2


async def test_token_rotation_through_keychain_manager_invalidates_immediately(system):
    from test_credentials import FakeKeychain

    from newspaw.credentials import CredentialManager

    registry, api, store = system
    await bind(registry, api)
    binding = registry.snapshot("bot1")
    manager = CredentialManager(store, FakeKeychain())
    await manager.set(
        "bots", "bot1", "1000:fixture_replacement_abcdefghijklmnop", store.config_revision()
    )
    with pytest.raises(TelegramError):
        registry.revalidate(binding)
    assert not registry.status("bot1")["verified"]


async def test_first_owner_revokes_other_code_and_inflight_poll(system):
    registry, api, store = system
    revision, config = store.load_config()
    config["owner_id"] = None
    for bot in config["bots"]:
        bot.update(verified=False, paired=False, telegram_id=None, chat_id=None)
    config["bots"].append({**config["bots"][0], "id": "bot2", "name": "Second"})
    store.save_config(config, expected_revision=revision)
    await registry.verify("bot1", now=NOW)
    first_code = registry.pair_code("bot1", now=NOW)["code"]
    second = API()
    second.remote_id = 1000
    registry.client_factory = lambda token: second
    await registry.verify("bot2", now=NOW)
    second_code = registry.pair_code("bot2", now=NOW)["code"]
    prior = registry.status("bot2")["generation"]
    entered, release = asyncio.Event(), asyncio.Event()

    async def delayed(method, params=None):
        assert method == "getUpdates"
        entered.set()
        await release.wait()
        return [update("/pair " + second_code, 22)]

    second.call = delayed
    pending = asyncio.create_task(registry.poll_once("bot2", now=NOW))
    await entered.wait()
    registry.client_factory = lambda token: api
    api.updates = [update("/pair " + first_code, 11)]
    await registry.poll_once("bot1", now=NOW)
    release.set()
    result = await asyncio.gather(pending, return_exceptions=True)
    assert isinstance(result[0], TelegramError)
    status = registry.status("bot2")
    assert status["generation"] > prior and not status["verified"] and not status["paired"]
    assert status["cursor"] is None
    assert registry._row("bot2")["state"]["pair_hash"] is None
    assert registry.snapshot("bot1").owner_id == 123
    assert store.load_config()[1]["bots"][1]["verified"] is False


async def test_wrong_pair_replay_once_across_restart(system):
    registry, api, store = system
    await registry.verify("bot1", now=NOW)
    code = registry.pair_code("bot1", now=NOW)["code"]
    api.updates = [update("/pair wrong", 19)]
    await registry.poll_once("bot1", now=NOW)
    restarted = BotRegistry(store, Keys(), client_factory=lambda token: api)
    for _ in range(5):
        await restarted.poll_once("bot1", now=NOW)
    assert restarted._row("bot1")["state"]["pair_tries"] == 1
    assert restarted.status("bot1")["polling"]
    assert restarted.inbox("bot1") == []
    assert "/pair" not in "\n".join(store._db.iterdump())
    api.updates = [update("/pair " + code, 20)]
    await restarted.poll_once("bot1", now=NOW)
    assert restarted.snapshot("bot1").owner_id == 123
