import asyncio
import json
from copy import deepcopy

import httpx
import pytest

from newspaw.app_config import default_config
from newspaw.budget import BudgetLedger
from newspaw.credentials import CredentialError, CredentialManager
from newspaw.providers import (
    ModelRequest,
    ProbeService,
    ProfileRegistry,
    ProviderAdapter,
    ProviderError,
)
from newspaw.store import Store

REF = "keychain:00000000-0000-0000-0000-000000000001"


def profile(provider="openai", partition="normal"):
    result = deepcopy(
        next(p for p in default_config()["model_profiles"] if p["provider"] == provider)
    )
    result.update(partition=partition, credential_ref=REF)
    return result


def response(text="hello", *, model="observed-model", **kwargs):
    return {
        "id": "response1",
        "model": model,
        "status": "completed",
        "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
        "usage": {"input_tokens": 10, "output_tokens": 3},
        **kwargs,
    }


@pytest.mark.parametrize("provider", ["openai", "mimo", "deepseek", "grok"])
async def test_four_protocols_are_explicit_and_no_network_at_construction(provider):
    requests = []

    def handler(request):
        requests.append(request)
        body = json.loads(request.content)
        assert body["model"] == profile(provider)["model"]
        assert request.headers["authorization"] == "Bearer synthetic-key"
        assert request.url.path == ("/responses" if provider == "deepseek" else "/v1/responses")
        assert body["max_output_tokens"] == 128
        assert ("store" in body) == (provider in {"openai", "grok"})
        return httpx.Response(200, json=response())

    adapter = ProviderAdapter(
        profile(provider),
        "synthetic-key",
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    assert not requests
    result = await adapter.generate(
        ModelRequest("normal", "instructions", "data", max_output_tokens=128)
    )
    assert result["reported_model"] == "observed-model"
    assert result["usage"] == {"input_tokens": 10, "output_tokens": 3}
    assert len(requests) == 1
    await adapter.close()


async def test_mimo_auto_tool_and_local_schema_validation():
    requests = []

    def handler(request):
        body = json.loads(request.content)
        requests.append(body)
        return httpx.Response(
            200,
            json=response(
                output=[
                    {
                        "type": "function_call",
                        "name": "collect",
                        "arguments": '{"topic":"news","unexpected":true}',
                    }
                ]
            ),
        )

    adapter = ProviderAdapter(
        profile("mimo"),
        "synthetic",
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    spec = ModelRequest(
        "normal",
        "call collect",
        "news",
        tool_name="collect",
        tool_schema={"type": "object", "properties": {"topic": {"type": "string"}}},
        validator=lambda value: value == {"topic": "news"},
    )
    with pytest.raises(ProviderError, match="invalid_output"):
        await adapter.generate(spec)
    assert requests[0]["tool_choice"] == "auto" and requests[0]["tools"][0]["strict"] is False
    await adapter.close()


@pytest.mark.parametrize(
    "status,code",
    [
        (401, "authentication_failed"),
        (403, "permission_denied"),
        (404, "model_unavailable"),
        (400, "protocol_error"),
        (429, "rate_limited"),
        (500, "provider_failed"),
    ],
)
async def test_errors_are_safe_and_not_retried(status, code):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(status, json={"error": {"message": "synthetic-secret"}})

    adapter = ProviderAdapter(
        profile(), "synthetic", client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
    )
    with pytest.raises(ProviderError, match=code) as error:
        await adapter.generate(ModelRequest("normal", "i", "d"))
    assert error.value.outcome == "known" and "secret" not in str(error.value)
    assert len(calls) == 1
    await adapter.close()


@pytest.fixture
def registry(tmp_path):
    store = Store(tmp_path / "state.db")
    config = default_config()
    config["model_profiles"][0]["credential_ref"] = REF
    store.save_config(config, expected_revision=1)
    yield store, ProfileRegistry(store)
    store.close()


class Keys:
    def read(self, ref):
        assert ref == REF
        return "synthetic"


def probes(store, handler):
    def factory(entry, key):
        return ProviderAdapter(
            entry, key, client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        )

    return ProbeService(store, Keys(), adapter_factory=factory)


def echo(request):
    payload = json.loads(request.content)
    return httpx.Response(
        200, json=response(payload["input"][0]["content"][0]["text"].split("Reply exactly: ")[-1])
    )


async def test_explicit_probe_is_idempotent_and_capability_specific(registry):
    store, records = registry
    calls = []

    def handler(request):
        calls.append(request)
        return echo(request)

    service = probes(store, handler)
    assert records.status("normal_primary")["text"]["state"] == "untested"
    revision = store.config_revision()
    result = await service.probe("probe1", "normal_primary", "text", 100, revision=revision)
    assert result["status"] == "verified"
    assert store.config_revision() > revision
    assert (await service.probe("probe1", "normal_primary", "text", 100, revision=revision)) == result
    with pytest.raises(ProviderError, match="probe_id_conflict"):
        await service.probe("probe1", "normal_primary", "vision", 100, revision=revision)
    with pytest.raises(ProviderError, match="config_conflict"):
        await service.probe("new_probe", "normal_primary", "text", 100, revision=revision)
    assert len(calls) == 1
    states = records.status("normal_primary")
    assert states["text"]["state"] == "verified" and states["vision"]["state"] == "untested"
    assert states["image"]["state"] == "untested" and states["stt"]["state"] == "untested"
    assert BudgetLedger(store).get("probe.probe1")["settled_units"] is None
    assert (await service.probe("image1", "normal_primary", "image", 100))[
        "status"
    ] == "probe_unavailable"
    assert len(calls) == 1


async def test_url_model_key_changes_away_and_back_revoke_validation(registry):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)
    revision, config = store.load_config()
    original = deepcopy(config)
    config["model_profiles"][0]["model"] = "different-model"
    store.save_config(config, expected_revision=revision)
    store.save_config(original, expected_revision=store.config_revision())
    assert records.status("normal_primary")["text"]["state"] == "stale"
    assert store.load_config()[1]["model_profiles"][0]["capabilities"] == []


async def test_unrelated_save_preserves_verification_and_ui_cannot_forge_it(registry):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)
    revision, config = store.load_config()
    config["ui_locale"] = "en"
    manager = CredentialManager(store, Keys())
    await manager.save_config(config, revision)
    assert records.status("normal_primary")["text"]["state"] == "verified"
    revision, config = store.load_config()
    config["model_profiles"][0]["capabilities"].append("image")
    with pytest.raises(CredentialError, match="protected"):
        await manager.save_config(config, revision)


