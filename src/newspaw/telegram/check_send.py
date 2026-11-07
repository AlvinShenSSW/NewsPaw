"""Explicit, single-attempt Telegram connection checks on the shared send lane."""

from __future__ import annotations

import asyncio
import re
from contextlib import suppress
from datetime import timedelta

import httpx

from ..credentials import CredentialError
from .client import TelegramError, TelegramSendError
from .outbox import _clock, send_lane_blocked

_REQUEST = re.compile(r"^[A-Za-z0-9_.:-]{1,120}$")
_MESSAGE = {
    "en": "NewsPaw test message. Your Telegram Bot received this delivery check.",
    "zh-Hans": "NewsPaw 测试消息。已通过此 Bot 送达。",
    "ja": "NewsPaw のテストメッセージです。この Bot への配信を確認しました。",
}


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS bot_test_sends (
           id TEXT PRIMARY KEY,bot_id TEXT NOT NULL,generation INTEGER NOT NULL,
           telegram_id INTEGER NOT NULL,state TEXT NOT NULL,reason TEXT,
           backoff_until TEXT,updated_at TEXT NOT NULL)"""
    )
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS bot_test_one_inflight
           ON bot_test_sends(telegram_id) WHERE state='inflight'"""
    )


class TestSends:
    __test__ = False

    def __init__(self, registry, *, clock=_clock, client_factory=None):
        self.registry, self.store, self.db = registry, registry.store, registry.db
        self.clock = clock
        self.client_factory = registry.client_factory if client_factory is None else client_factory

    def _prior(self, identity, bot, generation):
        row = self.db.execute(
            "SELECT bot_id,generation,state,reason FROM bot_test_sends WHERE id=?", (identity,)
        ).fetchone()
        if row is None:
            return None
        if row[:2] != (bot, generation):
            raise TelegramError("request_id_conflict")
        return dict(request_id=identity, generation=generation, state=row[2], reason=row[3])

    def status(self, bot, generation, request):
        if (
            not isinstance(request, str)
            or not _REQUEST.fullmatch(request)
            or type(generation) is not int
        ):
            raise TelegramError("invalid_test_request")
        return self._prior(request, bot, generation) or dict(
            request_id=request, generation=generation, state="not_started", reason=None
        )

    def _finish(self, request, binding, error=None):
        with self.store._write():
            backoff = None
            if error is None:
                state, reason = "confirmed", None
            elif error.kind in {
                "token_revoked",
                "forbidden",
                "payload_rejected",
                "rate_limited",
                "rate_limit_invalid",
            }:
                state, reason = "failed", error.kind
                if error.kind == "rate_limited":
                    backoff = (self.clock() + timedelta(seconds=error.retry_after)).isoformat()
                if error.kind in {"token_revoked", "forbidden"}:
                    self.registry.revoke_send_binding(binding, error.kind)
            else:
                state, reason = "outcome_unknown", "outcome_unknown"
            self.db.execute(
                """UPDATE bot_test_sends SET state=?,reason=?,backoff_until=?,updated_at=?
                   WHERE id=? AND state='inflight'""",
                (state, reason, backoff, self.clock().isoformat(), request),
            )
            return self._prior(request, binding.bot_id, binding.generation)

    async def send(self, bot, generation, request):
        if (
            not isinstance(request, str)
            or not _REQUEST.fullmatch(request)
            or type(generation) is not int
            or generation < 1
        ):
            raise TelegramError("invalid_test_request")
        existing = self._prior(request, bot, generation)
        if existing is not None:
            return existing
        binding = self.registry.snapshot(bot)
        if binding.generation != generation:
            raise TelegramError("binding_changed")
        client = None
        try:
            try:
                token = await asyncio.to_thread(self.registry.backend.read, binding.credential_ref)
                client = self.client_factory(token)
            except (CredentialError, OSError):
                raise TelegramError("credential_unavailable") from None
            with self.store._write():
                existing = self._prior(request, bot, generation)
                if existing is not None:
                    return existing
                self.registry._expect_generation(bot, generation)
                self.registry.revalidate(binding)
                now = self.clock()
                if send_lane_blocked(self.db, binding.telegram_id, now):
                    raise TelegramError("send_lane_busy")
                locale = self.store.load_config()[1]["ui_locale"]
                self.db.execute(
                    "INSERT INTO bot_test_sends VALUES (?,?,?,?,'inflight',NULL,NULL,?)",
                    (request, bot, generation, binding.telegram_id, now.isoformat()),
                )
            try:
                await client.send_message(binding, _MESSAGE[locale])
            except asyncio.CancelledError:
                self._finish(request, binding, TelegramSendError("cancelled_after_intent"))
                raise
            except TelegramSendError as exc:
                return self._finish(request, binding, exc)
            return self._finish(request, binding)
        finally:
            if client is not None:
                with suppress(httpx.HTTPError, OSError):
                    await client.close()

    def recover_interrupted(self):
        with self.store._write():
            self.db.execute(
                """UPDATE bot_test_sends SET state='outcome_unknown',reason='interrupted'
                   WHERE state='inflight'"""
            )
