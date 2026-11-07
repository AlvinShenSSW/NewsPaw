"""Bounded HTTPS for one local worker: public fetches and isolated API origins."""

from __future__ import annotations

import asyncio
import ipaddress
import socket
import zlib

import httpcore
import httpx


class SafeHTTPError(httpx.RequestError):
    def __init__(self, kind: str):
        self.kind = kind
        super().__init__(f"NewsPaw HTTP request rejected: {kind}")


def _public_ip(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise SafeHTTPError("invalid_address") from None
    if not address.is_global or address.is_multicast or address.is_reserved or "%" in value:
        raise SafeHTTPError("private_address")
    return str(address)


def checked_url(value: str | httpx.URL) -> httpx.URL:
    if any(ord(c) < 32 for c in str(value)) or len(str(value)) > 2048:
        raise SafeHTTPError("unsafe_url")
    try:
        url = httpx.URL(value)
        host = url.host.rstrip(".").lower()
        if url.scheme != "https" or not host or url.username or url.password:
            raise SafeHTTPError("unsafe_url")
        if url.port is not None and not 1 <= url.port <= 65535:
            raise SafeHTTPError("unsafe_url")
        if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
            raise SafeHTTPError("private_address")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            # inet_aton catches legacy numeric forms such as 127.1 and 0x7f000001.
            try:
                literal = socket.inet_ntoa(socket.inet_aton(host))
            except OSError:
                if "." not in host or "%" in host:
                    raise SafeHTTPError("unsafe_host") from None
            else:
                _public_ip(literal)
        else:
            _public_ip(host)
        return url
    except (httpx.InvalidURL, ValueError):
        raise SafeHTTPError("unsafe_url") from None


def _origin(url: httpx.URL) -> tuple[str, str, int]:
    return url.scheme, url.host.lower(), url.port or 443


class PublicNetworkBackend(httpcore.AsyncNetworkBackend):
    def __init__(self, *, dialer=None):
        self._dialer = dialer or httpcore.AnyIOBackend()

    async def resolve(self, host: str, port: int) -> list[str]:
        try:
            return [_public_ip(host)]
        except SafeHTTPError as exc:
            if exc.kind != "invalid_address":
                raise
        try:
            async with asyncio.timeout(5):
                rows = await asyncio.get_running_loop().getaddrinfo(
                    host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP
                )
        except (OSError, TimeoutError):
            raise SafeHTTPError("dns_failure") from None
        return list(dict.fromkeys(row[4][0] for row in rows))

    async def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):
        addresses = await self.resolve(host, port)
        if not addresses or len(addresses) > 32:
            raise SafeHTTPError("dns_answer_limit")
        # Validate the entire answer set before trying any address.
        addresses = [_public_ip(value) for value in addresses]
        for address in addresses:
            try:
                return await self._dialer.connect_tcp(
                    host=address,
                    port=port,
                    timeout=timeout,
                    local_address=None,
                    socket_options=socket_options,
                )
            except (httpcore.ConnectError, httpcore.ConnectTimeout):
                continue
        raise httpcore.ConnectError("No validated public address could be connected")

    async def sleep(self, seconds):
        await asyncio.sleep(seconds)


