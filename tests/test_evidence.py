import asyncio
from copy import deepcopy
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from newspaw.app_config import default_config
from newspaw.evidence import EvidenceError, EvidenceStore, FeedCollector
from newspaw.news import parse_evidence
from newspaw.store import Store

NOW = datetime(2026, 11, 7, 12, tzinfo=UTC)
URL = "https://example.com/feed"


def rss(date="Sat, 07 Nov 2026 03:00:00 +0000", *, title="国内 新闻", empty=False):
    item = (
        ""
        if empty
        else f"<item><title>{title}</title><link>https://example.com/a</link><pubDate>{date}</pubDate><description>摘要</description></item>"
    )
    return f'<rss version="2.0"><channel><title>Publisher</title><language>ja</language>{item}</channel></rss>'.encode()


@pytest.fixture
def configured(tmp_path):
    store = Store(tmp_path / "state.db")
    config = default_config()
    config["sources"] = [
        dict(
            id="source1",
            name="Feed",
            url=URL,
            kind="rss",
            partition="normal",
            category_ids=["world", "japan"],
            enabled=True,
        )
    ]
    store.save_config(config, expected_revision=1)
    yield store, EvidenceStore(store)
    store.close()


def collector(repo, handler):
    return FeedCollector(repo, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))


def test_parser_keeps_real_distinct_dates_and_nonfresh_evidence():
    entries, rejected = parse_evidence(rss(), URL, NOW)
    assert not rejected
    entry = entries[0]
    assert entry.published_at == NOW.replace(hour=3)
    assert entry.updated_at is None and entry.updated_raw == ""
    assert entry.fetched_at == NOW and entry.language == "ja"
    atom = b'<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en"><title>Source</title><entry><title>AI</title><link href="https://example.com/b"/><updated>2026-11-07T10:00:00Z</updated></entry></feed>'
    entries, _ = parse_evidence(atom, URL, NOW)
    assert entries[0].published_at is None
    assert entries[0].updated_at == NOW.replace(hour=10)


@pytest.mark.asyncio
async def test_shared_fetch_associations_and_restart_304(configured):
    store, repo = configured
    calls = []

    def first(request):
        calls.append(request)
        return httpx.Response(
            200,
            content=rss(),
            headers={"ETag": '"one"', "Last-Modified": "Sat, 07 Nov 2026 03:00:00 GMT"},
        )

    service = collector(repo, first)
    outcomes = await service.collect(["sub_world", "sub_japan"], now=NOW)
    await service.close()
    assert len(calls) == len(outcomes) == 1
    identity = outcomes[0]["id"]
    assert outcomes[0]["status"] == "fresh"
    for sub in ("sub_world", "sub_japan"):
        assert len(repo.articles(identity, partition="normal", subscription_id=sub, now=NOW)) == 1
    assert repo.attempt(identity, partition="normal")["associations"] == [
        {"source_id": "source1", "subscription_id": "sub_japan", "category_id": "japan"},
        {"source_id": "source1", "subscription_id": "sub_world", "category_id": "world"},
    ]

    # A new repository/client uses the durable cache, not process memory.
    def conditional(request):
        assert request.headers["if-none-match"] == '"one"'
        assert "if-modified-since" in request.headers
        return httpx.Response(304)

    service = collector(EvidenceStore(store), conditional)
    later = NOW + timedelta(days=2)
    result = (await service.collect(["sub_world"], now=later))[0]
    assert result["status"] == "not_modified" and result["content_status"] == "stale"
    assert (
        repo.articles(result["id"], partition="normal", subscription_id="sub_world", now=later)
        == []
    )
    all_items = repo.articles(
        result["id"], partition="normal", subscription_id="sub_world", now=later, fresh_only=False
    )
    assert all_items[0].fetched_at == NOW
    assert repo.health("source1", now=later)["freshness"] == "current"
    repo.set_health_threshold("source1", 24)
    assert repo.health("source1", now=later)["freshness"] == "stale"
    await service.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "date,status",
    [
        ("", "no_eligible"),
        ("2026-11-07T11:00:00", "no_eligible"),
        ("2026-11-08T03:00:00Z", "no_eligible"),
        ("2026-10-01T03:00:00Z", "stale"),
    ],
)
async def test_nonfresh_dates_retained_but_never_briefed(configured, date, status):
    _, repo = configured
    service = collector(repo, lambda _: httpx.Response(200, content=rss(date)))
    result = (await service.collect(["sub_world"], now=NOW))[0]
    assert result["status"] == status
    assert not repo.articles(result["id"], partition="normal", subscription_id="sub_world", now=NOW)
    assert (
        len(
            repo.articles(
                result["id"],
                partition="normal",
                subscription_id="sub_world",
                now=NOW,
                fresh_only=False,
            )
        )
        == 1
    )
    assert repo.health("source1", now=NOW)["freshness"] != "current"
    await service.close()


