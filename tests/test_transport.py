import asyncio
import gzip
from unittest.mock import AsyncMock

import httpcore
import httpx
import pytest

from newspaw.transport import BoundedTransport, PublicNetworkBackend, SafeHTTPError, provider_client


class Stream(httpcore.AsyncMockStream):
    def __init__(self, data, *, stall=False):
        super().__init__([data])
        self.sni = None
        self.stall = stall
        self.read_started = asyncio.Event()

    async def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        self.sni = server_hostname
        return self

    async def read(self, max_bytes, timeout=None):
        self.read_started.set()
        if self.stall:
            await asyncio.Event().wait()
        return await super().read(max_bytes, timeout)


def transport(monkeypatch, data, *, addresses=None, stall=False, **kwargs):
    stream = Stream(data, stall=stall)
    dialer = AsyncMock(spec=httpcore.AsyncNetworkBackend)
    dialer.connect_tcp.return_value = stream
    backend = PublicNetworkBackend(dialer=dialer)
    resolver = AsyncMock(return_value=addresses or ["93.184.216.34"])
    monkeypatch.setattr(backend, "resolve", resolver)
    return BoundedTransport(network_backend=backend, **kwargs), stream, dialer


def response(body=b"ok", extra=b""):
    return (
        b"HTTP/1.1 200 OK\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\n"
        + extra
        + b"\r\n"
        + body
    )


@pytest.mark.parametrize(
    "url",
    [
        "https://127.0.0.1",
        "https://[::1]",
        "https://10.0.0.1",
        "https://169.254.169.254",
        "https://user:secret@example.com",
        "file:///tmp/a",
        "http://example.com",
    ],
)
async def test_unsafe_urls_never_dial(monkeypatch, url):
    adapter, _, dialer = transport(monkeypatch, response())
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError):
            await client.get(url)
    dialer.connect_tcp.assert_not_awaited()


@pytest.mark.parametrize(
    "addresses",
    [
        ["127.0.0.1"],
        ["93.184.216.34", "10.0.0.1"],
        ["::ffff:127.0.0.1"],
        ["fe80::1"],
        ["224.0.0.1"],
    ],
)
async def test_dns_answers_checked_at_connection(monkeypatch, addresses):
    adapter, _, dialer = transport(monkeypatch, response(), addresses=addresses)
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError):
            await client.get("https://feed.example.com")
    dialer.connect_tcp.assert_not_awaited()


async def test_validated_ip_is_dialed_and_tls_keeps_original_name(monkeypatch):
    adapter, stream, dialer = transport(monkeypatch, response())
    async with httpx.AsyncClient(transport=adapter) as client:
        assert (await client.get("https://feed.example.com/rss")).text == "ok"
    assert dialer.connect_tcp.call_args.kwargs["host"] == "93.184.216.34"
    assert stream.sni == "feed.example.com"
    assert stream._closed


async def test_provider_redirect_cannot_send_credentials_to_another_origin(monkeypatch):
    redirect = b"HTTP/1.1 307 Temporary Redirect\r\nLocation: https://other.example.com/\r\nContent-Length: 0\r\n\r\n"
    adapter, _, dialer = transport(
        monkeypatch, redirect, trusted_origin="https://api.example.com/v1"
    )
    async with httpx.AsyncClient(transport=adapter, follow_redirects=True) as client:
        with pytest.raises(SafeHTTPError):
            await client.post(
                "https://api.example.com/v1/responses", headers={"X-API-Key": "fixture"}, json={}
            )
    assert dialer.connect_tcp.await_count == 1


async def test_source_refuses_credentials_before_dial(monkeypatch):
    adapter, _, dialer = transport(monkeypatch, response())
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError):
            await client.get(
                "https://feed.example.com", headers={"Authorization": "Bearer fixture"}
            )
    dialer.connect_tcp.assert_not_awaited()


async def test_gzip_decoded_once_through_real_httpx_client(monkeypatch):
    adapter, _, _ = transport(
        monkeypatch, response(gzip.compress(b"news"), b"Content-Encoding: gzip\r\n")
    )
    async with httpx.AsyncClient(transport=adapter) as client:
        result = await client.get("https://feed.example.com")
    assert result.content == b"news"
    assert "content-encoding" not in result.headers
    assert result.headers["content-length"] == "4"


@pytest.mark.parametrize("compressed", [False, True])
async def test_response_limits_apply_before_buffer_expansion(monkeypatch, compressed):
    body = gzip.compress(b"x" * 10000) if compressed else b"x" * 10000
    extra = b"Content-Encoding: gzip\r\n" if compressed else b""
    adapter, _, _ = transport(monkeypatch, response(body, extra), max_bytes=100)
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError):
            await client.get("https://feed.example.com")


