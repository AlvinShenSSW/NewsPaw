"""Bounded multipart transcription through the official OpenAI audio endpoint."""

from __future__ import annotations

import re

import httpx

from ..providers import ProviderError, _usage
from ..transport import provider_client
from .audio import MAX_WAV

_ORIGIN = "https://api.openai.com"
_ENDPOINT = _ORIGIN + "/v1/audio/transcriptions"
_MAX_RESPONSE = 64 * 1024


def supported_stt_profile(profile):
    return (
        profile["partition"] == "normal"
        and profile["provider"] == "openai"
        and profile["base_url"].rstrip("/") == _ORIGIN + "/v1"
        and bool(profile["credential_ref"])
    )


class TranscriptionProvider:
    def __init__(self, profile, key, *, client=None):
        if not supported_stt_profile(profile):
            raise ProviderError("stt_capability_unavailable")
        if not isinstance(key, str) or not re.fullmatch(r"[!-~]{1,4096}", key):
            raise ProviderError("credential_unavailable")
        self.model, self.key = profile["model"], key
        self.client = client or provider_client(_ORIGIN, max_bytes=_MAX_RESPONSE, deadline=55)

    async def close(self):
        await self.client.aclose()

    async def transcribe(self, audio):
        if (
            not isinstance(audio, bytes)
            or not 44 <= len(audio) <= MAX_WAV
            or audio[:4] != b"RIFF"
            or audio[8:12] != b"WAVE"
        ):
            raise ProviderError("invalid_audio")
        try:
            result = await self.client.post(
                _ENDPOINT,
                headers={"Authorization": "Bearer " + self.key},
                data={"model": self.model, "response_format": "json"},
                files={"file": ("speech.wav", audio, "audio/wav")},
                follow_redirects=False,
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise ProviderError("connection_failed") from None
        except (httpx.RequestError, OSError, TimeoutError):
            raise ProviderError("outcome_unknown", outcome="unknown") from None
        if result.status_code != 200:
            reason = {
                400: "invalid_audio",
                401: "authentication_failed",
                403: "permission_denied",
                404: "model_unavailable",
                429: "rate_limited",
            }.get(result.status_code, "provider_failed")
            raise ProviderError(reason, outcome="known")
        try:
            if len(result.content) > _MAX_RESPONSE:
                raise ValueError()
            body = result.json()
            transcript = body.get("text") if isinstance(body, dict) else None
            if not isinstance(transcript, str) or len(transcript) > 2000:
                raise ValueError()
            text = " ".join(transcript.split())
            if not text or any(ord(char) < 32 for char in text):
                raise ValueError()
            return text, _usage(body.get("usage"))
        except (ValueError, RecursionError):
            raise ProviderError("invalid_transcript", outcome="known") from None
