# F03 / #12 — Shared bounded HTTP transport

## Frozen contract
Single Mac backend, no proxy service or browser automation. Replace literal-only URL safety at actual fetch boundaries; retain ordinary custom public HTTPS model gateways. Source documents and model credentials use separate client instances. Source text remains data.

Acceptance: reject userinfo, dangerous schemes, local/private/link-local/reserved/multicast IPv4/IPv6 and DNS results; connect only to validated numeric addresses (no second hostname resolution). Validate every redirect request, prevent credential transmission outside the configured provider origin, enforce encoded/decoded byte limits and total deadlines, and preserve cancellation/resource cleanup. Existing RSS/AV consumers must use this path; AIService must supply the trusted-origin HTTP client to its SDK. Display-only article URL filtering remains syntactic and is not claimed to verify DNS.

## Approach / source evidence
Use a small HTTPX AsyncBaseTransport backed by httpcore.AsyncConnectionPool with a custom AsyncNetworkBackend. Official APIs: https://www.python-httpx.org/advanced/transports/ and https://www.encode.io/httpcore/network-backends/. The backend resolves once with asyncio getaddrinfo, rejects any non-global answer, and passes only one of the verified IP literals to httpcore.AnyIOBackend.connect_tcp; TLS still receives the original hostname from httpcore. Verify installed httpcore connection/backend source before relying on that property. Limit addresses and DNS deadline, do not inspect real internal hosts in tests. No proxies/trust_env or automatic retries.

The transport buffers a bounded response under asyncio.timeout, then returns an HTTPX response. Bound both encoded bytes and decoded gzip/deflate bytes with zlib's max_length; reject unsupported encodings and malformed/truncated compressed streams. No unbounded gzip.decompress. Normal source bound is MAX_FEED_BYTES with a 30-second total request deadline; provider bound is a configurable larger response limit and 90-second deadline. Byte/deadline controls are technical resource bounds, not a new spending limit. Response buffers simplify this one-user non-streaming news app; streaming model output is out of scope.

Each transport validates HTTPS URL syntax and requested origin before sending. Source mode permits only GET/HEAD and refuses credential headers. Trusted provider mode is bound to one explicit (scheme, host, port); all subsequent requests, including an SDK redirect override, must match it. Clients default to follow_redirects=False; the existing bounded RSS redirect loop still rechecks each hop, and future webpage clients can explicitly use bounded redirects through this transport. Connections are pinned to verified IPs while preserving TLS SNI/Host; each fresh connection repeats DNS validation. Private DNS answers are never dialed.

## Files / consumers / execution surface
- Add src/newspaw/transport.py: URL/connection guard, bounded response adapter, source/provider client factories.
- news.py: construct source client through factory; keep current feed parse limits and error reporting. No source catalog change.
- ai.py: give OpenAI SDK a separate trusted-origin client; retain current product behavior/model choices, which M01/M02 later replace. AV retrieval inherits NewsService; adult model wrapper inherits AIService.
- pyproject.toml/uv.lock: declare httpcore directly because production now imports its documented API (already an HTTPX dependency).
- tests/test_transport.py and existing news/AV fake-client helpers: inject mock network backends/HTTP responses without bypassing new transport tests. No real DNS or network. Tests for consumers retain their feed parsing fixtures.
- This spec only; no UI/mockup or other business code.

Read/execute installed HTTPX/httpcore source and uv test/lint/build. No private data, model request or service install. Generated package outputs remain ignored. Network verification uses mocked DNS and AsyncMock network streams only.

## Risk and assumptions
DNS resolves to multiple public addresses; try at most the bounded returned set on connect failures, never retry a dispatched model request. Connection pinning prevents DNS rebinding; no claim to protect against a compromised routing table, trusted gateway or malicious same-user code. SDK redirect controls and TLS hostname preservation require source/fixture verification, not assumptions. Bounded decompression must handle end-of-stream and trailing data explicitly. Avoid retaining raw URLs with credentials in exception messages.

## Test plan / handoff
RED absent transport imports, then private literal/odd IPv4/IPv6/DNS mixed answers, rebinding (dial receives only validated IP), SNI hostname propagation, same-origin provider request and cross-origin refusal before backend I/O, source credential/method refusal, redirects to private hosts, oversized declared/streamed/compressed bodies, malformed gzip, total timeout and cancellation closes response. Re-run affected news/AV/AI fixtures, then full suite after Kimi. Design debate before implementation. No new content policy/model fallback/feature behavior in this issue.
