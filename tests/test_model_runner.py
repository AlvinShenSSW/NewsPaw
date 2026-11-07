import asyncio
import json
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
from test_routing import REF, configured

from newspaw.budget import BudgetLedger
from newspaw.model_runner import ModelRunner, RunnerError
from newspaw.providers import ModelRequest, ProfileRegistry, ProviderAdapter
from newspaw.store import Store

NOW = datetime(2026, 11, 7, 3, tzinfo=UTC)


class Keys:
    def read(self, ref):
        assert ref == REF
        return "synthetic"


def response(text="valid"):
    return dict(
        status="completed",
        id="response",
        model="reported",
        output=[dict(type="message", content=[dict(type="output_text", text=text)])],
        usage={"input_tokens": 20, "output_tokens": 10},
    )


@pytest.fixture
def setup(tmp_path, monkeypatch):
    monkeypatch.setattr("newspaw.providers._now", lambda: (NOW - timedelta(hours=1)).isoformat())
    store = Store(tmp_path / "state.db")
    config, sub = configured()
    store.save_config(config, expected_revision=1)
    records = ProfileRegistry(store)
    for key in ("normal_primary", "normal_backup"):
        records.begin("verify." + key, key, "text", 1)
        records.finish("verify." + key, {"status": "verified"})
    yield store, sub["id"]
    store.close()


def runner(store, handler, *, backend=None):
    def factory(profile, key):
        return ProviderAdapter(
            profile, key, client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        )

    return ModelRunner(store, backend or Keys(), adapter_factory=factory)


def submit(executor, sub, task="task", **kwargs):
    request = ModelRequest(
        "normal", "Trusted instruction", "Frozen evidence", validator=lambda text: text == "valid"
    )
    executor.submit(
        task,
        executor.store.preview_route(sub),
        request,
        operation="brief",
        version="1",
        evidence_hash="a" * 64,
        evidence_count=1,
        holds={"normal_primary": 100, "normal_backup": 100},
        task_limit=500,
        **kwargs,
    )
    return request


