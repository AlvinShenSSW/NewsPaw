import asyncio
import json
import threading
from datetime import timedelta

import httpx
from test_model_runner import NOW
from test_outbox import TOKEN, TOKEN2, ready_response, sender
from test_outbox import system as outbox_system
from test_telegram_registry import update

from newspaw.telegram.commands import Commands

system = outbox_system


def command_service(system, responder=None):
    pipeline, targets, _, _, _ = system
    outbox, sent = sender(pipeline, targets, responder)
    return Commands(outbox, clock=lambda: NOW), outbox, sent


async def inbox(system, text, identity, *, bot="bot1", reply=None, **fields):
    _, targets, _, _, _ = system
    registry = targets.registry
    api = registry.client_factory(TOKEN if bot == "bot1" else TOKEN2)
    incoming = update(text, identity, when=NOW, **fields)
    if reply is not None:
        incoming["message"]["reply_to_message"] = {"message_id": reply}
    api.updates = [incoming]
    await registry.poll_once(bot, now=NOW + timedelta(seconds=identity))
    return incoming


def bodies(sent):
    return [json.loads(request.content)["text"] for request in sent]


async def test_commands_consume_only_private_owner_and_cite_existing_news(system):
    commands, _, sent = command_service(system)
    _, _, _, model_calls, _ = system
    await inbox(system, "/news", 2, owner=456)
    await inbox(system, "/news", 3, kind="group")
    await commands.tick()
    assert not sent
    await inbox(system, "/news s:sub_world", 4)
    await commands.tick()
    assert len(sent) == 1 and "https://example.com/a" in bodies(sent)[0]
    assert json.loads(sent[0].content)["link_preview_options"] == {"is_disabled": True}
    await commands.tick()
    assert len(sent) == len(model_calls) == 1


async def test_reply_requires_same_confirmed_bot_and_no_fallback(system):
    commands, outbox, sent = command_service(system)
    _, _, job, _, _ = system
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await inbox(system, "/why", 2, bot="bot2", reply=1)
    await inbox(system, "/why", 2, bot="bot1", reply=1)
    await commands.tick()
    answers = {
        request.url.path.split("/")[1]: json.loads(request.content)["text"] for request in sent[1:]
    }
    assert "https://example.com/a" in answers["bot" + TOKEN]
    assert "https://example.com/a" not in answers["bot" + TOKEN2]


async def test_unknown_reply_is_never_replayed_after_restart(system):
    async def lose_reply(_):
        raise httpx.ReadTimeout("synthetic lost send")

    commands, outbox, sent = command_service(system, lose_reply)
    await inbox(system, "/news", 2)
    await commands.tick()
    restarted = Commands(outbox, clock=lambda: NOW + timedelta(minutes=2))
    restarted.recover_interrupted()
    await restarted.tick()
    assert len(sent) == 1


async def test_assignment_revoked_while_awaiting_keychain_stops_reply(system):
    commands, _, sent = command_service(system)
    _, targets, _, _, _ = system
    await inbox(system, "/news", 2)
    entered, release = asyncio.Event(), threading.Event()
    loop = asyncio.get_running_loop()
    backend = targets.credentials.backend
    read = backend.read

    def blocked(ref):
        loop.call_soon_threadsafe(entered.set)
        assert release.wait(5)
        return read(ref)

    backend.read = blocked
    running = asyncio.create_task(commands.tick())
    try:
        await asyncio.wait_for(entered.wait(), 2)
        await targets.set_subscription("sub_world", ["bot2"], targets.store.config_revision())
    finally:
        release.set()
        await running
    assert not sent


async def test_commands_share_outbox_remote_bot_backoff(system):
    async def respond(_):
        if len(sent) == 1:
            return httpx.Response(
                429, json={"ok": False, "error_code": 429, "parameters": {"retry_after": 60}}
            )
        return ready_response()

    commands, outbox, sent = command_service(system, respond)
    _, _, job, _, _ = system
    await inbox(system, "/news", 2)
    await commands.tick()
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW + timedelta(seconds=30))
    assert len(sent) == 1
    await outbox.advance(job, "bot2", now=NOW + timedelta(seconds=30))
    assert len(sent) == 2


async def test_schedule_rejects_retime_of_inheriting_special_scope(system):
    from test_routing import account

    commands, _, sent = command_service(system)
    pipeline, _, _, _, _ = system
    revision, config = pipeline.store.load_config()
    x = next(sub for sub in config["subscriptions"] if sub["category_id"] == "x")
    x.update(enabled=True, times=["08:00"], bot_ids=["bot1"])
    special = account(config, x)
    special["bot_ids"] = ["bot2"]
    revision = pipeline.store.save_config(config, expected_revision=revision)

    await inbox(system, "/schedule s:sub_x 09:00", 2)
    await commands.tick()
    assert "08:00" not in bodies(sent)[-1]
    assert pipeline.store.config_revision() == revision

    await inbox(system, "/schedule s:sub_x 08:00", 3)
    await commands.tick()
    assert "08:00" in bodies(sent)[-1]
    assert pipeline.store.config_revision() == revision

    await inbox(system, "/schedule a:account1 10:00", 2, bot="bot2")
    await commands.tick()
    assert "10:00" in bodies(sent)[-1]
    await inbox(system, "/schedule s:sub_x 09:00", 4)
    await commands.tick()
    assert "09:00" in bodies(sent)[-1]
    _, changed = pipeline.store.load_config()
    assert changed["accounts"][0]["times"] == ["10:00"]


