import asyncio
import sqlite3
import threading
from contextlib import closing, contextmanager
from datetime import timedelta

import httpx
import pytest
from test_editorial import service
from test_model_runner import NOW
from test_routing import configured

from newspaw.budget import BudgetLedger
from newspaw.credentials import CredentialError
from newspaw.evidence import FeedCollector
from newspaw.pipeline import Pipeline, PipelineError
from newspaw.providers import ProfileRegistry
from newspaw.store import Store

FRESH = b"""<rss version="2.0"><channel><title>Example</title><item>
<title>OpenAI releases GPT-6</title><link>https://example.com/a</link>
<pubDate>Sat, 07 Nov 2026 02:00:00 +0000</pubDate>
<description>OpenAI released GPT-6.</description>
</item></channel></rss>"""
EMPTY = b'<rss version="2.0"><channel><title>Example</title></channel></rss>'
HOLDS = {"normal_primary": 100, "normal_backup": 100}


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "state.db"
    store = Store(path)
    config, sub = configured()
    store.save_config(config, expected_revision=1)
    registry = ProfileRegistry(store)
    for profile in HOLDS:
        registry.begin("verify." + profile, profile, "text", 1)
        registry.finish("verify." + profile, {"status": "verified"})
    yield store, sub["id"], path
    store.close()


def prepare(store, *, feed=None, model=None):
    editor, calls = service(store, handler=model)
    reads = []

    def factory(evidence):
        async def fetch(request):
            reads.append(str(request.url))
            return await feed(request) if feed else httpx.Response(200, content=FRESH)

        return FeedCollector(
            evidence, client=httpx.AsyncClient(transport=httpx.MockTransport(fetch))
        )

    return (
        Pipeline(store, editor.runner.backend, runner=editor.runner, feed_factory=factory),
        reads,
        calls,
    )


def create(pipeline, sub, key="daily", *, style=None):
    return pipeline.create(sub, key, holds=HOLDS, task_limit=500, style=style, now=NOW)["job_id"]


async def run_to_terminal(pipeline, job):
    for _ in range(6):
        result = await pipeline.advance(job, now=NOW)
        if result["stage"] in {"awaiting_delivery", "no_news", "collection_failed"}:
            return result
    pytest.fail(f"job did not finish: {result['stage']}")


async def test_edition_pipeline_durable_handoff_and_idempotence(database):
    store, sub, path = database
    pipeline, reads, calls = prepare(store)
    job = create(pipeline, sub, style="newspaper")
    assert create(pipeline, sub, style="newspaper") == job
    with pytest.raises(PipelineError, match="job_key_conflict"):
        create(pipeline, sub, style="text")
    assert not reads and not calls
    result = await run_to_terminal(pipeline, job)
    assert len(reads) == len(calls) == 1
    assert result["media"]["style"] == "text"
    assert result["media"]["fallback_reason"]
    assert result["model"]["state"] == "completed"
    assert len(result["attempt_ids"]) == 1
    with closing(Store(path)) as reopened:
        restarted, extra_reads, extra_calls = prepare(reopened)
        assert create(restarted, sub, style="newspaper") == job
        assert (await restarted.advance(job, now=NOW))["stage"] == "awaiting_delivery"
        assert not extra_reads and not extra_calls
        events = restarted.audit(job)
        assert {event["stage"] for event in events} >= {
            "collecting",
            "editing",
            "preparing_media",
            "awaiting_delivery",
        }


@pytest.mark.parametrize("http_status,stage", [(200, "no_news"), (503, "collection_failed")])
async def test_empty_distinct_from_failed_collection(database, http_status, stage):
    store, sub, _ = database

    async def feed(request):
        return httpx.Response(http_status, content=EMPTY)

    pipeline, reads, calls = prepare(store, feed=feed)
    job = create(pipeline, sub)
    result = await run_to_terminal(pipeline, job)
    assert result["stage"] == stage
    assert len(reads) == 1 and not calls
    assert result["media"] is None


