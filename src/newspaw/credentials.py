"""Keychain references and serialized, recoverable local credential changes."""

from __future__ import annotations

import asyncio
import hmac
import io
import os
import stat
import sys
from pathlib import Path
from uuid import uuid4

from dotenv import dotenv_values

from .app_config import _CREDENTIAL, validate_config


class CredentialError(ValueError):
    """Only fixed public diagnostic codes, never backend exception text."""


def _reference(ref):
    if not isinstance(ref, str) or not _CREDENTIAL.fullmatch(ref):
        raise CredentialError("invalid_credential_reference")


def _value(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 4096 or any(ord(c) < 32 for c in value):
        raise CredentialError("invalid_credential")


def references(document):
    return {
        entry["credential_ref"]
        for kind in ("model_profiles", "bots")
        for entry in document[kind]
        if entry["credential_ref"] is not None
    }


class MacKeychain:
    def __init__(self, *, service="io.newspaw.credentials"):
        if sys.platform != "darwin":
            raise CredentialError("keychain_requires_macos")
        try:
            from keyring.backends.macOS import Keyring
            from keyring.errors import KeyringLocked

            self._locked_exception = KeyringLocked

            self.backend = Keyring()
            self.backend.keychain = None
            self.service = service
        except Exception:
            raise CredentialError("keychain_unavailable") from None

    def _call(self, operation, ref, *args):
        _reference(ref)
        try:
            return getattr(self.backend, operation)(self.service, ref, *args)
        except Exception as exc:
            cause = exc.__cause__
            codes = getattr(cause, "args", ())
            if isinstance(exc, getattr(self, "_locked_exception", ())) or -25308 in codes:
                raise CredentialError("keychain_locked") from None
            if -25293 in codes or -128 in codes:
                raise CredentialError("keychain_denied") from None
            raise CredentialError("keychain_unavailable") from None

    def write(self, ref, value):
        _value(value)
        return self._call("set_password", ref, value)

    def read(self, ref):
        return self._call("get_password", ref)

    def delete(self, ref):
        if self.read(ref) is not None:
            self._call("delete_password", ref)


def read_legacy(path):
    path = Path(path)
    if not path.is_absolute():
        raise CredentialError("legacy_path_invalid")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise CredentialError("legacy_file_not_private")
            data = handle.read(65537)
        if len(data) > 65536:
            raise CredentialError("legacy_file_too_large")
        return dotenv_values(stream=io.StringIO(data.decode("utf-8")), interpolate=False)
    except CredentialError:
        raise
    except Exception:
        raise CredentialError("legacy_file_unreadable") from None


class CredentialManager:
    def __init__(self, store, backend):
        self.store = store
        self.backend = backend
        self._lock = asyncio.Lock()
        self._tasks = set()

    async def _submit(self, operation):
        async def run():
            async with self._lock:
                try:
                    return await operation()
                except CredentialError:
                    raise
                except Exception:
                    raise CredentialError("configuration_operation_failed") from None

        task = asyncio.create_task(run())
        self._tasks.add(task)

        def finished(task):
            self._tasks.discard(task)
            if not task.cancelled():
                task.exception()  # Observe disconnected clients' completed operations.

        task.add_done_callback(finished)
        return await asyncio.shield(task)

    async def drain(self):
        while self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)

    def _current(self, revision):
        actual, document = self.store.load_config()
        if type(revision) is not int or revision != actual:
            raise CredentialError("config_conflict")
        return document

    async def _cleanup(self):
        used = references(self.store.load_config()[1])
        errors = {}
        for ref in self.store.pending_credentials():
            try:
                if ref not in used:
                    await asyncio.to_thread(self.backend.delete, ref)
                self.store.finish_credential(ref)
            except CredentialError as exc:
                errors[ref] = str(exc)
            except Exception:
                errors[ref] = "cleanup_failed"
        return {"cleanup_pending": len(self.store.pending_credentials()), "cleanup_errors": errors}

    async def cleanup(self):
        return await self._submit(self._cleanup)

    async def status(self):
        if self._tasks:
            return {"pending": True, "cleanup_pending": len(self.store.pending_credentials())}

        async def operation():
            states = {}
            for ref in sorted(references(self.store.load_config()[1])):
                try:
                    states[ref] = (
                        "available"
                        if await asyncio.to_thread(self.backend.read, ref) is not None
                        else "missing"
                    )
                except CredentialError as exc:
                    states[ref] = str(exc)
                except Exception:
                    states[ref] = "keychain_unavailable"
            return {
                "pending": False,
                "references": states,
                "cleanup_pending": len(self.store.pending_credentials()),
            }

        return await self._submit(operation)

    async def _commit(self, document, revision, writes=(), *, imported=False):
        validate_config(document)
        original = self._current(revision)
        refs = [ref for ref, value in writes]
        self.store.reserve_credentials(refs)
        try:
            for ref, value in writes:
                await asyncio.to_thread(self.backend.write, ref, value)
                actual = await asyncio.to_thread(self.backend.read, ref)
                if not isinstance(actual, str) or not hmac.compare_digest(
                    actual.encode(), value.encode()
                ):
                    raise CredentialError("keychain_verification_failed")
            self._current(revision)
            new_revision = self.store.commit_credentials(
                document,
                revision,
                retired=references(original) - references(document),
                imported=imported,
            )
        except Exception as exc:
            await self._cleanup()
            if isinstance(exc, CredentialError):
                raise
            raise CredentialError("configuration_commit_failed") from None
        return {"revision": new_revision, **await self._cleanup()}

    @staticmethod
    def _entry(document, kind, identity):
        if kind not in {"model_profiles", "bots"}:
            raise CredentialError("invalid_credential_entity")
        entry = next((e for e in document[kind] if e["id"] == identity), None)
        if entry is None:
            raise CredentialError("missing_credential_entity")
        return entry

    @staticmethod
    def _reset(entry, kind):
        if kind == "bots":
            entry.update(verified=False, paired=False, telegram_id=None, chat_id=None)
        else:
            entry["capabilities"] = []

    async def set(self, kind, identity, value, revision):
        _value(value)

        async def operation():
            document = self._current(revision)
            entry = self._entry(document, kind, identity)
            ref = f"keychain:{uuid4()}"
            entry["credential_ref"] = ref
            self._reset(entry, kind)
            return await self._commit(document, revision, [(ref, value)])

        return await self._submit(operation)

    async def remove(self, kind, identity, revision):
        async def operation():
            document = self._current(revision)
            entry = self._entry(document, kind, identity)
            entry["credential_ref"] = None
            self._reset(entry, kind)
            return await self._commit(document, revision)

        return await self._submit(operation)

    async def save_config(self, document, revision):
        async def operation():
            validate_config(document)
            current = self._current(revision)
            for kind in ("model_profiles", "bots"):
                old = {e["id"]: e for e in current[kind]}
                fields = ["credential_ref"] + (
                    ["verified", "paired", "telegram_id", "chat_id"] if kind == "bots" else []
                )
                for entry in document[kind]:
                    for field in fields:
                        default = False if field in {"verified", "paired"} else None
                        if entry[field] != old.get(entry["id"], {}).get(field, default):
                            raise CredentialError("protected_configuration_field")
            return await self._commit(document, revision)

        return await self._submit(operation)

    async def import_preferences(self, path, revision):
        async def operation():
            self._current(revision)
            values = read_legacy(path)
            self.store.import_legacy_config(values=values)
            return {"revision": self.store.config_revision()}

        return await self._submit(operation)

    async def import_secrets(self, path, revision):
        async def operation():
            document = self._current(revision)
            if self.store.legacy_secrets_imported():
                return {"revision": revision, "already_imported": True}
            values = read_legacy(path)
            writes = []
            key = values.get("OPENAI_API_KEY")
            token = values.get("TELEGRAM_BOT_TOKEN")
            if key:
                _value(key)
                entry = self._entry(document, "model_profiles", "normal_primary")
                if entry["credential_ref"] is not None:
                    raise CredentialError("credential_already_configured")
                entry["credential_ref"] = f"keychain:{uuid4()}"
                self._reset(entry, "model_profiles")
                writes.append((entry["credential_ref"], key))
            if token:
                _value(token)
                if any(b["id"] == "legacy_bot" for b in document["bots"]):
                    raise CredentialError("credential_already_configured")
                ref = f"keychain:{uuid4()}"
                document["bots"].append(
                    dict(
                        id="legacy_bot",
                        name="Imported Bot",
                        credential_ref=ref,
                        telegram_id=None,
                        chat_id=None,
                        verified=False,
                        paired=False,
                        adult_allowed=False,
                    )
                )
                writes.append((ref, token))
            if not writes:
                return {"revision": revision, "no_secrets": True}
            return await self._commit(document, revision, writes, imported=True)

        return await self._submit(operation)
