import asyncio
import json
import os
import socket
import tempfile
from pathlib import Path

import pytest
from test_credentials import FakeKeychain

from newspaw.control import ControlServer, peer_uid
from newspaw.credentials import CredentialManager
from newspaw.store import Store


@pytest.fixture
async def control():
    with tempfile.TemporaryDirectory(prefix="np-") as folder:
        root = Path(folder)
        store = Store(root / "state.db")
        manager = CredentialManager(store, FakeKeychain())
        server = ControlServer(root, manager)
        await server.start()
        yield server, store
        await server.close()
        store.close()


async def request(server, data):
    reader, writer = await asyncio.open_unix_connection(server.path, limit=8 * 1024 * 1024)
    writer.write(json.dumps(data, ensure_ascii=False).encode() + b"\n")
    await writer.drain()
    reply = json.loads(await reader.readline())
    writer.close()
    await writer.wait_closed()
    return reply


def test_actual_unix_peer_uid_matches_current_user():
    a, b = socket.socketpair()
    try:
        assert peer_uid(a) == os.getuid()
    finally:
        a.close()
        b.close()


async def test_private_socket_config_roundtrip_and_conflict(control):
    server, store = control
    assert server.path.stat().st_mode & 0o777 == 0o600
    response = await request(server, {"op": "config.get"})
    document = response["result"]["document"]
    document["ui_locale"] = "en"
    saved = await request(server, {"op": "config.save", "document": document, "revision": 1})
    assert saved["ok"] and store.config_revision() == 2
    stale = await request(server, {"op": "config.save", "document": document, "revision": 1})
    assert stale == {"ok": False, "error": "config_conflict"}
    assert (await request(server, {"op": "shell", "value": "secret"}))["ok"] is False


async def test_large_valid_configuration_is_saveable(control):
    server, _ = control
    response = await request(server, {"op": "config.get"})
    document = response["result"]["document"]
    document["sources"] = [
        dict(
            id=f"source{i}",
            name="Feed",
            url="https://example.com/" + "a" * 1100,
            kind="rss",
            partition="normal",
            category_ids=["world"],
            enabled=False,
        )
        for i in range(120)
    ]
    data = {"op": "config.save", "document": document, "revision": 1}
    assert len(json.dumps(data).encode()) > 128 * 1024
    assert (await request(server, data))["ok"]
    assert (await request(server, {"op": "config.get"}))["result"]["document"] == document


async def test_foreign_peer_denied_before_dispatch(control, monkeypatch):
    import newspaw.control as module

    server, store = control
    monkeypatch.setattr(module, "peer_uid", lambda sock: os.getuid() + 1)
    reply = await request(server, {"op": "config.get"})
    assert reply == {"ok": False, "error": "peer_denied"}
    assert store.config_revision() == 1


async def test_second_server_cannot_replace_live_socket(control):
    server, _ = control
    other = ControlServer(server.path.parent, server.credentials)
    with pytest.raises(ValueError, match="already_running"):
        await other.start()
    assert (await request(server, {"op": "config.get"}))["ok"]


async def test_malformed_overlong_and_disconnected_requests(control, monkeypatch):
    import newspaw.control as module

    server, store = control
    monkeypatch.setattr(module, "MAX_FRAME", 1024)
    reader, writer = await asyncio.open_unix_connection(server.path)
    writer.write(b"x" * 1025 + b"\n")
    await writer.drain()
    assert json.loads(await reader.readline())["error"] == "invalid_request"
    writer.close()
    await writer.wait_closed()
    reader, writer = await asyncio.open_unix_connection(server.path)
    writer.write(b"{broken json}\n")
    await writer.drain()
    assert not json.loads(await reader.readline())["ok"]
    writer.close()
    await writer.wait_closed()
    reader, writer = await asyncio.open_unix_connection(server.path)
    writer.close()
    await writer.wait_closed()
    assert store.config_revision() == 1