async def test_success_is_reused_across_fanout_and_restart(setup):
    store, sub = setup
    calls = []

    def handler(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "completed" and len(calls) == 1
    assert result["result"]["text"] == "valid"
    other = runner(store, handler)
    assert (await other.advance("task", spec.validator, now=NOW))["result"] == result["result"]
    assert len(calls) == 1
    attempt = result["attempts"][0]
    assert BudgetLedger(store).get(attempt["budget_id"])["state"] == "settled"
    assert "Frozen evidence" not in json.dumps(result)


@pytest.mark.parametrize(
    "status,expected",
    [
        (401, "authentication_failed"),
        (403, "permission_denied"),
        (404, "model_unavailable"),
        (400, "protocol_error"),
    ],
)
async def test_configuration_failure_uses_only_same_partition_backup(setup, status, expected):
    store, sub = setup
    calls = []

    def handler(request):
        body = json.loads(request.content)
        calls.append(body["model"])
        return httpx.Response(status) if len(calls) == 1 else httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    first = await executor.advance("task", spec.validator, now=NOW)
    assert first["state"] == "waiting" and first["error_kind"] == expected
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "completed"
    assert calls == ["gpt-6-luna", "mimo-v2.6-flash"]


async def test_unknown_response_never_automatically_retries_or_falls_back(setup):
    store, sub = setup
    calls = []

    def handler(request):
        calls.append(request)
        raise httpx.ReadTimeout("charged but lost response")

    executor = runner(store, handler)
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "outcome_unknown"
    executor.recover_interrupted()
    for _ in range(2):
        assert (await executor.advance("task", spec.validator, now=NOW))[
            "state"
        ] == "outcome_unknown"
    assert len(calls) == 1
    assert BudgetLedger(store).get(result["attempts"][0]["budget_id"])["state"] == "outcome_unknown"


async def test_intent_failure_rolls_back_reservation_and_sends_nothing(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req))
    spec = submit(executor, sub)
    store._db.set_authorizer(
        lambda action, table, *args: (
            sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_INSERT and table == "model_attempts"
            else sqlite3.SQLITE_OK
        )
    )
    try:
        with pytest.raises(RunnerError, match="storage_failed"):
            await executor.advance("task", spec.validator, now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert not calls
    assert store._db.execute("SELECT COUNT(*) FROM budget_attempts").fetchone()[0] == 0
    assert executor.status("task")["state"] == "pending"


@pytest.mark.parametrize("status", [429, 500, 503])
async def test_transient_retry_after_and_finite_attempts(setup, status):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(req)
        return httpx.Response(status, headers={"Retry-After": "20"})

    executor = runner(store, handler)
    spec = submit(executor, sub)
    first = await executor.advance("task", spec.validator, now=NOW)
    assert first["state"] == "waiting"
    assert first["next_at"] == (NOW + timedelta(seconds=20)).isoformat()
    await executor.advance("task", spec.validator, now=NOW + timedelta(seconds=19))
    assert len(calls) == 1
    for index in range(1, 6):
        result = await executor.advance(
            "task", spec.validator, now=NOW + timedelta(seconds=20 * index)
        )
    assert len(calls) == 4 and result["state"] == "blocked"


async def test_format_repair_preserves_evidence_and_revalidates_citations(setup):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(json.loads(req.content))
        return httpx.Response(200, json=response("invented citation"))

    executor = runner(store, handler)
    spec = submit(executor, sub)
    for _ in range(5):
        result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "blocked" and result["result"] is None and len(calls) == 4
    assert all(c["input"] == calls[0]["input"] for c in calls)
    assert "previous response failed" in calls[1]["instructions"]
    assert "previous response failed" not in calls[2]["instructions"]


async def test_refusal_stops_without_backup(setup):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(req)
        return httpx.Response(
            200,
            json={**response(), "output": [{"type": "message", "content": [{"type": "refusal"}]}]},
        )

    executor = runner(store, handler)
    spec = submit(executor, sub)
    for _ in range(3):
        result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "refused" and len(calls) == 1


@pytest.mark.parametrize("table", ["model_attempts", "budget_attempts"])
async def test_result_persistence_failure_recovers_unknown_without_replay(setup, table):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(req)
        store._db.set_authorizer(
            lambda action, name, *args: (
                sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_UPDATE and name == table
                else sqlite3.SQLITE_OK
            )
        )
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    try:
        with pytest.raises(RunnerError, match="storage_failed"):
            await executor.advance("task", spec.validator, now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert executor.status("task")["state"] == "inflight"
    path = store._db.execute("PRAGMA database_list").fetchone()[2]
    store.close()
    reopened = Store(Path(path))
    try:
        executor = runner(reopened, handler)
        BudgetLedger(reopened).recover_inflight()
        assert executor.recover_interrupted() == 1
        result = await executor.advance("task", spec.validator, now=NOW)
        assert result["state"] == "outcome_unknown" and len(calls) == 1
    finally:
        reopened.close()


async def test_concurrent_instances_cannot_double_dispatch(setup):
    store, sub = setup
    entered, release = asyncio.Event(), asyncio.Event()
    calls = []

    async def handler(req):
        calls.append(req)
        entered.set()
        await release.wait()
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    other = runner(store, handler)
    first = asyncio.create_task(executor.advance("task", spec.validator, now=NOW))
    await entered.wait()
    assert (await other.advance("task", spec.validator, now=NOW))["state"] == "inflight"
    release.set()
    assert (await first)["state"] == "completed" and len(calls) == 1


async def test_cancellation_after_dispatch_keeps_hold(setup):
    store, sub = setup
    entered = asyncio.Event()

    async def handler(req):
        entered.set()
        await asyncio.Event().wait()

    executor = runner(store, handler)
    spec = submit(executor, sub)
    pending = asyncio.create_task(executor.advance("task", spec.validator, now=NOW))
    await entered.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    result = executor.status("task")
    assert result["state"] == "outcome_unknown"
    assert BudgetLedger(store).get(result["attempts"][0]["budget_id"])["settled_units"] is None
    with pytest.raises(RunnerError, match="ack_required"):
        executor.resume("task")
    executor.resume("task", acknowledge_duplicate_charge=True)
    assert executor.status("task")["state"] == "pending"


async def test_no_news_and_budget_denial_never_dispatch(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req))
    spec = submit(executor, sub)
    ledger = BudgetLedger(store)
    rev, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 99
    ledger.configure(policy, rev)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "blocked" and result["error_kind"] == "model_limit"
    assert not calls and not result["attempts"]
    executor.submit(
        "empty",
        store.preview_route(sub),
        spec,
        operation="brief",
        version="1",
        evidence_hash="a" * 64,
        evidence_count=0,
        holds={"normal_primary": 100, "normal_backup": 100},
    )
    assert (await executor.advance("empty", spec.validator, now=NOW))["state"] == "no_news"
    assert not calls


async def test_config_change_during_request_suppresses_result(setup):
    store, sub = setup

    def handler(req):
        revision, config = store.load_config()
        config["news_output_locale"] = "ja"
        store.save_config(config, expected_revision=revision)
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "stale" and result["result"] is None
    assert BudgetLedger(store).get(result["attempts"][0]["budget_id"])["state"] == "settled"


async def test_cooldown_persists_and_recovers_without_extra_paid_probe(setup):
    store, sub = setup
    calls = []
    failing = True

    def handler(req):
        calls.append(req)
        return httpx.Response(503) if failing else httpx.Response(200, json=response())

    executor = runner(store, handler)
    # One failed attempt on each profile per task accumulates profile health.
    for index in range(3):
        spec = submit(executor, sub, f"t{index}", attempts_per_profile=1)
        await executor.advance(f"t{index}", spec.validator, now=NOW)
        await executor.advance(f"t{index}", spec.validator, now=NOW + timedelta(seconds=10))
    assert len(calls) == 6
    other = runner(store, handler)
    spec = submit(other, sub, "after")
    result = await other.advance("after", spec.validator, now=NOW + timedelta(seconds=20))
    assert result["state"] == "waiting" and result["error_kind"] == "profile_cooldown"
    assert len(calls) == 6
    failing = False
    result = await other.advance("after", spec.validator, now=NOW + timedelta(seconds=301))
    assert result["state"] == "completed" and len(calls) == 7
    assert next(h for h in other.health() if h["profile_id"] == "normal_primary")["failures"] == 0


async def test_durable_inflight_before_http_is_conservatively_unknown(setup):
    store, sub = setup

    class Crash(BaseException):
        pass

    class BeforeHTTP(ProviderAdapter):
        async def generate(self, request):
            raise Crash()

    executor = ModelRunner(
        store,
        Keys(),
        adapter_factory=lambda p, k: BeforeHTTP(
            p, k, client=httpx.AsyncClient(transport=httpx.MockTransport(lambda req: None))
        ),
    )
    spec = submit(executor, sub)
    with pytest.raises(Crash):
        await executor.advance("task", spec.validator, now=NOW)
    assert executor.status("task")["state"] == "inflight"
    assert executor.recover_interrupted() == 1
    assert (await executor.advance("task", spec.validator, now=NOW))["state"] == "outcome_unknown"


async def test_pretransaction_restart_uses_current_period_without_orphan_hold(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req) or httpx.Response(200, json=response()))
    spec = submit(executor, sub)
    assert not store._db.execute("SELECT 1 FROM budget_attempts").fetchall()
    next_month = datetime(2026, 12, 2, tzinfo=UTC)
    result = await runner(
        store, lambda req: calls.append(req) or httpx.Response(200, json=response())
    ).advance("task", spec.validator, now=next_month)
    record = BudgetLedger(store).get(result["attempts"][0]["budget_id"])
    period = store._db.execute(
        "SELECT start,end FROM budget_periods WHERE id=?", (record["period_id"],)
    ).fetchone()
    assert datetime.fromisoformat(period[0]) <= next_month < datetime.fromisoformat(period[1])
    assert len(calls) == 1


