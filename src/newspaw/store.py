"""Local configuration, credential journal, and migration markers in SQLite."""

from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from newspaw.app_config import import_preferences, validate_config
from newspaw.migrations import check_version, migrate


def _now() -> str:
    return datetime.now(UTC).isoformat()


class Store:
    def __init__(self, path: Path) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.parent.chmod(0o700)
        # Create/chmod the database before opening WAL files so SQLite inherits
        # private permissions for those sidecars as well.
        path.touch(mode=0o600, exist_ok=True)
        path.chmod(0o600)
        self._db = sqlite3.connect(path, timeout=10)
        self._write_depth = 0
        try:
            check_version(self._db)
            self._db.execute("PRAGMA foreign_keys=ON")
            self._db.execute("PRAGMA busy_timeout=10000")
            migrate(self._db, path)
            self._db.execute("PRAGMA journal_mode=WAL")
        except BaseException:
            self._db.close()
            raise

    @contextmanager
    def _write(self):
        if self._write_depth:
            # A write inside another (e.g. a settings import applying each policy through its
            # owner): a savepoint that commits or rolls back with the outer write (E10 R05).
            self._db.execute("SAVEPOINT nested_write")
            self._write_depth += 1
            try:
                yield
                self._db.execute("RELEASE nested_write")
            except BaseException:
                self._db.execute("ROLLBACK TO nested_write")
                self._db.execute("RELEASE nested_write")
                raise
            finally:
                self._write_depth -= 1
            return
        self._db.execute("BEGIN IMMEDIATE")
        self._write_depth = 1
        try:
            check_version(self._db)
            yield
            self._db.commit()
        except BaseException:
            self._db.rollback()
            raise
        finally:
            self._write_depth = 0

    def load_config(self) -> tuple[int, dict]:
        check_version(self._db)
        row = self._db.execute(
            "SELECT revision, document FROM app_configuration WHERE id=1"
        ).fetchone()
        if row is None:
            raise ValueError("Missing application configuration")
        document = json.loads(row[1])
        validate_config(document)
        return row[0], document

    def save_config(self, document: dict, *, expected_revision: int) -> int:
        with self._write():
            return self._save_config_tx(document, expected_revision)

    def _save_config_tx(self, document: dict, expected_revision: int) -> int:
        """Write configuration and invalidate dependent identities in the caller transaction."""
        from .providers import invalidate_profiles
        from .source_manager import invalidate_sources
        from .telegram.registry import invalidate_bots
        from .x.accounts import invalidate_accounts

        if not self._db.in_transaction:
            raise RuntimeError("Configuration write requires a transaction")
        validate_config(document)
        if type(expected_revision) is not int or expected_revision < 1:
            raise ValueError("Invalid expected configuration revision")
        revision, current = self.load_config()
        if revision != expected_revision:
            raise ValueError("Configuration changed; reload before saving")
        document = invalidate_profiles(self._db, current, document)
        document = invalidate_bots(self._db, current, document)
        document = invalidate_sources(self._db, current, document)
        invalidate_accounts(self._db, current, document)
        changed = self._db.execute(
            "UPDATE app_configuration SET document=?,revision=revision+1 WHERE id=1 AND revision=?",
            (json.dumps(document, ensure_ascii=False, allow_nan=False), revision),
        ).rowcount
        if changed != 1:
            raise ValueError("Configuration changed; reload before saving")
        return revision + 1

    def pending_credentials(self) -> list[str]:
        check_version(self._db)
        return [
            row[0] for row in self._db.execute("SELECT ref FROM credential_intents ORDER BY ref")
        ]

    def reserve_credentials(self, refs) -> None:
        from .app_config import _CREDENTIAL

        refs = list(refs)
        if any(not isinstance(ref, str) or not _CREDENTIAL.fullmatch(ref) for ref in refs):
            raise ValueError("Invalid credential reference")
        with self._write():
            self._db.executemany(
                "INSERT OR IGNORE INTO credential_intents VALUES (?)", [(ref,) for ref in refs]
            )

    def finish_credential(self, ref) -> None:
        with self._write():
            self._db.execute("DELETE FROM credential_intents WHERE ref=?", (ref,))

    def legacy_secrets_imported(self) -> bool:
        check_version(self._db)
        return bool(
            self._db.execute(
                "SELECT 1 FROM migration_info WHERE key='legacy_secrets_imported'"
            ).fetchone()
        )

    def commit_credentials(self, document, expected_revision, *, retired=(), imported=False) -> int:
        with self._write():
            eligible = self._db.execute(
                "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
            ).fetchone()
            self._save_config_tx(document, expected_revision)
            self._db.executemany(
                "INSERT OR IGNORE INTO credential_intents VALUES (?)", [(ref,) for ref in retired]
            )
            if imported:
                self._db.execute(
                    "INSERT INTO migration_info VALUES ('legacy_secrets_imported', ?)", (_now(),)
                )
                if expected_revision == (int(eligible[0]) if eligible else 1):
                    self._db.execute(
                        "INSERT OR REPLACE INTO migration_info VALUES ('untouched_import_revision', ?)",
                        (str(expected_revision + 1),),
                    )
        return expected_revision + 1

    def config_revision(self) -> int:
        """Durable invalidation signal, shared by all local consumers."""
        check_version(self._db)
        return self._db.execute("SELECT revision FROM app_configuration WHERE id=1").fetchone()[0]

    def preview_route(self, subscription_id, *, account_id=None, style=None):
        from .routing import resolve_route

        revision, config = self.load_config()
        return resolve_route(config, revision, subscription_id, account_id=account_id, style=style)

    def revalidate_route(self, snapshot):
        from .routing import RouteBlocked, RouteStale

        current = self.preview_route(
            snapshot.subscription_id, account_id=snapshot.account_id, style=snapshot.request_style
        )
        if current.blockers:
            raise RouteBlocked(current.blockers)
        if current.fingerprint != snapshot.fingerprint:
            raise RouteStale("Effective route changed; rebuild pending work")
        return current

    def migration_cutover(self) -> str:
        check_version(self._db)
        return self._db.execute("SELECT value FROM migration_info WHERE key='cutover'").fetchone()[
            0
        ]

    def import_legacy_config(self, env_path: Path | None = None, *, values=None) -> None:
        """Explicit, once-only preference import. Never starts jobs or imports keys."""
        with self._write():
            if self._db.execute(
                "SELECT 1 FROM migration_info WHERE key='legacy_imported'"
            ).fetchone():
                return
            revision, current = self.load_config()
            eligible = self._db.execute(
                "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
            ).fetchone()
            if revision != (int(eligible[0]) if eligible else 1) or any(
                s["enabled"] for s in current["subscriptions"]
            ):
                raise ValueError("Legacy import requires untouched disabled configuration")
            # Databases created by v0.5.0 or earlier keep the old bot's `settings` table;
            # new databases no longer create it, so their legacy preferences are empty.
            has_legacy = self._db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'"
            ).fetchone()
            legacy = dict(self._db.execute("SELECT key, value FROM settings")) if has_legacy else {}
            document = import_preferences(env_path, legacy, values=values)
            # A successful secrets-only import may precede untouched preference import.
            old_profiles = {p["id"]: p for p in current["model_profiles"]}
            for profile in document["model_profiles"]:
                if profile["id"] in old_profiles:
                    profile["credential_ref"] = old_profiles[profile["id"]]["credential_ref"]
            document["bots"] = current["bots"]
            document["x_api"] = current["x_api"]
            document["speech_api"] = current["speech_api"]
            self._save_config_tx(document, revision)
            self._db.execute("INSERT INTO migration_info VALUES ('legacy_imported', ?)", (_now(),))

    def close(self) -> None:
        self._db.close()
