import asyncio
import threading
from datetime import UTC, date, datetime, timedelta

import httpx
import pytest
from test_credentials import FakeKeychain
from test_model_runner import NOW
from test_outbox import REF2, sender
from test_outbox import system as outbox_system
from test_pipeline import FRESH
from test_routing import configured

from newspaw.credentials import CredentialManager
from newspaw.evidence import FeedCollector
from newspaw.pipeline import Pipeline
from newspaw.scheduler import ScheduleError, Scheduler, resolve_wall_time
from newspaw.store import Store
from newspaw.telegram.outbox import Outbox
from newspaw.telegram.registry import BotRegistry
from newspaw.telegram.targets import TargetManager

system = outbox_system


@pytest.mark.parametrize(
    ("day", "value", "zone", "expected"),
    [
        (date(2026, 10, 4), "02:30", "Australia/Sydney", "2026-10-03T16:00:00+00:00"),
        (date(2026, 4, 5), "02:30", "Australia/Sydney", "2026-04-04T15:30:00+00:00"),
        (date(2026, 11, 8), "00:05", "Asia/Tokyo", "2026-11-07T15:05:00+00:00"),
        (date(2011, 12, 30), "00:00", "Pacific/Apia", None),
    ],
)
def test_wall_clock_dst_and_skipped_day(day, value, zone, expected):
    result = resolve_wall_time(day, value, zone)
    assert (result.isoformat() if result else None) == expected


@pytest.fixture
def planner(tmp_path):
    store = Store(tmp_path / "state.db")
    cfg, sub = configured()
    sub.update(times=["09:00", "12:00"], timezone="Asia/Tokyo")
    store.save_config(cfg, expected_revision=1)
    keys = FakeKeychain()
    pipeline = Pipeline(store, keys)
    targets = TargetManager(CredentialManager(store, keys), BotRegistry(store, keys))
    scheduler = Scheduler(pipeline, Outbox(pipeline, targets))
    yield scheduler, store
    store.close()


def moment(hour, minute=0, day=8):
    return datetime(2026, 11, day, hour, minute, tzinfo=UTC)


def activate(scheduler):
    policy = scheduler.policy()
    settings = policy["settings"]
    settings.update(enabled=True, holds={"normal": 1000, "adult": None})
    return scheduler.configure(settings, policy["revision"], now=moment(20, day=7))


def test_policy_is_disabled_and_independent_from_config_revision(planner):
    scheduler, store = planner
    assert scheduler.plan(moment(4)) == []
    revision = store.config_revision()
    saved = activate(scheduler)
    assert saved["revision"] == 2 and store.config_revision() == revision
    with pytest.raises(ScheduleError, match="schedule_policy_changed"):
        scheduler.configure(saved["settings"], 1, now=moment(4))


def test_long_sleep_newest_elapsed_and_future_lead_are_independent(planner):
    scheduler, _ = planner
    activate(scheduler)
    # Wake at 12:05 Tokyo. 09:00 is still within the six-hour window.
    ready = scheduler.plan(moment(3, 5))
    rows = scheduler.status()["occurrences"]
    assert len(ready) == 1
    assert {row["target_at"][11:16]: row["status"] for row in rows} == {
        "00:00": "superseded",
        "03:00": "late",
    }


def test_lead_time_crosses_midnight_and_does_not_create_duplicate_slot(planner):
    scheduler, _ = planner
    activate(scheduler)
    ready = scheduler.plan(moment(23, 50, day=7))
    assert len(ready) == 1
    row = ready[0]
    assert row["target_at"] == moment(0).isoformat()
    assert row["prepare_at"] == (moment(0) - timedelta(minutes=15)).isoformat()
    assert scheduler.plan(moment(23, 51, day=7))[0]["id"] == row["id"]


def test_expired_missed_slots_are_not_queued(planner):
    scheduler, _ = planner
    activate(scheduler)
    assert scheduler.plan(moment(14)) == []
    assert {row["status"] for row in scheduler.status()["occurrences"]} == {"skipped"}


def scheduled(pipeline, outbox, now, *, catchup=360, subscription="sub_world"):
    revision, config = pipeline.store.load_config()
    sub = next(row for row in config["subscriptions"] if row["id"] == subscription)
    target = now + timedelta(minutes=10)
    sub.update(times=[target.strftime("%H:%M")], timezone="UTC")
    pipeline.store.save_config(config, expected_revision=revision)
    clock = [now]
    scheduler = Scheduler(pipeline, outbox, clock=lambda: clock[0])
    policy = scheduler.policy()
    settings = policy["settings"]
    settings.update(enabled=True, catchup_minutes=catchup, holds={"normal": 100, "adult": 100})
    scheduler.configure(settings, policy["revision"], now=now)
    return scheduler, clock, target