async def test_probe_timeout_holds_budget_and_same_id_never_replays(registry):
    store, records = registry
    calls = []

    def handler(request):
        calls.append(request)
        raise httpx.ReadTimeout("do-not-log")

    service = probes(store, handler)
    result = await service.probe("p", "normal_primary", "text", 100)
    assert result["status"] == "outcome_unknown"
    assert BudgetLedger(store).get("probe.p")["state"] == "outcome_unknown"
    assert await service.probe("p", "normal_primary", "text", 100) == result
    assert len(calls) == 1


async def test_probe_config_change_during_call_cannot_validate_replacement(registry):
    store, records = registry

    def handler(request):
        revision, config = store.load_config()
        config["model_profiles"][0]["base_url"] = "https://other.example/v1"
        store.save_config(config, expected_revision=revision)
        return echo(request)

    result = await probes(store, handler).probe("p", "normal_primary", "text", 100)
    assert result["status"] == "stale"
    assert records.status("normal_primary")["text"]["state"] == "stale"


async def test_budget_denial_and_partition_mismatch_have_no_http(registry):
    store, records = registry
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 0
    ledger.configure(policy, revision)

    def forbidden(request):
        pytest.fail("unexpected dispatch")

    result = await probes(store, forbidden).probe("p", "normal_primary", "text", 100)
    assert result["status"] == "budget_blocked"
    adapter = ProviderAdapter(
        profile(), "synthetic", client=httpx.AsyncClient(transport=httpx.MockTransport(forbidden))
    )
    with pytest.raises(ProviderError, match="partition_mismatch"):
        await adapter.generate(ModelRequest("adult", "i", "d"))
    await adapter.close()