async def test_unsafe_path_and_live_foreign_socket_not_removed(tmp_path):
    with tempfile.TemporaryDirectory(prefix="np-") as folder:
        root = Path(folder)
        store = Store(root / "state.db")
        manager = CredentialManager(store, FakeKeychain())
        server = ControlServer(root, manager)
        server.path.write_text("keep")
        with pytest.raises(ValueError, match="unsafe_control_socket"):
            await server.start()
        assert server.path.read_text() == "keep"
        server.path.unlink()
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(server.path))
            listener.listen(1)
            with pytest.raises(ValueError, match="control_socket_in_use"):
                await server.start()
            assert server.path.exists()
        # Closed listener leaves a stale socket, now safely replaceable.
        await server.start()
        await server.close()
        assert not server.path.exists()
        root.chmod(0o755)
        with pytest.raises(ValueError, match="unsafe_control_directory"):
            await server.start()
        root.chmod(0o700)
        store.close()


async def test_disconnect_after_mutation_still_commits(control):
    server, store = control
    _, writer = await asyncio.open_unix_connection(server.path)
    writer.write(
        json.dumps(
            {
                "op": "credentials.set",
                "kind": "model_profiles",
                "id": "normal_primary",
                "value": "synthetic-value",
                "revision": 1,
            }
        ).encode()
        + b"\n"
    )
    await writer.drain()
    writer.close()
    await writer.wait_closed()
    # A config read can race the accepted write, so wait for its visible completion.
    async with asyncio.timeout(2):
        while store.config_revision() == 1:
            await asyncio.sleep(0.01)
    assert store.config_revision() == 2


def test_control_cli_does_not_load_legacy_settings(monkeypatch, tmp_path):
    import newspaw.cli as cli
    import newspaw.control as module

    calls = []

    async def serve(directory):
        calls.append(directory)

    def forbidden(*args):
        raise AssertionError("control setup must not load runtime secrets")

    monkeypatch.setattr(module, "serve_control", serve)
    monkeypatch.setattr(cli, "load_settings", forbidden)
    assert cli.main(["control", "--data-dir", str(tmp_path)]) == 0
    assert calls == [tmp_path]


async def test_budget_policy_uses_separate_cas_without_changing_news_config(control):
    server, store = control
    response = await request(server, {"op": "budget.get"})
    document = response["result"]["document"]
    document["model"]["monthly_limit"] = 100
    assert (await request(server, {"op": "budget.save", "document": document, "revision": 1}))["ok"]
    stale = await request(server, {"op": "budget.save", "document": document, "revision": 1})
    assert stale == {"ok": False, "error": "budget_policy_conflict"}
    assert store.config_revision() == 1


async def test_control_restart_recovers_durable_inflight_budget(control):
    from datetime import UTC, datetime

    from newspaw.budget import BudgetLedger

    server, store = control
    ledger = BudgetLedger(store)
    now = datetime.now(UTC)
    ledger.reserve(
        "pending", "task", max_units=5, quote={"known": False, "source": "manual_hold"}, now=now
    )
    ledger.begin_attempt("pending", now=now)
    await server.close()
    await server.start()
    assert ledger.get("pending")["state"] == "outcome_unknown"
    assert ledger.get("pending")["reserved_units"] == 5


async def test_control_restart_recovers_interrupted_feed_attempt(control):
    from datetime import UTC, datetime

    from newspaw.evidence import EvidenceStore, _selection

    server, store = control
    revision, config = store.load_config()
    config["sources"] = [
        dict(
            id="feed",
            name="Feed",
            url="https://example.com/rss",
            kind="rss",
            partition="normal",
            category_ids=["world"],
            enabled=True,
        )
    ]
    store.save_config(config, expected_revision=revision)
    repo = EvidenceStore(store)
    scope = dict(
        partition="normal",
        url="https://example.com/rss",
        selected=_selection(config, None, "feed"),
        subscriptions=None,
        source_id="feed",
    )
    identity = repo.begin(scope, datetime.now(UTC))
    await server.close()
    await server.start()
    assert repo.attempt(identity, partition="normal")["status"] == "interrupted"


