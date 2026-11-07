import logging

import httpx
import pytest
from test_telegram_registry import TOKEN

from newspaw.telegram.client import TelegramClient, TelegramError


async def test_fixed_origin_client_redacts_token_even_with_http_debug_logging(caplog):
    caplog.set_level(logging.DEBUG)
    seen = []

    def respond(r):
        seen.append(r)
        return httpx.Response(200, json={"ok": True, "result": {"id": 999, "is_bot": True}})

    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=httpx.MockTransport(respond)))
    try:
        assert (await client.call("getMe"))["id"] == 999
    finally:
        await client.close()
    assert seen[0].url.host == "api.telegram.org"
    assert TOKEN not in caplog.text


@pytest.mark.parametrize(
    "status,kind",
    [(401, "token_revoked"), (403, "forbidden"), (409, "consumer_conflict"), (429, "rate_limited")],
)
async def test_errors_expose_only_fixed_diagnostics(status, kind):
    client = TelegramClient(
        TOKEN,
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda r: httpx.Response(
                    status,
                    json={
                        "ok": False,
                        "error_code": status,
                        "description": TOKEN,
                        "parameters": {"retry_after": 60},
                    },
                )
            )
        ),
    )
    try:
        with pytest.raises(TelegramError) as caught:
            await client.call("getUpdates", {"offset": 1})
        assert str(caught.value) == kind and TOKEN not in repr(caught.value)
        assert caught.value.retry_after == 60
    finally:
        await client.close()


async def test_redirect_not_followed_and_write_methods_unavailable():
    calls = []

    def respond(r):
        calls.append(r)
        return httpx.Response(302, headers={"Location": "https://evil.example/"})

    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=httpx.MockTransport(respond)))
    try:
        with pytest.raises(TelegramError):
            await client.call("getMe")
        for method in ("deleteWebhook", "sendMessage", "setWebhook"):
            with pytest.raises(TelegramError, match="method_not_allowed"):
                await client.call(method)
        assert len(calls) == 1
    finally:
        await client.close()


async def test_real_guarded_telegram_request_uses_only_official_tls_origin(monkeypatch):
    from test_transport import response, transport

    adapter, stream, dialer = transport(
        monkeypatch,
        response(b'{"ok":true,"result":{"id":999,"is_bot":true}}'),
        trusted_origin="https://api.telegram.org",
    )
    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=adapter))
    try:
        assert (await client.call("getMe"))["id"] == 999
    finally:
        await client.close()
    assert stream.sni == "api.telegram.org" and dialer.connect_tcp.await_count == 1


@pytest.mark.parametrize(
    "token",
    [
        "",
        "999:short",
        "999:bad/secret_abcdefghijklmnopqrstuvwxyz",
        "999:bad?secret_abcdefghijklmnopqrstuvwxyz",
    ],
)
def test_invalid_token_cannot_create_request(token):
    with pytest.raises(TelegramError, match="invalid_token"):
        TelegramClient(token)
