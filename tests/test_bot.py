from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from telegram.error import TelegramError

from newspaw import bot as bot_module
from newspaw.bot import NewsBot, split_text
from newspaw.config import Settings
from newspaw.news import Article, NewsError
from newspaw.store import Store


@pytest.fixture
def harness(tmp_path):
    settings = Settings(
        config_path=tmp_path / ".env",
        data_dir=tmp_path / "state",
        pairing_code="test-random-pairing-code",
        topics=["AI"],
    )
    store = Store(settings.data_dir / "newspaw.sqlite3")
    news = SimpleNamespace(latest=AsyncMock(), search=AsyncMock(), last_failed_sources=0)
    ai = SimpleNamespace(enabled=False, summarize=AsyncMock(), speak=AsyncMock())
    worker = NewsBot(settings, store, news, ai)
    transport = SimpleNamespace(
        send_message=AsyncMock(), send_photo=AsyncMock(), send_audio=AsyncMock()
    )
    yield SimpleNamespace(
        worker=worker,
        store=store,
        settings=settings,
        news=news,
        ai=ai,
        transport=transport,
        context=SimpleNamespace(bot=transport, args=[]),
    )
    store.close()


def update(user_id=42, chat_type="private", text=""):
    message = SimpleNamespace(
        text=text,
        photo=[],
        voice=None,
        audio=None,
        caption=None,
        reply_text=AsyncMock(),
        delete=AsyncMock(),
    )
    return SimpleNamespace(
        effective_chat=SimpleNamespace(id=user_id, type=chat_type),
        effective_user=SimpleNamespace(id=user_id),
        effective_message=message,
    )


@pytest.mark.asyncio
async def test_unpaired_users_and_groups_cannot_use_news_or_bind_chat(harness):
    private = update()
    await harness.worker.request_news(private, harness.context)
    assert harness.store.get("chat_id") is None
    harness.news.latest.assert_not_awaited()
    harness.news.search.assert_not_awaited()
    harness.store.set("owner_id", "42")
    group = update(chat_type="group")
    assert not await harness.worker.authorize(group)
    assert harness.store.get("chat_id") is None
    assert not await harness.worker.authorize(update(user_id=99))
    assert harness.store.get("chat_id") is None


@pytest.mark.asyncio
async def test_pairing_persists_owner_and_cannot_be_reused_by_another_user(harness):
    harness.context.args = [harness.settings.pairing_code]
    owner_update = update()
    await harness.worker.pair(owner_update, harness.context)
    assert harness.store.get("owner_id") == "42"
    assert harness.store.get("chat_id") == "42"
    owner_update.effective_message.delete.assert_awaited_once()
    other = update(user_id=99)
    await harness.worker.pair(other, harness.context)
    assert harness.store.get("owner_id") == "42"
    assert harness.store.get("chat_id") == "42"
    restarted = Store(harness.settings.data_dir / "newspaw.sqlite3")
    try:
        assert NewsBot(harness.settings, restarted, harness.news, harness.ai).owner_id == 42
    finally:
        restarted.close()


@pytest.mark.asyncio
async def test_wrong_pairing_code_does_not_claim_owner(harness):
    harness.context.args = ["wrong-code"]
    await harness.worker.pair(update(), harness.context)
    assert harness.store.get("owner_id") is None
    harness.transport.send_message.assert_not_awaited()


@pytest.mark.asyncio
async def test_partial_delivery_marks_only_successfully_sent_articles(harness):
    articles = [
        Article("First", "https://example.com/one", "Publisher", datetime.now(UTC)),
        Article("Second", "https://example.com/two", "Publisher", datetime.now(UTC)),
    ]

    async def send(chat_id, text):
        if text.startswith("2. Second"):
            raise TelegramError("fixture network failure")

    harness.transport.send_message.side_effect = send
    with pytest.raises(TelegramError):
        await harness.worker.deliver(harness.transport, 42, articles, track=True)
    assert harness.store.unseen(42, articles) == [articles[1]]
    assert harness.store.unseen(99, articles) == articles


@pytest.mark.asyncio
async def test_photo_failure_falls_back_to_text_before_recording_receipt(harness):
    article = Article(
        "First",
        "https://example.com/one",
        "Publisher",
        datetime.now(UTC),
        image_url="https://example.com/photo.jpg",
    )
    harness.transport.send_photo.side_effect = TelegramError("fixture image unavailable")
    await harness.worker.deliver(harness.transport, 42, [article], track=True)
    harness.transport.send_photo.assert_awaited_once()
    harness.transport.send_message.assert_awaited_once()
    assert harness.store.unseen(42, [article]) == []


@pytest.mark.asyncio
async def test_scheduled_failure_retries_then_persists_completed_slot(harness, monkeypatch):
    harness.store.set("owner_id", "42")
    harness.store.set("chat_id", "42")
    slot = "2026-11-07T09:00:00+09:00"
    monkeypatch.setattr(bot_module, "due_slot", lambda *args: slot)
    clock = [100.0]
    monkeypatch.setattr(bot_module.time, "monotonic", lambda: clock[0])
    fetch = AsyncMock(side_effect=[NewsError("fixture failure"), True])
    harness.worker.fetch_and_send = fetch
    await harness.worker.scheduled(harness.context)
    assert harness.store.get("last_slot") is None
    assert harness.worker.next_retry == 400.0
    await harness.worker.scheduled(harness.context)
    assert fetch.await_count == 1
    clock[0] = 401.0
    await harness.worker.scheduled(harness.context)
    assert fetch.await_count == 2
    assert harness.store.get("last_slot") == slot
    assert harness.store.get("last_delivery")
    restarted = NewsBot(harness.settings, harness.store, harness.news, harness.ai)
    restarted.fetch_and_send = AsyncMock()
    await restarted.scheduled(harness.context)
    restarted.fetch_and_send.assert_not_awaited()


@pytest.mark.asyncio
async def test_scheduled_news_never_sends_to_unpaired_or_wrong_chat(harness, monkeypatch):
    monkeypatch.setattr(bot_module, "due_slot", lambda *args: "fixture-slot")
    harness.worker.fetch_and_send = AsyncMock()
    harness.store.set("chat_id", "42")
    await harness.worker.scheduled(harness.context)
    harness.store.set("owner_id", "99")
    await harness.worker.scheduled(harness.context)
    harness.worker.fetch_and_send.assert_not_awaited()


def test_long_emoji_messages_are_split_by_telegram_utf16_units():
    original = "🐾" * 4000 + "中文新闻"
    chunks = split_text(original)
    assert "".join(chunks) == original
    assert all(len(chunk.encode("utf-16-le")) // 2 <= 3500 for chunk in chunks)