async def prepare_scheduled(scheduler, clock, *, steps=3):
    for _ in range(steps):
        (row,) = scheduler.plan(clock[0])
        await scheduler.step(row)
    (row,) = scheduler.plan(clock[0])
    return row


async def test_prepares_before_send_and_completed_slot_survives_retime(system):

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock)
    assert pipeline.get(row["job_id"])["stage"] == "awaiting_delivery"
    await scheduler.step(row)
    assert not calls and scheduler.status()["occurrences"][0]["reason"] == "awaiting_target_time"
    clock[0] = target
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(calls) == 2 and scheduler.status()["occurrences"][0]["status"] == "delivered"
    assert scheduler.status()["occurrences"][0]["state"] == "delivered"

    revision, config = pipeline.store.load_config()
    sub = next(row for row in config["subscriptions"] if row["id"] == "sub_world")
    sub["times"] = [(target + timedelta(minutes=5)).strftime("%H:%M")]
    pipeline.store.save_config(config, expected_revision=revision)
    assert scheduler.plan(target + timedelta(minutes=1)) == []
    assert scheduler.status()["occurrences"][0]["id"] == row["id"]


async def test_slow_source_marks_late_without_sending_before_ready(system):

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    entered, release = asyncio.Event(), asyncio.Event()

    async def fetch(request):
        entered.set()
        await release.wait()
        return httpx.Response(200, content=FRESH)

    pipeline.feed_factory = lambda evidence: FeedCollector(
        evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(fetch))
    )
    (row,) = scheduler.plan(clock[0])
    task = asyncio.create_task(scheduler.step(row))
    try:
        await asyncio.wait_for(entered.wait(), 2)
        clock[0] = target + timedelta(minutes=1)
        scheduler.plan(clock[0])
        assert scheduler.status()["occurrences"][0]["status"] == "late"
        assert not calls
    finally:
        release.set()
        await task
    row = await prepare_scheduled(scheduler, clock, steps=2)
    assert not calls and pipeline.get(row["job_id"])["stage"] == "awaiting_delivery"
    await scheduler.step(row)
    assert len(calls) == 2


async def test_send_deadline_is_rechecked_after_keychain_wait(system, monkeypatch):

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW, catchup=1)
    row = await prepare_scheduled(scheduler, clock)
    clock[0] = target
    backend = targets.credentials.backend
    read = backend.read
    entered, release = threading.Event(), threading.Event()

    def delayed(ref):
        entered.set()
        assert release.wait(3)
        return read(ref)

    monkeypatch.setattr(backend, "read", delayed)
    task = asyncio.create_task(scheduler.step(row))
    try:
        assert await asyncio.to_thread(entered.wait, 2)
        clock[0] = target + timedelta(minutes=2)
    finally:
        release.set()
        await task
    assert not calls and not outbox.status(row["job_id"])["started"]
    assert scheduler.status()["occurrences"][0]["reason"] == "catchup_expired"


async def test_partial_assignment_change_during_peer_keychain_wait_holds(system, monkeypatch):

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock)
    clock[0] = target
    backend = targets.credentials.backend
    read = backend.read
    entered, release = threading.Event(), threading.Event()

    def delayed(ref):
        if ref == REF2:
            entered.set()
            assert release.wait(3)
        return read(ref)

    monkeypatch.setattr(backend, "read", delayed)
    task = asyncio.create_task(scheduler.step(row))
    try:
        assert await asyncio.to_thread(entered.wait, 2)
        for _ in range(200):
            if outbox.status(row["job_id"])["targets"]["bot1"]["status"] == "delivered":
                break
            await asyncio.sleep(0.002)
        else:
            pytest.fail("first Bot did not complete")
        await targets.set_subscription("sub_world", ["bot2"], pipeline.store.config_revision())
    finally:
        release.set()
        await task
    assert len(calls) == 1
    assert scheduler.status()["occurrences"][0]["reason"] == "partial_assignment_changed"
    scheduler.resolve(row["id"], "continue")
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(calls) == 2 and scheduler.status()["occurrences"][0]["status"] == "delivered"