async def test_price_update_never_silently_raises_authorized_hold(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req))
    spec = submit(executor, sub)
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["prices"] = [
        dict(
            provider="openai",
            model="gpt-6-luna",
            input_per_million=1000000,
            output_per_million=1000000,
            id="new",
            updated_at=NOW.isoformat(),
        )
    ]
    ledger.configure(policy, revision)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "blocked" and result["error_kind"] == "authorized_hold_insufficient"
    assert not calls and not result["attempts"]
    assert not store._db.execute("SELECT 1 FROM budget_attempts").fetchall()


@pytest.mark.parametrize(
    "verified,lookup_state",
    [(False, "completed"), (True, "not_found"), (True, "completed"), (True, "definitely_unsent")],
)
async def test_unknown_recovery_only_verified_nonbillable_lookup(setup, verified, lookup_state):
    store, sub = setup
    generations, lookups = [], []

    class Recoverable(ProviderAdapter):
        verified_nonbillable_lookup = verified

        async def lookup(self, identity):
            lookups.append(identity)
            return dict(state=lookup_state, response=response())

    def handler(req):
        generations.append(req)
        raise httpx.ReadTimeout("lost")

    def factory(p, k):
        return Recoverable(p, k, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))

    executor = ModelRunner(store, Keys(), adapter_factory=factory)
    spec = submit(executor, sub)
    await executor.advance("task", spec.validator, now=NOW)
    result = await executor.recover_result("task", spec.validator, now=NOW)
    assert len(generations) == 1 and len(lookups) == int(verified)
    expected = (
        "completed"
        if verified and lookup_state == "completed"
        else "pending"
        if verified and lookup_state == "definitely_unsent"
        else "outcome_unknown"
    )
    assert result["state"] == expected
    if expected == "completed":
        assert (
            BudgetLedger(store).get(result["attempts"][0]["budget_id"])["usage"]["input_tokens"]
            == 20
        )


