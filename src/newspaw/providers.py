"""Explicit Responses protocols and opt-in, version-bound capability probes."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import re
import sqlite3
import struct
import zlib
from collections.abc import Callable
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from uuid import uuid4

import httpx

from .budget import BudgetError, BudgetLedger
from .credentials import CredentialError
from .transport import SafeHTTPError, checked_url, provider_client

PROVIDERS = {"openai", "mimo", "deepseek", "grok"}
CAPABILITIES = ("text", "vision", "image", "stt", "tts")
IDENTITY_FIELDS = ("id", "partition", "role", "provider", "base_url", "model", "credential_ref")
_ID = re.compile(r"[A-Za-z0-9_.:-]{1,140}")


class ProviderError(ValueError):
    def __init__(self, code, *, outcome="not_sent", usage=None, retry_after_seconds=None):
        super().__init__(code)
        self.code = code
        self.outcome = outcome
        self.usage = usage or {}
        self.retry_after_seconds = retry_after_seconds


def _json(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def _now():
    return datetime.now(UTC).isoformat()


def identity(profile):
    return hashlib.sha256(_json({k: profile[k] for k in IDENTITY_FIELDS}).encode()).hexdigest()


def initialize(db):
    legacy = not db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='model_probes'"
    ).fetchone()
    db.execute(
        "CREATE TABLE IF NOT EXISTS profile_epochs (profile_id TEXT PRIMARY KEY, generation INTEGER NOT NULL)"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS model_probes (probe_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, generation INTEGER NOT NULL, identity_hash TEXT NOT NULL, capability TEXT NOT NULL, hold_units INTEGER NOT NULL, started_at TEXT NOT NULL, finished_at TEXT, result_json TEXT NOT NULL)"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS model_probes_profile ON model_probes(profile_id,capability)"
    )
    config = json.loads(
        db.execute("SELECT document FROM app_configuration WHERE id=1").fetchone()[0]
    )
    for profile in config["model_profiles"]:
        db.execute("INSERT OR IGNORE INTO profile_epochs VALUES (?,1)", (profile["id"],))
    if legacy and any(p["capabilities"] for p in config["model_profiles"]):
        for profile in config["model_profiles"]:
            profile["capabilities"] = []
        db.execute(
            "UPDATE app_configuration SET revision=revision+1,document=? WHERE id=1",
            (_json(config),),
        )


def invalidate_profiles(db, current, document):
    """Called inside every configuration transaction, never performs I/O."""
    result = deepcopy(document)
    old = {p["id"]: p for p in current["model_profiles"]}
    new = {p["id"]: p for p in result["model_profiles"]}
    for key in old.keys() | new.keys():
        changed = key not in old or key not in new or identity(old[key]) != identity(new[key])
        if changed:
            db.execute(
                "INSERT INTO profile_epochs VALUES (?,1) ON CONFLICT(profile_id) DO UPDATE SET generation=generation+1",
                (key,),
            )
        if key in new:
            new[key]["capabilities"] = [] if changed else list(old[key]["capabilities"])
    return result


@dataclass(frozen=True)
class ModelRequest:
    partition: str
    instructions: str
    text: str
    max_output_tokens: int = 4096
    image: bytes | None = None
    image_mime: str | None = None
    tool_name: str | None = None
    tool_schema: dict | None = None
    json_schema: dict | None = None
    validator: Callable | None = None
    reasoning_none: bool = False


@dataclass(frozen=True)
class SearchRequest(ModelRequest):
    domains: tuple[str, ...] = ()


def _search_result(data, spec, usage):
    from .news import plain_text

    output = data.get("output")
    if not isinstance(output, list) or any(not isinstance(item, dict) for item in output):
        raise ProviderError("invalid_output", outcome="known", usage=usage)
    calls = [item for item in output if item.get("type") == "web_search_call"]
    if len(calls) > 1:
        raise ProviderError("invalid_search_receipt", outcome="known", usage=usage)
    if not calls:
        return {"tool_calls": 0, "citations": [], "provider_queries": None, "usage": usage}
    action = calls[0].get("action")
    if (
        calls[0].get("status") != "completed"
        or not isinstance(action, dict)
        or action.get("type") != "search"
        or not isinstance(action.get("sources"), list)
    ):
        raise ProviderError("invalid_search_receipt", outcome="known", usage=usage)

    def approved(value):
        if not isinstance(value, str):
            return None
        try:
            url = checked_url(value)
            if (
                url.host in spec.domains
                and url.port in {None, 443}
                and not (url.query or url.fragment)
            ):
                return str(url)
        except SafeHTTPError:
            pass
        return None

    source_urls = {
        approved(row.get("url")) for row in action["sources"][:100] if isinstance(row, dict)
    } - {None}
    citations = {}
    for item in output:
        parts = item.get("content")
        if item.get("type") != "message" or not isinstance(parts, list):
            continue
        for part in parts:
            if not isinstance(part, dict) or part.get("type") != "output_text":
                continue
            annotations = part.get("annotations")
            if not isinstance(annotations, list):
                continue
            for annotation in annotations:
                if not isinstance(annotation, dict) or annotation.get("type") != "url_citation":
                    continue
                url = approved(annotation.get("url"))
                title = annotation.get("title")
                if url in source_urls and isinstance(title, str):
                    title = plain_text(title, 300)
                    if title:
                        citations.setdefault(
                            url, dict(url=url, title=title, scope="citation_title_only")
                        )
                if len(citations) == 10:
                    break
            if len(citations) == 10:
                break
        if len(citations) == 10:
            break
    queries = action.get("queries", [action.get("query")])
    reported = (
        [plain_text(q, 300) for q in queries[:8] if isinstance(q, str) and q.strip()]
        if isinstance(queries, list)
        else []
    )
    return {
        "tool_calls": 1,
        "citations": list(citations.values()),
        "provider_queries": reported or None,
        "usage": usage,
    }


def _usage(value):
    if not isinstance(value, dict):
        return {}
    result = {
        k: v
        for k, v in value.items()
        if k in {"input_tokens", "output_tokens"} and type(v) is int and 0 <= v <= 2**53
    }
    details = value.get("input_tokens_details")
    if (
        isinstance(details, dict)
        and type(details.get("cached_tokens")) is int
        and 0 <= details["cached_tokens"] <= 2**53
    ):
        result["cached_tokens"] = details["cached_tokens"]
    return result


def _safe_id(value):
    return (
        value
        if isinstance(value, str) and len(value) <= 200 and all(32 <= ord(c) < 127 for c in value)
        else None
    )


def _image_data(data, mime):
    signatures = {
        "image/png": b"\x89PNG\r\n\x1a\n",
        "image/jpeg": b"\xff\xd8\xff",
        "image/webp": b"RIFF",
    }
    if (
        not isinstance(data, bytes)
        or not 1 <= len(data) <= 10 * 1024 * 1024
        or mime not in signatures
        or not data.startswith(signatures[mime])
    ):
        raise ProviderError("invalid_image")
    if mime == "image/webp" and data[8:12] != b"WEBP":
        raise ProviderError("invalid_image")
    return f"data:{mime};base64," + base64.b64encode(data).decode("ascii")


class ProviderAdapter:
    def __init__(self, profile, key, *, client=None):
        self.profile = deepcopy(profile)
        if profile["provider"] not in PROVIDERS:
            raise ProviderError("unsupported_provider")
        if (
            not isinstance(key, str)
            or not key
            or not key.isascii()
            or any(ord(c) < 33 or ord(c) == 127 for c in key)
        ):
            raise ProviderError("invalid_credential")
        try:
            base = checked_url(profile["base_url"])
            if base.path.rstrip("/").endswith("/responses"):
                raise ProviderError("base_url_is_operation")
            self.endpoint = base.copy_with(path=base.path.rstrip("/") + "/responses")
        except SafeHTTPError:
            raise ProviderError("invalid_endpoint") from None
        self.key = key
        self.client = (
            client
            if client is not None
            else provider_client(str(base), max_bytes=2 * 1024 * 1024, deadline=90)
        )

    async def close(self):
        await self.client.aclose()

    def payload(self, spec):
        if spec.partition not in {"normal", "adult"} or spec.partition != self.profile["partition"]:
            raise ProviderError("partition_mismatch")
        if (
            not isinstance(spec.instructions, str)
            or not isinstance(spec.text, str)
            or len((spec.instructions + spec.text).encode()) > 1024 * 1024
        ):
            raise ProviderError("invalid_input")
        if type(spec.max_output_tokens) is not int or not 1 <= spec.max_output_tokens <= 32768:
            raise ProviderError("invalid_output_limit")
        content = [{"type": "input_text", "text": spec.text}]
        if spec.image is not None:
            content.append(
                {"type": "input_image", "image_url": _image_data(spec.image, spec.image_mime)}
            )
        body = dict(
            model=self.profile["model"],
            instructions=spec.instructions,
            input=[{"role": "user", "content": content}],
            max_output_tokens=spec.max_output_tokens,
        )
        provider = self.profile["provider"]
        if provider in {"openai", "grok"}:
            body["store"] = False
        if spec.reasoning_none:
            body["reasoning"] = {"effort": "none"}
        if spec.tool_name is not None:
            if (
                not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", spec.tool_name)
                or not callable(spec.validator)
                or not isinstance(spec.tool_schema, dict)
                or len(_json(spec.tool_schema)) > 20000
            ):
                raise ProviderError("invalid_tool_contract")
            body["tools"] = [
                dict(
                    type="function",
                    name=spec.tool_name,
                    parameters=deepcopy(spec.tool_schema),
                    strict=provider != "mimo",
                )
            ]
            body["tool_choice"] = (
                "auto" if provider == "mimo" else {"type": "function", "name": spec.tool_name}
            )
        if spec.json_schema is not None:
            if (
                spec.tool_name
                or not callable(spec.validator)
                or not isinstance(spec.json_schema, dict)
                or len(_json(spec.json_schema)) > 20000
            ):
                raise ProviderError("invalid_output_contract")
            body["text"] = {
                "format": {"type": "json_object"}
                if provider == "mimo"
                else {
                    "type": "json_schema",
                    "name": "result",
                    "schema": deepcopy(spec.json_schema),
                    "strict": True,
                }
            }
            body["instructions"] += "\nReturn only JSON matching this schema: " + _json(
                spec.json_schema
            )
        if isinstance(spec, SearchRequest):
            if (
                provider != "openai"
                or spec.partition != "normal"
                or self.profile["base_url"].rstrip("/") != "https://api.openai.com/v1"
                or spec.image is not None
                or spec.tool_name is not None
                or spec.json_schema is not None
                or not 1 <= len(spec.domains) <= 12
                or any(not re.fullmatch(r"[a-z0-9.-]{1,253}", host) for host in spec.domains)
            ):
                raise ProviderError("invalid_search_scope")
            body.update(
                tools=[
                    {
                        "type": "web_search",
                        "search_context_size": "low",
                        "filters": {"allowed_domains": list(spec.domains)},
                    }
                ],
                max_tool_calls=1,
                tool_choice={"type": "web_search"},
                include=["web_search_call.action.sources"],
            )
        return body

    async def generate(self, spec):
        body = self.payload(spec)
        try:
            async with asyncio.timeout(90):
                response = await self.client.post(
                    self.endpoint, headers={"Authorization": "Bearer " + self.key}, json=body
                )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise ProviderError("connection_failed", outcome="not_sent") from None
        except SafeHTTPError as exc:
            unsent = exc.kind in {
                "invalid_address",
                "private_address",
                "unsafe_url",
                "unsafe_host",
                "provider_origin_mismatch",
                "dns_failure",
                "dns_answer_limit",
            }
            raise ProviderError(
                "transport_rejected", outcome="not_sent" if unsent else "unknown"
            ) from None
        except (httpx.RequestError, TimeoutError):
            raise ProviderError("outcome_unknown", outcome="unknown") from None
        if response.status_code != 200:
            code = {
                400: "protocol_error",
                401: "authentication_failed",
                403: "permission_denied",
                404: "model_unavailable",
                429: "rate_limited",
            }.get(response.status_code, "provider_failed")
            if response.status_code == 429:
                try:
                    error = response.json().get("error", {})
                    if (
                        isinstance(error, dict)
                        and isinstance(error.get("code"), str)
                        and error["code"]
                        in {
                            "insufficient_quota",
                            "billing_hard_limit_reached",
                            "credit_exhausted",
                            "quota_exceeded",
                        }
                    ):
                        code = "quota_exhausted"
                except (ValueError, AttributeError):
                    pass
            retry_after = response.headers.get("retry-after", "")
            seconds = (
                min(int(retry_after), 604800)
                if retry_after.isascii() and retry_after.isdigit() and len(retry_after) <= 12
                else None
            )
            if seconds is None and len(retry_after) <= 128:
                try:
                    date = parsedate_to_datetime(retry_after)
                    if date.tzinfo is not None:
                        seconds = max(0, min(604800, (date - datetime.now(UTC)).total_seconds()))
                except (ValueError, TypeError, OverflowError):
                    pass
            raise ProviderError(code, outcome="known", retry_after_seconds=seconds)
        try:
            if len(response.content) > 2 * 1024 * 1024:
                raise ValueError()
            data = response.json()
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, UnicodeError):
            raise ProviderError("invalid_output", outcome="known") from None
        return self.normalize(data, spec)

    def normalize(self, data, spec):
        try:
            if not isinstance(data, dict) or len(_json(data)) > 2 * 1024 * 1024:
                raise ValueError()
        except (ValueError, TypeError):
            raise ProviderError("invalid_output", outcome="known") from None
        usage = _usage(data.get("usage"))

        def fail(code):
            raise ProviderError(code, outcome="known", usage=usage)

        if data.get("status") != "completed":
            details = data.get("incomplete_details")
            if isinstance(details, dict) and details.get("reason") == "content_filter":
                fail("policy_refused")
            fail("incomplete_output")
        if isinstance(spec, SearchRequest):
            return _search_result(data, spec, usage)
        output = data.get("output")
        if not isinstance(output, list):
            fail("invalid_output")
        texts, calls = [], []
        for item in output:
            if not isinstance(item, dict):
                fail("invalid_output")
            if item.get("status", "completed") != "completed":
                fail("incomplete_output")
            if item.get("type") == "function_call":
                calls.append(item)
            elif item.get("type") == "message":
                if not isinstance(item.get("content"), list):
                    fail("invalid_output")
                for part in item["content"]:
                    if not isinstance(part, dict):
                        fail("invalid_output")
                    if part.get("type") == "refusal":
                        fail("policy_refused")
                    if part.get("type") == "output_text" and isinstance(part.get("text"), str):
                        texts.append(part["text"])
            elif item.get("type") != "reasoning":
                fail("invalid_output")
        text = "".join(texts)
        arguments = None
        try:
            if spec.tool_name:
                if len(calls) != 1 or calls[0].get("name") != spec.tool_name:
                    fail("invalid_output")
                arguments = json.loads(calls[0]["arguments"])
                if (
                    not isinstance(arguments, dict)
                    or set(arguments) - set(spec.tool_schema.get("properties", {}))
                    or spec.validator(arguments) is not True
                ):
                    fail("invalid_output")
            else:
                if calls or not text.strip() or len(text) > 200000:
                    fail("invalid_output")
                if spec.json_schema is not None:
                    arguments = json.loads(text)
                    if spec.validator(arguments) is not True:
                        fail("invalid_output")
                elif spec.validator is not None and spec.validator(text) is not True:
                    fail("invalid_output")
        except ProviderError:
            raise
        except Exception:
            fail("invalid_output")
        return {
            "text": text,
            "arguments": arguments,
            "requested_model": self.profile["model"],
            "reported_model": _safe_id(data.get("model")),
            "response_id": _safe_id(data.get("id")),
            "usage": usage,
        }


class ProfileRegistry:
    def __init__(self, store):
        self.store, self.db = store, store._db

    def profile(self, profile_id):
        config = self.store.load_config()[1]
        entry = next((p for p in config["model_profiles"] if p["id"] == profile_id), None)
        if entry is None:
            raise ProviderError("missing_profile")
        row = self.db.execute(
            "SELECT generation FROM profile_epochs WHERE profile_id=?", (profile_id,)
        ).fetchone()
        return entry, row[0]

    def status(self, profile_id):
        entry, generation = self.profile(profile_id)
        result = {}
        for capability in CAPABILITIES:
            row = self.db.execute(
                "SELECT generation,identity_hash,result_json FROM model_probes WHERE profile_id=? AND capability=? AND finished_at IS NOT NULL ORDER BY rowid DESC LIMIT 1",
                (profile_id, capability),
            ).fetchone()
            if row is None:
                result[capability] = {"state": "untested"}
            else:
                record = json.loads(row[2])
                result[capability] = {
                    **record,
                    "state": record["status"]
                    if row[0] == generation and row[1] == identity(entry)
                    else "stale",
                }
        return result

    def get(self, probe_id):
        self.store.load_config()  # Version guard.
        row = self.db.execute(
            "SELECT result_json FROM model_probes WHERE probe_id=?", (probe_id,)
        ).fetchone()
        return json.loads(row[0]) if row else None

    def begin(self, probe_id, profile_id, capability, hold):
        if (
            not isinstance(probe_id, str)
            or not _ID.fullmatch(probe_id)
            or capability not in CAPABILITIES
            or type(hold) is not int
            or not 1 <= hold <= 2**53
        ):
            raise ProviderError("invalid_probe")
        with self.store._write():
            existing = self.db.execute(
                "SELECT profile_id,capability,hold_units,result_json FROM model_probes WHERE probe_id=?",
                (probe_id,),
            ).fetchone()
            if existing:
                if existing[:3] != (profile_id, capability, hold):
                    raise ProviderError("probe_id_conflict")
                return None, None, json.loads(existing[3])
            entry, generation = self.profile(profile_id)
            result = dict(
                probe_id=probe_id,
                profile_id=profile_id,
                capability=capability,
                status="pending",
                requested_model=entry["model"],
                checked_at=None,
            )
            self.db.execute(
                "INSERT INTO model_probes VALUES (?,?,?,?,?,?,?,NULL,?)",
                (
                    probe_id,
                    profile_id,
                    generation,
                    identity(entry),
                    capability,
                    hold,
                    _now(),
                    _json(result),
                ),
            )
            return entry, generation, result

    def matches(self, entry, generation):
        try:
            current, current_gen = self.profile(entry["id"])
        except ProviderError:
            return False
        return current_gen == generation and identity(current) == identity(entry)

    def finish(self, probe_id, result, *, budget=None, usage=None):
        with self.store._write():
            row = self.db.execute(
                "SELECT profile_id,generation,identity_hash,result_json FROM model_probes WHERE probe_id=?",
                (probe_id,),
            ).fetchone()
            previous = json.loads(row[3])
            result = {**previous, **result, "checked_at": _now()}
            try:
                entry, generation = self.profile(row[0])
                current = generation == row[1] and identity(entry) == row[2]
            except ProviderError:
                current = False
            if not current:
                result["status"] = "stale"
            self.db.execute(
                "UPDATE model_probes SET finished_at=?,result_json=? WHERE probe_id=?",
                (result["checked_at"], _json(result), probe_id),
            )
            if budget is not None:
                budget._settle(
                    "probe." + probe_id, units=None, usage=usage or {}, cost_source="unknown"
                )
            if current:
                self._sync_capabilities({row[0]})
        return result

    def _sync_capabilities(self, profile_ids):
        # Caller owns the transaction that changes verification records.
        revision, config = self.store.load_config()
        changed = False
        for profile in config["model_profiles"]:
            if profile["id"] not in profile_ids:
                continue
            capabilities = [
                cap
                for cap, state in self.status(profile["id"]).items()
                if state["state"] == "verified"
            ]
            if profile["capabilities"] != capabilities:
                profile["capabilities"] = capabilities
                changed = True
        if changed:
            self.db.execute(
                "UPDATE app_configuration SET revision=?,document=? WHERE id=1",
                (revision + 1, _json(config)),
            )

    def recover_interrupted(self):
        with self.store._write():
            rows = self.db.execute(
                "SELECT probe_id,profile_id,result_json FROM model_probes WHERE finished_at IS NULL"
            ).fetchall()
            for probe_id, _profile_id, payload in rows:
                result = {
                    **json.loads(payload),
                    "status": "outcome_unknown",
                    "error_kind": "interrupted",
                    "checked_at": _now(),
                }
                self.db.execute(
                    "UPDATE model_probes SET finished_at=?,result_json=? WHERE probe_id=?",
                    (result["checked_at"], _json(result), probe_id),
                )
            self._sync_capabilities({row[1] for row in rows})
            return len(rows)


def _probe_image():
    # A synthetic red 64x64 PNG; no user image or external media is read.
    def chunk(kind, value):
        return (
            struct.pack(">I", len(value))
            + kind
            + value
            + struct.pack(">I", zlib.crc32(kind + value))
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0" * 64) * 64))
        + chunk(b"IEND", b"")
    )


class ProbeService:
    def __init__(self, store, backend, *, adapter_factory=ProviderAdapter, image_factory=None):
        self.store = store
        self.backend = backend
        self.registry = ProfileRegistry(store)
        self.budget = BudgetLedger(store)
        self.adapter_factory = adapter_factory
        self.image_factory = image_factory

    async def probe(self, probe_id, profile_id, capability, hold):
        entry, generation, existing = self.registry.begin(probe_id, profile_id, capability, hold)
        if entry is None:
            return existing
        image_probe = capability == "image" and self.image_factory is not None
        if capability not in {"text", "vision"} and not image_probe:
            return self.registry.finish(
                probe_id, {"status": "probe_unavailable", "error_kind": "adapter_not_implemented"}
            )
        attempt_id = "probe." + probe_id
        begun = reserved = False
        adapter = None
        try:
            if entry["provider"] not in PROVIDERS:
                raise ProviderError("unsupported_provider")
            if entry["credential_ref"] is None:
                raise ProviderError("credential_missing")
            key = await asyncio.to_thread(self.backend.read, entry["credential_ref"])
            if key is None:
                raise ProviderError("credential_missing")
            if not self.registry.matches(entry, generation):
                raise ProviderError("configuration_changed")
            adapter = (
                self.image_factory(entry, key) if image_probe else self.adapter_factory(entry, key)
            )
            nonce = uuid4().hex
            request = ModelRequest(
                entry["partition"],
                "Perform only this synthetic capability check.",
                "Reply exactly: " + nonce,
                max_output_tokens=128,
                validator=lambda text: text.strip() == nonce,
                reasoning_none=True,
            )
            if capability == "vision":
                request = ModelRequest(
                    entry["partition"],
                    "Describe only the dominant color of the image in one English word.",
                    "What is the dominant color?",
                    max_output_tokens=128,
                    image=_probe_image(),
                    image_mime="image/png",
                    validator=lambda text: text.strip().lower().rstrip(".") == "red",
                    reasoning_none=True,
                )
            if not image_probe:
                adapter.payload(request)  # Validate before reserving or dispatching.
            self.budget.reserve(
                attempt_id,
                attempt_id,
                max_units=hold,
                quote={"known": False, "source": "manual_hold"},
                partition=entry["partition"],
                provider=entry["provider"],
                image=image_probe,
            )
            reserved = True
            self.budget.begin_attempt(attempt_id)
            begun = True
            if image_probe:
                from .media.source_images import ImageError, normalize_photo

                raster, usage = await adapter.generate(
                    "Draw one small solid black circle centered on a clean white portrait page. No text."
                )
                try:
                    normalize_photo(raster, "image/jpeg")
                except ImageError:
                    raise ProviderError(
                        "invalid_generated_image", outcome="known", usage=usage
                    ) from None
                result = {"reported_model": None, "response_id": None, "usage": usage}
            else:
                result = await adapter.generate(request)
            return self.registry.finish(
                probe_id,
                {
                    "status": "verified",
                    "reported_model": result["reported_model"],
                    "response_id": result["response_id"],
                    "usage": result["usage"],
                },
                budget=self.budget,
                usage=result["usage"],
            )
        except asyncio.CancelledError:
            if begun:
                self.budget.mark_unknown(attempt_id)
            elif reserved:
                self.budget.release(attempt_id)
            self.registry.finish(
                probe_id,
                {"status": "outcome_unknown" if begun else "cancelled", "error_kind": "cancelled"},
            )
            raise
        except BudgetError as exc:
            if reserved and not begun:
                self.budget.release(attempt_id)
            return self.registry.finish(
                probe_id, {"status": "budget_blocked", "error_kind": str(exc)}
            )
        except (ProviderError, CredentialError) as exc:
            code = str(exc)
            outcome = exc.outcome if isinstance(exc, ProviderError) else "not_sent"
            if begun and outcome == "not_sent":
                self.budget.mark_unknown(attempt_id)
                self.budget.reconcile(attempt_id, units=0, reason="provider_confirmation")
            elif begun and outcome == "unknown":
                self.budget.mark_unknown(attempt_id)
            return self.registry.finish(
                probe_id,
                {
                    "status": "outcome_unknown" if outcome == "unknown" else "failed",
                    "error_kind": code,
                },
                budget=self.budget if begun and outcome == "known" else None,
                usage=getattr(exc, "usage", {}),
            )
        except (sqlite3.Error, OSError):
            # Intent/inflight is already durable. Recovery conservatively retains
            # the hold; a repeated probe ID cannot repeat the request.
            raise ProviderError(
                "probe_storage_failed", outcome="unknown" if begun else "not_sent"
            ) from None
        finally:
            if adapter is not None:
                await adapter.close()
