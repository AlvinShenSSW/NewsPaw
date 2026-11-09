import asyncio
import json
import os
import socket
import sqlite3
import tempfile
from pathlib import Path

import pytest
from test_credentials import FakeKeychain

from newspaw.control import ControlServer, peer_uid
from newspaw.credentials import CredentialError, CredentialManager
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


async def raw_request(server, data):
    reader, writer = await asyncio.open_unix_connection(server.path, limit=8 * 1024 * 1024)
    writer.write(json.dumps(data, ensure_ascii=False).encode() + b"\n")
    await writer.drain()
    reply = json.loads(await reader.readline())
    writer.close()
    await writer.wait_closed()
    return reply


async def request(server, data):
    """Wire reply without the structured detail, which has its own tests."""
    reply = await raw_request(server, data)
    reply.pop("error_detail", None)
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


async def test_public_search_is_independently_disabled_by_default(control):
    server, store = control
    original = store.config_revision()
    assert (await request(server, {"op": "sources.search.policy"}))["result"] == {
        "revision": 1,
        "profile_id": None,
        "state": "disabled",
    }
    assert await request(
        server,
        {
            "op": "sources.search.run",
            "subscription_id": "sub_world",
            "request_id": "lookup",
            "revision": 1,
            "hold_units": 100_000,
        },
    ) == {"ok": False, "error": "search_not_configured"}
    assert store.config_revision() == original


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


async def test_explicit_service_stop_acknowledges_and_releases_private_endpoint(monkeypatch):
    from types import SimpleNamespace

    from newspaw.control import acquire_control_lock, serve_control

    monkeypatch.setattr("newspaw.credentials.MacKeychain", FakeKeychain)
    with tempfile.TemporaryDirectory(prefix="np-stop-") as directory:
        root = Path(directory)
        endpoint = SimpleNamespace(path=root / "control.sock")
        running = asyncio.create_task(serve_control(root))
        try:
            async with asyncio.timeout(3):
                while True:
                    try:
                        status = await request(endpoint, {"op": "service.status"})
                    except (FileNotFoundError, ConnectionRefusedError):
                        if running.done():
                            running.result()
                            pytest.fail("control server exited before accepting connections")
                        await asyncio.sleep(0.01)
                    else:
                        break
            assert status["ok"] and "service.stop" in status["result"].pop("operations")
            assert status == {"ok": True, "result": {"protocol_version": 1, "state": "running"}}
            stopped = await request(endpoint, {"op": "service.stop"})
            stopped["result"].pop("operations")
            assert stopped == {"ok": True, "result": {"protocol_version": 1, "state": "stopping"}}
            await asyncio.wait_for(running, 3)
            assert not endpoint.path.exists()
            os.close(acquire_control_lock(root))
        finally:
            if not running.done():
                running.cancel()
                await asyncio.gather(running, return_exceptions=True)


async def test_jobs_are_readable_and_controllable_through_private_socket(control):
    from test_routing import configured

    server, store = control
    assert (await request(server, {"op": "jobs.list"}))["result"] == []
    config, sub = configured()
    store.save_config(config, expected_revision=store.config_revision())
    created = server.pipeline.create(
        sub["id"], "manual", holds={"normal_primary": 100, "normal_backup": 100}
    )
    job_id = created["job_id"]
    assert (await request(server, {"op": "jobs.get", "job_id": job_id}))["result"] == created
    assert (await request(server, {"op": "jobs.pause", "job_id": job_id}))["result"]["paused"]
    assert not (await request(server, {"op": "jobs.resume", "job_id": job_id}))["result"]["paused"]
    assert (await request(server, {"op": "jobs.cancel", "job_id": job_id}))["result"]["cancelled"]
    audit = (await request(server, {"op": "jobs.audit", "job_id": job_id}))["result"]
    assert [event["action"] for event in audit] == ["created", "pause", "resume", "cancel"]
    assert (await request(server, {"op": "jobs.advance", "job_id": job_id}))[
        "error"
    ] == "unknown_operation"


async def test_outbox_rpc_exposes_status_and_resolution_without_dispatch(control):
    server, _ = control
    reply = await request(server, {"op": "delivery.status", "job_id": "job.missing"})
    assert reply == {"ok": False, "error": "missing_delivery"}
    bad = await request(
        server,
        {
            "op": "delivery.resolve",
            "job_id": "job.missing",
            "bot_id": "bot1",
            "ordinal": -1,
            "action": "retry",
        },
    )
    assert bad == {"ok": False, "error": "invalid_resolution"}
    assert await request(
        server, {"op": "delivery.requeue_target", "job_id": "job.missing", "bot_id": "bot1"}
    ) == {"ok": False, "error": "missing_delivery"}
    assert (await request(server, {"op": "delivery.advance", "job_id": "job.missing"}))[
        "error"
    ] == "unknown_operation"


