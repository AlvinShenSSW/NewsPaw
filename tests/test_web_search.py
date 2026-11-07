import asyncio
import json

import httpx
import pytest
from test_credentials import FakeKeychain
from test_evidence import NOW
from test_providers import REF

from newspaw.budget import BudgetError, BudgetLedger
from newspaw.connectors.web_search import WebSearch, WebSearchError
from newspaw.providers import ProfileRegistry, ProviderAdapter
from newspaw.store import Store

FEED = "https://feeds.bbci.co.uk/news/world/rss.xml"
URL = "https://www.bbc.com/example"
SUB = "sub_world"
PROFILE = "normal_primary"
HOLD = 100_000


def reply(*, tool=True):
    output = [
        {
            "type": "message",
            "content": [
                {
                    "type": "output_text",
                    "text": "Generated prose must not be retained",
                    "annotations": [
                        {"type": "url_citation", "url": URL, "title": "Verified citation"},
                        {"type": "url_citation", "url": "https://evil.example/a", "title": "Bad"},
                        {
                            "type": "url_citation",
                            "url": "https://www.bbc.com/not-searched",
                            "title": "Bad",
                        },
                    ],
                }
            ],
        }
    ]
    if tool:
        output.insert(
            0,
            {
                "type": "web_search_call",
                "status": "completed",
                "action": {
                    "type": "search",
                    "queries": ["public query"],
                    "sources": [{"url": URL}],
                },
            },
        )
    return {
        "status": "completed",
        "output": output,
        "usage": {"input_tokens": 20, "output_tokens": 2},
    }


@pytest.fixture
def local(tmp_path):
    path = tmp_path / "state.db"
    store = Store(path)
    revision, config = store.load_config()
    config["sources"] = [
        dict(
            id="bbc",
            kind="rss",
            name="Sensitive local nickname",
            url=FEED,
            partition="normal",
            category_ids=["world"],
            enabled=True,
        )
    ]
    next(p for p in config["model_profiles"] if p["id"] == PROFILE)["credential_ref"] = REF
    next(s for s in config["subscriptions"] if s["id"] == SUB)["enabled"] = True
    store.save_config(config, expected_revision=revision)
    profiles = ProfileRegistry(store)
    profiles.begin("probe", PROFILE, "text", 1)
    profiles.finish("probe", {"status": "verified"})
    budget = BudgetLedger(store)
    revision, policy = budget.policy()
    policy["prices"] = [
        dict(
            id="luna.1",
            provider="openai",
            model="gpt-6-luna",
            input_per_million=100000,
            output_per_million=500000,
            updated_at=NOW.isoformat(),
        )
    ]
    budget.configure(policy, revision)
    backend = FakeKeychain()
    backend.items[REF] = "fixture-key"
    yield store, backend, path
    store.close()


def service(store, backend, handler):
    def factory(profile, key):
        return ProviderAdapter(
            profile, key, client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        )

    return WebSearch(store, backend, adapter_factory=factory)


async def test_search_explicitly_configured_scoped_and_idempotent(local):
    store, backend, _ = local
    calls = []

    def handler(request):
        data = json.loads(request.content)
        calls.append(data)
        assert str(request.url) == "https://api.openai.com/v1/responses"
        assert data["model"] == "gpt-6-luna" and data["max_tool_calls"] == 1
        assert data["tools"][0]["filters"] == {"allowed_domains": ["www.bbc.co.uk", "www.bbc.com"]}
        assert "Sensitive local nickname" not in request.content.decode()
        return httpx.Response(200, json=reply())

    search = service(store, backend, handler)
    with pytest.raises(WebSearchError, match="search_not_configured"):
        await search.run(SUB, "lookup", 1, HOLD)
    assert calls == []
    assert search.configure(PROFILE, 1)["revision"] == 2
    result = await search.run(SUB, "lookup", 2, HOLD)
    assert result["state"] == "completed" and result["provider"] == "openai"
    assert result["provider_queries"] == ["public query"]
    assert result["citations"] == [
        {"url": URL, "title": "Verified citation", "scope": "citation_title_only"}
    ]
    assert "Generated prose" not in json.dumps(result)
    assert await search.run(SUB, "lookup", 2, HOLD) == result
    assert len(calls) == 1
    with pytest.raises(WebSearchError, match="request_id_conflict"):
        await search.run(SUB, "lookup", 2, HOLD + 1)
    assert BudgetLedger(store).get(result["budget_id"])["settled_units"] == 10_003