async def test_finished_feed_is_reused_if_job_ack_is_lost(database):
    store, sub, path = database
    pipeline, reads, calls = prepare(store)
    job = create(pipeline, sub)
    # Deny the stage event after EvidenceStore has committed its attempt.
    store._db.set_authorizer(
        lambda action, table, *args: (
            sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_INSERT and table == "pipeline_events"
            else sqlite3.SQLITE_OK
        )
    )
    try:
        with pytest.raises(PipelineError, match="storage_failed"):
            await pipeline.advance(job, now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert len(reads) == 1 and not calls
    with closing(Store(path)) as reopened:
        restarted, repeated, model_calls = prepare(reopened)
        restarted.recover_interrupted()
        assert (await run_to_terminal(restarted, job))["stage"] == "awaiting_delivery"
        assert not repeated and len(model_calls) == 1


async def test_unknown_attempt_keeps_hold_when_job_ack_is_lost(database):
    store, sub, path = database

    def lost_response(request):
        raise httpx.ReadTimeout("synthetic lost paid response")

    pipeline, reads, calls = prepare(store, model=lost_response)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    result = await pipeline.advance(job, now=NOW)
    assert result["status"] == "outcome_unknown"
    attempt = result["model"]["attempts"][0]
    assert BudgetLedger(store).get(attempt["budget_id"])["state"] == "outcome_unknown"
    with closing(Store(path)) as reopened:
        restarted, repeated, extra_calls = prepare(reopened)
        restarted.recover_interrupted()
        assert (await restarted.advance(job, now=NOW))["status"] == "outcome_unknown"
        assert not repeated and not extra_calls
        with pytest.raises(ValueError, match="duplicate_charge_ack_required"):
            restarted.resume(job)
    assert len(reads) == len(calls) == 1


async def test_database_lease_blocks_second_collector_and_fences_old_cache(database):
    store, sub, path = database
    started, release = asyncio.Event(), asyncio.Event()

    async def slow(request):
        started.set()
        await release.wait()
        return httpx.Response(200, content=FRESH, headers={"ETag": "old"})

    pipeline, reads, _ = prepare(store, feed=slow)
    job = create(pipeline, sub)
    pending = asyncio.create_task(pipeline.advance(job, now=NOW))
    await asyncio.wait_for(started.wait(), 2)
    with closing(Store(path)) as reopened:
        next_worker, takeover_reads, _ = prepare(reopened)
        await next_worker.advance(job, now=NOW)
        assert not takeover_reads
        await next_worker.advance(job, now=NOW + timedelta(hours=1))
        assert len(takeover_reads) == 1
        release.set()
        await pending
        snapshot = next_worker.get(job)
        assert snapshot["stage"] == "editing"
        assert len(snapshot["attempt_ids"]) == 1
        cache = reopened._db.execute("SELECT etag FROM feed_cache").fetchone()
        assert cache == (None,)
    assert len(reads) == 1


class WaitingKey:
    def __init__(self, error=None):
        self.error = error
        self.started = asyncio.Event()
        self.release = threading.Event()
        self.loop = asyncio.get_running_loop()

    def read(self, ref):
        self.loop.call_soon_threadsafe(self.started.set)
        assert self.release.wait(5), "fixture credential read timed out"
        if self.error:
            raise self.error
        return "synthetic"


@pytest.mark.parametrize("old_key_error", [None, CredentialError("key_unavailable")])
async def test_expired_model_lease_fences_dispatch_after_key_read(database, old_key_error):
    store, sub, path = database
    first, _, first_calls = prepare(store)
    first_key = first.runner.backend = WaitingKey(old_key_error)
    job = create(first, sub)
    await first.advance(job, now=NOW)
    old = asyncio.create_task(first.advance(job, now=NOW))
    await asyncio.wait_for(first_key.started.wait(), 2)
    with closing(Store(path)) as reopened:
        second, _, second_calls = prepare(reopened)
        second_key = second.runner.backend = WaitingKey()
        fresh = asyncio.create_task(second.advance(job, now=NOW + timedelta(minutes=3)))
        try:
            await asyncio.wait_for(second_key.started.wait(), 2)
            first_key.release.set()
            await old
            assert not first_calls and not second_calls
            assert second.get(job)["model"]["attempts"] == []
        finally:
            first_key.release.set()
            second_key.release.set()
        result = await fresh
        assert result["stage"] == "preparing_media", (result["model"], len(second_calls))
        assert len(second_calls) == 1


async def test_pause_while_waiting_for_key_releases_other_subscription(database):
    store, sub, _ = database
    revision, config = store.load_config()
    world = next(item for item in config["subscriptions"] if item["id"] == sub)
    config["subscriptions"].append(dict(world, id="sub_second"))
    store.save_config(config, expected_revision=revision)
    pipeline, _, calls = prepare(store)
    paused = create(pipeline, sub)
    other = create(pipeline, "sub_second")
    await pipeline.advance(paused, now=NOW)
    await pipeline.advance(other, now=NOW)
    original = pipeline.runner.backend
    waiting_key = pipeline.runner.backend = WaitingKey()
    old = asyncio.create_task(pipeline.advance(paused, now=NOW))
    try:
        await asyncio.wait_for(waiting_key.started.wait(), 2)
        assert pipeline.pause(paused)["status"] == "paused"
        assert (await asyncio.wait_for(old, 2))["model"]["state"] == "pending"
        pipeline.runner.backend = original
        assert (await run_to_terminal(pipeline, other))["stage"] == "awaiting_delivery"
        assert len(calls) == 1
        pipeline.resume(paused)
        assert (await run_to_terminal(pipeline, paused))["stage"] == "awaiting_delivery"
        assert len(calls) == 2
    finally:
        waiting_key.release.set()


async def test_shutdown_before_dispatch_preserves_pending_job(database):
    store, sub, path = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    key = pipeline.runner.backend = WaitingKey()
    running = asyncio.create_task(pipeline.advance(job, now=NOW))
    try:
        await asyncio.wait_for(key.started.wait(), 2)
        await pipeline.close()
        with pytest.raises(asyncio.CancelledError):
            await running
        assert not calls and pipeline.get(job)["model"]["state"] == "pending"
    finally:
        key.release.set()
    with closing(Store(path)) as reopened:
        restarted, reads, new_calls = prepare(reopened)
        restarted.recover_interrupted()
        assert (await run_to_terminal(restarted, job))["stage"] == "awaiting_delivery"
        assert not reads and len(new_calls) == 1


@pytest.mark.parametrize(
    "action,table,calls_expected,expected_before_recovery,after",
    [
        (sqlite3.SQLITE_INSERT, "model_attempts", 0, "pending", "pending"),
        (sqlite3.SQLITE_UPDATE, "model_attempts", 1, "inflight", "outcome_unknown"),
        (sqlite3.SQLITE_UPDATE, "editorial_editions", 1, "completed", "completed"),
    ],
)
async def test_model_sql_fault_boundaries(
    database, action, table, calls_expected, expected_before_recovery, after
):
    store, sub, path = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    store._db.set_authorizer(
        lambda op, name, *args: (
            sqlite3.SQLITE_DENY if (op, name) == (action, table) else sqlite3.SQLITE_OK
        )
    )
    try:
        with pytest.raises(PipelineError, match="storage_failed"):
            await pipeline.advance(job, now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert len(calls) == calls_expected
    assert pipeline.get(job)["model"]["state"] == expected_before_recovery
    with closing(Store(path)) as reopened:
        restarted, reads, extra_calls = prepare(reopened)
        restarted.recover_interrupted()
        model = restarted.get(job)["model"]
        assert model["state"] == after
        if after == "outcome_unknown":
            attempt = model["attempts"][0]
            hold = BudgetLedger(reopened).get(attempt["budget_id"])
            assert hold["state"] == "outcome_unknown" and hold["reserved_units"] == 100
            for _ in range(2):
                assert (await restarted.advance(job, now=NOW))["status"] == after
            assert not extra_calls
        else:
            if after == "pending":
                assert not model["attempts"]
                assert reopened._db.execute("SELECT COUNT(*) FROM budget_attempts").fetchone() == (
                    0,
                )
            assert (await run_to_terminal(restarted, job))["stage"] == "awaiting_delivery"
            assert len(extra_calls) == 1 - calls_expected
        assert not reads


async def test_cancel_after_paid_dispatch_retains_unknown_and_never_handoffs(database):
    store, sub, _ = database
    from newspaw.providers import ProviderAdapter

    pipeline, _, _ = prepare(store)
    dispatched = asyncio.Event()

    async def model(request):
        dispatched.set()
        await asyncio.Future()

    pipeline.runner.adapter_factory = lambda profile, key: ProviderAdapter(
        profile, key, client=httpx.AsyncClient(transport=httpx.MockTransport(model))
    )
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    pending = asyncio.create_task(pipeline.advance(job, now=NOW))
    await asyncio.wait_for(dispatched.wait(), 2)
    assert pipeline.cancel(job)["cancelled"]
    result = await pending
    assert result["stage"] == "cancelled" and result["status"] == "outcome_unknown"
    assert (await pipeline.advance(job, now=NOW))["media"] is None
    with pytest.raises(PipelineError, match="job_not_resumable"):
        pipeline.resume(job, acknowledge_duplicate_charge=True)


async def test_busy_database_prevents_even_collection_dispatch(database):
    store, sub, path = database
    pipeline, reads, calls = prepare(store)
    job = create(pipeline, sub)
    store._db.execute("PRAGMA busy_timeout=0")
    with closing(sqlite3.connect(path)) as writer:
        writer.execute("BEGIN IMMEDIATE")
        with pytest.raises(PipelineError, match="storage_failed"):
            await pipeline.advance(job, now=NOW)
        writer.rollback()
    assert not reads and not calls
    assert (await pipeline.advance(job, now=NOW))["stage"] == "editing"


async def test_output_locale_change_invalidates_frozen_unsent_job(database):
    store, sub, _ = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    revision, config = store.load_config()
    config["news_output_locale"] = "ja"
    store.save_config(config, expected_revision=revision)
    assert (await pipeline.advance(job, now=NOW))["stage"] == "stale"
    assert not calls and pipeline.get(job)["locale"] != "ja"
    rebuilt = create(pipeline, sub, key="daily.rebuilt")
    assert pipeline.get(rebuilt)["locale"] == "ja"


async def test_crash_after_intent_commit_before_dispatch_is_conservatively_unknown(
    database, monkeypatch
):
    store, sub, path = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    original = store._write
    armed = True

    @contextmanager
    def crash_after_commit():
        nonlocal armed
        with original():
            yield
        if (
            armed
            and store._db.execute("SELECT 1 FROM model_attempts WHERE state='inflight'").fetchone()
        ):
            armed = False
            raise OSError("synthetic process exit immediately after intent commit")

    monkeypatch.setattr(store, "_write", crash_after_commit)
    with pytest.raises(PipelineError, match="storage_failed"):
        await pipeline.advance(job, now=NOW)
    assert not calls
    assert pipeline.get(job)["model"]["state"] == "inflight"
    with closing(Store(path)) as reopened:
        restarted, _, restarted_calls = prepare(reopened)
        restarted.recover_interrupted()
        result = await restarted.advance(job, now=NOW)
        assert result["status"] == "outcome_unknown"
        budget = result["model"]["attempts"][0]["budget_id"]
        assert BudgetLedger(reopened).get(budget)["reserved_units"] == 100
        assert not restarted_calls


async def test_lost_handoff_write_does_not_replay_completed_edition(database):
    store, sub, path = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    assert (await pipeline.advance(job, now=NOW))["stage"] == "preparing_media"
    store._db.execute(
        """CREATE TRIGGER blocked_handoff BEFORE UPDATE OF stage ON pipeline_jobs
           WHEN NEW.stage='awaiting_delivery' BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END"""
    )
    try:
        with pytest.raises(PipelineError, match="storage_failed"):
            await pipeline.advance(job, now=NOW)
    finally:
        store._db.execute("DROP TRIGGER blocked_handoff")
    assert pipeline.get(job)["stage"] == "preparing_media"
    assert pipeline.get(job)["media"] is None
    assert len(calls) == 1
    with closing(Store(path)) as reopened:
        restarted, reads, repeated = prepare(reopened)
        result = await restarted.advance(job, now=NOW)
        assert result["stage"] == "awaiting_delivery"
        assert not reads and not repeated


async def test_profile_epoch_aba_invalidates_job_before_paid_dispatch(database):
    store, sub, _ = database
    pipeline, _, calls = prepare(store)
    job = create(pipeline, sub)
    await pipeline.advance(job, now=NOW)
    revision, config = store.load_config()
    profile = next(item for item in config["model_profiles"] if item["id"] == "normal_primary")
    original = profile["model"]
    fingerprint = store.preview_route(sub).fingerprint
    profile["model"] = "other-model"
    revision = store.save_config(config, expected_revision=revision)
    profile["model"] = original
    store.save_config(config, expected_revision=revision)
    registry = ProfileRegistry(store)
    registry.begin("verify.restored", "normal_primary", "text", 1)
    registry.finish("verify.restored", {"status": "verified"})
    assert store.preview_route(sub).fingerprint == fingerprint
    assert (await pipeline.advance(job, now=NOW))["stage"] == "stale"
    assert not calls


async def test_api_collection_is_correlated_with_partial_rss_failure(database):
    from test_ai_sources import NOW as API_TIME
    from test_ai_sources import gh

    from newspaw.connectors import AICollector
    from newspaw.evidence import EvidenceStore

    store, sub, _ = database
    revision, config = store.load_config()
    config["sources"].append(
        dict(
            config["sources"][0], id="ai_repo", kind="github", url="https://github.com/acme/skills"
        )
    )
    store.save_config(config, expected_revision=revision)

    async def feed(request):
        return httpx.Response(503)

    pipeline, reads, calls = prepare(store, feed=feed)
    pipeline.ai_factory = lambda evidence: AICollector(
        evidence,
        client=httpx.AsyncClient(transport=httpx.MockTransport(gh)),
    )
    job = create(pipeline, sub)
    assert (await pipeline.advance(job, now=API_TIME))["stage"] == "collecting"
    result = await pipeline.advance(job, now=API_TIME)
    assert result["stage"] == "editing"
    attempts = [
        EvidenceStore(store).attempt(identity, partition="normal")
        for identity in result["attempt_ids"]
    ]
    assert [attempt["status"] for attempt in attempts] == ["failed", "fresh"]
    assert attempts[1]["evidence_scope"] == "api_metadata_excerpt"
    assert len(reads) == 1 and not calls


def test_schema_upgrade_keeps_legacy_receipts_without_enqueuing(tmp_path):
    path = tmp_path / "state.db"
    with closing(Store(path)) as original:
        original.set("last_slot", "legacy-daily")
        original._db.execute(
            "INSERT INTO deliveries_v2(chat_id,scope,article_key) VALUES (123,'news','article')"
        )
        original._db.executescript(
            """DROP TABLE pipeline_events; DROP TABLE pipeline_jobs;
               DROP INDEX feed_attempts_collection; PRAGMA user_version=11;"""
        )
    with closing(Store(path)) as upgraded:
        assert upgraded.get("last_slot") == "legacy-daily"
        assert upgraded._db.execute(
            "SELECT chat_id,scope,article_key FROM deliveries_v2"
        ).fetchall() == [(123, "news", "article")]
        assert upgraded._db.execute("SELECT COUNT(*) FROM pipeline_jobs").fetchone() == (0,)
    assert len(list(tmp_path.glob("state.db.backup-*"))) == 1


@pytest.mark.parametrize(
    ("message", "expected"),
    [("model_refused", "model_refused"), ("Editor said: no!", "preparation_failed")],
)
async def test_blocked_preparation_keeps_a_stable_reason_code(
    database, monkeypatch, message, expected
):
    from newspaw.editorial import EditorialError

    store, sub, _ = database
    pipeline, _, _ = prepare(store)
    job = create(pipeline, sub)
    assert (await pipeline.advance(job, now=NOW))["stage"] == "editing"

    async def refuse(*args, **kwargs):
        raise EditorialError(message)

    monkeypatch.setattr(pipeline, "_edit", refuse)
    result = await pipeline.advance(job, now=NOW)
    assert result["stage"] == "blocked"
    assert result["error_kind"] == expected