async def test_retry_after_http_date_parses_aware_value(setup):
    from email.utils import format_datetime

    store, sub = setup
    future = datetime.now(UTC) + timedelta(minutes=2)
    executor = runner(
        store, lambda req: httpx.Response(429, headers={"Retry-After": format_datetime(future)})
    )
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    delay = (datetime.fromisoformat(result["next_at"]) - NOW).total_seconds()
    assert 115 <= delay <= 120


async def test_fallback_and_format_repair_share_task_budget(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req) or httpx.Response(500))
    spec = ModelRequest("normal", "instruction", "evidence", validator=lambda text: text == "valid")
    executor.submit(
        "capped",
        store.preview_route(sub),
        spec,
        operation="brief",
        version="1",
        evidence_hash="b" * 64,
        evidence_count=1,
        holds={"normal_primary": 100, "normal_backup": 100},
        task_limit=100,
        attempts_per_profile=1,
    )
    await executor.advance("capped", spec.validator, now=NOW)
    result = await executor.advance("capped", spec.validator, now=NOW + timedelta(seconds=6))
    assert result["state"] == "blocked" and result["error_kind"] == "task_limit"
    assert len(calls) == 1


async def test_config_change_while_keychain_waits_prevents_dispatch(setup):
    from threading import Event

    store, sub = setup
    entered, release = Event(), Event()

    class SlowKeys:
        def read(self, ref):
            entered.set()
            assert release.wait(2)
            return "synthetic"

    calls = []
    executor = runner(store, lambda req: calls.append(req), backend=SlowKeys())
    spec = submit(executor, sub)
    pending = asyncio.create_task(executor.advance("task", spec.validator, now=NOW))
    assert await asyncio.to_thread(entered.wait, 2)
    revision, config = store.load_config()
    config["news_output_locale"] = "ja"
    store.save_config(config, expected_revision=revision)
    release.set()
    assert (await pending)["state"] == "stale" and not calls
    assert not store._db.execute("SELECT 1 FROM budget_attempts").fetchall()


