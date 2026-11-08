from contextlib import closing
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from test_x_accounts import directory, user
from test_x_accounts import system as directory_system

from newspaw.store import Store
from newspaw.x.timelines import TimelineError, Timelines

system = directory_system
NOW = datetime(2026, 11, 8, 2, tzinfo=UTC)


def post(identity, *, author="12345", minutes=1, sensitive=False, references=None):
    result = {
        "id": str(identity),
        "author_id": author,
        "created_at": (NOW - timedelta(minutes=minutes)).isoformat(),
        "text": f"Synthetic post {identity}",
    }
    if sensitive is not None:
        result["possibly_sensitive"] = sensitive
    if references is not None:
        result["referenced_posts"] = references
    return result


def page(items, token=None):
    meta = {"result_count": len(items)}
    if token:
        meta["next_token"] = token
    return httpx.Response(200, json={"data": items, "meta": meta})


async def setup(system, responder):
    store, _, _ = system
    path = "/2/users/12345/tweets"

    async def responses(request, ordinal):
        route = request.url.path
        if route == "/2/users/by/username/fixture":
            return httpx.Response(200, json={"data": user("12345", "fixture")})
        if route == "/2/lists/456":
            return httpx.Response(
                200, json={"data": {"id": "456", "name": "Fixture", "private": False}}
            )
        if route == "/2/lists/456/members":
            return page([user("12345", "fixture")])
        assert route in {path, "/2/lists/456/tweets"}
        return await responder(request, ordinal)

    x, requests = directory(system, responses)
    item = (await x.add_account("fixture", store.config_revision()))["account"]
    await x.verify(item["id"], "directory.verify", store.config_revision())
    revision, config = store.load_config()
    sub = next(s for s in config["subscriptions"] if s["category_id"] == "x")
    sub["enabled"] = True
    store.save_config(config, expected_revision=revision)
    await x.classify(item["id"], "normal", store.config_revision())
    await x.set_route(item["id"], sub["id"], "normal", store.config_revision())
    return Timelines(x, clock=lambda: NOW), x, item["id"], requests


async def test_new_post_types_require_fresh_window_and_durable_complete_cursor(system):
    reads = []

    async def responses(request, _):
        reads.append(dict(request.url.params))
        return page(
            [post(120), post(115, minutes=3, references=[{"type": "replied_to", "id": "113"}])]
        )

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    rev = store.config_revision()
    scans.begin("scan.one", "account", account, rev)
    result = await scans.advance("scan.one", "step.one")
    assert result["state"] == "complete" and result["complete_cursor"] == "120"
    assert [item["id"] for item in scans.posts("account", account)] == ["120"]
    assert "since_id" not in reads[0] and "start_time" in reads[0]
    with pytest.raises(TimelineError, match="fresh_window_required"):
        scans.begin("scan.two", "account", account, rev, include_replies=True)
    scans.begin("scan.fresh", "account", account, rev, include_replies=True, fresh=True)
    result = await scans.advance("scan.fresh", "step.fresh")
    assert result["state"] == "complete" and result["history_gap"] == "fresh_window"
    assert [item["id"] for item in scans.posts("account", account)] == ["120", "115"]
    assert "since_id" not in reads[-1]


@pytest.mark.parametrize("flag", [True, None])
async def test_normal_cache_is_revoked_by_overlapping_sensitive_observation(system, flag):
    async def responses(request, _):
        if request.url.path.endswith("/lists/456/tweets"):
            assert "since_id" not in request.url.params and "start_time" not in request.url.params
            return page([post(125, sensitive=flag)])
        return page([post(125)])

    store, _, _ = system
    scans, x, account, _ = await setup(system, responses)
    rev = store.config_revision()
    scans.begin("account.one", "account", account, rev)
    await scans.advance("account.one", "step.one")
    assert [p["id"] for p in scans.posts("account", account)] == ["125"]
    x.add_list("456", "normal", rev)
    await x.refresh_list("456", "members", rev)
    scans.begin("list.one", "list", "456", rev)
    await scans.advance("list.one", "step.list")
    assert scans.posts("account", account) == scans.posts("list", "456") == []
    scans.begin("account.fresh", "account", account, rev, fresh=True)
    await scans.advance("account.fresh", "step.fresh")
    assert scans.posts("account", account) == []
    assert "Synthetic post 125" not in "\n".join(store._db.iterdump())


