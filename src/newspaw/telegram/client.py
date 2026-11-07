"""Fixed-origin Telegram reads with bounded responses and safe diagnostics."""

import json
import logging
import re

import httpx

from ..transport import provider_client


class TelegramError(ValueError):
    def __init__(self, kind, retry_after=None):
        super().__init__(kind)
        self.kind = kind
        self.retry_after = retry_after


class _TokenFilter(logging.Filter):
    def filter(self, record):
        message = record.getMessage()
        record.msg = re.sub(r"/bot[1-9][0-9]*:[A-Za-z0-9_-]+", "/bot<redacted>", message)
        record.args = ()
        return True


_TOKEN_FILTER = _TokenFilter()


class TelegramClient:
    def __init__(self, token, *, client=None):
        if not isinstance(token, str) or not re.fullmatch(
            r"[1-9][0-9]{0,15}:[A-Za-z0-9_-]{16,200}", token
        ):
            raise TelegramError("invalid_token")
        for name in ("httpx", "httpcore.connection", "httpcore.http11", "httpcore.http2"):
            logger = logging.getLogger(name)
            if _TOKEN_FILTER not in logger.filters:
                logger.addFilter(_TOKEN_FILTER)
        self._token = token
        self.client = (
            client
            if client is not None
            else provider_client("https://api.telegram.org", max_bytes=2 * 1024 * 1024, deadline=35)
        )

    async def close(self):
        await self.client.aclose()

    async def call(self, method, params=None):
        if method not in {"getMe", "getWebhookInfo", "getUpdates"}:
            raise TelegramError("method_not_allowed")
        try:
            response = await self.client.get(
                f"https://api.telegram.org/bot{self._token}/{method}",
                params=params or {},
                follow_redirects=False,
            )
            if len(response.content) > 2 * 1024 * 1024:
                raise TelegramError("response_too_large")
            data = json.loads(
                response.content, parse_constant=lambda _: (_ for _ in ()).throw(ValueError())
            )
            if not isinstance(data, dict):
                raise ValueError()
            if response.status_code != 200 or data.get("ok") is not True:
                code = data.get("error_code", response.status_code)
                if type(code) is not int:
                    code = response.status_code
                kind = {
                    401: "token_revoked",
                    403: "forbidden",
                    409: "consumer_conflict",
                    429: "rate_limited",
                }.get(code, "telegram_error")
                retry = data.get("parameters", {})
                retry = retry.get("retry_after") if isinstance(retry, dict) else None
                retry = min(retry, 86400) if type(retry) is int and retry >= 0 else None
                raise TelegramError(kind, retry)
            if "result" not in data:
                raise ValueError()
            return data["result"]
        except TelegramError:
            raise
        except (ValueError, RecursionError):
            raise TelegramError("malformed_response") from None
        except httpx.HTTPError:
            raise TelegramError("transport_error") from None
