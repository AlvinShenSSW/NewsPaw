from copy import deepcopy

import pytest
from test_routing import account, configured
from test_x_timelines import system as timeline_fixture

from newspaw.app_config import validate_config
from newspaw.routing import resolve_route
from newspaw.telegram.targets import _scopes

timeline_system = timeline_fixture


@pytest.mark.parametrize("partition", ["normal", "adult"])
def test_special_digest_requires_explicit_opt_in_and_preserves_its_own_overrides(partition):
    config, _ = configured(partition)
    category = "x" if partition == "normal" else "x_adult"
    sub = next(row for row in config["subscriptions"] if row["category_id"] == category)
    sub.update(enabled=True, bot_ids=["bot1"], times=["08:00"], style="text")
    ordinary = account(config, sub, priority="normal")
    ordinary["partition"] = partition
    special = dict(
        ordinary,
        id="account2",
        remote_id="101",
        handle="special",
        priority="special",
        times=["07:00"],
        bot_ids=["bot2"],
        style="newspaper",
    )
    config["accounts"].append(special)
    config["bots"].append(dict(config["bots"][0], id="bot2", telegram_id=1000))
    regular = resolve_route(config, 1, sub["id"])
    daily = resolve_route(config, 1, sub["id"], account_id="account2")
    assert not regular.blockers and not daily.blockers
    assert [row["id"] for row in regular.effective["accounts"]] == ["account1"]
    assert daily.effective["times"] == ["07:00"] and daily.effective["style"] == "newspaper"
    assert [row["id"] for row in daily.effective["bots"]] == ["bot2"]
    unchanged = deepcopy(config)
    unchanged["accounts"][-1]["include_in_aggregate"] = False
    assert resolve_route(unchanged, 2, sub["id"]).fingerprint == regular.fingerprint

    special["include_in_aggregate"] = True
    opted_in = resolve_route(config, 2, sub["id"])
    assert [row["id"] for row in opted_in.effective["accounts"]] == ["account1", "account2"]
    assert [row["id"] for row in opted_in.effective["bots"]] == ["bot1"]
    assert opted_in.effective["partition"] == partition
    assert opted_in.effective["style"] == "text" and opted_in.effective["times"] == ["08:00"]
    assert (
        resolve_route(config, 2, sub["id"], account_id="account2").fingerprint == daily.fingerprint
    )
    assert _scopes(config)["subscription", sub["id"]][-1] == ("account1", "account2")
    ordinary["include_in_aggregate"] = True
    with pytest.raises(ValueError, match="aggregate"):
        validate_config(config)


async def test_managed_timeline_uses_one_paid_read_per_page_and_keeps_prior_complete_cursor(
    timeline_system,
):
    from test_x_timelines import page, post, setup

    from newspaw.x.timelines import TimelineError

    reads = []

    async def reply(request, _):
        reads.append(request)
        if len(reads) == 1:
            return page([post(110)])
        if len(reads) == 2:
            return page([post(150)], "continuation1")
        return page([post(135, minutes=2)], "continuation2")

    scans, directory, account, _ = await setup(timeline_system, reply)
    revision = directory.store.config_revision()
    scans.begin("scan.previous", "account", account, revision)
    assert (await scans.advance("scan.previous", "step.previous"))["complete_cursor"] == "110"
    scans.begin("scan.managed", "account", account, revision, max_pages=2)
    with pytest.raises(TimelineError, match="digest_scope_required"):
        await scans.advance("scan.managed", "manual.unscoped")

    async def advance(step):
        return await scans.advance("scan.managed", step, before_intent=lambda: True)

    denied = await scans.advance("scan.managed", "step.managed1", before_intent=lambda: False)
    assert denied["state"] == "pending" and len(reads) == 1
    first = await advance("step.managed1")
    assert first["completed_pages"] == 1
    assert (await advance("step.managed1")) == first
    second = await advance("step.managed2")
    assert second["state"] == "incomplete" and second["reason"] == "page_limit"
    assert second["complete_cursor"] == "110" and second["completed_pages"] == 2
    assert await advance("step.managed3") == second
    assert len(reads) == 3
    assert reads[1].url.params["since_id"] == "110"
    assert {row["observed_at"] for row in scans.posts("account", account)} == {
        scans.clock().isoformat(timespec="microseconds")
    }