async def test_special_account_assignment_does_not_grant_aggregate_scope(system):
    from test_routing import account

    commands, _, sent = command_service(system)
    pipeline, targets, _, _, _ = system
    revision, config = pipeline.store.load_config()
    x = next(sub for sub in config["subscriptions"] if sub["category_id"] == "x")
    x.update(enabled=True, bot_ids=["bot1"])
    special = account(config, x)
    special.update(bot_ids=["bot2"], times=["09:42"])
    pipeline.store.save_config(config, expected_revision=revision)
    await targets.set_subscription("sub_world", ["bot1"], pipeline.store.config_revision())

    await inbox(system, "/schedule s:sub_x", 2, bot="bot2")
    await commands.tick()
    assert "09:42" not in bodies(sent)[-1]
    await inbox(system, "/schedule a:account1", 3, bot="bot2")
    await commands.tick()
    assert "09:42" in bodies(sent)[-1]


async def test_management_ui_locale_is_independent_of_validated_news(system):
    commands, _, sent = command_service(system)
    pipeline, _, _, _, _ = system
    revision, config = pipeline.store.load_config()
    config["ui_locale"] = "ja"
    pipeline.store.save_config(config, expected_revision=revision)
    await inbox(system, "/schedule", 2)
    await commands.tick()
    assert "配信時刻" in bodies(sent)[-1]
    await inbox(system, "/news", 3)
    await commands.tick()
    assert "https://example.com/a" in bodies(sent)[-1]
    assert "配信時刻" not in bodies(sent)[-1]


async def test_pause_mutates_once_and_does_not_change_shared_bot_state(system):
    commands, _, sent = command_service(system)
    pipeline, targets, job, _, _ = system
    await inbox(system, "/pause", 2)
    await commands.tick()
    await commands.tick()
    assert pipeline.get(job)["paused"]
    assert [e["action"] for e in pipeline.audit(job) if e["action"] == "pause"] == ["pause"]
    assert not targets.registry.status("bot1")["paused"]
    assert len(sent) == 1
    await inbox(system, "/resume", 3)
    await commands.tick()
    assert not pipeline.get(job)["paused"]
    assert len(sent) == 2


async def test_mixed_bot_prompts_for_media_scope_without_model_or_file_fetch(system):
    commands, _, sent = command_service(system)
    pipeline, targets, _, model_calls, _ = system
    await targets.adult_permission("bot1", True, pipeline.store.config_revision())
    await targets.set_subscription("sub_av", ["bot1"], pipeline.store.config_revision())
    revision, config = pipeline.store.load_config()
    sub = next(row for row in config["subscriptions"] if row["id"] == "sub_av")
    sub["enabled"] = True
    pipeline.store.save_config(config, expected_revision=revision)

    bot = targets.registry.client_factory(TOKEN)
    raw = update("", 2, when=NOW)
    raw["message"].pop("text")
    raw["message"]["photo"] = [{"file_id": "fixture-opaque-file", "width": 128, "height": 64}]
    bot.updates = [raw]
    await targets.registry.poll_once("bot1", now=NOW + timedelta(seconds=2))
    await commands.tick()

    text = bodies(sent)[-1]
    assert "s:sub_av" in text and "s:sub_world" in text
    assert "fixture-opaque-file" not in "\n".join(pipeline.db.iterdump())
    assert len(model_calls) == 1


async def test_command_migration_keeps_existing_inbox_and_delivery(system):
    from contextlib import closing

    from newspaw.store import Store

    pipeline, targets, job, _, path = system
    _, outbox, _ = command_service(system)
    outbox.enqueue(job, now=NOW)
    await inbox(system, "/news", 2)
    binding = targets.registry.snapshot("bot1")
    with pipeline.store._write():
        pipeline.db.execute("DROP TABLE command_replies")
        pipeline.db.execute("DROP INDEX inbox_pending")
        pipeline.db.execute("DROP INDEX command_jobs_scope")
        pipeline.db.execute("DROP INDEX delivery_message_binding")
        pipeline.db.execute("PRAGMA user_version=16")

    with closing(Store(path)) as upgraded:
        assert upgraded._db.execute("PRAGMA user_version").fetchone() == (17,)
        assert upgraded._db.execute("SELECT count(*) FROM command_replies").fetchone() == (0,)
        assert upgraded._db.execute(
            "SELECT state FROM bot_inbox WHERE bot_id=? AND generation=? AND update_id=2",
            (binding.bot_id, binding.generation),
        ).fetchone() == ("pending",)
        assert upgraded._db.execute(
            "SELECT telegram_id FROM delivery_targets WHERE job_id=? AND bot_id=?",
            (job, binding.bot_id),
        ).fetchone() == (binding.telegram_id,)