async def test_schedule_policy_defaults_enabled_and_updates_independently(control):
    server, store = control
    config_revision = store.config_revision()
    current = (await request(server, {"op": "schedule.status"}))["result"]
    # E10 contract §2: on by default with built-in holds; nothing runs until a digest is enabled.
    assert current["settings"]["enabled"] and current["occurrences"] == []
    assert current["settings"]["holds"] == {"normal": 500_000, "adult": 500_000}
    assert current["settings"]["catchup_minutes"] == 360
    edited = await request(
        server,
        {
            "op": "schedule.configure",
            "settings": {**current["settings"], "catchup_minutes": 0},
            "revision": current["revision"],
        },
    )
    assert edited["ok"] and edited["result"]["revision"] == current["revision"] + 1
    assert store.config_revision() == config_revision


async def test_x_control_creates_local_draft_without_network_or_credentials(control):
    server, store = control
    listed = await request(server, {"op": "x.accounts.list"})
    assert listed["result"]["accounts"] == [] and not listed["result"]["credential_configured"]
    result = await request(
        server, {"op": "x.accounts.add", "handle": "@fixture", "revision": store.config_revision()}
    )
    account = result["result"]["account"]
    assert account["handle"] == "fixture" and not account["can_collect"]
    outcome = await request(
        server,
        {
            "op": "x.accounts.verify",
            "account_id": account["id"],
            "request_id": "ui.verify.1",
            "revision": store.config_revision(),
        },
    )
    assert outcome["result"]["state"] == "credential_missing"
    assert outcome["result"]["attempts"] == []


async def test_failures_carry_structured_detail_with_domain_and_field(control):
    server, _ = control
    missing = await raw_request(server, {"op": "models.probe", "profile_id": "normal_primary"})
    assert missing["error"] == "invalid_request"
    assert missing["error_detail"] == {
        "code": "invalid_request",
        "domain": "models",
        "retryable": False,
        "field": "capability",
    }
    extra = await raw_request(server, {"op": "config.get", "unexpected": 1})
    assert extra["error_detail"]["field"] == "unexpected"
    unknown = await raw_request(server, {"op": "shell"})
    assert unknown["error_detail"] == {
        "code": "unknown_operation",
        "domain": "shell",
        "retryable": False,
    }
    namespaced = await raw_request(server, {"op": "bots.not_real"})
    assert namespaced["error_detail"]["domain"] == "bots"
    for shape in ([], {}, 7, None):
        malformed = await raw_request(server, {"op": shape})
        assert malformed["error_detail"] == {
            "code": "invalid_request",
            "domain": "protocol",
            "retryable": False,
        }
    stale = await raw_request(server, {"op": "budget.save", "document": {}, "revision": 99})
    assert stale["error_detail"]["domain"] == "budget"


@pytest.mark.parametrize(
    ("raised", "code"),
    [
        (KeyError("secret-token-value"), "internal_error"),
        (sqlite3.OperationalError("disk I/O secret-token-value"), "internal_error"),
        (ValueError("route_blocked"), "route_blocked"),
        (ValueError("Invalid secret-token-value"), "invalid_request"),
        (CredentialError("rate_limited"), "rate_limited"),
    ],
)
async def test_unexpected_failures_are_internal_and_logged_without_message(
    control, monkeypatch, caplog, raised, code
):
    server, _ = control

    def fail():
        raise raised

    monkeypatch.setattr(server.operations, "diagnostics", fail)
    with caplog.at_level("WARNING", logger="newspaw.control"):
        reply = await raw_request(server, {"op": "ops.diagnostics"})
    assert reply["error"] == code
    assert reply["error_detail"]["domain"] == "ops"
    assert reply["error_detail"]["retryable"] is (code == "rate_limited")
    assert "secret-token-value" not in json.dumps(reply) + caplog.text
    if code == "internal_error":
        assert f"ops.diagnostics failed ({type(raised).__name__})" in caplog.text


async def test_value_error_field_is_forwarded(control, monkeypatch):
    server, _ = control

    def fail():
        error = ValueError("invalid_document")
        error.field = "document"
        raise error

    monkeypatch.setattr(server.operations, "diagnostics", fail)
    reply = await raw_request(server, {"op": "ops.diagnostics"})
    assert reply["error_detail"] == {
        "code": "invalid_document",
        "domain": "ops",
        "retryable": False,
        "field": "document",
    }


async def test_oversized_reply_keeps_the_structured_envelope(control, monkeypatch):
    server, _ = control
    monkeypatch.setattr(server.operations, "diagnostics", lambda: "x" * (9 * 1024 * 1024))
    reply = await raw_request(server, {"op": "ops.diagnostics"})
    assert reply == {
        "ok": False,
        "error": "response_too_large",
        "error_detail": {"code": "response_too_large", "domain": "ops", "retryable": False},
    }