async def test_disabled_schedule_denies_model_intent_after_keychain_wait(system, monkeypatch):

    pipeline, targets, _, model_calls, _ = system
    outbox, _ = sender(pipeline, targets)
    scheduler, clock, _ = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock, steps=1)
    assert pipeline.get(row["job_id"])["stage"] == "editing"
    backend = pipeline.runner.backend
    read = backend.read
    entered, release = threading.Event(), threading.Event()

    def delayed(ref):
        entered.set()
        assert release.wait(3)
        return read(ref)

    monkeypatch.setattr(backend, "read", delayed)
    previous = len(model_calls)
    task = asyncio.create_task(scheduler.step(row))
    try:
        assert await asyncio.to_thread(entered.wait, 2)
        policy = scheduler.policy()
        scheduler.configure({**policy["settings"], "enabled": False}, policy["revision"])
    finally:
        release.set()
        await task
    assert len(model_calls) == previous
    assert pipeline.get(row["job_id"])["model"]["attempts"] == []
    assert scheduler.status()["occurrences"][0]["reason"] == "schedule_disabled"


async def test_false_source_guard_commits_state_and_prevents_request(system):

    pipeline, targets, _, _, _ = system
    outbox, _ = sender(pipeline, targets)
    scheduler, clock, _ = scheduled(pipeline, outbox, NOW)
    (row,) = scheduler.plan(clock[0])
    with pipeline.store._write():
        pipeline.db.execute("CREATE TABLE guard_proof (decision TEXT)")
    settings = scheduler.policy()["settings"]
    attached = scheduler._attach(row, settings, NOW)
    before = pipeline.db.execute("SELECT COUNT(*) FROM feed_attempts").fetchone()[0]

    def deny():
        pipeline.db.execute("INSERT INTO guard_proof VALUES ('held')")
        return False

    result = await pipeline.advance(attached["job_id"], now=NOW, effect_guard=deny)
    assert result["stage"] == "collecting"
    assert pipeline.db.execute("SELECT COUNT(*) FROM feed_attempts").fetchone()[0] == before
    assert pipeline.db.execute("SELECT decision FROM guard_proof").fetchone() == ("held",)


async def test_slow_model_can_settle_after_cutoff_without_sending(system, monkeypatch):
    pipeline, targets, _, model_calls, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW, catchup=1)
    row = await prepare_scheduled(scheduler, clock, steps=1)
    entered, release = asyncio.Event(), asyncio.Event()
    factory = pipeline.runner.adapter_factory

    def slow(profile, key):
        adapter = factory(profile, key)
        original = adapter.generate

        async def generate(spec):
            entered.set()
            await release.wait()
            return await original(spec)

        monkeypatch.setattr(adapter, "generate", generate)
        return adapter

    monkeypatch.setattr(pipeline.runner, "adapter_factory", slow)
    before = len(model_calls)
    task = asyncio.create_task(scheduler.step(row))
    try:
        await asyncio.wait_for(entered.wait(), 2)
        clock[0] = target + timedelta(minutes=2)
        assert scheduler.plan(clock[0]) == []
        assert scheduler.status()["occurrences"][0]["status"] == "outcome_unknown"
    finally:
        release.set()
        await task
    assert not calls and len(model_calls) == before + 1
    assert pipeline.get(row["job_id"])["model"]["state"] == "completed"
    assert scheduler.status()["occurrences"][0]["status"] == "skipped"


async def test_restart_reuses_job_inserted_before_occurrence_link(system):
    pipeline, targets, _, _, _ = system
    outbox, _ = sender(pipeline, targets)
    scheduler, clock, _ = scheduled(pipeline, outbox, NOW)
    (row,) = scheduler.plan(clock[0])
    job = pipeline.create(
        "sub_world",
        f"{row['id']}.{row['generation']}",
        holds={"normal_primary": 100, "normal_backup": 100},
        now=NOW,
    )
    saved_count = pipeline.db.execute("SELECT COUNT(*) FROM pipeline_jobs").fetchone()[0]
    resumed = Scheduler(pipeline, outbox, clock=lambda: clock[0])
    await resumed.step(resumed.plan(clock[0])[0])
    current = resumed.status()["occurrences"][0]
    assert current["job_id"] == job["job_id"]
    assert pipeline.db.execute("SELECT COUNT(*) FROM pipeline_jobs").fetchone()[0] == saved_count