async def _digest_fixture(system, reply, partition="normal"):
    from test_editorial import service
    from test_x_timelines import setup

    from newspaw.pipeline import Pipeline
    from newspaw.providers import ProfileRegistry
    from newspaw.x.digests import XDigests

    scans, directory, account_id, _ = await setup(system, reply)
    store = directory.store
    revision, config = store.load_config()
    category = "x" if partition == "normal" else "x_adult"
    existing = configured(partition)[0]
    config.update(
        owner_id=existing["owner_id"],
        bots=existing["bots"],
        model_profiles=existing["model_profiles"],
        news_output_locale="en",
    )
    config["bots"].append(dict(config["bots"][0], id="bot2", telegram_id=1000))
    sub = next(row for row in config["subscriptions"] if row["category_id"] == category)
    sub.update(enabled=True, bot_ids=["bot1"])
    store.save_config(config, expected_revision=revision)
    if partition == "adult":
        await directory.classify(account_id, "adult", store.config_revision())
    await directory.set_route(
        account_id, sub["id"], "special", store.config_revision(), include_in_aggregate=True
    )
    revision, config = store.load_config()
    config["accounts"][0].update(bot_ids=["bot2"], times=["07:00"])
    store.save_config(config, expected_revision=revision)
    registry = ProfileRegistry(store)
    holds = {f"{partition}_{role}": 100 for role in ("primary", "backup")}
    for profile in holds:
        registry.begin("verify." + profile, profile, "text", 100)
        registry.finish("verify." + profile, {"status": "verified"})
    editor, model_calls = service(store)

    def build():
        return Pipeline(
            store, editor.runner.backend, runner=editor.runner, x_digests=XDigests(scans)
        )

    return build, scans, sub["id"], account_id, holds, model_calls


async def test_special_and_aggregate_share_paginated_scan_after_lost_ack(timeline_system):
    from datetime import timedelta

    from test_x_timelines import NOW, page, post

    from newspaw.evidence import EvidenceError, EvidenceStore
    from newspaw.pipeline import PipelineError

    paid = []

    async def reply(request, _):
        paid.append(request)
        if len(paid) == 1:
            return page([dict(post(190), text="OpenAI released GPT-6.")], "continuation")
        return page([dict(post(189, minutes=3), text="OpenAI released GPT-6.")])

    build, scans, sub, account_id, holds, model_calls = await _digest_fixture(
        timeline_system, reply
    )
    pipeline = build()
    aggregate = pipeline.create(sub, "aggregate", holds=holds, now=NOW)["job_id"]
    special = pipeline.create(sub, "special", account_id=account_id, holds=holds, now=NOW)["job_id"]
    first = await pipeline.advance(aggregate, now=NOW)
    assert first["stage"] == "collecting" and len(paid) == 1
    assert not first["attempt_ids"]
    assert scans.db.execute("SELECT count(*) FROM x_digest_links").fetchone() == (1,)

    # Fresh workers recover the paid page without a persisted pipeline attempt acknowledgement.
    pipeline = build()
    pipeline.recover_interrupted()
    assert (await pipeline.advance(special, now=NOW))["stage"] == "editing"
    assert (await pipeline.advance(aggregate, now=NOW))["stage"] == "editing"
    assert len(paid) == 2 and paid[1].url.params["pagination_token"] == "continuation"
    assert scans.db.execute("SELECT count(DISTINCT scan_id) FROM x_digest_links").fetchone() == (1,)
    evidence = EvidenceStore(scans.store)
    aggregate_attempt = pipeline.get(aggregate)["attempt_ids"][0]
    special_attempt = pipeline.get(special)["attempt_ids"][0]
    assert aggregate_attempt != special_attempt
    with pytest.raises(EvidenceError, match="evidence_scope_changed"):
        evidence.articles(special_attempt, partition="normal", subscription_id=sub, now=NOW)
    for job, account_key in [(aggregate, None), (special, account_id)]:
        assert (await pipeline.advance(job, now=NOW))["stage"] == "preparing_media"
        assert (await pipeline.advance(job, now=NOW))["stage"] == "awaiting_delivery"
        route, text, _ = pipeline.delivery_input(job)
        assert route.account_id == account_key
        assert "Posted on X by @fixture" in text
        assert "https://x.com/i/web/status/190" in text
        assert "Repository release" not in text
    assert len(model_calls) == 2

    # Another eligible edition can reuse the same scan, but coverage keeps its actual end.
    later = NOW + timedelta(minutes=30)
    scans.clock = lambda: later
    next_job = pipeline.create(sub, "next", holds=holds, now=later)["job_id"]
    assert (await pipeline.advance(next_job, now=later))["stage"] == "editing"
    recorded = evidence.attempt(pipeline.get(next_job)["attempt_ids"][0], partition="normal")
    assert recorded["x_coverage"]["through_time"] == NOW.isoformat()
    assert "reused_through_prior_time" in recorded["coverage_gaps"] and len(paid) == 2

    with scans.store._write():
        scans.db.execute("UPDATE x_posts SET tombstone=1,body=NULL WHERE id='190'")
    with pytest.raises(PipelineError, match="edition_changed"):
        pipeline.delivery_scope(aggregate)


