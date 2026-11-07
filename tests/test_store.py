import hashlib
import sqlite3
from dataclasses import asdict
from datetime import UTC, datetime

import pytest

from newspaw.news import Article, canonical_url
from newspaw.store import AUDIT_RETENTION, MAX_AUDIT_ITEMS, MAX_AUDIT_STRING, Store


def test_delivery_receipts_survive_restart_and_are_per_chat(tmp_path):
    path = tmp_path / "nested" / "state.sqlite3"
    article = Article("A story", "https://example.com/story?utm_source=first", "Publisher")
    same_story = Article("A story", "https://example.com/story?utm_source=second", "Publisher")
    store = Store(path)
    assert store.unseen(1, [article, same_story]) == [article]
    store.mark_sent(1, article)
    store.mark_sent(1, article)
    store.close()

    store = Store(path)
    try:
        assert store.unseen(1, [same_story]) == []
        assert store.unseen(2, [same_story]) == [same_story]
    finally:
        store.close()


def test_settings_replace_and_survive_restart(tmp_path):
    path = tmp_path / "state.sqlite3"
    store = Store(path)
    assert store.get("missing") is None
    assert store.get("missing", "fallback") == "fallback"
    store.set("topics", '["AI"]')
    store.set("topics", '["AI", "机器人"]')
    store.set("sql' key", "value' with quote")
    store.close()

    store = Store(path)
    try:
        assert store.get("topics") == '["AI", "机器人"]'
        assert store.get("sql' key") == "value' with quote"
    finally:
        store.close()


def test_audit_provenance_and_delivery_status_survive_restart(tmp_path):
    path = tmp_path / "private" / "state.sqlite3"
    published = datetime(2026, 11, 7, 7, 15, tzinfo=UTC)
    article = Article(
        "新闻标题",
        "https://example.com/story",
        "Publisher",
        published,
        "The full supplied evidence.",
        "https://example.com/photo.jpg",
    )
    report = {"query": "AI", "fetched_at": published, "accepted": [article], "failures": []}
    store = Store(path)
    collection_id = store.save_collection(report)
    brief_id = store.save_brief(collection_id, [article], "中文总结", kind="scheduled")
    assert collection_id.startswith("collection_")
    assert brief_id.startswith("brief_")
    assert store.get_audit()[0]["brief"]["status"] == "prepared"
    store.mark_brief(brief_id, "partial", "TimedOut")
    store.close()

    store = Store(path)
    try:
        collection = store.get_collection(collection_id)
        assert collection["report"]["fetched_at"] == published.isoformat()
        audit = store.get_audit()[0]
        assert audit["collection_id"] == collection_id
        assert audit["brief"]["brief_id"] == brief_id
        assert audit["brief"]["summary"] == "中文总结"
        assert audit["brief"]["kind"] == "scheduled"
        assert audit["brief"]["status"] == "partial"
        assert audit["brief"]["error_kind"] == "TimedOut"
        expected_article = asdict(article)
        expected_article["published_at"] = published.isoformat()
        assert audit["brief"]["articles"] == [expected_article]
        store.mark_brief(brief_id, "delivered")
        assert store.get_audit()[0]["brief"]["error_kind"] == ""
    finally:
        store.close()