async def test_content_change_after_first_part_preserves_receipts(system):
    from test_outbox import with_photos

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock)
    asset = with_photos(pipeline, row["job_id"])
    outbox.asset_resolver = lambda _: asset
    clock[0] = target
    await scheduler.step(row)
    assert len(calls) == 2
    revision, config = pipeline.store.load_config()
    config["news_output_locale"] = "ja" if config["news_output_locale"] != "ja" else "en"
    pipeline.store.save_config(config, expected_revision=revision)
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(calls) == 2
    status = scheduler.status()["occurrences"][0]
    assert status["status"] == "partial" and status["reason"] == "edition_changed"
    assert outbox.status(row["job_id"], bot_id="bot1")["targets"]["bot1"]["parts"][0]["message_id"]


async def test_target_edit_before_first_intent_reuses_prepared_content(system):
    pipeline, targets, _, model_calls, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock)
    previous = len(model_calls)
    await targets.set_subscription("sub_world", ["bot2"], pipeline.store.config_revision())
    clock[0] = target
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(calls) == 1 and len(model_calls) == previous
    assert outbox.status(row["job_id"])["targets"]["bot2"]["status"] == "delivered"
    assert scheduler.status()["occurrences"][0]["generation"] == 1


async def test_known_inflight_send_settles_after_cutoff_without_extra_request(system):
    pipeline, targets, _, _, _ = system
    entered, release = asyncio.Event(), asyncio.Event()
    requests = 0

    async def respond(_):
        nonlocal requests
        requests += 1
        if requests == 2:
            entered.set()
        await release.wait()
        return httpx.Response(
            200,
            json={"ok": True, "result": {"message_id": 99, "chat": {"id": 123, "type": "private"}}},
        )

    outbox, calls = sender(pipeline, targets, respond)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW, catchup=1)
    row = await prepare_scheduled(scheduler, clock)
    clock[0] = target
    task = asyncio.create_task(scheduler.step(row))
    try:
        await asyncio.wait_for(entered.wait(), 2)
        clock[0] = target + timedelta(minutes=2)
        assert scheduler.plan(clock[0]) == []
        assert scheduler.status()["occurrences"][0]["status"] == "outcome_unknown"
    finally:
        release.set()
        await task
    assert len(calls) == 2
    assert scheduler.status()["occurrences"][0]["status"] == "delivered"
    assert scheduler.plan(clock[0]) == []


@pytest.mark.parametrize("system", ["adult"], indirect=True)
async def test_adult_opt_out_does_not_pause_authorized_peer(system):
    from test_outbox import with_photos

    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW, subscription="sub_av")
    row = await prepare_scheduled(scheduler, clock)
    asset = with_photos(pipeline, row["job_id"])
    outbox.asset_resolver = lambda _: asset
    clock[0] = target
    await scheduler.step(row)
    assert len(calls) == 2
    await targets.adult_permission("bot1", False, pipeline.store.config_revision())
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(calls) == 3 and "/bot1000:" in calls[-1].url.path
    assert scheduler.status()["occurrences"][0]["status"] != "held"


async def test_changed_source_during_only_fetch_rebuilds_unspent_job(system):
    pipeline, targets, _, model_calls, _ = system
    outbox, sends = sender(pipeline, targets)
    scheduler, clock, _ = scheduled(pipeline, outbox, NOW)
    entered, release = asyncio.Event(), asyncio.Event()

    async def fetch(_):
        entered.set()
        await release.wait()
        return httpx.Response(200, content=FRESH)

    pipeline.feed_factory = lambda evidence: FeedCollector(
        evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(fetch))
    )
    (row,) = scheduler.plan(clock[0])
    before = len(model_calls)
    task = asyncio.create_task(scheduler.step(row))
    try:
        await asyncio.wait_for(entered.wait(), 2)
        revision, config = pipeline.store.load_config()
        config["sources"][0]["url"] = "https://example.com/replacement"
        pipeline.store.save_config(config, expected_revision=revision)
    finally:
        release.set()
        await task
    (old,) = scheduler.plan(clock[0])
    assert pipeline.get(old["job_id"])["stage"] == "stale"
    await scheduler.step(old)
    (rebuilt,) = scheduler.plan(clock[0])
    assert rebuilt["generation"] == 2 and rebuilt["job_id"] is None
    assert not sends and len(model_calls) == before


def test_planned_occurrence_without_worker_is_late_at_target(planner):
    scheduler, _ = planner
    activate(scheduler)
    (original,) = scheduler.plan(moment(23, 50, day=7))
    (due,) = scheduler.plan(moment(0))
    assert due["id"] == original["id"] and due["status"] == "late"
    assert due["reason"] == "preparation_late"


