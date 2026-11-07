"""Fixed-origin Telegram requests with bounded responses and safe diagnostics."""

import asyncio
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


class TelegramSendError(TelegramError):
    pass


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
        self._custom_client = client is not None
        self.client = (
            client
            if client is not None
            else provider_client("https://api.telegram.org", max_bytes=2 * 1024 * 1024, deadline=35)
        )

    async def close(self):
        await self.client.aclose()

    async def call(self, method, params=None):
        if method not in {"getMe", "getWebhookInfo", "getUpdates", "getFile"}:
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

    async def download_file(self, file_id, limit, guard):
        if (
            not isinstance(file_id, str)
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,512}", file_id)
            or type(limit) is not int
            or not 1 <= limit <= 12 * 1024 * 1024
        ):
            raise TelegramError("invalid_media")
        if guard() is False:
            raise TelegramError("media_scope_changed")
        metadata = await self.call("getFile", {"file_id": file_id})
        path = metadata.get("file_path") if isinstance(metadata, dict) else None
        if (
            not isinstance(path, str)
            or len(path) > 300
            or not re.fullmatch(
                r"(?:[A-Za-z0-9_-]{1,80}/){1,5}[A-Za-z0-9_-]{1,100}(?:\.[A-Za-z0-9]{1,12})?", path
            )
        ):
            raise TelegramError("invalid_file_path")
        expected = metadata.get("file_size")
        if expected is not None and (type(expected) is not int or not 1 <= expected <= limit):
            raise TelegramError("media_too_large")
        if guard() is False:
            raise TelegramError("media_scope_changed")

        client = (
            self.client
            if self._custom_client
            else provider_client("https://api.telegram.org", max_bytes=limit, deadline=20)
        )
        try:
            data = bytearray()
            async with (
                asyncio.timeout(20),
                client.stream(
                    "GET",
                    f"https://api.telegram.org/file/bot{self._token}/{path}",
                    follow_redirects=False,
                    headers={"Accept-Encoding": "identity"},
                ) as response,
            ):
                if (
                    response.status_code != 200
                    or response.headers.get("content-encoding", "identity") != "identity"
                ):
                    raise TelegramError("media_download_failed")
                size = response.headers.get("content-length")
                if size is not None and (
                    not size.isdecimal() or len(size) > 9 or not 1 <= int(size) <= limit
                ):
                    raise TelegramError("media_too_large")
                async for chunk in response.aiter_bytes():
                    if len(data) + len(chunk) > limit:
                        raise TelegramError("media_too_large")
                    data.extend(chunk)
                if (
                    not data
                    or (size is not None and int(size) != len(data))
                    or (expected is not None and expected != len(data))
                ):
                    raise TelegramError("media_download_failed")
            if guard() is False:
                raise TelegramError("media_scope_changed")
            return bytes(data)
        except (httpx.HTTPError, TimeoutError):
            raise TelegramError("media_download_failed") from None
        finally:
            if client is not self.client:
                await client.aclose()

    async def send_audio(self, binding, data):
        return await self._send(
            "sendAudio",
            binding,
            data={"chat_id": str(binding.chat_id), "title": "NewsPaw"},
            files={"audio": ("newspaw.mp3", data, "audio/mpeg")},
        )

    async def send_message(self, binding, text):
        return await self._send(
            "sendMessage",
            binding,
            json={
                "chat_id": binding.chat_id,
                "text": text,
                "link_preview_options": {"is_disabled": True},
            },
        )

    async def send_photo(self, binding, data, mime, caption, *, spoiler=False):
        filename = {"image/jpeg": "news.jpg", "image/png": "news.png"}[mime]
        return await self._send(
            "sendPhoto",
            binding,
            data={
                "chat_id": str(binding.chat_id),
                "caption": caption,
                "has_spoiler": "true" if spoiler else "false",
            },
            files={"photo": (filename, data, mime)},
        )

    async def _send(self, method, binding, **body):
        try:
            response = await self.client.post(
                f"https://api.telegram.org/bot{self._token}/{method}",
                follow_redirects=False,
                **body,
            )
            if len(response.content) > 2 * 1024 * 1024:
                raise ValueError()
            data = response.json()
        except (httpx.HTTPError, ValueError, RecursionError, OSError):
            raise TelegramSendError("outcome_unknown") from None
        if isinstance(data, dict):
            code = response.status_code
            result = data.get("result")
            if code == 200 and data.get("ok") is True and isinstance(result, dict):
                chat = result.get("chat")
                author = result.get("from")
                message_id = result.get("message_id")
                if (
                    type(message_id) is int
                    and 0 < message_id <= 2**63 - 1
                    and isinstance(chat, dict)
                    and type(chat.get("id")) is int
                    and chat["id"] == binding.chat_id
                    and chat.get("type") == "private"
                    and (
                        "from" not in result
                        or (
                            isinstance(author, dict)
                            and type(author.get("id")) is int
                            and author["id"] == binding.telegram_id
                            and author.get("is_bot") is True
                        )
                    )
                ):
                    return message_id
            if (
                data.get("ok") is False
                and type(data.get("error_code")) is int
                and data["error_code"] == code
            ):
                if code == 429:
                    parameters = data.get("parameters", {})
                    retry = (
                        parameters.get("retry_after", 60) if isinstance(parameters, dict) else None
                    )
                    if type(retry) is not int or not 0 <= retry <= 2**31 - 1:
                        raise TelegramSendError("rate_limit_invalid")
                    raise TelegramSendError("rate_limited", max(1, retry))
                kind = {400: "payload_rejected", 401: "token_revoked", 403: "forbidden"}.get(code)
                if kind:
                    raise TelegramSendError(kind)
        raise TelegramSendError("outcome_unknown")
