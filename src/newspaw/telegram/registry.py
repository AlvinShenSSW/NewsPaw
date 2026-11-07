"""One owner's independent Bot bindings and durable inbound cursors."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import secrets
import sqlite3
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime

from ..credentials import CredentialError
from .client import TelegramClient, TelegramError


def _json(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def _now(value=None):
    value = datetime.now(UTC) if value is None else value
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise TelegramError("invalid_time")
    return value.timestamp()


def _id(value):
    return type(value) is int and 0 < value <= 2**52


def _initial():
    return dict(
        verified=False,
        paired=False,
        paused=False,
        polling=False,
        chat_id=None,
        cursor=None,
        cursor_bot_id=None,
        status="unverified",
        username="",
        display_name="",
        next_poll_at=0,
        cutover=0,
        pair_hash=None,
        pair_salt=None,
        pair_issued=0,
        pair_expires=0,
        pair_tries=0,
    )


def _clear_pair(state):
    state.update(pair_hash=None, pair_salt=None, pair_issued=0, pair_expires=0, pair_tries=0)


def _revoke(row):
    row["generation"] += 1
    state = row["state"]
    state.update(verified=False, paired=False, polling=False, chat_id=None)
    _clear_pair(state)


def remove_bot(config, identity):
    """Remove a Bot and all of its configured assignments in place."""
    config["bots"] = [b for b in config["bots"] if b["id"] != identity]
    for group in ("subscriptions", "accounts"):
        for entry in config[group]:
            if entry["bot_ids"] is not None:
                entry["bot_ids"] = [key for key in entry["bot_ids"] if key != identity]


def initialize(db):
    first = not db.execute("SELECT 1 FROM sqlite_master WHERE name='bot_registrations'").fetchone()
    db.execute(
        "CREATE TABLE IF NOT EXISTS bot_registrations (id TEXT PRIMARY KEY,generation INTEGER NOT NULL,credential_ref TEXT,remote_id INTEGER,active INTEGER NOT NULL,payload TEXT NOT NULL)"
    )
    db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS bot_remote_identity ON bot_registrations(remote_id) WHERE active=1 AND remote_id IS NOT NULL"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS bot_inbox (bot_id TEXT NOT NULL,generation INTEGER NOT NULL,update_id INTEGER NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(bot_id,generation,update_id))"
    )
    if first:
        config = json.loads(
            db.execute("SELECT document FROM app_configuration WHERE id=1").fetchone()[0]
        )
        changed = False
        for bot in config["bots"]:
            if (
                bot["verified"]
                or bot["paired"]
                or bot["telegram_id"] is not None
                or bot["chat_id"] is not None
            ):
                bot.update(verified=False, paired=False, telegram_id=None, chat_id=None)
                changed = True
        if changed:
            db.execute(
                "UPDATE app_configuration SET document=?,revision=revision+1 WHERE id=1",
                (_json(config),),
            )


def _projection(config, identity, remote, state, active):
    bot = next((b for b in config["bots"] if b["id"] == identity), None)
    if bot is not None:
        verified = bool(active and state["verified"])
        paired = bool(verified and state["paired"] and not state["paused"])
        bot.update(
            verified=verified,
            paired=paired,
            telegram_id=remote if verified else None,
            chat_id=state["chat_id"] if paired else None,
        )


def invalidate_bots(db, current, document):
    """Every ordinary config transaction invalidates known registrations before commit."""
    result = deepcopy(document)
    old = {b["id"]: b for b in current["bots"]}
    new = {b["id"]: b for b in result["bots"]}
    owner_changed = current["owner_id"] != result["owner_id"]
    for key, generation, ref, remote, active, payload in db.execute(
        "SELECT * FROM bot_registrations"
    ).fetchall():
        state = json.loads(payload)
        changed = (
            owner_changed or key not in new or key not in old or ref != new[key]["credential_ref"]
        )
        if changed:
            generation += 1
            state = {
                **_initial(),
                "cursor": state["cursor"],
                "cursor_bot_id": state["cursor_bot_id"],
            }
            ref = new[key]["credential_ref"] if key in new else None
            active = int(key in new)
            remote = None
            db.execute(
                "UPDATE bot_registrations SET generation=?,credential_ref=?,remote_id=?,active=?,payload=? WHERE id=?",
                (generation, ref, remote, active, _json(state), key),
            )
        db.execute(
            "UPDATE bot_inbox SET state='stale',payload='{}' WHERE bot_id=? AND generation<>? AND state='pending'",
            (key, generation),
        )
        _projection(result, key, remote, state, active)
    return result


@dataclass(frozen=True)
class Binding:
    bot_id: str
    generation: int
    credential_ref: str
    telegram_id: int
    chat_id: int
    owner_id: int


class BotRegistry:
    def __init__(self, store, backend, *, client_factory=TelegramClient):
        self.store, self.db, self.backend = store, store._db, backend
        self.client_factory = client_factory
        self._locks = {}
        self._workers = {}
        self._supervisor = None

    def _bot(self, identity):
        config = self.store.load_config()[1]
        bot = next((b for b in config["bots"] if b["id"] == identity), None)
        if bot is None:
            raise TelegramError("missing_bot")
        return config, bot

    def _row(self, identity):
        row = self.db.execute(
            "SELECT generation,credential_ref,remote_id,active,payload FROM bot_registrations WHERE id=?",
            (identity,),
        ).fetchone()
        if row is None:
            raise TelegramError("unregistered_bot")
        return dict(
            id=identity,
            generation=row[0],
            credential_ref=row[1],
            remote_id=row[2],
            active=bool(row[3]),
            state=json.loads(row[4]),
        )

    def _ensure(self, identity):
        _, bot = self._bot(identity)
        row = self.db.execute("SELECT 1 FROM bot_registrations WHERE id=?", (identity,)).fetchone()
        if row is None:
            self.db.execute(
                "INSERT INTO bot_registrations VALUES (?,1,?,NULL,1,?)",
                (identity, bot["credential_ref"], _json(_initial())),
            )
        return self._row(identity)

    def _save(self, row, config=None):
        self.db.execute(
            "UPDATE bot_registrations SET generation=?,credential_ref=?,remote_id=?,active=?,payload=? WHERE id=?",
            (
                row["generation"],
                row["credential_ref"],
                row["remote_id"],
                int(row["active"]),
                _json(row["state"]),
                row["id"],
            ),
        )
        self.db.execute(
            "UPDATE bot_inbox SET state='stale',payload='{}' WHERE bot_id=? AND generation<>? AND state='pending'",
            (row["id"], row["generation"]),
        )
        current = self.store.load_config()[1]
        config = deepcopy(current) if config is None else config
        _projection(config, row["id"], row["remote_id"], row["state"], row["active"])
        if config != current:
            self.db.execute(
                "UPDATE app_configuration SET document=?,revision=revision+1 WHERE id=1",
                (_json(config),),
            )

    def status(self, identity):
        _, bot = self._bot(identity)
        try:
            row = self._row(identity)
        except TelegramError:
            row = dict(
                generation=0,
                credential_ref=bot["credential_ref"],
                remote_id=None,
                active=False,
                state=_initial(),
            )
        state = row["state"]
        return dict(
            id=identity,
            name=bot["name"],
            generation=row["generation"],
            telegram_id=row["remote_id"],
            verified=bool(row["active"] and state["verified"]),
            paired=bool(row["active"] and state["verified"] and state["paired"]),
            paused=state["paused"],
            chat_id=state["chat_id"],
            cursor=state["cursor"],
            status=state["status"],
            polling=state["polling"],
            next_poll_at=state["next_poll_at"],
            username=state["username"],
            display_name=state["display_name"],
            token_exclusive_required=True,
        )

    def list(self):
        return [self.status(b["id"]) for b in self.store.load_config()[1]["bots"]]

    def snapshot(self, identity):
        config, bot = self._bot(identity)
        row = self._row(identity)
        state = row["state"]
        if (
            not row["active"]
            or row["credential_ref"] != bot["credential_ref"]
            or not state["verified"]
            or not state["paired"]
            or state["paused"]
            or not _id(config["owner_id"])
            or state["chat_id"] != config["owner_id"]
        ):
            raise TelegramError("binding_not_ready")
        return Binding(
            identity,
            row["generation"],
            row["credential_ref"],
            row["remote_id"],
            state["chat_id"],
            config["owner_id"],
        )

    def revalidate(self, binding):
        if not isinstance(binding, Binding) or self.snapshot(binding.bot_id) != binding:
            raise TelegramError("binding_changed")
        return binding

    def revoke_send_binding(self, binding, reason):
        """Called in the receipt transaction for a verified rejection."""
        try:
            self.revalidate(binding)
            row = self._current(binding.bot_id, binding.generation)
        except TelegramError:
            return
        row["state"]["status"] = reason
        _revoke(row)
        self._save(row)

    def _current(self, identity, generation):
        _, bot = self._bot(identity)
        row = self._row(identity)
        if (
            not row["active"]
            or row["generation"] != generation
            or row["credential_ref"] != bot["credential_ref"]
        ):
            raise TelegramError("binding_changed")
        return row

    async def _client(self, row):
        if row["credential_ref"] is None:
            raise TelegramError("missing_token")
        try:
            token = await asyncio.to_thread(self.backend.read, row["credential_ref"])
        except CredentialError as exc:
            raise TelegramError(str(exc)) from None
        self._current(row["id"], row["generation"])
        return self.client_factory(token)

    def _expect_generation(self, identity, generation):
        if generation is not None and (
            type(generation) is not int or self.status(identity)["generation"] != generation
        ):
            raise TelegramError("binding_changed")

    async def verify(self, identity, *, now=None, generation=None):
        _now(now)
        async with self._locks.setdefault(identity, asyncio.Lock()):
            with self.store._write():
                self._expect_generation(identity, generation)
                row = self._ensure(identity)
                prior = deepcopy(row)
                row["generation"] += 1
                row["state"].update(verified=False, paired=False, polling=False, status="verifying")
                _clear_pair(row["state"])
                self._save(row)
            client = None
            error = None
            me = None
            try:
                client = await self._client(row)
                me = await client.call("getMe")
                self._current(identity, row["generation"])
                if (
                    not isinstance(me, dict)
                    or not _id(me.get("id"))
                    or me.get("is_bot") is not True
                ):
                    raise TelegramError("malformed_identity")
                webhook = await client.call("getWebhookInfo")
                if not isinstance(webhook, dict) or not isinstance(webhook.get("url"), str):
                    raise TelegramError("malformed_response")
                if webhook["url"]:
                    raise TelegramError("webhook_conflict")
            except TelegramError as exc:
                error = exc
            finally:
                if client is not None:
                    await client.close()
            with self.store._write():
                row = self._current(identity, row["generation"])
                state = row["state"]
                if error is None:
                    duplicate = self.db.execute(
                        "SELECT 1 FROM bot_registrations WHERE remote_id=? AND active=1 AND id<>?",
                        (me["id"], identity),
                    ).fetchone()
                    if duplicate:
                        error = TelegramError("duplicate_bot")
                if error is not None:
                    state.update(
                        status=error.kind, verified=False, paired=False, polling=False, chat_id=None
                    )
                else:
                    if state["cursor_bot_id"] != me["id"]:
                        state["cursor"] = None
                    same = prior["remote_id"] == me["id"] and prior["state"]["verified"]
                    row["remote_id"] = me["id"]
                    state.update(
                        verified=True,
                        status="verified",
                        cursor_bot_id=me["id"],
                        username=me.get("username", "")[:100]
                        if isinstance(me.get("username", ""), str)
                        else "",
                        display_name=me.get("first_name", "")[:100]
                        if isinstance(me.get("first_name", ""), str)
                        else "",
                        paired=bool(same and prior["state"]["paired"]),
                        chat_id=prior["state"]["chat_id"] if same else None,
                        polling=bool(same and prior["state"]["polling"]),
                        next_poll_at=0,
                    )
                self._save(row)
            return self.status(identity)

    def pair_code(self, identity, *, now=None, generation=None):
        when = _now(now)
        code = secrets.token_urlsafe(24)
        salt = secrets.token_hex(16)
        with self.store._write():
            self._expect_generation(identity, generation)
            row = self._row(identity)
            self._current(identity, row["generation"])
            state = row["state"]
            if not state["verified"]:
                raise TelegramError("bot_not_verified")
            row["generation"] += 1
            state.update(
                pair_hash=hashlib.sha256((salt + code).encode()).hexdigest(),
                pair_salt=salt,
                pair_issued=when,
                pair_expires=when + 600,
                pair_tries=0,
                paired=False,
                chat_id=None,
                paused=False,
                polling=True,
                status="awaiting_pair",
                next_poll_at=0,
                cutover=when,
            )
            self._save(row)
        return dict(code=code, expires_at=when + 600, max_attempts=5)

    def action(self, identity, action, *, now=None, generation=None):
        if action not in {"pause", "resume", "unbind"}:
            raise TelegramError("invalid_bot_action")
        when = _now(now)
        with self.store._write():
            self._expect_generation(identity, generation)
            row = self._row(identity)
            self._current(identity, row["generation"])
            state = row["state"]
            row["generation"] += 1
            _clear_pair(state)
            if action == "unbind":
                state.update(
                    paired=False, chat_id=None, polling=False, status="unpaired", cutover=when
                )
            elif action == "pause":
                state.update(paused=True, polling=False, status="paused", cutover=when)
            else:
                if not state["verified"] or not state["paired"]:
                    raise TelegramError("binding_not_ready")
                state.update(
                    paused=False, polling=True, status="paired", cutover=when, next_poll_at=0
                )
            self._save(row)
        return self.status(identity)

    async def delete(self, identity, manager, revision):
        actual, config = self.store.load_config()
        if actual != revision:
            raise TelegramError("config_conflict")
        self._bot(identity)
        remove_bot(config, identity)
        return await manager.save_config(config, revision)

    def inbox(self, identity, limit=100):
        self._bot(identity)
        if type(limit) is not int or not 1 <= limit <= 1000:
            raise TelegramError("invalid_limit")
        return [
            dict(generation=g, update_id=u, payload=json.loads(p), state=s)
            for g, u, p, s in self.db.execute(
                "SELECT generation,update_id,payload,state FROM bot_inbox WHERE bot_id=? AND state<>'pair_seen' ORDER BY rowid LIMIT ?",
                (identity, limit),
            )
        ]

    def _message(self, update):
        message = update.get("message")
        if not isinstance(message, dict) or "business_connection_id" in message:
            return None
        chat = message.get("chat")
        sender = message.get("from")
        if (
            not isinstance(chat, dict)
            or not isinstance(sender, dict)
            or chat.get("type") != "private"
            or not _id(sender.get("id"))
            or sender.get("is_bot") is not False
            or chat.get("id") != sender["id"]
            or not _id(message.get("message_id"))
            or type(message.get("date")) is not int
            or message["date"] < 0
        ):
            return None
        result = {key: message[key] for key in ("message_id", "date")}
        result.update(chat_id=chat["id"], sender_id=sender["id"])
        for key, maximum in [("text", 4096), ("caption", 1024)]:
            if key in message:
                if not isinstance(message[key], str) or len(message[key]) > maximum:
                    raise TelegramError("malformed_update")
                result[key] = message[key]
        reply = message.get("reply_to_message")
        if isinstance(reply, dict) and _id(reply.get("message_id")):
            result["reply_to_message_id"] = reply["message_id"]
        for kind in ("photo", "voice", "audio", "document", "video"):
            media = message.get(kind)
            if kind == "photo" and isinstance(media, list):
                media = media[-1] if 0 < len(media) <= 20 else None
            if isinstance(media, dict):
                file_id = media.get("file_id")
                if not isinstance(file_id, str) or not 1 <= len(file_id) <= 512:
                    raise TelegramError("malformed_update")
                result["media"] = dict(kind=kind, file_id=file_id)
                for key in ("file_size", "duration", "width", "height"):
                    if type(media.get(key)) is int and 0 <= media[key] <= 2**52:
                        result["media"][key] = media[key]
        if len(_json(result).encode()) > 32768:
            raise TelegramError("update_too_large")
        return result

    def _updates(self, updates):
        if not isinstance(updates, list) or len(updates) > 100:
            raise TelegramError("malformed_updates")
        unique = {}
        for update in updates:
            if (
                not isinstance(update, dict)
                or type(update.get("update_id")) is not int
                or not 0 <= update["update_id"] <= 2**31 - 1
            ):
                raise TelegramError("malformed_updates")
            key = update["update_id"]
            if key in unique and unique[key] != update:
                raise TelegramError("malformed_updates")
            unique[key] = update
        return [(key, self._message(unique[key])) for key in sorted(unique)]

    def _consume(self, row, updates, when):
        state = row["state"]
        config = self.store.load_config()[1]
        incoming = []
        for update_id, message in updates:
            if message is None:
                continue
            text = message.get("text", "")
            if text.startswith("/pair"):
                parts = text.split()
                valid_shape = len(parts) == 2 and parts[0] == "/pair" and len(parts[1]) <= 128
                if self.db.execute(
                    "SELECT 1 FROM bot_inbox WHERE bot_id=? AND generation=? AND update_id=?",
                    (row["id"], row["generation"], update_id),
                ).fetchone():
                    continue
                if (
                    state["pair_hash"]
                    and state["pair_expires"] > when
                    and state["pair_tries"] < 5
                    and message["date"] >= int(state["pair_issued"])
                ):
                    # A code-free marker prevents a replay consuming another attempt.
                    self.db.execute(
                        "INSERT INTO bot_inbox VALUES (?,?,?,'{}','pair_seen')",
                        (row["id"], row["generation"], update_id),
                    )
                    matches = valid_shape and hmac.compare_digest(
                        hashlib.sha256((state["pair_salt"] + parts[1]).encode()).hexdigest(),
                        state["pair_hash"],
                    )
                    owner = config["owner_id"]
                    if matches and (owner is None or owner == message["sender_id"]):
                        if owner is None:
                            prior_config = deepcopy(config)
                            config["owner_id"] = message["sender_id"]
                            config = invalidate_bots(self.db, prior_config, config)
                            # Preserve only the pair established by this transaction;
                            # every pre-owner-change registration has been revoked.
                            row["generation"] += 1
                        state.update(
                            paired=True, chat_id=message["chat_id"], status="paired", cutover=when
                        )
                        _clear_pair(state)
                    else:
                        state["pair_tries"] += 1
                        if state["pair_tries"] >= 5:
                            _clear_pair(state)
                            state.update(polling=False, status="pair_attempts_exhausted")
                continue
            if (
                state["paired"]
                and message["sender_id"] == config["owner_id"] == state["chat_id"]
                and message["date"] >= int(state["cutover"])
            ):
                incoming.append(
                    (row["id"], row["generation"], update_id, _json(message), "pending")
                )
        existing = self.db.execute(
            "SELECT count(*) FROM bot_inbox WHERE bot_id=? AND state='pending'", (row["id"],)
        ).fetchone()[0]
        new = [
            item
            for item in incoming
            if not self.db.execute(
                "SELECT 1 FROM bot_inbox WHERE bot_id=? AND generation=? AND update_id=?", item[:3]
            ).fetchone()
        ]
        if existing + len(new) > 1000:
            raise TelegramError("inbox_full")
        self.db.executemany("INSERT INTO bot_inbox VALUES (?,?,?,?,?)", new)
        if updates:
            state["cursor"] = updates[-1][0]
        self._save(row, config)

    async def poll_once(self, identity, *, now=None):
        when = _now(now)
        async with self._locks.setdefault(identity, asyncio.Lock()):
            row = self._row(identity)
            self._current(identity, row["generation"])
            state = row["state"]
            if (
                not state["polling"]
                or not state["verified"]
                or state["paused"]
                or state["next_poll_at"] > when
            ):
                return self.status(identity)
            if not state["paired"] and state["pair_expires"] <= when:
                with self.store._write():
                    _clear_pair(state)
                    state.update(polling=False, status="pair_expired")
                    self._save(row)
                return self.status(identity)
            if (
                self.db.execute(
                    "SELECT count(*) FROM bot_inbox WHERE bot_id=? AND state='pending'", (identity,)
                ).fetchone()[0]
                >= 1000
            ):
                with self.store._write():
                    current = self._current(identity, row["generation"])
                    current["state"]["status"] = "inbox_full"
                    self._save(current)
                return self.status(identity)
            client = None
            try:
                client = await self._client(row)
                params = dict(timeout=25, limit=100, allowed_updates='["message"]')
                if state["cursor"] is not None:
                    params["offset"] = state["cursor"] + 1
                updates = self._updates(await client.call("getUpdates", params))
                with self.store._write():
                    current = self._current(identity, row["generation"])
                    current["state"].update(
                        next_poll_at=0,
                        status="paired" if current["state"]["paired"] else "awaiting_pair",
                    )
                    self._consume(current, updates, _now(now))
            except TelegramError as exc:
                with self.store._write():
                    current = self._current(identity, row["generation"])
                    s = current["state"]
                    s.update(
                        status=exc.kind,
                        next_poll_at=_now(now)
                        + (exc.retry_after if exc.retry_after is not None else 5),
                    )
                    if exc.kind in {"token_revoked", "forbidden", "consumer_conflict"}:
                        _revoke(current)
                    self._save(current)
            finally:
                if client is not None:
                    await client.close()
            return self.status(identity)

    async def _worker(self, identity):
        try:
            while True:
                status = self.status(identity)
                if not status["polling"] or not status["verified"] or status["paused"]:
                    return
                try:
                    await self.poll_once(identity)
                except (TelegramError, sqlite3.Error):
                    # Cursor remains durable; no response bodies/credential URLs are logged.
                    await asyncio.sleep(5)
                await asyncio.sleep(1)
        except TelegramError:
            return

    async def _supervise(self):
        while True:
            desired = {
                s["id"] for s in self.list() if s["polling"] and s["verified"] and not s["paused"]
            }
            for identity, task in list(self._workers.items()):
                if task.done():
                    if not task.cancelled():
                        task.exception()
                    del self._workers[identity]
                elif identity not in desired:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                    del self._workers[identity]
            for identity in desired - self._workers.keys():
                self._workers[identity] = asyncio.create_task(self._worker(identity))
            await asyncio.sleep(0.5)

    async def start(self):
        if self._supervisor is None:
            with self.store._write():
                for (identity,) in self.db.execute("SELECT id FROM bot_registrations").fetchall():
                    row = self._row(identity)
                    if row["state"]["status"] == "verifying":
                        row["state"]["status"] = "verification_interrupted"
                        self._save(row)
            self._supervisor = asyncio.create_task(self._supervise())

    async def close(self):
        tasks = list(self._workers.values())
        if self._supervisor is not None:
            tasks.append(self._supervisor)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._workers.clear()
        self._supervisor = None
