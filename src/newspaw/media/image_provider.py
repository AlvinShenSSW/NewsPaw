"""Bounded raster generation through the official OpenAI Images endpoint."""

from __future__ import annotations

import base64

import httpx

from ..providers import ProviderError
from ..transport import SafeHTTPError, provider_client

_ORIGIN = "https://api.openai.com"
_ENDPOINT = _ORIGIN + "/v1/images/generations"
_MAX_RESPONSE = 7 * 1024 * 1024
_MAX_RASTER = 5 * 1024 * 1024


_IMAGE_MODEL_PREFIXES = ("gpt-image-", "dall-e-")


def image_model(model_id):
    """An image-only model: it generates images and has no text endpoint, so its key is
    checked with an image request. The app's `ModelNames.generatesImages` is the same rule."""
    return isinstance(model_id, str) and model_id.lower().startswith(_IMAGE_MODEL_PREFIXES)


def supported_image_profile(profile):
    return (
        profile["partition"] == "normal"
        and profile["provider"] == "openai"
        and profile["base_url"].rstrip("/") == _ORIGIN + "/v1"
        and bool(profile["credential_ref"])
    )


class ImageProvider:
    def __init__(self, profile, key, *, client=None):
        if not supported_image_profile(profile):
            raise ProviderError("image_capability_unavailable")
        if (
            not isinstance(key, str)
            or not 1 <= len(key) <= 4096
            or any(not 33 <= ord(char) <= 126 for char in key)
        ):
            raise ProviderError("credential_unavailable")
        self.model, self.key = profile["model"], key
        self.client = client or provider_client(_ORIGIN, max_bytes=_MAX_RESPONSE, deadline=120)

    async def close(self):
        await self.client.aclose()

    async def generate(self, prompt):
        if not isinstance(prompt, str) or not 1 <= len(prompt) <= 6000:
            raise ProviderError("invalid_image_prompt")
        try:
            result = await self.client.post(
                _ENDPOINT,
                headers={"Authorization": "Bearer " + self.key},
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "n": 1,
                    "size": "1024x1536",
                    "quality": "medium",
                    "output_format": "jpeg",
                    "stream": False,
                },
                follow_redirects=False,
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise ProviderError("connection_failed") from None
        except SafeHTTPError as exc:
            unsent = exc.kind in {
                "unsafe_url",
                "unsafe_host",
                "dns_failure",
                "private_address",
                "invalid_address",
            }
            raise ProviderError(
                "image_transport_error", outcome="not_sent" if unsent else "unknown"
            ) from None
        except (httpx.RequestError, OSError, TimeoutError):
            raise ProviderError("outcome_unknown", outcome="unknown") from None
        if result.status_code != 200:
            code = {
                400: "invalid_image_request",
                401: "authentication_failed",
                403: "permission_denied",
                404: "model_unavailable",
                429: "rate_limited",
            }.get(result.status_code, "provider_failed")
            if result.status_code == 400:
                try:
                    error = result.json().get("error", {})
                    if isinstance(error, dict) and error.get("code") in {
                        "content_policy_violation",
                        "moderation_blocked",
                    }:
                        code = "content_refused"
                except (ValueError, AttributeError):
                    pass
            raise ProviderError(code, outcome="known")
        try:
            if len(result.content) > _MAX_RESPONSE:
                raise ValueError()
            body = result.json()
            if not isinstance(body, dict) or body.get("output_format", "jpeg") != "jpeg":
                raise ValueError()
            items = body.get("data")
            if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
                raise ValueError()
            encoded = items[0].get("b64_json")
            if not isinstance(encoded, str) or not 1 <= len(encoded) <= _MAX_RESPONSE:
                raise ValueError()
            raster = base64.b64decode(encoded, validate=True)
            if not 1 <= len(raster) <= _MAX_RASTER or not raster.startswith(b"\xff\xd8\xff"):
                raise ValueError()
            usage = body.get("usage", {})
            if not isinstance(usage, dict):
                usage = {}
            observed = {
                key: usage[key]
                for key in ("input_tokens", "output_tokens")
                if type(usage.get(key)) is int and 0 <= usage[key] <= 2**53
            }
            observed["images"] = 1
        except (ValueError, UnicodeError, RecursionError):
            raise ProviderError("invalid_generated_image", outcome="known") from None
        return raster, observed