async def test_status_lists_operations_and_readiness_is_served(control):
    server, _ = control
    status = await request(server, {"op": "service.status"})
    assert status["result"]["protocol_version"] == 1
    assert "setup.readiness" in status["result"]["operations"]
    ready = await request(server, {"op": "setup.readiness"})
    assert ready["ok"] and ready["result"]["next"] == "bot"
    assert [s["step"] for s in ready["result"]["steps"]] == [
        "bot",
        "model",
        "digest",
        "first_delivery",
    ]


@pytest.mark.parametrize(
    "op", ["\ud800", "x" * (8 * 1024 * 1024 - 100), "Bots.List", "bots..list", "a.b.c.d.e"]
)
async def test_unbounded_or_odd_op_names_stay_in_the_protocol_domain(control, op):
    server, _ = control
    reader, writer = await asyncio.open_unix_connection(server.path, limit=9 * 1024 * 1024)
    writer.write(json.dumps({"op": op}).encode() + b"\n")  # ASCII-escaped, so surrogates survive
    await writer.drain()
    raw = await reader.readline()
    writer.close()
    await writer.wait_closed()
    assert len(raw) < 1024
    assert json.loads(raw) == {
        "ok": False,
        "error": "unknown_operation",
        "error_detail": {"code": "unknown_operation", "domain": "protocol", "retryable": False},
    }


async def _drain(server):
    await asyncio.gather(*list(server._background))


async def test_saving_a_model_key_checks_text_once_per_key(control, monkeypatch):
    server, store = control
    calls = []

    async def probe(probe_id, profile_id, capability, hold, *, revision=None):
        calls.append((probe_id, profile_id, capability, hold))
        return {"status": "verified"}

    monkeypatch.setattr(server.probes, "probe", probe)
    saved = await request(
        server,
        {
            "op": "credentials.set",
            "kind": "model_profiles",
            "id": "normal_primary",
            "value": "sk-fixture-value",
            "revision": store.config_revision(),
        },
    )
    assert saved["ok"]
    await _drain(server)
    assert len(calls) == 1
    probe_id, profile, capability, hold = calls[0]
    assert (profile, capability, hold) == ("normal_primary", "text", 10_000)
    assert probe_id.startswith("auto.normal_primary.text.g")
    bot = await request(
        server,
        {
            "op": "credentials.set",
            "kind": "bots",
            "id": "missing",
            "value": "999:fixture_credential_abcdefghijklmnop",
            "revision": store.config_revision(),
        },
    )
    assert not bot["ok"]
    await _drain(server)
    assert len(calls) == 1


async def test_enabling_newspaper_and_media_fills_holds_and_checks_capabilities(
    control, monkeypatch
):
    server, _ = control
    calls = []

    async def probe(probe_id, profile_id, capability, hold, *, revision=None):
        calls.append((profile_id, capability))
        return {"status": "verified"}

    monkeypatch.setattr(server.probes, "probe", probe)
    paper = (await request(server, {"op": "newspaper.policy"}))["result"]
    settings = dict(
        paper["settings"],
        enabled=True,
        generation_profile="normal_primary",
        vision_profile="normal_backup",
    )
    saved = await request(
        server, {"op": "newspaper.configure", "settings": settings, "revision": paper["revision"]}
    )
    assert saved["ok"], saved
    assert {
        k: saved["result"]["settings"][k] for k in ("generation_hold", "vision_hold", "task_limit")
    } == {
        "generation_hold": 400_000,
        "vision_hold": 50_000,
        "task_limit": 1_000_000,
    }
    media = (await request(server, {"op": "media.policy"}))["result"]
    chosen = dict(media["settings"], vision_profile="normal_primary")
    stored = await request(
        server, {"op": "media.configure", "settings": chosen, "revision": media["revision"]}
    )
    assert stored["ok"] and stored["result"]["settings"]["vision_hold"] == 50_000
    await _drain(server)
    assert sorted(calls) == [
        ("normal_backup", "vision"),
        ("normal_primary", "image"),
        ("normal_primary", "vision"),
    ]
    health = await request(server, {"op": "models.health"})
    assert health["ok"] and health["result"] == {"profiles": []}


async def test_an_already_verified_capability_is_not_checked_again(control, monkeypatch):
    from newspaw.providers import ProfileRegistry

    server, store = control
    registry = ProfileRegistry(store)
    registry.begin("manual.vision", "normal_primary", "vision", 1)
    registry.finish("manual.vision", {"status": "verified"})
    calls = []

    async def probe(*args, **kwargs):
        calls.append(args)

    monkeypatch.setattr(server.probes, "probe", probe)
    media = (await request(server, {"op": "media.policy"}))["result"]
    chosen = dict(media["settings"], vision_profile="normal_primary")
    assert (
        await request(
            server, {"op": "media.configure", "settings": chosen, "revision": media["revision"]}
        )
    )["ok"]
    await _drain(server)
    assert calls == []
