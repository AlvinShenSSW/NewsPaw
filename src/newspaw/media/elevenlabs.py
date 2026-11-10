"""Bounded speech through the official ElevenLabs endpoint, with its ledger hold and key check."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
from contextlib import suppress
from datetime import UTC, datetime

import httpx

from ..app_config import VOICE_ID
from ..budget import BudgetError, BudgetLedger
from ..credentials import CredentialError
from ..providers import _ID, ProviderError
from ..transport import SafeHTTPError, provider_client
from .audio import MAX_SPEECH, MediaInputError, speech_text

_ORIGIN = "https://api.elevenlabs.io"
_ENDPOINT = _ORIGIN + "/v1/text-to-speech/"
_MODEL = "eleven_multilingual_v2"
# 4,000 bytes a second: a reply of at most MAX_SPEECH (1 MiB) holds about 262 s of speech.
_FORMAT = "mp3_22050_32"
# Chinese is read at roughly 4.5 characters a second, so this many fit that reply (R18-B1).
_MAX_TEXT = 900
_CHECK_TEXT = "NewsPaw audio test."


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS speech_checks (
           request_id TEXT PRIMARY KEY,credential_ref TEXT NOT NULL,voice_id TEXT NOT NULL,
           started_at TEXT NOT NULL,finished_at TEXT,result_json TEXT NOT NULL)"""
    )


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _now():
    return datetime.now(UTC).isoformat()


def _mp3(data):
    return data[:3] == b"ID3" or (len(data) > 1 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0)