async def test_probe_cancellation_is_durable_and_not_replayed(registry):
    store, _ = registry
    entered = asyncio.Event()

    async def handler(request):
        entered.set()
        await asyncio.Event().wait()

    service = probes(store, handler)
    task = asyncio.create_task(service.probe("p", "normal_primary", "text", 100))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert (await service.probe("p", "normal_primary", "text", 100))["status"] == "outcome_unknown"
    assert BudgetLedger(store).get("probe.p")["state"] == "outcome_unknown"


@pytest.mark.parametrize(
    "payload,code",
    [
        (response(status="incomplete", incomplete_details=None), "incomplete_output"),
        (
            response(status="incomplete", incomplete_details={"reason": "content_filter"}),
            "policy_refused",
        ),
        (
            response(
                output=[{"type": "message", "content": [{"type": "refusal", "refusal": "no"}]}]
            ),
            "policy_refused",
        ),
        (response(""), "invalid_output"),
        (
            response(output=[{"type": "message", "status": "in_progress", "content": []}]),
            "incomplete_output",
        ),
        (response(output=[{"type": "web_search_call"}]), "invalid_output"),
    ],
)
async def test_malformed_incomplete_and_refused_are_distinct(payload, code):
    adapter = ProviderAdapter(
        profile(),
        "synthetic",
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, json=payload))
        ),
    )
    with pytest.raises(ProviderError, match=code):
        await adapter.generate(ModelRequest("normal", "i", "d"))
    await adapter.close()


@pytest.mark.parametrize(
    "field,value",
    [
        ("base_url", "https://gateway.example/api"),
        ("credential_ref", "keychain:00000000-0000-0000-0000-000000000002"),
        ("provider", "mimo"),
    ],
)
async def test_each_profile_identity_change_revokes_capability(registry, field, value):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)
    revision, config = store.load_config()
    config["model_profiles"][0][field] = value
    store.save_config(config, expected_revision=revision)
    assert records.status("normal_primary")["text"]["state"] == "stale"
    assert config["model_profiles"][1]["capabilities"] == []


async def test_deleting_and_readding_profile_does_not_revive_old_probe(registry):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)
    revision, config = store.load_config()
    original = deepcopy(config)
    config["model_profiles"] = [p for p in config["model_profiles"] if p["id"] != "normal_primary"]
    store.save_config(config, expected_revision=revision)
    store.save_config(original, expected_revision=store.config_revision())
    assert records.status("normal_primary")["text"]["state"] == "stale"


async def test_connection_failure_is_definitely_unsent_and_no_retry(registry):
    store, _ = registry

    def handler(request):
        raise httpx.ConnectError("synthetic")

    result = await probes(store, handler).probe("p", "normal_primary", "text", 100)
    assert result["status"] == "failed" and result["error_kind"] == "connection_failed"
    assert BudgetLedger(store).get("probe.p")["settled_units"] == 0


@pytest.mark.parametrize("denied_table", ["model_probes", "budget_attempts"])
async def test_response_storage_failure_retains_hold_across_restart(registry, denied_table):
    import sqlite3

    store, records = registry
    calls = []

    def handler(request):
        calls.append(request)

        def deny(action, table, column, *args):
            return (
                sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_UPDATE and table == denied_table
                else sqlite3.SQLITE_OK
            )

        store._db.set_authorizer(deny)
        return echo(request)

    service = probes(store, handler)
    with pytest.raises(ProviderError, match="probe_storage_failed"):
        await service.probe("p", "normal_primary", "text", 100)
    store._db.set_authorizer(None)
    assert BudgetLedger(store).get("probe.p")["state"] == "inflight"
    BudgetLedger(store).recover_inflight()
    assert records.recover_interrupted() == 1
    assert (await service.probe("p", "normal_primary", "text", 100))["status"] == "outcome_unknown"
    assert len(calls) == 1
    assert BudgetLedger(store).get("probe.p")["reserved_units"] == 100