@pytest.mark.parametrize(
    ("mode", "expected"),
    [("empty", "no_news"), ("unavailable", "collection_failed"), ("partial", "collection_failed")],
)
async def test_x_no_new_posts_is_distinct_from_failure_and_partial_coverage(
    timeline_system, mode, expected
):
    import httpx
    from test_x_timelines import NOW, page

    async def reply(request, _):
        if mode == "unavailable":
            return httpx.Response(403, json={"title": "Unavailable"})
        return page([], "continuation" if mode == "partial" else None)

    build, scans, sub, account_id, holds, model_calls = await _digest_fixture(
        timeline_system, reply
    )
    pipeline = build()
    identity = pipeline.create(sub, mode, account_id=account_id, holds=holds, now=NOW)["job_id"]
    for _ in range(4):
        result = await pipeline.advance(identity, now=NOW)
        if result["stage"] in {"no_news", "collection_failed"}:
            break
    assert result["stage"] == expected and not model_calls
    from newspaw.evidence import EvidenceStore

    evidence = EvidenceStore(scans.store).attempt(result["attempt_ids"][0], partition="normal")
    assert evidence["coverage_complete"] is (mode == "empty")
    assert evidence["status"] == ("empty" if mode == "empty" else "failed")
    assert evidence["x_coverage"]["author"] == "@fixture"


async def test_digest_reclassification_rejects_old_job_and_uses_adult_partition(timeline_system):
    import json

    from test_x_timelines import NOW, page, post

    from newspaw.providers import ProfileRegistry

    adult_mode = False

    async def reply(request, _):
        marker = "private adult clue" if adult_mode else "ordinary-only clue"
        return page(
            [
                dict(
                    post(190, sensitive=adult_mode),
                    text=f"OpenAI released GPT-6. {marker}",
                )
            ]
        )

    build, scans, normal, account_id, holds, model_calls = await _digest_fixture(
        timeline_system, reply
    )
    pipeline = build()
    old = pipeline.create(normal, "ordinary", holds=holds, now=NOW)["job_id"]
    assert (await pipeline.advance(old, now=NOW))["stage"] == "editing"

    adult_mode = True
    store, directory = scans.store, scans.directory
    await directory.classify(account_id, "adult", store.config_revision())
    revision, config = store.load_config()
    assert "include_in_aggregate" not in config["accounts"][0]
    adult = next(row for row in config["subscriptions"] if row["category_id"] == "x_adult")
    for bot in config["bots"]:
        bot["adult_allowed"] = True
    adult.update(enabled=True, bot_ids=["bot2"])
    store.save_config(config, expected_revision=revision)
    await directory.set_route(account_id, adult["id"], "special", store.config_revision())
    revision, config = store.load_config()
    config["accounts"][0]["bot_ids"] = ["bot2"]
    store.save_config(config, expected_revision=revision)
    registry = ProfileRegistry(store)
    adult_holds = {"adult_primary": 100, "adult_backup": 100}
    for profile in adult_holds:
        registry.begin("verify." + profile, profile, "text", 100)
        registry.finish("verify." + profile, {"status": "verified"})

    assert (await pipeline.advance(old, now=NOW))["stage"] == "stale" and not model_calls
    new = pipeline.create(adult["id"], "adult", account_id=account_id, holds=adult_holds, now=NOW)[
        "job_id"
    ]
    assert (await pipeline.advance(new, now=NOW))["stage"] == "editing"
    assert (await pipeline.advance(new, now=NOW))["stage"] == "preparing_media"
    assert len(model_calls) == 1 and model_calls[0].url.host == "api.deepseek.com"
    payload = json.loads(model_calls[0].content)["input"]
    assert "private adult clue" in str(payload) and "ordinary-only clue" not in str(payload)


async def test_parallel_digest_jobs_hold_one_paid_x_intent(timeline_system):
    import asyncio

    from test_x_timelines import NOW, page, post

    entered, release = asyncio.Event(), asyncio.Event()
    requests = []

    async def reply(request, _):
        requests.append(request)
        entered.set()
        await release.wait()
        return page([post(190)])

    build, scans, sub, account_id, holds, _ = await _digest_fixture(timeline_system, reply)
    pipeline = build()
    aggregate = pipeline.create(sub, "aggregate", holds=holds, now=NOW)["job_id"]
    special = pipeline.create(sub, "special", account_id=account_id, holds=holds, now=NOW)["job_id"]
    first = asyncio.create_task(pipeline.advance(aggregate, now=NOW))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        assert (await pipeline.advance(special, now=NOW))["stage"] == "collecting"
        assert len(requests) == 1
        assert scans.db.execute(
            "SELECT count(*) FROM x_timeline_steps WHERE state='inflight'"
        ).fetchone() == (1,)
    finally:
        release.set()
        await first
    assert (await pipeline.advance(special, now=NOW))["stage"] == "editing"
    assert len(requests) == 1