@pytest.mark.asyncio
async def test_failed_attempts_keep_cache_and_empty_200_replaces_it(configured):
    _, repo = configured
    sequence = [
        httpx.Response(200, content=rss(), headers={"etag": '"good"'}),
        httpx.Response(200, content=b"invalid", headers={"etag": '"bad"'}),
        httpx.Response(429, headers={"retry-after": "42"}),
        httpx.Response(304),
        httpx.Response(200, content=rss(empty=True)),
        httpx.Response(304),
    ]
    requests = []

    def handler(request):
        requests.append(request)
        return sequence.pop(0)

    service = collector(repo, handler)
    results = [(await service.preview("source1", now=NOW))[0] for _ in range(6)]
    assert [r["status"] for r in results] == [
        "fresh",
        "failed",
        "rate_limited",
        "not_modified",
        "empty",
        "not_modified",
    ]
    assert results[2]["retry_after_seconds"] == 42
    assert requests[3].headers["if-none-match"] == '"good"'
    assert "if-none-match" not in requests[5].headers
    assert results[-1]["content_status"] == "empty"
    assert (
        repo.attempt(results[1]["id"], partition="normal")["associations"][0]["source_id"]
        == "source1"
    )
    assert not repo.articles(results[1]["id"], partition="normal", source_id="source1", now=NOW)
    await service.close()


@pytest.mark.asyncio
async def test_partition_cache_and_query_isolation(configured):
    store, repo = configured
    revision, config = store.load_config()
    adult = deepcopy(config["sources"][0])
    adult.update(id="adult", partition="adult", category_ids=["av"])
    config["sources"].append(adult)
    store.save_config(config, expected_revision=revision)
    calls = []

    def handler(request):
        calls.append(request)
        assert "if-none-match" not in request.headers
        return httpx.Response(200, content=rss(), headers={"etag": '"one"'})

    service = collector(repo, handler)
    normal = (await service.preview("source1", now=NOW))[0]
    adult_result = (await service.preview("adult", now=NOW))[0]
    assert len(calls) == 2
    with pytest.raises(EvidenceError, match="missing_attempt"):
        repo.attempt(adult_result["id"], partition="normal")
    with pytest.raises(EvidenceError):
        repo.articles(normal["id"], partition="normal", source_id="adult", now=NOW)
    await service.close()


@pytest.mark.asyncio
async def test_config_change_during_fetch_cannot_attach_to_new_partition(configured):
    store, repo = configured

    def handler(request):
        revision, config = store.load_config()
        config["sources"][0].update(partition="adult", category_ids=["av"])
        store.save_config(config, expected_revision=revision)
        return httpx.Response(200, content=rss())

    service = collector(repo, handler)
    result = (await service.collect(["sub_world"], now=NOW))[0]
    assert result["status"] == "configuration_changed"
    with pytest.raises(EvidenceError):
        repo.articles(result["id"], partition="normal", subscription_id="sub_world", now=NOW)
    with pytest.raises(EvidenceError):
        repo.attempt(result["id"], partition="adult")
    await service.close()


@pytest.mark.asyncio
async def test_cancelled_and_protocol_failure_are_audited(configured):
    _, repo = configured
    service = collector(repo, lambda _: httpx.Response(304))
    result = (await service.preview("source1", now=NOW))[0]
    assert result["error_kind"] == "cache_missing"
    await service.close()
    entered = asyncio.Event()

    async def block(request):
        entered.set()
        await asyncio.Event().wait()

    service = collector(repo, block)
    task = asyncio.create_task(service.preview("source1", now=NOW))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert repo.history("source1")[-1]["status"] == "cancelled"
    await service.close()


@pytest.mark.asyncio
async def test_unclassified_source_never_reaches_transport(configured):
    store, repo = configured
    revision, config = store.load_config()
    config["sources"][0].update(partition=None, category_ids=[], enabled=False)
    store.save_config(config, expected_revision=revision)

    def handler(request):
        pytest.fail("unclassified content dispatched")

    service = collector(repo, handler)
    with pytest.raises(EvidenceError, match="unclassified_source"):
        await service.preview("source1", now=NOW)
    await service.close()