async def test_vision_probe_uses_inline_synthetic_image_only(registry):
    store, records = registry

    def handler(request):
        body = json.loads(request.content)
        parts = body["input"][0]["content"]
        assert parts[1]["image_url"].startswith("data:image/png;base64,")
        assert len(parts[1]["image_url"]) < 2048
        return httpx.Response(200, json=response("red"))

    result = await probes(store, handler).probe("vision", "normal_primary", "vision", 100)
    assert result["status"] == "verified"
    assert records.status("normal_primary")["text"]["state"] == "untested"


async def test_concurrent_calls_with_same_probe_id_dispatch_once(registry):
    store, _ = registry
    entered, finish = asyncio.Event(), asyncio.Event()
    calls = []

    async def handler(request):
        calls.append(request)
        entered.set()
        await finish.wait()
        return echo(request)

    service = probes(store, handler)
    running = asyncio.create_task(service.probe("same", "normal_primary", "text", 100))
    await entered.wait()
    assert (await service.probe("same", "normal_primary", "text", 100))["status"] == "pending"
    finish.set()
    assert (await running)["status"] == "verified"
    assert len(calls) == 1


async def test_quota_exhaustion_is_distinct_and_retry_after_is_bounded():
    adapter = ProviderAdapter(
        profile(),
        "synthetic",
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(
                    429,
                    headers={"retry-after": "42"},
                    json={"error": {"code": "insufficient_quota", "message": "private"}},
                )
            )
        ),
    )
    with pytest.raises(ProviderError, match="quota_exhausted") as error:
        await adapter.generate(ModelRequest("normal", "i", "d"))
    assert error.value.retry_after_seconds == 42
    await adapter.close()


async def test_custom_base_path_has_one_operation_and_model_is_not_rewritten():
    entry = profile()
    entry.update(base_url="https://gateway.example/custom/api/", model="custom-model")

    def handler(request):
        assert str(request.url) == "https://gateway.example/custom/api/responses"
        assert json.loads(request.content)["model"] == "custom-model"
        return httpx.Response(200, json=response(model="server-alias"))

    adapter = ProviderAdapter(
        entry, "synthetic", client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
    )
    result = await adapter.generate(ModelRequest("normal", "i", "d"))
    assert (
        result["requested_model"] == "custom-model" and result["reported_model"] == "server-alias"
    )
    assert adapter.profile["model"] == "custom-model"
    await adapter.close()


async def test_mimo_token_plan_key_is_not_sent_to_the_pay_as_you_go_address(registry):
    store, records = registry
    revision, config = store.load_config()
    config["model_profiles"][1]["credential_ref"] = REF
    store.save_config(config, expected_revision=revision)

    class PlanKeys:
        def read(self, ref):
            return "tp-synthetic"

    def forbidden(request):
        pytest.fail("unexpected dispatch")

    def factory(handler):
        return lambda entry, key: ProviderAdapter(
            entry, key, client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        )

    service = ProbeService(store, PlanKeys(), adapter_factory=factory(forbidden))
    result = await service.probe("plan-1", "normal_backup", "text", 100)
    assert result["status"] == "failed" and result["error_kind"] == "token_plan_endpoint"
    assert store._db.execute("SELECT count(*) FROM budget_attempts").fetchone() == (0,)

    # The plan's own address takes the same key; a pay-as-you-go key stays on the default one.
    plan = profile("mimo") | {"base_url": "https://token-plan-cn.xiaomimimo.com/v1"}
    for entry, key in ((plan, "tp-synthetic"), (profile("mimo"), "sk-synthetic")):
        adapter = ProviderAdapter(
            entry, key, client=httpx.AsyncClient(transport=httpx.MockTransport(echo))
        )
        await adapter.close()
    with pytest.raises(ProviderError, match="token_plan_endpoint"):
        ProviderAdapter(profile("mimo"), "tp-synthetic")


