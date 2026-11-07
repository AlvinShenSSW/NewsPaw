import asyncio
import threading

import httpx
import pytest
from test_model_runner import NOW
from test_outbox import ready_response, sender
from test_outbox import system as outbox_system

from newspaw.telegram.check_send import TestSends
from newspaw.telegram.client import TelegramError

system = outbox_system


async def test_only_explicit_bot_check_sends_and_uses_the_outbox_lane(system):
    pipeline, targets, job, _, _ = system
    entered, release = asyncio.Event(), asyncio.Event()

    async def response(request):
        if len(sent) == 1:
            assert b"NewsPaw" in request.content
            entered.set()
            await release.wait()
        return ready_response(len(sent))

    outbox, sent = sender(pipeline, targets, response)
    service = TestSends(targets.registry, clock=lambda: NOW, client_factory=outbox.client_factory)
    generation = targets.registry.status("bot1")["generation"]
    assert not sent
    outbox.enqueue(job, now=NOW)
    check = asyncio.create_task(service.send("bot1", generation, "test1"))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        assert (await service.send("bot1", generation, "test1"))["state"] == "inflight"
        await outbox.advance(job, "bot1", now=NOW)
        assert len(sent) == 1
        with pytest.raises(TelegramError, match="send_lane_busy"):
            await service.send("bot1", generation, "test2")
    finally:
        release.set()
        receipt = await check
    assert receipt["state"] == "confirmed"
    assert await service.send("bot1", generation, "test1") == receipt
    await outbox.advance(job, "bot1", now=NOW)
    assert len(sent) == 2


async def test_unknown_bot_check_is_never_resent_on_restart_or_rebinding(system):
    pipeline, targets, _, _, _ = system

    async def timeout(_):
        raise httpx.ReadTimeout("synthetic connection loss")

    outbox, sent = sender(pipeline, targets, timeout)
    registry = targets.registry
    generation = registry.status("bot1")["generation"]
    service = TestSends(registry, clock=lambda: NOW, client_factory=outbox.client_factory)
    receipt = await service.send("bot1", generation, "test1")
    assert receipt["state"] == "outcome_unknown"
    changed = registry.action("bot1", "pause", generation=generation)["generation"]
    restarted = TestSends(registry, clock=lambda: NOW, client_factory=outbox.client_factory)
    restarted.recover_interrupted()
    assert await restarted.send("bot1", generation, "test1") == receipt
    with pytest.raises(TelegramError, match="request_id_conflict"):
        await restarted.send("bot1", changed, "test1")
    assert len(sent) == 1


async def test_test_delivery_revalidates_generation_after_credential_wait(system, monkeypatch):
    pipeline, targets, _, _, _ = system
    outbox, sent = sender(pipeline, targets)
    registry = targets.registry
    generation = registry.status("bot1")["generation"]
    service = TestSends(registry, clock=lambda: NOW, client_factory=outbox.client_factory)
    entered, release = threading.Event(), threading.Event()
    backend = targets.credentials.backend
    read = backend.read

    def delayed(ref):
        entered.set()
        assert release.wait(3)
        return read(ref)

    monkeypatch.setattr(backend, "read", delayed)
    pending = asyncio.create_task(service.send("bot1", generation, "test1"))
    try:
        assert await asyncio.to_thread(entered.wait, 2)
        registry.action("bot1", "pause", generation=generation)
    finally:
        release.set()
    with pytest.raises(TelegramError, match="binding_changed"):
        await pending
    assert not sent
    assert pipeline.db.execute("SELECT count(*) FROM bot_test_sends").fetchone() == (0,)