async def test_configuration_cooldown_requires_retest_then_explicit_resume(setup, monkeypatch):
    store, sub = setup
    fail = True
    calls = []

    def handler(req):
        calls.append(req)
        return httpx.Response(401) if fail else httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    for _ in range(3):
        await executor.advance("task", spec.validator, now=NOW)
    other = submit(executor, sub, "new")
    assert (await executor.advance("new", other.validator, now=NOW))["state"] == "blocked"
    assert len(calls) == 2
    fail = False
    registry = ProfileRegistry(store)
    monkeypatch.setattr("newspaw.providers._now", lambda: (NOW + timedelta(seconds=1)).isoformat())
    registry.begin("retest", "normal_primary", "text", 1)
    registry.finish("retest", {"status": "verified"})
    executor.resume("new")
    assert (await executor.advance("new", other.validator, now=NOW))["state"] == "completed"
    assert len(calls) == 3


async def test_explicit_unknown_retry_retains_old_hold_and_attempt_limit(setup):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(req)
        raise httpx.ReadTimeout("lost")

    executor = runner(store, handler)
    spec = submit(executor, sub, attempts_per_profile=1)
    first = await executor.advance("task", spec.validator, now=NOW)
    executor.resume("task", acknowledge_duplicate_charge=True)
    second = await executor.advance("task", spec.validator, now=NOW)
    executor.resume("task", acknowledge_duplicate_charge=True)
    final = await executor.advance("task", spec.validator, now=NOW)
    assert final["state"] == "blocked" and len(calls) == 2
    assert first["attempts"][0]["budget_id"] != second["attempts"][1]["budget_id"]
    assert all(
        BudgetLedger(store).get(a["budget_id"])["state"] == "outcome_unknown"
        for a in final["attempts"]
    )


def test_task_identity_partition_and_validator_version_are_bound(setup):
    from dataclasses import replace

    store, sub = setup
    executor = runner(store, lambda req: None)
    spec = submit(executor, sub)
    submit(executor, sub)  # Identical submit is idempotent.
    with pytest.raises(RunnerError, match="partition_mismatch"):
        executor.submit(
            "other",
            store.preview_route(sub),
            replace(spec, partition="adult"),
            operation="brief",
            version="1",
            evidence_hash="a" * 64,
            evidence_count=1,
            holds={"normal_primary": 100, "normal_backup": 100},
        )
    with pytest.raises(RunnerError, match="contract_mismatch"):
        asyncio.run(executor.advance("task", spec.validator, version="2", now=NOW))


async def test_result_failure_from_error_response_is_safe_and_unknown_on_restart(setup):
    store, sub = setup

    def handler(req):
        store._db.set_authorizer(
            lambda action, name, *args: (
                sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_UPDATE and name == "model_attempts"
                else sqlite3.SQLITE_OK
            )
        )
        return httpx.Response(429)

    executor = runner(store, handler)
    spec = submit(executor, sub)
    try:
        with pytest.raises(RunnerError, match="storage_failed"):
            await executor.advance("task", spec.validator, now=NOW)
    finally:
        store._db.set_authorizer(None)
    assert executor.recover_interrupted() == 1
    assert executor.status("task")["state"] == "outcome_unknown"