async def test_deadline_and_cancellation_close_network_stream(monkeypatch):
    adapter, stream, _ = transport(monkeypatch, b"", stall=True, deadline=0.02)
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(httpx.TimeoutException):
            await client.get("https://feed.example.com")
    assert stream._closed
    adapter, stream, _ = transport(monkeypatch, b"", stall=True)
    async with httpx.AsyncClient(transport=adapter) as client:
        task = asyncio.create_task(client.get("https://feed.example.com"))
        await stream.read_started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert stream._closed


def test_provider_factory_disables_environment_proxy_and_redirects():
    client = provider_client("https://api.example.com:8443/v1")
    assert client.trust_env is False
    assert client.follow_redirects is False


async def test_source_redirect_to_private_address_is_rejected(monkeypatch):
    redirect = b"HTTP/1.1 302 Found\r\nLocation: https://127.0.0.1/\r\nContent-Length: 0\r\n\r\n"
    adapter, _, dialer = transport(monkeypatch, redirect)
    async with httpx.AsyncClient(transport=adapter, follow_redirects=True) as client:
        with pytest.raises(SafeHTTPError):
            await client.get("https://feed.example.com")
    assert dialer.connect_tcp.await_count == 1


async def test_fresh_connection_rechecks_dns_and_rejects_rebinding(monkeypatch):
    stream = Stream(response(extra=b"Connection: close\r\n"))
    dialer = AsyncMock(spec=httpcore.AsyncNetworkBackend)
    dialer.connect_tcp.return_value = stream
    backend = PublicNetworkBackend(dialer=dialer)
    monkeypatch.setattr(
        backend, "resolve", AsyncMock(side_effect=[["93.184.216.34"], ["127.0.0.1"]])
    )
    async with httpx.AsyncClient(transport=BoundedTransport(network_backend=backend)) as client:
        assert (await client.get("https://feed.example.com")).content == b"ok"
        with pytest.raises(SafeHTTPError):
            await client.get("https://feed.example.com")
    assert dialer.connect_tcp.await_count == 1


@pytest.mark.parametrize(
    "body", [b"not gzip", gzip.compress(b"news")[:-2], gzip.compress(b"news") + b"trailing"]
)
async def test_malformed_or_trailing_compression_rejected(monkeypatch, body):
    adapter, _, _ = transport(monkeypatch, response(body, b"Content-Encoding: gzip\r\n"))
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError, match="invalid_compression"):
            await client.get("https://feed.example.com")


async def test_head_keeps_size_metadata_without_decompressing_absent_body(monkeypatch):
    wire = b"HTTP/1.1 200 OK\r\nContent-Length: 99999\r\nContent-Encoding: gzip\r\n\r\n"
    adapter, _, _ = transport(monkeypatch, wire, max_bytes=10)
    async with httpx.AsyncClient(transport=adapter) as client:
        result = await client.head("https://feed.example.com")
    assert result.content == b""
    assert result.headers["content-length"] == "99999"


async def test_resolver_normalizes_dns_results_without_dialing_private_answer(monkeypatch):
    import socket

    dialer = AsyncMock(spec=httpcore.AsyncNetworkBackend)
    backend = PublicNetworkBackend(dialer=dialer)
    lookup = AsyncMock(
        return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.1", 443))]
    )
    monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", lookup)
    with pytest.raises(SafeHTTPError):
        await backend.connect_tcp("feed.example.com", 443)
    lookup.assert_awaited_once()
    dialer.connect_tcp.assert_not_awaited()


async def test_sni_override_and_non_get_source_requests_are_rejected(monkeypatch):
    adapter, _, dialer = transport(monkeypatch, response())
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(SafeHTTPError):
            await client.get(
                "https://feed.example.com", extensions={"sni_hostname": "other.example.com"}
            )
        with pytest.raises(SafeHTTPError):
            await client.post("https://feed.example.com", json={})
        with pytest.raises(SafeHTTPError):
            await client.get("https://feed.example.com", headers={"X-Custom-Secret": "fixture"})
    dialer.connect_tcp.assert_not_awaited()


async def test_lost_response_is_not_mislabelled_as_connect_failure(monkeypatch):
    adapter, stream, _ = transport(monkeypatch, response())
    monkeypatch.setattr(
        stream, "read", AsyncMock(side_effect=httpcore.ReadError("sensitive-provider-detail"))
    )
    async with httpx.AsyncClient(transport=adapter) as client:
        with pytest.raises(httpx.ReadError) as error:
            await client.get("https://feed.example.com")
    assert "sensitive-provider-detail" not in str(error.value)
    assert not isinstance(error.value, httpx.ConnectError)