async def test_confirmed_pages_and_prior_cursor_survive_unknown_and_restart(system, tmp_path):
    reads = []

    async def responses(request, _):
        reads.append(dict(request.url.params))
        if len(reads) == 1:
            return page([post(120)])
        if len(reads) == 2:
            return page([post(130)], "next")
        raise httpx.ReadTimeout("synthetic response loss")

    store, credentials, _ = system
    scans, x, account, _ = await setup(system, responses)
    rev = store.config_revision()
    scans.begin("initial", "account", account, rev)
    await scans.advance("initial", "initial.read")
    scans.begin("increment", "account", account, rev)
    first = await scans.advance("increment", "increment.first")
    assert first["state"] == "pending" and first["complete_cursor"] == "120"
    assert reads[1]["since_id"] == "120"
    lost = await scans.advance("increment", "increment.lost")
    assert lost["state"] == "outcome_unknown" and lost["complete_cursor"] == "120"
    assert reads[2]["pagination_token"] == "next"
    with closing(Store(tmp_path / "state.db")) as reopened:
        from newspaw.credentials import CredentialManager
        from newspaw.telegram.registry import BotRegistry
        from newspaw.telegram.targets import TargetManager
        from newspaw.x.accounts import XDirectory

        new_credentials = CredentialManager(reopened, credentials.backend)
        registry = BotRegistry(reopened, credentials.backend)
        new_targets = TargetManager(new_credentials, registry)
        new_x = XDirectory(new_credentials, new_targets, client_factory=x.client_factory)
        recovered = Timelines(new_x, clock=lambda: NOW)
        recovered.recover_interrupted()
        assert await recovered.advance("increment", "increment.lost") == lost
        assert len(reads) == 3
        assert [p["id"] for p in recovered.posts("account", account)] == ["130", "120"]


async def test_list_does_not_use_any_read_under_finite_account_limit(system):
    from newspaw.budget import BudgetLedger

    async def responses(request, _):
        pytest.fail("No timeline read allowed under finite account policy")

    store, _, _ = system
    scans, x, account, _ = await setup(system, responses)
    rev = store.config_revision()
    x.add_list("456", "normal", rev)
    await x.refresh_list("456", "members", rev)
    budget = BudgetLedger(store)
    revision, policy = budget.policy()
    policy["x"]["account_limits"][account] = 100
    budget.configure(policy, revision)
    scans.begin("limited.list", "list", "456", rev)
    status = await scans.advance("limited.list", "limited.first")
    assert status["reason"] == "account_limit_requires_individual"
    assert status["state"] == "budget_blocked"


async def test_known_429_backs_off_and_reuses_checkpoint_under_new_step(system):
    calls = []

    async def responses(request, _):
        calls.append(dict(request.url.params))
        if len(calls) == 1:
            return page([post(120)], "next")
        if len(calls) == 2:
            return httpx.Response(429, json={}, headers={"Retry-After": "45"})
        return page([post(110, minutes=2)])

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    clock = [NOW]
    scans.clock = lambda: clock[0]
    scans.begin("paged", "account", account, store.config_revision())
    await scans.advance("paged", "first")
    held = await scans.advance("paged", "limited")
    assert held["state"] == "rate_limited" and held["completed_pages"] == 1
    assert held["complete_cursor"] is None
    await scans.advance("paged", "too.soon")
    assert len(calls) == 2
    clock[0] += timedelta(seconds=45)
    assert await scans.advance("paged", "limited") == held
    result = await scans.advance("paged", "resume")
    assert result["state"] == "complete" and result["complete_cursor"] == "120"
    assert calls[1]["pagination_token"] == calls[2]["pagination_token"] == "next"
    assert store._db.execute(
        "SELECT settled_units FROM budget_attempts WHERE task_id LIKE 'xtimeline.%' ORDER BY rowid"
    ).fetchall() == [(1,), (1,), (1,)]


