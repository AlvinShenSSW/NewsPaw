import asyncio
import json

import pytest

from newspaw.credentials import CredentialError, CredentialManager
from newspaw.store import Store


class FakeKeychain:
    def __init__(self):
        self.items = {}
        self.failure = None
        self.readback_wrong = False

    def write(self, ref, value):
        if self.failure == "write":
            raise CredentialError("keychain_locked")
        self.items[ref] = value

    def read(self, ref):
        if self.failure == "read":
            raise CredentialError("keychain_denied")
        return "wrong" if self.readback_wrong else self.items.get(ref)

    def delete(self, ref):
        if self.failure == "delete":
            raise CredentialError("keychain_locked")
        self.items.pop(ref, None)


@pytest.fixture
def credentials(tmp_path):
    store = Store(tmp_path / "state.db")
    backend = FakeKeychain()
    manager = CredentialManager(store, backend)
    yield manager, store, backend
    store.close()


async def test_rotate_and_remove_without_plaintext_in_database(credentials):
    manager, store, backend = credentials
    result = await manager.set("model_profiles", "normal_primary", "synthetic-value", 1)
    assert result["revision"] == 2
    old_ref = store.load_config()[1]["model_profiles"][0]["credential_ref"]
    assert backend.items[old_ref] == "synthetic-value"
    await manager.set("model_profiles", "normal_primary", "second-value", 2)
    assert old_ref not in backend.items
    assert len(backend.items) == 1
    assert "value" not in json.dumps(store.load_config())
    await manager.remove("model_profiles", "normal_primary", 3)
    assert not backend.items and not store.pending_credentials()
    assert store.load_config()[1]["model_profiles"][0]["credential_ref"] is None


@pytest.mark.parametrize("failure", ["write", "read", "mismatch", "commit"])
async def test_failed_write_or_commit_retains_original(credentials, monkeypatch, failure):
    manager, store, backend = credentials
    original = store.load_config()
    backend.failure = failure
    backend.readback_wrong = failure == "mismatch"
    if failure == "commit":

        def fail(*args, **kwargs):
            raise ValueError("synthetic sensitive error")

        monkeypatch.setattr(store, "commit_credentials", fail)
    with pytest.raises(CredentialError) as error:
        await manager.set("model_profiles", "normal_primary", "synthetic-value", 1)
    assert "synthetic" not in str(error.value)
    assert store.load_config() == original
    assert not backend.items and not store.pending_credentials()


async def test_cleanup_intent_survives_restart_and_preserves_shared_refs(credentials):
    manager, store, backend = credentials
    await manager.set("model_profiles", "normal_primary", "first", 1)
    revision, config = store.load_config()
    ref = config["model_profiles"][0]["credential_ref"]
    config["model_profiles"][1]["credential_ref"] = ref
    store.save_config(config, expected_revision=revision)
    await manager.remove("model_profiles", "normal_primary", 3)
    assert ref in backend.items
    backend.failure = "delete"
    result = await manager.remove("model_profiles", "normal_backup", 4)
    assert result["cleanup_pending"] == 1
    assert store.pending_credentials() == [ref]
    backend.failure = None
    restarted = CredentialManager(store, backend)
    assert (await restarted.cleanup())["cleanup_pending"] == 0
    assert not backend.items


async def test_orphan_reserved_before_crash_is_cleaned(credentials):
    manager, store, backend = credentials
    ref = "keychain:00000000-0000-0000-0000-000000000001"
    store.reserve_credentials([ref])
    backend.items[ref] = "orphan"
    await manager.cleanup()
    assert not backend.items and not store.pending_credentials()


@pytest.mark.parametrize("order", ["secrets_first", "preferences_first"])
async def test_legacy_import_orders_idempotent_and_preserve_original(credentials, tmp_path, order):
    manager, store, backend = credentials
    path = tmp_path / "legacy.env"
    original = "OPENAI_API_KEY=synthetic-key\nTELEGRAM_BOT_TOKEN=synthetic-token\nNEWS_LANGUAGE=English\nTELEGRAM_OWNER_ID=0\n"
    path.write_text(original)
    path.chmod(0o600)
    calls = [manager.import_secrets, manager.import_preferences]
    if order == "preferences_first":
        calls.reverse()
    for call in calls:
        await call(path, store.config_revision())
    revision, config = store.load_config()
    assert config["news_output_locale"] == "en"
    assert config["owner_id"] is None
    assert config["model_profiles"][0]["credential_ref"] in backend.items
    assert config["bots"][0]["credential_ref"] in backend.items
    assert not config["bots"][0]["verified"]
    assert all(not s["enabled"] for s in config["subscriptions"])
    assert "synthetic" not in json.dumps(config)
    assert path.read_text() == original
    before = backend.items.copy()
    assert (await manager.import_secrets(path, revision))["already_imported"]
    assert backend.items == before and store.config_revision() == revision