async def test_preconnect_failure_reconciles_zero_and_retries_within_limit(setup):
    store, sub = setup
    calls = []

    def handler(req):
        calls.append(req)
        if len(calls) == 1:
            raise httpx.ConnectError("not connected")
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    first = await executor.advance("task", spec.validator, now=NOW)
    record = BudgetLedger(store).get(first["attempts"][0]["budget_id"])
    assert record["state"] == "settled" and record["settled_units"] == 0
    result = await executor.advance("task", spec.validator, now=NOW + timedelta(seconds=5))
    assert result["state"] == "completed" and len(calls) == 2


async def test_cancellation_before_intent_leaves_no_hold(setup):
    from threading import Event

    store, sub = setup
    entered, release = Event(), Event()

    class SlowKeys:
        def read(self, ref):
            entered.set()
            assert release.wait(2)
            return "synthetic"

    calls = []
    executor = runner(store, lambda req: calls.append(req), backend=SlowKeys())
    spec = submit(executor, sub)
    pending = asyncio.create_task(executor.advance("task", spec.validator, now=NOW))
    assert await asyncio.to_thread(entered.wait, 2)
    pending.cancel()
    release.set()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert executor.status("task")["state"] == "cancelled" and not calls
    assert not store._db.execute("SELECT 1 FROM budget_attempts").fetchall()


async def test_recovery_revalidates_output_instead_of_trusting_lookup(setup):
    store, sub = setup

    class Recoverable(ProviderAdapter):
        verified_nonbillable_lookup = True

        async def lookup(self, identity):
            return dict(state="completed", response=response("fabricated citation"))

    def handler(req):
        raise httpx.ReadTimeout("lost")

    def factory(p, k):
        return Recoverable(p, k, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))

    executor = ModelRunner(store, Keys(), adapter_factory=factory)
    spec = submit(executor, sub)
    await executor.advance("task", spec.validator, now=NOW)
    result = await executor.recover_result("task", spec.validator, now=NOW)
    assert result["state"] == "outcome_unknown"
    assert BudgetLedger(store).get(result["attempts"][0]["budget_id"])["state"] == "outcome_unknown"


async def test_pretransaction_price_change_requotes_within_original_hold(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req) or httpx.Response(200, json=response()))
    spec = submit(executor, sub)
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["prices"] = [
        dict(
            id="updated",
            provider="openai",
            model="gpt-6-luna",
            input_per_million=1,
            output_per_million=2,
            updated_at=NOW.isoformat(),
        )
    ]
    ledger.configure(policy, revision)
    result = await executor.advance("task", spec.validator, now=NOW)
    record = ledger.get(result["attempts"][0]["budget_id"])
    assert record["quote"]["rate"]["id"] == "updated"
    assert record["reserved_units"] == 100 and record["settled_units"] == 1
    assert len(calls) == 1


async def test_non_finite_provider_response_is_known_format_failure(setup):
    store, sub = setup
    executor = runner(
        store,
        lambda req: httpx.Response(
            200, content=b'{"status":"completed","usage":{"input_tokens":NaN}}'
        ),
    )
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "waiting" and result["error_kind"] == "invalid_output"
    assert BudgetLedger(store).get(result["attempts"][0]["budget_id"])["state"] == "settled"


async def test_profile_away_and_back_during_request_cannot_revive_old_result(setup):
    store, sub = setup

    def handler(req):
        revision, config = store.load_config()
        original = config["model_profiles"][0]["model"]
        config["model_profiles"][0]["model"] = "changed-model"
        store.save_config(config, expected_revision=revision)
        revision, config = store.load_config()
        config["model_profiles"][0]["model"] = original
        store.save_config(config, expected_revision=revision)
        registry = ProfileRegistry(store)
        registry.begin("new-generation", "normal_primary", "text", 1)
        registry.finish("new-generation", {"status": "verified"})
        return httpx.Response(200, json=response())

    executor = runner(store, handler)
    spec = submit(executor, sub)
    result = await executor.advance("task", spec.validator, now=NOW)
    assert result["state"] == "stale" and result["result"] is None