async def test_model_status_is_read_only_and_probe_requires_explicit_shape(control):
    server, store = control
    before = store.load_config()
    status = await request(server, {"op": "models.status", "profile_id": "normal_primary"})
    assert status["ok"] and status["result"]["text"]["state"] == "untested"
    assert store.load_config() == before
    invalid = await request(server, {"op": "models.probe", "profile_id": "normal_primary"})
    assert invalid == {"ok": False, "error": "invalid_request"}
    missing = await request(
        server,
        {
            "op": "models.probe",
            "profile_id": "normal_primary",
            "probe_id": "test",
            "capability": "text",
            "hold_units": 100,
        },
    )
    assert missing["ok"] and missing["result"]["error_kind"] == "credential_missing"


async def test_control_recovers_unfinished_model_probe(control):
    from newspaw.providers import ProfileRegistry

    server, store = control
    records = ProfileRegistry(store)
    records.begin("unfinished", "normal_primary", "text", 100)
    await server.close()
    await server.start()
    assert records.get("unfinished")["status"] == "outcome_unknown"


async def test_bot_control_status_verify_and_pair_code_are_local_operations(control):
    from test_routing import configured
    from test_telegram_registry import API

    server, store = control
    config, _ = configured()
    store.save_config(config, expected_revision=1)
    api = API()
    server.bots.client_factory = lambda token: api
    before = await request(server, {"op": "bots.status", "bot_id": "bot1"})
    assert before["ok"] and not before["result"]["verified"]
    verified = await request(server, {"op": "bots.verify", "bot_id": "bot1"})
    assert verified["ok"] and verified["result"]["verified"]
    code = await request(server, {"op": "bots.pair_code", "bot_id": "bot1"})
    assert code["ok"] and len(code["result"]["code"]) >= 24
    paused = await request(server, {"op": "bots.action", "bot_id": "bot1", "action": "pause"})
    assert paused["ok"] and paused["result"]["paused"]
    assert [m for m, p in api.calls] == ["getMe", "getWebhookInfo"]
    assert code["result"]["code"] not in "\n".join(store._db.iterdump())


async def test_source_setup_rpc_catalog_import_and_routes(control):
    server, store = control
    catalog = await request(server, {"op": "sources.catalog"})
    assert catalog["ok"] and any(s["id"] == "cnn" for s in catalog["result"])
    content = '<opml><body><outline text="Feed" xmlUrl="https://example.com/feed"/></body></opml>'
    imported = await request(
        server,
        {"op": "sources.import_opml", "content": content, "revision": store.config_revision()},
    )
    assert imported["ok"]
    identity = imported["result"]["added"][0]
    sources = await request(server, {"op": "sources.list"})
    assert sources["result"][0]["source"]["partition"] is None
    assert await request(server, {"op": "sources.preview", "source_id": identity}) == {
        "ok": False,
        "error": "unclassified_source",
    }
    assert (await request(server, {"op": "sources.routes", "source_id": identity}))["result"] == []
    rejected = await request(
        server, {"op": "sources.discover", "url": "https://example.com/?token=fixture-secret"}
    )
    assert rejected == {"ok": False, "error": "unsafe_url"}
    assert store.config_revision() == 2


async def test_target_rpc_no_fake_readiness_and_explicit_empty_assignment(control):
    server, store = control
    result = await request(server, {"op": "targets.preview", "subscription_id": "sub_world"})
    assert result["ok"] and result["result"]["ready_bot_ids"] == []
    assert "no_target" in result["result"]["blockers"]
    result = await request(
        server,
        {
            "op": "targets.set_subscription",
            "subscription_id": "sub_world",
            "bot_ids": [],
            "revision": store.config_revision(),
        },
    )
    assert result["ok"] and result["result"]["affected_subscriptions"] == []
    denied = await request(
        server,
        {
            "op": "targets.adult_permission",
            "bot_id": "missing",
            "allowed": True,
            "revision": store.config_revision(),
        },
    )
    assert denied == {"ok": False, "error": "missing_bot"}