@pytest.mark.asyncio
async def test_real_database_reopen_uses_conditional_cache(tmp_path):
    path = tmp_path / "restart.db"
    store = Store(path)
    revision, config = store.load_config()
    config["sources"] = [
        dict(
            id="source1",
            name="Feed",
            url=URL,
            kind="rss",
            partition="normal",
            category_ids=["world"],
            enabled=True,
        )
    ]
    store.save_config(config, expected_revision=revision)
    service = collector(
        EvidenceStore(store),
        lambda _: httpx.Response(200, content=rss(), headers={"etag": '"persisted"'}),
    )
    await service.preview("source1", now=NOW)
    await service.close()
    store.close()
    reopened = Store(path)

    def handler(request):
        assert request.headers["if-none-match"] == '"persisted"'
        return httpx.Response(304)

    service = collector(EvidenceStore(reopened), handler)
    assert (await service.preview("source1", now=NOW))[0]["status"] == "not_modified"
    await service.close()
    reopened.close()


@pytest.mark.asyncio
async def test_redirect_never_forwards_cached_validators(configured):
    _, repo = configured
    sequence = [
        httpx.Response(200, content=rss(), headers={"etag": '"old"'}),
        httpx.Response(302, headers={"location": "/new-feed"}),
        httpx.Response(200, content=rss(), headers={"etag": '"new"'}),
    ]
    requests = []

    def handler(request):
        requests.append(request)
        return sequence.pop(0)

    service = collector(repo, handler)
    await service.preview("source1", now=NOW)
    await service.preview("source1", now=NOW)
    assert requests[1].headers["if-none-match"] == '"old"'
    assert "if-none-match" not in requests[2].headers
    await service.close()


@pytest.mark.asyncio
async def test_atomic_snapshot_failure_is_recoverable(configured):
    import sqlite3

    store, repo = configured

    def handler(request):
        def deny(action, table, *args):
            return (
                sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_INSERT and table == "feed_cache"
                else sqlite3.SQLITE_OK
            )

        store._db.set_authorizer(deny)
        return httpx.Response(200, content=rss())

    service = collector(repo, handler)
    with pytest.raises(sqlite3.DatabaseError):
        await service.preview("source1", now=NOW)
    store._db.set_authorizer(None)
    assert store._db.execute("SELECT COUNT(*) FROM feed_snapshots").fetchone()[0] == 0
    assert repo.history("source1")[-1]["status"] == "running"
    assert repo.recover_interrupted() == 1
    assert repo.history("source1")[-1]["status"] == "interrupted"
    assert repo.recover_interrupted() == 0
    await service.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "failure,kind",
    [(httpx.ReadTimeout("private"), "timeout"), (httpx.ConnectError("private"), "network_error")],
)
async def test_safe_failure_audit_and_no_fresh_cache_fallback(configured, failure, kind):
    _, repo = configured
    call = 0

    def handler(request):
        nonlocal call
        call += 1
        if call == 1:
            return httpx.Response(200, content=rss())
        raise failure

    service = collector(repo, handler)
    await service.preview("source1", now=NOW)
    result = (await service.preview("source1", now=NOW))[0]
    assert result["status"] == "failed" and result["error_kind"] == kind
    assert "private" not in str(result)
    assert not repo.articles(result["id"], partition="normal", source_id="source1", now=NOW)
    assert repo.health("source1", now=NOW)["last_attempt"]["status"] == "failed"
    await service.close()


@pytest.mark.asyncio
async def test_same_url_multiple_source_ids_reuse_and_retired_scope_refuses_read(configured):
    store, repo = configured
    revision, config = store.load_config()
    second = deepcopy(config["sources"][0])
    second["id"] = "source2"
    config["sources"].append(second)
    store.save_config(config, expected_revision=revision)
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, content=rss())

    service = collector(repo, handler)
    result = (await service.collect(["sub_world", "sub_japan"], now=NOW))[0]
    assert len(calls) == 1 and len(result["associations"]) == 4
    revision, config = store.load_config()
    config["sources"][0]["enabled"] = False
    store.save_config(config, expected_revision=revision)
    with pytest.raises(EvidenceError, match="scope_changed"):
        repo.articles(result["id"], partition="normal", subscription_id="sub_world", now=NOW)
    await service.close()