def test_audit_keeps_failed_collections_and_joins_only_latest_brief(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    try:
        first_id = store.save_collection({"query": "AI", "accepted": []})
        first_brief = store.save_brief(first_id, [], "Initial summary")
        second_brief = store.save_brief(first_id, [], "Revised summary")
        assert first_brief != second_brief
        failure_id = store.save_collection({"status": "failed", "error_kind": "NewsError"})
        audit = store.get_audit()
        assert [entry["collection_id"] for entry in audit] == [failure_id, first_id]
        assert audit[0]["brief"] is None
        assert audit[1]["brief"]["brief_id"] == second_brief
        assert len(store.get_audit(1)) == 1
        assert store.get_audit(0) == []
        assert store.get_collection("missing") is None
    finally:
        store.close()


def test_brief_status_transitions_are_validated(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    try:
        collection_id = store.save_collection({})
        brief_id = store.save_brief(collection_id, [], "")
        store.mark_brief(brief_id, "failed", "NetworkError")
        with pytest.raises(ValueError, match="Invalid brief transition"):
            store.mark_brief(brief_id, "delivered")
        store.mark_brief(brief_id, "prepared")
        store.mark_brief(brief_id, "delivered")
        store.mark_brief(brief_id, "delivered")
        with pytest.raises(ValueError, match="Invalid brief transition"):
            store.mark_brief(brief_id, "failed", "NetworkError")
        with pytest.raises(ValueError, match="Unknown brief status"):
            store.mark_brief(brief_id, "sent")
        with pytest.raises(ValueError, match="Brief does not exist"):
            store.mark_brief("missing", "delivered")
        with pytest.raises(ValueError, match="Collection does not exist"):
            store.save_brief("missing", [], "")
    finally:
        store.close()


def test_audit_redacts_named_credentials_and_private_feed_url_credentials(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    try:
        collection_id = store.save_collection(
            {
                "OPENAI_API_KEY": "never-store-this-key",
                "nested": {"telegram_token": "never-store-this-token", "count": 2},
                "feed": "https://user:private-password@example.com/rss?topic=AI&api_key=private-key",
            }
        )
        report = store.get_collection(collection_id)["report"]
        assert report["OPENAI_API_KEY"] == "[REDACTED]"
        assert report["nested"] == {"telegram_token": "[REDACTED]", "count": 2}
        assert "private" not in report["feed"]
        assert "user:" not in report["feed"]
        assert "example.com/rss?topic=AI" in report["feed"]
    finally:
        store.close()


@pytest.mark.parametrize(
    "payload",
    [
        {"media": b"binary"},
        {"image": "data:image/png;base64,abc"},
        {"body": "x" * (MAX_AUDIT_STRING + 1)},
        {"items": [None] * (MAX_AUDIT_ITEMS + 1)},
        {"not_a_number": float("nan")},
    ],
)
def test_invalid_or_oversized_audit_payload_never_inserts_partial_record(tmp_path, payload):
    store = Store(tmp_path / "state.sqlite3")
    try:
        with pytest.raises(ValueError):
            store.save_collection(payload)
        assert store.get_audit() == []
    finally:
        store.close()


def test_error_kind_cannot_store_raw_error_text_and_brief_size_is_bounded(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    try:
        collection_id = store.save_collection({})
        brief_id = store.save_brief(collection_id, [], "")
        with pytest.raises(ValueError, match="exception identifier"):
            store.mark_brief(brief_id, "failed", "Request failed with Bearer secret")
        with pytest.raises(ValueError, match="storage limit"):
            store.save_brief(collection_id, [], "x" * (MAX_AUDIT_STRING + 1))
        with pytest.raises(ValueError, match="at most 200"):
            store.save_brief(
                collection_id, [Article("A", "https://example.com", "source")] * 201, ""
            )
        assert store.get_audit()[0]["brief"]["brief_id"] == brief_id
        assert store.get_audit()[0]["brief"]["status"] == "prepared"
    finally:
        store.close()


def test_storage_and_sidecars_have_private_permissions(tmp_path):
    path = tmp_path / "private" / "state.sqlite3"
    store = Store(path)
    try:
        store.save_collection({"query": "AI"})
        assert path.parent.stat().st_mode & 0o777 == 0o700
        for file in path.parent.iterdir():
            assert file.stat().st_mode & 0o777 == 0o600
    finally:
        store.close()


def test_news_and_av_delivery_receipts_are_independent_after_restart(tmp_path):
    path = tmp_path / "state.sqlite3"
    article = Article("A story", "https://example.com/story", "Publisher")
    store = Store(path)
    store.mark_sent(1, article)
    assert store.unseen(1, [article], scope="news") == []
    assert store.unseen(1, [article], scope="av") == [article]
    store.mark_sent(1, article, scope="av")
    store.close()
    store = Store(path)
    try:
        assert store.unseen(1, [article]) == []
        assert store.unseen(1, [article], scope="av") == []
        assert store.unseen(2, [article], scope="av") == [article]
    finally:
        store.close()


def test_legacy_receipts_migrate_idempotently_to_news_scope(tmp_path):
    path = tmp_path / "state.sqlite3"
    article = Article("A story", "https://example.com/story", "Publisher")
    key = hashlib.sha256(canonical_url(article.url).encode("utf-8")).hexdigest()
    legacy = sqlite3.connect(path)
    legacy.execute(
        "CREATE TABLE deliveries (chat_id INTEGER NOT NULL, article_key TEXT NOT NULL, "
        "sent_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (chat_id, article_key))"
    )
    legacy.execute("INSERT INTO deliveries (chat_id, article_key) VALUES (?, ?)", (1, key))
    legacy.commit()
    legacy.close()
    for _ in range(2):
        store = Store(path)
        try:
            assert store.unseen(1, [article]) == []
            assert store.unseen(1, [article], scope="av") == [article]
        finally:
            store.close()


def test_pruning_removes_old_collections_and_briefs_but_retains_delivery_receipts(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    article = Article("A story", "https://example.com/story", "Publisher")
    try:
        first_id = store.save_collection({"sequence": 1})
        first_brief = store.save_brief(first_id, [article], "First")
        second_id = store.save_collection({"sequence": 2})
        second_brief = store.save_brief(second_id, [article], "Second")
        store.mark_sent(1, article)
        store.mark_sent(1, article, scope="av")
        assert store.prune_audit(keep=1) == 1
        assert store.get_collection(first_id) is None
        assert store.get_collection(second_id) is not None
        assert store.get_audit()[0]["brief"]["brief_id"] == second_brief
        with pytest.raises(ValueError, match="Brief does not exist"):
            store.mark_brief(first_brief, "delivered")
        assert store.unseen(1, [article]) == []
        assert store.unseen(1, [article], scope="av") == []
        assert store.prune_audit(keep=0) == 1
        assert store.get_audit() == []
    finally:
        store.close()


def test_save_collection_enforces_automatic_retention(tmp_path):
    store = Store(tmp_path / "state.sqlite3")
    try:
        ids = [store.save_collection({"sequence": i}) for i in range(AUDIT_RETENTION + 2)]
        assert store.get_collection(ids[0]) is None
        assert store.get_collection(ids[1]) is None
        assert store.get_collection(ids[2]) is not None
        assert store.get_collection(ids[-1]) is not None
        assert store.prune_audit(keep=0) == AUDIT_RETENTION
    finally:
        store.close()