async def test_aggregate_revocation_during_keychain_wait_creates_no_paid_x_intent(
    timeline_system, monkeypatch
):
    import asyncio
    import threading

    from test_x_timelines import NOW, page

    entered, release = threading.Event(), threading.Event()
    requests = []

    async def reply(request, _):
        requests.append(request)
        return page([])

    build, scans, sub, account_id, holds, _ = await _digest_fixture(timeline_system, reply)
    store = scans.store
    pipeline = build()
    aggregate = pipeline.create(sub, "aggregate", holds=holds, now=NOW)["job_id"]
    backend = scans.directory.credentials.backend
    actual_read = backend.read

    def delayed(ref):
        entered.set()
        assert release.wait(3)
        return actual_read(ref)

    monkeypatch.setattr(backend, "read", delayed)
    worker = asyncio.create_task(pipeline.advance(aggregate, now=NOW))
    try:
        assert await asyncio.to_thread(entered.wait, 2)
        await scans.directory.set_route(
            account_id, sub, "special", store.config_revision(), include_in_aggregate=False
        )
    finally:
        release.set()
        await worker
    assert not requests
    assert scans.db.execute("SELECT count(*) FROM x_timeline_steps").fetchone() == (0,)
    assert pipeline.get(aggregate)["stage"] == "stale"


async def test_post_type_policy_invalidates_old_edition_and_reopens_bounded_history(
    timeline_system,
):
    from test_x_timelines import NOW, page, post

    from newspaw.pipeline import PipelineError

    reads = []

    async def reply(request, _):
        reads.append(dict(request.url.params))
        return page(
            [
                dict(post(190), text="OpenAI released GPT-6."),
                post(189, minutes=2, references=[{"id": "188", "type": "replied_to"}]),
            ]
        )

    build, scans, sub, identity, holds, _ = await _digest_fixture(timeline_system, reply)
    pipeline = build()
    prior = pipeline.create(sub, "prior-types", holds=holds, now=NOW)["job_id"]
    for _ in range(3):
        await pipeline.advance(prior, now=NOW)
    assert pipeline.delivery_scope(prior).effective["accounts"][0].get("post_types") is None
    current = scans.coverage("account", identity)
    assert current["state"] == "complete"
    assert current["last_complete"]["through_time"] == NOW.isoformat()
    before = scans.store.config_revision()
    with pytest.raises(ValueError, match="post types"):
        revision, config = scans.store.load_config()
        config["accounts"][0]["post_types"] = ["quoted", "quoted"]
        scans.store.save_config(config, expected_revision=revision)

    await scans.directory.set_route(
        identity, sub, "special", before, post_types=["replied_to", "original", "quoted"]
    )
    with pytest.raises(PipelineError, match="edition_changed"):
        pipeline.delivery_scope(prior)
    stale = scans.coverage("account", identity)
    assert stale["reason"] == "coverage_scope_changed" and stale["latest"]["historical"]
    assert stale["last_complete"] is None and len(reads) == 1

    next_job = pipeline.create(sub, "new-types", holds=holds, now=NOW)["job_id"]
    assert (await pipeline.advance(next_job, now=NOW))["stage"] == "editing"
    assert "since_id" not in reads[-1] and len(reads) == 2
    current = scans.coverage("account", identity)
    assert current["last_complete"]["history_gap"] == "fresh_window"
    assert current["last_complete"]["post_types"] == ["original", "quoted", "replied_to"]
    assert {item["id"] for item in scans.posts("account", identity)} == {"189", "190"}

    impact = scans.directory.partition_impact(identity)
    assert impact["cached_posts"] == impact["pending_jobs"] == 2
    assert impact["aggregate_bot_ids"] == ["bot1"] and impact["special_bot_ids"] == ["bot2"]
    assert impact["clears_post_types"]
    await scans.directory.classify(identity, "adult", impact["revision"])
    assert "post_types" not in scans.directory.account_status(identity)
    assert scans.directory.partition_impact(identity)["cached_posts"] == 0
    assert scans.coverage("account", identity)["latest"]["historical"]
    assert scans.db.execute("SELECT DISTINCT partition FROM x_posts").fetchall() == [("normal",)]
