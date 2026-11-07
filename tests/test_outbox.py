import asyncio
import base64
import hashlib
import json
import threading
from contextlib import closing, contextmanager
from datetime import timedelta

import httpx
import pytest
from test_credentials import FakeKeychain
from test_model_runner import NOW
from test_pipeline import create, prepare, run_to_terminal
from test_routing import REF, configured
from test_telegram_registry import API, TOKEN, bind, update

from newspaw.credentials import CredentialManager
from newspaw.providers import ProfileRegistry
from newspaw.store import Store
from newspaw.telegram.client import TelegramClient
from newspaw.telegram.outbox import Outbox, OutboxError
from newspaw.telegram.registry import BotRegistry
from newspaw.telegram.targets import TargetManager

REF2 = "keychain:00000000-0000-0000-0000-000000000002"
TOKEN2 = "1000:fixture_second_abcdefghijklmnop"


@pytest.fixture
async def system(tmp_path, request):
    partition = getattr(request, "param", "normal")
    path = tmp_path / "state.db"
    store = Store(path)
    config, sub = configured(partition)
    if partition == "adult":
        # This fixture exercises general adult delivery, not the AV industry adapter.
        fixture = next(row for row in config["categories"] if row["id"] == "av")
        fixture["id"] = sub["category_id"] = "adult_fixture"
        config["sources"][0]["category_ids"] = ["adult_fixture"]
    config["bots"].append(dict(config["bots"][0], id="bot2", credential_ref=REF2))
    sub["bot_ids"] = ["bot1", "bot2"]
    store.save_config(config, expected_revision=1)
    keys = FakeKeychain()
    keys.items.update({REF: TOKEN, REF2: TOKEN2})
    api1, api2 = API(), API()
    api2.remote_id = 1000
    registry = BotRegistry(
        store, keys, client_factory=lambda token: api1 if token == TOKEN else api2
    )
    await bind(registry, api1, now=NOW)
    await registry.verify("bot2", now=NOW)
    code = registry.pair_code("bot2", now=NOW)["code"]
    api2.updates = [update("/pair " + code, when=NOW)]
    await registry.poll_once("bot2", now=NOW)
    profiles = ProfileRegistry(store)
    holds = {f"{partition}_{role}": 100 for role in ("primary", "backup")}
    for profile in holds:
        profiles.begin("verify." + profile, profile, "text", 1)
        profiles.finish("verify." + profile, {"status": "verified"})
    pipeline, _, model_calls = prepare(store)
    targets = TargetManager(CredentialManager(store, keys), registry)
    job_id = pipeline.create(sub["id"], "daily", holds=holds, task_limit=500, now=NOW)["job_id"]
    assert (await run_to_terminal(pipeline, job_id))["stage"] == "awaiting_delivery"
    yield pipeline, targets, job_id, model_calls, path
    await registry.close()
    store.close()


def ready_response(identity=42):
    return httpx.Response(
        200,
        json={
            "ok": True,
            "result": {"message_id": identity, "chat": {"id": 123, "type": "private"}},
        },
    )


def sender(pipeline, targets, responder=None):
    calls = []

    async def respond(request):
        calls.append(request)
        return await responder(request) if responder else ready_response(len(calls))

    def factory(token):
        return TelegramClient(
            token, client=httpx.AsyncClient(transport=httpx.MockTransport(respond))
        )

    return Outbox(pipeline, targets, client_factory=factory), calls


def bot_status(outbox, job_id, bot):
    return outbox.status(job_id, bot_id=bot)["targets"][bot]


async def test_fanout_reuses_content_and_has_one_receipt_per_bot(system):
    pipeline, targets, job, model_calls, _ = system
    outbox, calls = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    outbox.enqueue(job, now=NOW)
    for bot in ("bot1", "bot2", "bot1", "bot2"):
        await outbox.advance(job, bot, now=NOW)
    assert len(calls) == 2 and len(model_calls) == 1
    assert [request.url.path.split("/")[1] for request in calls] == ["bot" + TOKEN, "bot" + TOKEN2]
    bodies = [json.loads(request.content) for request in calls]
    assert bodies[0] == bodies[1]
    assert "https://example.com/a" in bodies[0]["text"]
    assert bodies[0]["link_preview_options"] == {"is_disabled": True}
    for bot, message_id in (("bot1", 1), ("bot2", 2)):
        result = bot_status(outbox, job, bot)
        assert result["status"] == "delivered"
        assert result["parts"][0]["message_id"] == message_id
    assert TOKEN not in "\n".join(pipeline.db.iterdump())