class BoundedTransport(httpx.AsyncBaseTransport):
    """Buffer within fixed bounds; do not stream unbounded provider/source bodies."""

    def __init__(
        self, *, trusted_origin=None, max_bytes=2 * 1024 * 1024, deadline=30.0, network_backend=None
    ):
        if type(max_bytes) is not int or max_bytes < 1 or deadline <= 0:
            raise ValueError("Positive HTTP byte limit and deadline required")
        self._trusted = _origin(checked_url(trusted_origin)) if trusted_origin is not None else None
        self._max_bytes = max_bytes
        self._deadline = deadline
        self._pool = httpcore.AsyncConnectionPool(
            network_backend=network_backend or PublicNetworkBackend(),
            max_connections=5,
            max_keepalive_connections=5,
            retries=0,
        )

    def _check_request(self, request):
        url = checked_url(request.url)
        if self._trusted is not None:
            if _origin(url) != self._trusted:
                raise SafeHTTPError("provider_origin_mismatch")
        else:
            if request.method not in {"GET", "HEAD"}:
                raise SafeHTTPError("source_method_rejected")
            allowed_headers = {
                "host",
                "accept",
                "accept-encoding",
                "user-agent",
                "connection",
                "if-none-match",
                "if-modified-since",
                "range",
                "cache-control",
                "x-github-api-version",
            }
            if any(key.lower() not in allowed_headers for key in request.headers):
                raise SafeHTTPError("source_credentials_rejected")
        if request.extensions.get("sni_hostname") not in (None, url.host):
            raise SafeHTTPError("tls_hostname_mismatch")

    async def handle_async_request(self, request):
        self._check_request(request)
        core_request = httpcore.Request(
            method=request.method,
            url=httpcore.URL(
                scheme=request.url.raw_scheme,
                host=request.url.raw_host,
                port=request.url.port,
                target=request.url.raw_path,
            ),
            headers=request.headers.raw,
            content=request.stream,
            extensions={k: v for k, v in request.extensions.items() if k != "sni_hostname"},
        )
        try:
            async with asyncio.timeout(self._deadline):
                response = await self._pool.handle_async_request(core_request)
                try:
                    headers = httpx.Headers(response.headers)
                    if request.method == "HEAD" or response.status in {204, 304}:
                        return httpx.Response(
                            response.status,
                            headers=headers,
                            content=b"",
                            extensions=response.extensions,
                        )
                    declared = headers.get("content-length", "")
                    if declared.isdigit() and int(declared) > self._max_bytes:
                        raise SafeHTTPError("response_too_large")
                    encoding = headers.get("content-encoding", "identity").strip().lower()
                    if encoding not in {"", "identity", "gzip", "deflate"}:
                        raise SafeHTTPError("unsupported_encoding")
                    decoder = (
                        zlib.decompressobj(31 if encoding == "gzip" else 15)
                        if encoding in {"gzip", "deflate"}
                        else None
                    )
                    body = bytearray()
                    encoded_size = 0
                    async for chunk in response.stream:
                        encoded_size += len(chunk)
                        if encoded_size > self._max_bytes:
                            raise SafeHTTPError("response_too_large")
                        if decoder:
                            chunk = decoder.decompress(chunk, self._max_bytes + 1 - len(body))
                        body.extend(chunk)
                        if len(body) > self._max_bytes or (decoder and decoder.unconsumed_tail):
                            raise SafeHTTPError("response_too_large")
                    if decoder and (not decoder.eof or decoder.unused_data):
                        raise SafeHTTPError("invalid_compression")
                    # HTTPX must not decode our already-decoded bounded body again.
                    headers.pop("content-encoding", None)
                    headers.pop("transfer-encoding", None)
                    headers["content-length"] = str(len(body))
                    return httpx.Response(
                        response.status,
                        headers=headers,
                        content=bytes(body),
                        extensions=response.extensions,
                    )
                finally:
                    await response.aclose()
        except TimeoutError:
            raise httpx.ReadTimeout("NewsPaw request deadline exceeded", request=request) from None
        except zlib.error:
            raise SafeHTTPError("invalid_compression") from None
        except (httpcore.TimeoutException, httpcore.NetworkError, httpcore.ProtocolError) as exc:
            # Preserve the failure phase: a lost response is not an unsent request.
            errors = {
                httpcore.ConnectTimeout: httpx.ConnectTimeout,
                httpcore.ReadTimeout: httpx.ReadTimeout,
                httpcore.WriteTimeout: httpx.WriteTimeout,
                httpcore.PoolTimeout: httpx.PoolTimeout,
                httpcore.ConnectError: httpx.ConnectError,
                httpcore.ReadError: httpx.ReadError,
                httpcore.WriteError: httpx.WriteError,
                httpcore.RemoteProtocolError: httpx.RemoteProtocolError,
                httpcore.LocalProtocolError: httpx.LocalProtocolError,
            }
            error = errors.get(type(exc), httpx.TransportError)
            raise error("NewsPaw HTTP transport failed", request=request) from None

    async def aclose(self):
        await self._pool.aclose()


def source_client(*, max_bytes=2 * 1024 * 1024, deadline=30.0) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=BoundedTransport(max_bytes=max_bytes, deadline=deadline),
        trust_env=False,
        timeout=httpx.Timeout(deadline, connect=10),
        follow_redirects=False,
        max_redirects=3,
        headers={"User-Agent": "NewsPaw/0.1", "Accept-Encoding": "identity"},
    )


def provider_client(
    base_url: str, *, max_bytes=32 * 1024 * 1024, deadline=90.0
) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=BoundedTransport(trusted_origin=base_url, max_bytes=max_bytes, deadline=deadline),
        trust_env=False,
        timeout=httpx.Timeout(deadline, connect=10),
        follow_redirects=False,
        headers={"Accept-Encoding": "identity"},
    )