async def test_paused_pipeline_job_is_not_marked_late_before_status_sync(system):
    pipeline, targets, _, _, _ = system
    outbox, calls = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock, steps=1)
    assert row["status"] == "preparing" and row["reason"] is None
    pipeline.pause(row["job_id"])
    clock[0] = target
    (paused,) = scheduler.plan(clock[0])
    assert paused["status"] != "late"
    await scheduler.step(paused)
    occurrence = scheduler.status()["occurrences"][0]
    assert occurrence["reason"] == "job_paused" and occurrence["state"] == "paused"
    assert not calls


async def test_skipping_an_unknown_part_of_a_paused_job_reads_abandoned(system):
    pipeline, targets, _, _, _ = system

    async def respond(request):
        if len(calls) == 1:
            raise httpx.ReadTimeout("fixture response lost")
        return httpx.Response(
            200,
            json={"ok": True, "result": {"message_id": 7, "chat": {"id": 123, "type": "private"}}},
        )

    outbox, calls = sender(pipeline, targets, respond)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    row = await prepare_scheduled(scheduler, clock)
    clock[0] = target
    await scheduler.step(scheduler.plan(clock[0])[0])
    (unknown,) = [
        bot
        for bot, item in outbox.status(row["job_id"])["targets"].items()
        if item["status"] == "outcome_unknown"
    ]
    assert scheduler.status()["occurrences"][0]["reason"] == "delivery_outcome_unknown"

    pipeline.pause(row["job_id"])
    await scheduler.step(scheduler.plan(clock[0])[0])
    occurrence = scheduler.status()["occurrences"][0]
    assert (occurrence["status"], occurrence["reason"]) == ("waiting", "job_paused")
    # Still unknown: never abandoned before the owner chooses.
    assert occurrence["state"] == "paused"

    outbox.resolve(row["job_id"], unknown, 0, "skip", now=clock[0])
    occurrence = scheduler.status()["occurrences"][0]
    assert (occurrence["status"], occurrence["reason"]) == ("waiting", "job_paused")
    assert occurrence["state"] == "abandoned"
    assert len(calls) == 2


def test_default_policy_activates_on_first_plan_not_at_database_creation(planner):
    scheduler, store = planner
    policy = scheduler.policy()
    assert policy["settings"]["enabled"] and policy["activated_at"] is None
    assert policy["settings"]["holds"] == {"normal": 500_000, "adult": 500_000}
    scheduler.plan(moment(4))
    assert scheduler.policy()["activated_at"] == moment(4).isoformat()


def test_send_now_queues_one_extra_edition_per_day_that_survives_retiming(planner):
    from newspaw.scheduler import MANUAL_SLOT

    scheduler, store = planner
    activate(scheduler)
    sub = next(s for s in store.load_config()[1]["subscriptions"] if s["enabled"])
    first = scheduler.send_now(sub["id"], now=moment(4))
    assert first["slot"] == MANUAL_SLOT and first["status"] == "planned"
    assert first["target_at"] == (moment(4) + timedelta(minutes=2)).isoformat()
    assert scheduler.send_now(sub["id"], now=moment(4, 1))["id"] == first["id"]
    ready = scheduler.plan(moment(4, 1))
    assert first["id"] in {row["id"] for row in ready}
    revision, config = store.load_config()
    changed = next(s for s in config["subscriptions"] if s["id"] == sub["id"])
    changed["times"] = ["10:00"]
    store.save_config(config, expected_revision=revision)
    scheduler.plan(moment(4, 2))
    kept = next(r for r in scheduler.status()["occurrences"] if r["id"] == first["id"])
    assert kept["status"] in {"planned", "late"}
    scheduler.plan(moment(11))  # past the six-hour catch-up window
    expired = next(r for r in scheduler.status()["occurrences"] if r["id"] == first["id"])
    assert (expired["status"], expired["reason"]) == ("skipped", "catchup_expired")


def test_send_now_requires_an_enabled_digest_and_active_scheduling(planner):
    scheduler, store = planner
    activate(scheduler)
    disabled = next(s for s in store.load_config()[1]["subscriptions"] if not s["enabled"])
    with pytest.raises(ScheduleError, match="digest_not_enabled"):
        scheduler.send_now(disabled["id"], now=moment(4))
    policy = scheduler.policy()
    scheduler.configure(dict(policy["settings"], enabled=False), policy["revision"], now=moment(4))
    enabled = next(s for s in store.load_config()[1]["subscriptions"] if s["enabled"])
    with pytest.raises(ScheduleError, match="scheduling_paused"):
        scheduler.send_now(enabled["id"], now=moment(4))