async def test_later_failed_probe_hides_previous_pass(registry):
    store, records = registry
    await probes(store, echo).probe("pass", "normal_primary", "text", 100)
    await probes(store, lambda _: httpx.Response(401)).probe("fail", "normal_primary", "text", 100)
    assert records.status("normal_primary")["text"]["state"] == "failed"
    assert store.load_config()[1]["model_profiles"][0]["capabilities"] == []


async def test_credential_rotation_uses_same_invalidation_transaction(registry):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)

    class MutableKeys:
        def __init__(self):
            self.values = {REF: "synthetic"}

        def read(self, ref):
            return self.values.get(ref)

        def write(self, ref, value):
            self.values[ref] = value

        def delete(self, ref):
            self.values.pop(ref, None)

    manager = CredentialManager(store, MutableKeys())
    await manager.set("model_profiles", "normal_primary", "new-synthetic", store.config_revision())
    assert records.status("normal_primary")["text"]["state"] == "stale"
    assert store.load_config()[1]["model_profiles"][0]["capabilities"] == []


async def test_failed_config_cas_does_not_invalidate_existing_capability(registry):
    store, records = registry
    await probes(store, echo).probe("p", "normal_primary", "text", 100)
    revision, config = store.load_config()
    config["model_profiles"][0]["model"] = "different"
    with pytest.raises(ValueError, match="changed"):
        store.save_config(config, expected_revision=revision - 1)
    assert records.status("normal_primary")["text"]["state"] == "verified"


@pytest.mark.parametrize("error_code", [[], {"unexpected": "object"}])
async def test_malformed_provider_error_code_finishes_known_failure(registry, error_code):
    store, records = registry
    result = await probes(
        store, lambda _: httpx.Response(429, json={"error": {"code": error_code}})
    ).probe("bad-code", "normal_primary", "text", 100)
    assert result["status"] == "failed" and result["error_kind"] == "rate_limited"
    assert records.get("bad-code")["status"] == "failed"
    assert BudgetLedger(store).get("probe.bad-code")["state"] == "settled"


async def test_pending_reverification_keeps_last_completed_capability(registry):
    store, records = registry
    await probes(store, echo).probe("passed", "normal_primary", "text", 100)
    records.begin("pending", "normal_primary", "text", 100)
    assert records.get("pending")["status"] == "pending"
    assert records.status("normal_primary")["text"]["state"] == "verified"
    assert store.load_config()[1]["model_profiles"][0]["capabilities"] == ["text"]


async def test_interrupted_reverification_removes_derived_capability_atomically(registry):
    import sqlite3

    store, records = registry
    await probes(store, echo).probe("passed", "normal_primary", "text", 100)
    records.begin("pending", "normal_primary", "text", 100)
    revision = store.config_revision()
    store._db.set_authorizer(
        lambda action, table, *args: sqlite3.SQLITE_DENY
        if action == sqlite3.SQLITE_UPDATE and table == "app_configuration"
        else sqlite3.SQLITE_OK
    )
    try:
        with pytest.raises(sqlite3.DatabaseError):
            records.recover_interrupted()
    finally:
        store._db.set_authorizer(None)
    assert records.get("pending")["status"] == "pending"
    assert store.config_revision() == revision
    assert records.recover_interrupted() == 1
    assert records.status("normal_primary")["text"]["state"] == "outcome_unknown"
    assert store.load_config()[1]["model_profiles"][0]["capabilities"] == []
    assert store.config_revision() == revision + 1


def test_native_probe_rejects_stale_configuration_before_recording_intent(tmp_path):
    from contextlib import closing

    from newspaw.store import Store

    with closing(Store(tmp_path / "state.db")) as store:
        registry = ProfileRegistry(store)
        revision, config = store.load_config()
        config["model_profiles"][0]["model"] = "new-fixture-model"
        store.save_config(config, expected_revision=revision)
        with pytest.raises(ProviderError, match="config_conflict"):
            registry.begin("stale.probe", "normal_primary", "text", 100, revision=revision)
        assert registry.get("stale.probe") is None
        assert store._db.execute("SELECT count(*) FROM budget_attempts").fetchone() == (0,)