async def test_vision_call_obeys_image_budget_before_dispatch(setup):
    from dataclasses import replace

    from newspaw.providers import _probe_image

    store, sub = setup
    registry = ProfileRegistry(store)
    registry.begin("vision", "normal_primary", "vision", 1)
    registry.finish("vision", {"status": "verified"})
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["model"]["image_limit"] = 99
    ledger.configure(policy, revision)
    calls = []
    executor = runner(store, lambda req: calls.append(req) or httpx.Response(200, json=response()))
    spec = replace(
        ModelRequest("normal", "instruction", "evidence", validator=lambda text: text == "valid"),
        image=_probe_image(),
        image_mime="image/png",
    )
    executor.submit(
        "vision",
        store.preview_route(sub),
        spec,
        operation="brief",
        version="1",
        evidence_hash="a" * 64,
        evidence_count=1,
        holds={"normal_primary": 100, "normal_backup": 100},
    )
    result = await executor.advance("vision", spec.validator, now=NOW)
    assert result["state"] == "blocked" and result["error_kind"] == "image_limit"
    assert not calls


async def test_lookup_completed_cost_uses_frozen_quote(setup):
    store, sub = setup

    class Recoverable(ProviderAdapter):
        verified_nonbillable_lookup = True

        async def lookup(self, identity):
            return dict(state="completed", response=response())

    def handler(req):
        raise httpx.ReadTimeout("lost")

    def factory(p, k):
        return Recoverable(p, k, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))

    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["prices"] = [
        dict(
            id="v1",
            provider="openai",
            model="gpt-6-luna",
            input_per_million=1,
            output_per_million=2,
            updated_at=NOW.isoformat(),
        )
    ]
    ledger.configure(policy, revision)
    executor = ModelRunner(store, Keys(), adapter_factory=factory)
    spec = submit(executor, sub)
    await executor.advance("task", spec.validator, now=NOW)
    result = await executor.recover_result("task", spec.validator, now=NOW)
    record = ledger.get(result["attempts"][0]["budget_id"])
    assert record["settled_units"] == 1 and record["cost_source"] == "usage_derived"


async def test_primary_cooldown_remains_waiting_when_backup_exhausts(setup):
    store, sub = setup
    phase = "seed"
    calls = []

    def handler(req):
        model = json.loads(req.content)["model"]
        calls.append(model)
        return (
            httpx.Response(503)
            if model == "gpt-6-luna" or phase == "target"
            else httpx.Response(200, json=response())
        )

    executor = runner(store, handler)
    for index in range(3):
        spec = submit(executor, sub, f"seed{index}", attempts_per_profile=1)
        await executor.advance(f"seed{index}", spec.validator, now=NOW)
        await executor.advance(f"seed{index}", spec.validator, now=NOW + timedelta(seconds=10))
    phase = "target"
    spec = submit(executor, sub, "target")
    await executor.advance("target", spec.validator, now=NOW + timedelta(seconds=20))
    await executor.advance("target", spec.validator, now=NOW + timedelta(seconds=30))
    result = await executor.advance("target", spec.validator, now=NOW + timedelta(seconds=40))
    assert result["state"] == "waiting" and result["error_kind"] == "profile_cooldown"
    assert len(calls) == 8


async def test_identical_submission_returns_saved_result_after_route_changes(setup):
    store, sub = setup
    calls = []
    executor = runner(store, lambda req: calls.append(req) or httpx.Response(200, json=response()))
    route = store.preview_route(sub)
    spec = submit(executor, sub)
    saved = await executor.advance("task", spec.validator, now=NOW)
    revision, config = store.load_config()
    config["news_output_locale"] = "ja"
    store.save_config(config, expected_revision=revision)
    again = executor.submit(
        "task",
        route,
        spec,
        operation="brief",
        version="1",
        evidence_hash="a" * 64,
        evidence_count=1,
        holds={"normal_primary": 100, "normal_backup": 100},
        task_limit=500,
    )
    assert again["result"] == saved["result"] and len(calls) == 1