@pytest.mark.parametrize(
    "case", ["duplicate", "out_of_order", "empty_with_token", "foreign_author"]
)
async def test_partial_page_never_advances_complete_cursor(system, case):
    calls = []

    async def responses(request, _):
        calls.append(request)
        if len(calls) == 1:
            return page([post(100)])
        if len(calls) == 2:
            return page([post(120)], "next")
        if case == "duplicate":
            return page([post(120)])
        if case == "out_of_order":
            return page([post(130)])
        if case == "empty_with_token":
            return page([], "another")
        return page([post(110, author="54321", minutes=2)])

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    revision = store.config_revision()
    scans.begin("prior", "account", account, revision)
    await scans.advance("prior", "prior.step")
    scans.begin("partial", "account", account, revision)
    await scans.advance("partial", "page.one")
    result = await scans.advance("partial", "page.two")
    assert result["state"] == "incomplete" and result["complete_cursor"] == "100"
    assert result["reason"] == "pagination_gap" and result["completed_pages"] == 1
    assert [post["id"] for post in scans.posts("account", account)] == ["120", "100"]


async def test_begin_does_not_unhide_cache_after_authoritative_denial(system):
    calls = []

    async def responses(request, _):
        calls.append(request)
        if len(calls) == 1:
            return page([post(120)])
        if len(calls) == 2:
            return httpx.Response(403, json={})
        return page([post(130)])

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    revision = store.config_revision()
    scans.begin("one", "account", account, revision)
    await scans.advance("one", "one.step")
    assert scans.posts("account", account)
    scans.begin("two", "account", account, revision)
    assert (await scans.advance("two", "two.step"))["reason"] == "permission_denied"
    assert scans.posts("account", account) == []
    scans.begin("three", "account", account, revision)
    assert scans.posts("account", account) == []
    await scans.advance("three", "three.step")
    assert [post["id"] for post in scans.posts("account", account)] == ["130", "120"]


async def test_version_17_upgrade_preserves_directory_and_commands(tmp_path):
    from test_credentials import FakeKeychain

    from newspaw.control import ControlServer
    from newspaw.credentials import CredentialManager
    from newspaw.migrations import DATABASE_VERSION

    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        server = ControlServer(tmp_path, CredentialManager(store, FakeKeychain()))
        server.x.add_list("456", "normal", store.config_revision())
        with store._write():
            for table in (
                "x_post_observations",
                "x_posts",
                "x_timeline_steps",
                "x_timeline_scans",
                "x_timeline_cursors",
            ):
                store._db.execute(f"DROP TABLE {table}")
            store._db.execute("PRAGMA user_version=17")

    with closing(Store(path)) as store:
        server = ControlServer(tmp_path, CredentialManager(store, FakeKeychain()))
        assert store._db.execute("PRAGMA user_version").fetchone() == (DATABASE_VERSION,)
        assert store._db.execute("SELECT count(*) FROM command_replies").fetchone() == (0,)
        assert server.x.list_status("456")["id"] == "456"
        assert await server._dispatch({"op": "x.posts.purge_expired"}) == {"purged": 0}


@pytest.mark.parametrize("field", ["id", "author_id", "reference"])
async def test_malformed_remote_ids_settle_all_returned_rows(system, field):
    async def responses(request, _):
        bad = post(110, minutes=2)
        if field == "reference":
            bad["referenced_posts"] = [{"type": "quoted", "id": "0"}]
        else:
            bad[field] = "0"
        return page([post(120), bad])

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    scans.begin("malformed", "account", account, store.config_revision())
    result = await scans.advance("malformed", "malformed.step")
    assert result["state"] == "incomplete" and result["reason"] == "partial_response"
    assert store._db.execute(
        "SELECT settled_units FROM budget_attempts WHERE task_id LIKE 'xtimeline.%'"
    ).fetchone() == (2,)