async def test_search_guard_budget_and_intent_write_failure(local):
    store, backend, _ = local

    def forbidden(_):
        pytest.fail("must not call provider")

    search = service(store, backend, forbidden)
    search.configure(PROFILE, 1)
    with pytest.raises(BudgetError, match="authorized_hold_insufficient"):
        await search.run(SUB, "budget", 2, 1)
    store._db.execute(
        """CREATE TRIGGER reject_search BEFORE INSERT ON web_search_requests
        BEGIN SELECT RAISE(ABORT, 'fixture'); END"""
    )
    with pytest.raises(WebSearchError, match="storage_failed"):
        await search.run(SUB, "write", 2, HOLD)
    assert store._db.execute("SELECT COUNT(*) FROM budget_attempts").fetchone()[0] == 0


async def test_search_late_result_is_settled_but_hidden(local):
    store, backend, _ = local
    started, release = asyncio.Event(), asyncio.Event()

    async def handler(_):
        started.set()
        await release.wait()
        return httpx.Response(200, json=reply())

    search = service(store, backend, handler)
    search.configure(PROFILE, 1)
    running = asyncio.create_task(search.run(SUB, "late", 2, HOLD))
    await asyncio.wait_for(started.wait(), 2)
    search.configure(None, 2)
    release.set()
    result = await running
    assert result["state"] == "configuration_changed" and not result.get("citations")
    assert BudgetLedger(store).get(result["budget_id"])["state"] == "settled"


async def test_search_lost_response_cannot_replay_after_restart(local):
    store, backend, path = local

    def unknown(request):
        raise httpx.ReadTimeout("fixture", request=request)

    search = service(store, backend, unknown)
    search.configure(PROFILE, 1)
    before = await search.run(SUB, "unknown", 2, HOLD)
    assert before["state"] == "outcome_unknown"
    reopened = Store(path)
    try:

        def forbidden(_):
            pytest.fail("must not replay")

        restarted = service(reopened, backend, forbidden)
        assert await restarted.run(SUB, "unknown", 2, HOLD) == before
    finally:
        reopened.close()


async def test_provider_without_tool_does_not_claim_search(local):
    store, backend, _ = local
    search = service(store, backend, lambda _: httpx.Response(200, json=reply(tool=False)))
    search.configure(PROFILE, 1)
    result = await search.run(SUB, "no-tool", 2, HOLD)
    assert result["state"] == "no_tool_result" and not result.get("citations")


async def test_search_recovery_after_uncommitted_provider_result(local):

    store, backend, path = local
    search = service(store, backend, lambda _: httpx.Response(200, json=reply()))
    search.configure(PROFILE, 1)
    store._db.execute(
        """CREATE TRIGGER reject_confirmation BEFORE UPDATE ON web_search_requests
        BEGIN SELECT RAISE(ABORT, 'fixture'); END"""
    )
    with pytest.raises(WebSearchError, match="storage_failed"):
        await search.run(SUB, "lost-commit", 2, HOLD)
    first = search.status("lost-commit")
    assert first["state"] == "inflight"
    store._db.execute("DROP TRIGGER reject_confirmation")

    reopened = Store(path)
    try:

        def forbidden(_):
            pytest.fail("must not replay an inflight paid request")

        resumed = service(reopened, backend, forbidden)
        assert resumed.recover_interrupted() == 1
        assert resumed.recover_interrupted() == 0
        result = await resumed.run(SUB, "lost-commit", 2, HOLD)
        assert result["state"] == "outcome_unknown"
        assert BudgetLedger(reopened).get(first["budget_id"])["state"] == "outcome_unknown"
    finally:
        reopened.close()


async def test_search_never_uses_adult_or_unknown_sources(local):
    store, backend, _ = local
    search = service(store, backend, lambda _: pytest.fail("scope forbidden"))
    search.configure(PROFILE, 1)
    revision, cfg = store.load_config()
    next(s for s in cfg["subscriptions"] if s["id"] == "sub_av")["enabled"] = True
    cfg["sources"][0]["url"] = "https://unrecognized.example/feed.xml"
    store.save_config(cfg, expected_revision=revision)
    with pytest.raises(WebSearchError, match="search_scope_unavailable"):
        await search.run("sub_av", "adult", 2, HOLD)
    with pytest.raises(WebSearchError, match="search_domains_unavailable"):
        await search.run(SUB, "unknown-source", 2, HOLD)