class ElevenLabsSpeech:
    def __init__(self, key, voice_id, *, client=None):
        if not isinstance(key, str) or not re.fullmatch(r"[!-~]{1,4096}", key):
            raise ProviderError("credential_unavailable")
        if not isinstance(voice_id, str) or not VOICE_ID.fullmatch(voice_id):
            raise ProviderError("invalid_voice_request")
        self.key, self.voice_id = key, voice_id
        self.client = client or provider_client(_ORIGIN, max_bytes=MAX_SPEECH, deadline=60)

    async def close(self):
        await self.client.aclose()

    async def synthesize(self, text):
        try:
            text = speech_text(text)[:_MAX_TEXT]
        except MediaInputError:
            raise ProviderError("invalid_speech_text") from None
        try:
            result = await self.client.post(
                _ENDPOINT + self.voice_id,
                params={"output_format": _FORMAT},
                headers={"xi-api-key": self.key},
                json={"text": text, "model_id": _MODEL},
                follow_redirects=False,
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise ProviderError("connection_failed") from None
        except SafeHTTPError as exc:
            if exc.kind == "response_too_large":
                raise ProviderError("invalid_speech_audio", outcome="known") from None
            if exc.kind in {
                "invalid_address",
                "private_address",
                "unsafe_url",
                "unsafe_host",
                "provider_origin_mismatch",
                "dns_failure",
                "dns_answer_limit",
            }:
                raise ProviderError("connection_failed") from None
            raise ProviderError("outcome_unknown", outcome="unknown") from None
        except (httpx.RequestError, OSError, TimeoutError):
            raise ProviderError("outcome_unknown", outcome="unknown") from None
        if result.status_code != 200:
            reason = {
                401: "authentication_failed",
                403: "permission_denied",
                404: "invalid_voice_request",
                422: "invalid_voice_request",
                429: "rate_limited",
            }.get(result.status_code, "provider_failed")
            raise ProviderError(reason, outcome="known")
        audio = result.content
        if not 1 <= len(audio) <= MAX_SPEECH or not _mp3(audio):
            raise ProviderError("invalid_speech_audio", outcome="known")
        return audio


class ElevenLabs:
    """The owner's one ElevenLabs connection: `/listen` audio and the Connect page's test."""

    def __init__(self, store, backend, *, hold, factory=ElevenLabsSpeech):
        self.store, self.db, self.backend = store, store._db, backend
        self.budget, self.hold, self.factory = BudgetLedger(store), hold, factory

    def _settings(self):
        return self.store.load_config()[1]["speech_api"]

    def configured(self):
        return self._settings()["credential_ref"] is not None

    async def _synthesize(self, attempt_id, settings, text, guard=None):
        """One synthesis under a ledger hold taken before the request; the hold stays an
        unpriced amount unless the request is known not to have left. `guard` is asked once
        more in the transaction that takes the hold: reading the key may have taken a while."""
        key = await asyncio.to_thread(self.backend.read, settings["credential_ref"])
        if key is None:
            raise ProviderError("credential_missing")
        if self._settings() != settings:
            raise ProviderError("configuration_changed")
        adapter = self.factory(key, settings["voice_id"])
        try:
            with self.store._write():
                if guard is not None and not guard():
                    raise ProviderError("speech_scope_changed")
                self.budget._reserve(
                    attempt_id,
                    attempt_id,
                    max_units=self.hold,
                    quote={"known": False, "source": "manual_hold"},
                    partition="normal",
                    provider="elevenlabs",
                    operation="tts",
                )
                self.budget._begin_attempt(attempt_id)
            try:
                audio = await adapter.synthesize(text)
            except asyncio.CancelledError:
                self.budget.mark_unknown(attempt_id)
                raise
            except ProviderError as exc:
                if exc.outcome == "unknown":
                    self.budget.mark_unknown(attempt_id)
                else:
                    self.budget.settle(
                        attempt_id,
                        units=0 if exc.outcome == "not_sent" else None,
                        cost_source="usage_derived",
                    )
                raise
            self.budget.settle(attempt_id, units=None)
            return audio
        finally:
            with suppress(httpx.HTTPError, OSError):
                await adapter.close()

    async def speak(self, update_key, text, guard=None):
        """`/listen` audio for one Telegram update; any failure is `speech_unavailable`."""
        attempt_id = "speech." + hashlib.sha256(_json(update_key).encode()).hexdigest()
        try:
            return await self._synthesize(attempt_id, self._settings(), text, guard)
        except (BudgetError, ProviderError, CredentialError, OSError):
            raise MediaInputError("speech_unavailable") from None

    def status(self):
        settings = self._settings()
        row = self.db.execute(
            "SELECT credential_ref,voice_id,result_json FROM speech_checks"
            " ORDER BY rowid DESC LIMIT 1"
        ).fetchone()
        check = None
        if row is not None:
            record = json.loads(row[2])
            current = row[:2] == (settings["credential_ref"], settings["voice_id"])
            # A check made with another key or voice says nothing about this one.
            check = {**record, "state": record["status"] if current else "stale"}
        return {
            "has_key": settings["credential_ref"] is not None,
            "voice_id": settings["voice_id"],
            "check": check,
        }

    def _finish(self, request_id, result):
        with self.store._write():
            previous = self.db.execute(
                "SELECT result_json FROM speech_checks WHERE request_id=?", (request_id,)
            ).fetchone()[0]
            result = {**json.loads(previous), **result, "checked_at": _now()}
            self.db.execute(
                "UPDATE speech_checks SET finished_at=?,result_json=? WHERE request_id=?",
                (result["checked_at"], _json(result), request_id),
            )
        return result

    async def check(self, request_id):
        """Synthesizes one fixed short sentence with the saved key and voice. A request id
        names one check: asking again returns its record and never a second synthesis."""
        if not isinstance(request_id, str) or not _ID.fullmatch(request_id):
            raise ProviderError("invalid_speech_check")
        with self.store._write():
            existing = self.db.execute(
                "SELECT result_json FROM speech_checks WHERE request_id=?", (request_id,)
            ).fetchone()
            if existing:
                return json.loads(existing[0])
            settings = self._settings()
            if settings["credential_ref"] is None:
                raise ProviderError("credential_missing")
            pending = dict(
                request_id=request_id, status="pending", error_kind=None, checked_at=None
            )
            self.db.execute(
                "INSERT INTO speech_checks VALUES (?,?,?,?,NULL,?)",
                (
                    request_id,
                    settings["credential_ref"],
                    settings["voice_id"],
                    _now(),
                    _json(pending),
                ),
            )
        attempt_id = "speech.check." + request_id
        try:
            await self._synthesize(attempt_id, settings, _CHECK_TEXT)
        except asyncio.CancelledError:
            sent = self.budget._get(attempt_id) is not None
            self._finish(
                request_id,
                {"status": "outcome_unknown" if sent else "cancelled", "error_kind": "cancelled"},
            )
            raise
        except BudgetError as exc:
            return self._finish(request_id, {"status": "budget_blocked", "error_kind": str(exc)})
        except (ProviderError, CredentialError) as exc:
            unknown = isinstance(exc, ProviderError) and exc.outcome == "unknown"
            return self._finish(
                request_id,
                {"status": "outcome_unknown" if unknown else "failed", "error_kind": str(exc)},
            )
        return self._finish(request_id, {"status": "verified"})

    def recover_interrupted(self):
        with self.store._write():
            rows = self.db.execute(
                "SELECT request_id,result_json FROM speech_checks WHERE finished_at IS NULL"
            ).fetchall()
            for request_id, payload in rows:
                result = {
                    **json.loads(payload),
                    "status": "outcome_unknown",
                    "error_kind": "interrupted",
                    "checked_at": _now(),
                }
                self.db.execute(
                    "UPDATE speech_checks SET finished_at=?,result_json=? WHERE request_id=?",
                    (result["checked_at"], _json(result), request_id),
                )