async def test_rate_limit_holds_only_that_bot_and_applies_to_other_jobs(system):
    pipeline, targets, job, _, _ = system

    async def respond(request):
        if (
            "/bot999:" in request.url.path
            and sum("/bot999:" in call.url.path for call in calls) == 1
        ):
            return httpx.Response(
                429, json={"ok": False, "error_code": 429, "parameters": {"retry_after": 31}}
            )
        return ready_response()

    outbox, calls = sender(pipeline, targets, respond)
    other = create(pipeline, "sub_world", "later")
    await run_to_terminal(pipeline, other)
    outbox.enqueue(job, now=NOW)
    outbox.enqueue(other, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(other, "bot1", now=NOW + timedelta(seconds=30))
    assert len(calls) == 1
    await outbox.advance(job, "bot2", now=NOW)
    assert bot_status(outbox, job, "bot2")["status"] == "delivered"
    await outbox.advance(job, "bot1", now=NOW + timedelta(seconds=31))
    assert len(calls) == 3 and bot_status(outbox, job, "bot1")["status"] == "delivered"


async def test_unknown_send_needs_explicit_ack_and_does_not_block_peer(system):
    pipeline, targets, job, _, _ = system

    async def respond(request):
        if len(calls) == 1:
            raise httpx.ReadTimeout("fixture response lost")
        return ready_response()

    outbox, calls = sender(pipeline, targets, respond)
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(job, "bot1", now=NOW + timedelta(hours=1))
    assert bot_status(outbox, job, "bot1")["status"] == "outcome_unknown"
    assert len(calls) == 1
    await outbox.advance(job, "bot2", now=NOW)
    assert bot_status(outbox, job, "bot2")["status"] == "delivered"
    with pytest.raises(OutboxError, match="duplicate_send_ack_required"):
        outbox.resolve(job, "bot1", 0, "retry", now=NOW)
    outbox.resolve(job, "bot1", 0, "retry", acknowledge_duplicate_send=True, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    assert bot_status(outbox, job, "bot1")["status"] == "delivered"
    assert [a["state"] for a in bot_status(outbox, job, "bot1")["parts"][0]["attempts"]] == [
        "outcome_unknown",
        "delivered",
    ]


async def test_competing_connections_cannot_send_same_part(system):
    pipeline, targets, job, _, path = system
    started, release = asyncio.Event(), asyncio.Event()

    async def slow(request):
        started.set()
        await release.wait()
        return ready_response()

    first, calls = sender(pipeline, targets, slow)
    first.enqueue(job, now=NOW)
    running = asyncio.create_task(first.advance(job, "bot1", now=NOW))
    await asyncio.wait_for(started.wait(), 2)
    with closing(Store(path)) as store:
        other_pipeline, _, _ = prepare(store)
        manager = CredentialManager(store, targets.credentials.backend)
        registry = BotRegistry(store, manager.backend)
        second, repeated = sender(other_pipeline, TargetManager(manager, registry))
        try:
            await second.advance(job, "bot1", now=NOW + timedelta(hours=1))
            assert not repeated
        finally:
            release.set()
            await running
    assert len(calls) == 1 and bot_status(first, job, "bot1")["status"] == "delivered"


async def test_pause_one_binding_does_not_change_peer_authority(system):
    pipeline, targets, job, _, _ = system
    outbox, calls = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    targets.registry.action("bot1", "pause")
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 1 and "/bot1000:" in calls[0].url.path
    assert bot_status(outbox, job, "bot1")["status"] == "revoked"
    assert bot_status(outbox, job, "bot2")["status"] == "delivered"


@pytest.mark.parametrize("code,reason", [(401, "token_revoked"), (403, "forbidden")])
async def test_verified_rejection_revokes_only_current_bot(system, code, reason):
    pipeline, targets, job, _, _ = system

    async def respond(request):
        if len(calls) == 1:
            return httpx.Response(code, json={"ok": False, "error_code": code})
        return ready_response()

    outbox, calls = sender(pipeline, targets, respond)
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    assert not targets.registry.status("bot1")["verified"]
    assert bot_status(outbox, job, "bot1")["reason"] == reason
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 2 and bot_status(outbox, job, "bot2")["status"] == "delivered"


async def test_old_rejection_cannot_revoke_new_token_generation(system):
    pipeline, targets, job, _, _ = system

    async def respond(request):
        replacement = "999:fixture_rotation_abcdefghijklmnop"
        await targets.credentials.set("bots", "bot1", replacement, pipeline.store.config_revision())
        new_api = API()
        targets.registry.client_factory = lambda token: new_api
        await bind(targets.registry, new_api, now=NOW + timedelta(minutes=1))
        return httpx.Response(401, json={"ok": False, "error_code": 401})

    outbox, calls = sender(pipeline, targets, respond)
    outbox.enqueue(job, now=NOW)
    original = targets.registry.snapshot("bot1")
    await outbox.advance(job, "bot1", now=NOW)
    current = targets.registry.snapshot("bot1")
    assert (
        current.generation != original.generation
        and current.credential_ref != original.credential_ref
    )
    assert len(calls) == 1 and bot_status(outbox, job, "bot1")["status"] == "revoked"


async def test_binding_checked_again_after_awaited_key_read(system, monkeypatch):
    pipeline, targets, job, _, _ = system
    outbox, calls = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    started, release = asyncio.Event(), threading.Event()
    loop = asyncio.get_running_loop()
    backend = targets.credentials.backend
    original = backend.read

    def read(ref):
        if ref == REF:
            loop.call_soon_threadsafe(started.set)
            assert release.wait(5)
        return original(ref)

    monkeypatch.setattr(backend, "read", read)
    sending = asyncio.create_task(outbox.advance(job, "bot1", now=NOW))
    try:
        await asyncio.wait_for(started.wait(), 2)
        targets.registry.action("bot1", "unbind", now=NOW)
    finally:
        release.set()
    await sending
    assert not calls and bot_status(outbox, job, "bot1")["status"] == "revoked"
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 1


@pytest.mark.parametrize("point", ["before_intent", "after_intent", "receipt"])
async def test_recovery_never_blindly_replays_durable_intent(system, monkeypatch, point):
    pipeline, targets, job, _, path = system
    outbox, calls = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    db = pipeline.db
    if point in {"before_intent", "receipt"}:
        condition = (
            "NEW.inflight_part IS NOT NULL"
            if point == "before_intent"
            else "OLD.inflight_part IS NOT NULL AND NEW.inflight_part IS NULL"
        )
        db.execute(
            f"""CREATE TRIGGER fail_send_write BEFORE UPDATE ON delivery_targets
                WHEN {condition} BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END"""
        )
    else:
        original = pipeline.store._write
        armed = True

        @contextmanager
        def crash_after_intent():
            nonlocal armed
            with original():
                yield
            if (
                armed
                and db.execute(
                    "SELECT 1 FROM delivery_targets WHERE inflight_part IS NOT NULL"
                ).fetchone()
            ):
                armed = False
                raise OSError("synthetic exit after intent commit")

        monkeypatch.setattr(pipeline.store, "_write", crash_after_intent)
    try:
        with pytest.raises(OutboxError, match="storage_failed"):
            await outbox.advance(job, "bot1", now=NOW)
    finally:
        if point in {"before_intent", "receipt"}:
            db.execute("DROP TRIGGER fail_send_write")
    assert len(calls) == int(point == "receipt")
    with closing(Store(path)) as restarted:
        restarted_pipeline, _, _ = prepare(restarted)
        creds = CredentialManager(restarted, targets.credentials.backend)
        restarted_registry = BotRegistry(restarted, creds.backend)
        resumed, new_calls = sender(restarted_pipeline, TargetManager(creds, restarted_registry))
        assert resumed.recover_interrupted() == int(point != "before_intent")
        await resumed.advance(job, "bot1", now=NOW)
        if point == "before_intent":
            assert len(new_calls) == 1
            assert bot_status(resumed, job, "bot1")["status"] == "delivered"
        else:
            assert not new_calls
            assert bot_status(resumed, job, "bot1")["status"] == "outcome_unknown"
            await resumed.advance(job, "bot2", now=NOW)
            assert len(new_calls) == 1


def with_photos(pipeline, job):
    data = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ9sAAAAASUVORK5CYII="
    )
    row = pipeline._row(job)
    row["payload"]["media"]["photos"] = [
        dict(
            asset_id=f"photo{i}",
            sha256=hashlib.sha256(data).hexdigest(),
            mime="image/png",
            width=1,
            height=1,
            caption=f"第 {i} 页",
        )
        for i in (1, 2)
    ]
    with pipeline.store._write():
        pipeline.db.execute(
            "UPDATE pipeline_jobs SET payload=? WHERE id=?",
            (json.dumps(row["payload"]), job),
        )
    return data


async def test_partial_photos_preserve_text_and_first_photo_receipts(system):
    pipeline, targets, job, _, _ = system
    data = with_photos(pipeline, job)

    async def respond(request):
        if len(calls) == 3:
            return httpx.Response(
                429, json={"ok": False, "error_code": 429, "parameters": {"retry_after": 10}}
            )
        return ready_response(len(calls))

    outbox, calls = sender(pipeline, targets, respond)
    outbox.asset_resolver = lambda asset_id: data
    outbox.enqueue(job, now=NOW)
    for _ in range(3):
        await outbox.advance(job, "bot1", now=NOW)
    assert [call.url.path.rsplit("/", 1)[1] for call in calls] == [
        "sendMessage",
        "sendPhoto",
        "sendPhoto",
    ]
    assert calls[1].headers["content-type"].startswith("multipart/form-data;")
    assert data in calls[1].content and b'name="has_spoiler"' in calls[1].content
    result = bot_status(outbox, job, "bot1")
    assert result["status"] == "partial"
    assert [part.get("message_id") for part in result["parts"]] == [1, 2, None]
    await outbox.advance(job, "bot1", now=NOW + timedelta(seconds=10))
    assert [part["message_id"] for part in bot_status(outbox, job, "bot1")["parts"]] == [1, 2, 4]


async def test_locale_change_stops_remaining_parts_without_losing_first_receipt(system):
    pipeline, targets, job, _, _ = system
    data = with_photos(pipeline, job)
    outbox, calls = sender(pipeline, targets)
    outbox.asset_resolver = lambda asset_id: data
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    revision, config = pipeline.store.load_config()
    original = config["news_output_locale"]
    config["news_output_locale"] = "ja" if original != "ja" else "en"
    revision = pipeline.store.save_config(config, expected_revision=revision)
    await outbox.advance(job, "bot1", now=NOW)
    config["news_output_locale"] = original
    pipeline.store.save_config(config, expected_revision=revision)
    await outbox.advance(job, "bot1", now=NOW)
    view = bot_status(outbox, job, "bot1")
    assert len(calls) == 1 and view["status"] == "partial"
    assert view["reason"] == "edition_changed" and view["parts"][0]["message_id"] == 1


async def test_assignment_recomputed_before_intent_and_no_new_peer_after_intent(system):
    pipeline, targets, job, _, _ = system
    outbox, calls = sender(pipeline, targets)
    await targets.set_subscription("sub_world", ["bot1"], pipeline.store.config_revision())
    assert list(outbox.enqueue(job, now=NOW)["targets"]) == ["bot1"]
    await targets.set_subscription("sub_world", ["bot2"], pipeline.store.config_revision())
    outbox.enqueue(job, now=NOW)
    assert bot_status(outbox, job, "bot1")["status"] == "revoked"
    await outbox.advance(job, "bot2", now=NOW)
    await targets.set_subscription("sub_world", ["bot1", "bot2"], pipeline.store.config_revision())
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    assert len(calls) == 1 and not bot_status(outbox, job, "bot1")["selected"]


@pytest.mark.parametrize(
    "response_kind", ["wrong_chat", "wrong_sender", "mismatched_code", "server_error"]
)
async def test_malformed_or_ambiguous_telegram_response_does_not_authorize_retry(
    system, response_kind
):
    pipeline, targets, job, _, _ = system

    async def respond(request):
        if response_kind == "mismatched_code":
            return httpx.Response(500, json={"ok": False, "error_code": 429})
        if response_kind == "server_error":
            return httpx.Response(502)
        result = {"message_id": 1, "chat": {"type": "private", "id": 123}}
        if response_kind == "wrong_chat":
            result["chat"]["id"] = 456
        else:
            result["from"] = {"id": 1000, "is_bot": True}
        return httpx.Response(200, json={"ok": True, "result": result})

    outbox, calls = sender(pipeline, targets, respond)
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(job, "bot1", now=NOW + timedelta(hours=1))
    assert len(calls) == 1 and bot_status(outbox, job, "bot1")["status"] == "outcome_unknown"


@pytest.mark.parametrize("system", ["adult"], indirect=True)
async def test_adult_optout_revokes_only_that_target_and_photo_is_spoilered(system):
    pipeline, targets, job, _, _ = system
    data = with_photos(pipeline, job)
    outbox, calls = sender(pipeline, targets)
    outbox.asset_resolver = lambda asset_id: data
    outbox.enqueue(job, now=NOW)
    await targets.adult_permission("bot1", False, pipeline.store.config_revision())
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(job, "bot2", now=NOW)
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 2 and all("/bot1000:" in call.url.path for call in calls)
    assert bot_status(outbox, job, "bot1")["status"] == "revoked"
    assert b'name="has_spoiler"\r\n\r\ntrue\r\n' in calls[1].content


async def test_cancellation_after_dispatch_preserves_unknown(system):
    pipeline, targets, job, _, _ = system
    started = asyncio.Event()

    async def hanging(request):
        started.set()
        await asyncio.Future()

    outbox, calls = sender(pipeline, targets, hanging)
    outbox.enqueue(job, now=NOW)
    running = asyncio.create_task(outbox.advance(job, "bot1", now=NOW))
    await asyncio.wait_for(started.wait(), 2)
    running.cancel()
    with pytest.raises(asyncio.CancelledError):
        await running
    result = bot_status(outbox, job, "bot1")
    assert result["status"] == "outcome_unknown"
    assert result["parts"][0]["reason"] == "cancelled_after_intent"
    await outbox.advance(job, "bot1", now=NOW + timedelta(days=1))
    assert len(calls) == 1


def test_splitter_keeps_astral_budget_and_citation_links():
    from newspaw.telegram.text import split_delivery_text

    link = "https://example.com/article"
    parts = split_delivery_text("🐾" * 10 + "\n" + link, limit=30)
    assert parts == ["🐾" * 10, link]
    with pytest.raises(ValueError, match="citation_line_too_long"):
        split_delivery_text(link + "a" * 30, limit=30)


async def test_owner_requeue_only_arms_initially_unready_existing_target(system):
    pipeline, targets, job, _, _ = system
    targets.registry.action("bot2", "pause", now=NOW)
    outbox, calls = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    assert bot_status(outbox, job, "bot2")["reason"] == "paused"
    targets.registry.action("bot2", "resume", now=NOW)
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot2", now=NOW)
    assert not calls and bot_status(outbox, job, "bot2")["part_count"] == 0

    with pytest.raises(OutboxError, match="target_not_requeueable"):
        outbox.requeue_target(job, "bot1")
    view = outbox.requeue_target(job, "bot2")
    assert not calls and not view["started"]
    assert view["targets"]["bot2"]["parts"][0]["attempts"] == []
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 1 and bot_status(outbox, job, "bot2")["status"] == "delivered"


async def test_owner_requeue_cannot_expand_recipients_after_other_bot_intent(system):
    pipeline, targets, job, _, _ = system
    dispatch_started, response_ready = asyncio.Event(), asyncio.Event()

    async def respond(_):
        dispatch_started.set()
        await response_ready.wait()
        return ready_response()

    targets.registry.action("bot2", "pause", now=NOW)
    outbox, calls = sender(pipeline, targets, respond)
    outbox.enqueue(job, now=NOW)
    sending = asyncio.create_task(outbox.advance(job, "bot1", now=NOW))
    try:
        await asyncio.wait_for(dispatch_started.wait(), 2)
        targets.registry.action("bot2", "resume", now=NOW)
        with pytest.raises(OutboxError, match="recipient_set_frozen"):
            outbox.requeue_target(job, "bot2")
    finally:
        response_ready.set()
        await sending
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 1 and bot_status(outbox, job, "bot2")["part_count"] == 0
