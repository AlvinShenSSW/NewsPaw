from datetime import timedelta

import httpx
from test_outbox import REF2, TOKEN2, bot_status, ready_response, sender
from test_routing import REF
from test_telegram_registry import API, TOKEN, bind, update
from test_x_digests import _digest_fixture, timeline_system
from test_x_timelines import NOW, page, post

from newspaw.x.alerts import Alerts

assert timeline_system is not None


async def alert_system(system, responder):
    async def reply(request, _):
        return page([dict(post(190), text="OpenAI released GPT-6.")])

    build, scans, sub, identity, holds, model_calls = await _digest_fixture(system, reply)
    pipeline = build()
    targets = scans.directory.targets
    keys = targets.credentials.backend
    keys.items.update({REF: TOKEN, REF2: TOKEN2})
    revision, config = pipeline.store.load_config()
    config["bots"][1]["credential_ref"] = REF2
    next(row for row in config["subscriptions"] if row["id"] == sub)["bot_ids"] = ["bot1", "bot2"]
    pipeline.store.save_config(config, expected_revision=revision)
    api1, api2 = API(), API()
    api2.remote_id = 1000
    registry = targets.registry
    registry.client_factory = lambda token: api1 if token == TOKEN else api2
    await bind(registry, api1, now=NOW)
    await registry.verify("bot2", now=NOW)
    code = registry.pair_code("bot2", now=NOW)["code"]
    api2.updates = [update("/pair " + code, when=NOW)]
    await registry.poll_once("bot2", now=NOW)
    outbox, calls = sender(pipeline, targets, responder)
    clock = [NOW]
    alerts = Alerts(pipeline, outbox, clock=lambda: clock[0])
    outbox.alert_guard = alerts.guard

    async def edition(name):
        job = pipeline.create(sub, name, holds=holds, now=clock[0])["job_id"]
        for _ in range(3):
            await pipeline.advance(job, now=clock[0])
        assert pipeline.get(job)["stage"] == "awaiting_delivery"
        return job

    settings = alerts.status()["settings"]
    settings.update(
        enabled=True,
        timezone="UTC",
        quiet_start="02:01",
        quiet_end="02:05",
        daily_limit=1,
        rules=[
            dict(subscription_id=sub, account_id=None, phrase="GPT-6"),
            dict(subscription_id=sub, account_id=None, phrase="OpenAI"),
        ],
    )
    return alerts, clock, outbox, calls, model_calls, edition, settings


async def test_quiet_hours_recheck_each_bot_after_credentials_and_preserve_single_count(
    timeline_system,
):
    async def response(_):
        return ready_response()

    alerts, clock, outbox, calls, model_calls, edition, settings = await alert_system(
        timeline_system, response
    )
    await alerts.tick()
    assert not calls and not alerts.status()["occurrences"]
    alerts.configure(settings, alerts.status()["revision"])
    parent = await edition("prepared")
    revision, policy, active = alerts._policy()
    alerts._discover(revision, policy, active, clock[0])
    [entry] = alerts.status()["occurrences"]
    job = entry["job_id"]
    assert job != parent
    assert outbox.enqueue(job, now=clock[0])["partition"] == "normal"
    await outbox.advance(job, "bot1", now=clock[0])
    original_read = outbox.targets.credentials.backend.read

    def crossing(ref):
        value = original_read(ref)
        if ref == REF2:
            clock[0] = NOW + timedelta(minutes=1)
        return value

    outbox.targets.credentials.backend.read = crossing
    await outbox.advance(job, "bot2", now=NOW)
    assert len(calls) == 1 and bot_status(outbox, job, "bot2")["status"] == "pending"
    assert alerts.status()["occurrences"][0]["reason"] == "quiet_hours"
    assert alerts.status()["occurrences"][0]["claimed_at"] == NOW.isoformat()

    outbox.targets.credentials.backend.read = original_read
    restarted = Alerts(alerts.pipeline, outbox, clock=lambda: clock[0])
    outbox.alert_guard = restarted.guard
    clock[0] = NOW + timedelta(minutes=5)
    await restarted.tick()
    assert len(calls) == 2 and len(model_calls) == 1
    assert all(b"Major event on X" in call.content for call in calls)
    assert restarted.status()["occurrences"][0]["state"] == "delivered"
    assert restarted.status()["occurrences"][0]["claimed_at"] == NOW.isoformat()
    await edition("same-post")
    await restarted.tick()
    assert len(calls) == 2 and len(restarted.status()["occurrences"]) == 1


async def test_unknown_alert_delivery_does_not_automatically_repeat(timeline_system):
    async def response(_):
        raise httpx.ReadTimeout("fixture")

    alerts, _, outbox, calls, _, edition, settings = await alert_system(timeline_system, response)
    alerts.configure(settings, alerts.status()["revision"])
    await edition("prepared")
    await alerts.tick()
    [entry] = alerts.status()["occurrences"]
    assert entry["state"] == "outcome_unknown" and len(calls) == 2
    await alerts.tick()
    await outbox.advance(entry["job_id"], "bot1", now=NOW)
    assert len(calls) == 2