async def test_same_remote_sensitive_revocation_survives_local_account_replacement(system):
    reads = []

    async def responses(request, _):
        reads.append(request)
        return page([post(125, sensitive=len(reads) > 1)])

    store, _, _ = system
    scans, x, original, _ = await setup(system, responses)
    scans.begin("old.owner", "account", original, store.config_revision())
    await scans.advance("old.owner", "old.step")
    assert scans.posts("account", original)

    old = store.load_config()[1]
    await x.remove_account(original, store.config_revision())
    replacement = (await x.add_account("fixture", store.config_revision()))["account"]["id"]
    assert replacement != original
    await x.verify(replacement, "verify.replacement", store.config_revision())
    await x.classify(replacement, "normal", store.config_revision())
    await x.set_route(replacement, "sub_x", "normal", store.config_revision())
    scans.begin("new.owner", "account", replacement, store.config_revision())
    await scans.advance("new.owner", "new.step")
    assert store._db.execute(
        "SELECT body,tombstone FROM x_posts WHERE partition='normal' AND id='125'"
    ).fetchone() == (None, 1)

    store.save_config(old, expected_revision=store.config_revision())
    await x.verify(original, "verify.original", store.config_revision())
    assert scans.posts("account", original) == []


async def test_fractional_publication_after_window_floor_is_eligible(system):
    async def responses(request, _):
        timestamp = NOW - timedelta(hours=24) + timedelta(milliseconds=500)
        return page([dict(post(120), created_at=timestamp.isoformat())])

    store, _, _ = system
    scans, _, account, _ = await setup(system, responses)
    scans.begin("fractional", "account", account, store.config_revision())
    status = await scans.advance("fractional", "fractional.step")
    assert status["state"] == "complete" and status["complete_cursor"] == "120"
    assert [post["id"] for post in scans.posts("account", account)] == ["120"]


async def test_coverage_displays_partial_and_preserves_prior_complete_without_network(system):
    calls = []

    async def responses(request, _):
        calls.append(request)
        return page([post(120)]) if len(calls) == 1 else page([post(125)], "more")

    scans, x, identity, _ = await setup(system, responses)
    revision = x.store.config_revision()
    assert scans.coverage("account", identity)["state"] == "unobserved"
    scans.begin("initial", "account", identity, revision)
    assert scans.coverage("account", identity)["latest"]["through_time"] is None
    await scans.advance("initial", "initial.read")
    first = scans.coverage("account", identity)["last_complete"]
    scans.begin("partial", "account", identity, revision, max_pages=1)
    await scans.advance("partial", "partial.read", before_intent=lambda: True)
    result = scans.coverage("account", identity)
    assert result["latest"]["reason"] == "page_limit"
    assert result["latest"]["from_time"] is None
    assert result["last_complete"] == first
    assert len(calls) == 2 and "Synthetic post" not in repr(result)


async def test_timeline_keeps_literal_markup_and_long_plain_post_text(system):
    expected = {
        "130": "Literal <b>markup</b> text &amp; entities",
        "125": "<script>example-only text</script>",
        "120": "A long original post " + "日" * 4600,
    }

    async def response(request, _):
        return page(
            [
                dict(post(int(identity), minutes=index), text=body)
                for index, (identity, body) in enumerate(expected.items(), 1)
            ]
        )

    scans, directory, account, _ = await setup(system, response)
    scans.begin("exact", "account", account, directory.store.config_revision())
    state = await scans.advance("exact", "exact.read")
    assert state["state"] == "complete" and state["complete_cursor"] == "130"
    assert {item["id"]: item["text"] for item in scans.posts("account", account)} == expected