async def test_generic_edit_does_not_preserve_import_eligibility(credentials, tmp_path):
    manager, store, _ = credentials
    revision, config = store.load_config()
    config["ui_locale"] = "en"
    await manager.save_config(config, revision)
    path = tmp_path / "legacy.env"
    path.write_text("NEWS_LANGUAGE=Japanese\n")
    path.chmod(0o600)
    with pytest.raises(CredentialError):
        await manager.import_preferences(path, 2)
    assert store.load_config()[1]["ui_locale"] == "en"


async def test_save_cannot_inject_credential_reference(credentials):
    manager, store, _ = credentials
    revision, config = store.load_config()
    config["model_profiles"][0]["credential_ref"] = "keychain:00000000-0000-0000-0000-000000000001"
    with pytest.raises(CredentialError, match="protected"):
        await manager.save_config(config, revision)
    assert store.config_revision() == 1


async def test_cancelled_request_does_not_cancel_keychain_commit(credentials):
    manager, store, backend = credentials
    import threading

    started, finish = threading.Event(), threading.Event()
    original = backend.write

    def slow(ref, value):
        started.set()
        assert finish.wait(5)
        original(ref, value)

    backend.write = slow
    call = asyncio.create_task(manager.set("model_profiles", "normal_primary", "synthetic", 1))
    assert await asyncio.to_thread(started.wait, 5)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call
    finish.set()
    await manager.drain()
    assert store.config_revision() == 2
    assert not store.pending_credentials()


async def test_legacy_failure_does_not_mark_imported_or_delete_file(credentials, tmp_path):
    manager, store, backend = credentials
    path = tmp_path / "legacy.env"
    path.write_text("OPENAI_API_KEY=synthetic\nTELEGRAM_BOT_TOKEN=synthetic-bot\n")
    path.chmod(0o600)
    original = backend.write
    calls = []

    def fail_second(ref, value):
        calls.append(ref)
        if len(calls) == 2:
            raise CredentialError("keychain_locked")
        original(ref, value)

    backend.write = fail_second
    with pytest.raises(CredentialError):
        await manager.import_secrets(path, 1)
    assert store.config_revision() == 1
    assert not store.legacy_secrets_imported()
    assert not backend.items and path.exists()
    backend.write = original
    await manager.import_secrets(path, 1)
    assert store.legacy_secrets_imported()


async def test_secret_input_and_private_file_errors_are_sanitized(credentials, tmp_path, caplog):
    manager, _, _ = credentials
    with pytest.raises(CredentialError, match="invalid_credential"):
        await manager.set("model_profiles", "normal_primary", "synthetic\nsecret", 1)
    path = tmp_path / "legacy.env"
    path.write_text("OPENAI_API_KEY=synthetic-secret\n")
    path.chmod(0o644)
    with pytest.raises(CredentialError, match="legacy_file_not_private"):
        await manager.import_secrets(path, 1)
    link = tmp_path / "link.env"
    link.symlink_to(path)
    with pytest.raises(CredentialError, match="legacy_file_unreadable"):
        await manager.import_secrets(link, 1)
    assert "synthetic" not in caplog.text


async def test_bot_rotation_clears_binding_and_retains_other_bot(credentials):
    manager, store, _ = credentials
    revision, config = store.load_config()
    ref = "keychain:00000000-0000-0000-0000-000000000001"
    config["owner_id"] = 123
    config["bots"] = [
        dict(
            id="bot",
            name="Bot",
            credential_ref=ref,
            telegram_id=99,
            chat_id=123,
            verified=True,
            paired=True,
            adult_allowed=False,
        )
    ]
    store.save_config(config, expected_revision=revision)
    await manager.set("bots", "bot", "synthetic", 2)
    bot = store.load_config()[1]["bots"][0]
    assert not bot["verified"] and not bot["paired"]
    assert bot["telegram_id"] is None and bot["chat_id"] is None


def test_native_adapter_does_not_expose_backend_error(monkeypatch):
    from newspaw.credentials import MacKeychain

    adapter = object.__new__(MacKeychain)

    class Broken:
        def get_password(self, *args):
            raise RuntimeError("synthetic secret native error")

    adapter.backend = Broken()
    adapter.service = "io.newspaw.tests"
    with pytest.raises(CredentialError, match="keychain_unavailable") as error:
        adapter.read("keychain:00000000-0000-0000-0000-000000000001")
    assert "synthetic" not in str(error.value)
