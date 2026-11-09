"""Local settings, delivery receipts, and durable news provenance in SQLite."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from contextlib import contextmanager
from dataclasses import asdict, is_dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from uuid import uuid4

from newspaw.app_config import import_preferences, validate_config
from newspaw.migrations import check_version, migrate
from newspaw.news import Article, canonical_url

# Retrieval can contain 30 sources x 200 eligible entries before ranking. Keep
# every supplied source snapshot; never silently trim the evidence to UI limits.
MAX_AUDIT_BYTES = 128 * 1024 * 1024
MAX_AUDIT_ITEMS = 6000
MAX_AUDIT_STRING = 20_000
MAX_AUDIT_ARTICLES = 200
AUDIT_RETENTION = 200
_SECRET_KEYS = {
    "apikey",
    "accesstoken",
    "authorization",
    "bottoken",
    "cookie",
    "credentials",
    "password",
    "privatekey",
    "refreshtoken",
    "secret",
    "telegrambottoken",
    "token",
}
_TRANSITIONS = {
    "prepared": {"prepared", "delivered", "partial", "failed"},
    "partial": {"partial", "delivered", "failed"},
    "failed": {"failed", "prepared"},
    "delivered": {"delivered"},
}


def _secret_key(value: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", value.lower())
    return normalized in _SECRET_KEYS or normalized.endswith(
        ("apikey", "password", "secret", "token", "privatekey", "authorization")
    )


def _safe_audit_value(value, depth: int = 0):
    """Keep JSON evidence bounded and exclude credentials and binary media.

    Callers supply structured collection reports, never request headers, raw
    provider responses, or downloaded media. Recognized secret fields and URL
    credentials are redacted as a second line of protection.
    """
    if depth > 12:
        raise ValueError("Audit payload is nested too deeply.")
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if is_dataclass(value) and not isinstance(value, type):
        return _safe_audit_value(asdict(value), depth + 1)
    if isinstance(value, dict):
        if len(value) > 500 or not all(isinstance(key, str) for key in value):
            raise ValueError("Audit objects require at most 500 string keys.")
        return {
            key: "[REDACTED]" if _secret_key(key) else _safe_audit_value(item, depth + 1)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        if len(value) > MAX_AUDIT_ITEMS:
            raise ValueError(f"Audit lists may contain at most {MAX_AUDIT_ITEMS} entries.")
        return [_safe_audit_value(item, depth + 1) for item in value]
    if isinstance(value, str):
        if len(value) > MAX_AUDIT_STRING:
            raise ValueError("Audit text exceeds the storage limit.")
        if value.lstrip().lower().startswith("data:"):
            raise ValueError("Inline media must not be stored in audit records.")
        if value.startswith(("https://", "http://")):
            parsed = urlsplit(value)
            query = [
                (key, "[REDACTED]" if _secret_key(key) else item)
                for key, item in parse_qsl(parsed.query, keep_blank_values=True)
            ]
            if parsed.username or parsed.password or any(_secret_key(key) for key, _ in query):
                # Preserve the host/path for attribution without retaining URL
                # credentials or tokens from a private feed URL.
                netloc = parsed.netloc.rsplit("@", 1)[-1]
                return urlunsplit(
                    (parsed.scheme, netloc, parsed.path, urlencode(query), parsed.fragment)
                )
        return value
    if value is None or isinstance(value, (bool, int, float)):
        return value
    raise ValueError("Audit records accept JSON values and dates, not binary media.")


def _audit_json(value) -> str:
    try:
        payload = json.dumps(_safe_audit_value(value), ensure_ascii=False, allow_nan=False)
    except (TypeError, OverflowError) as exc:
        raise ValueError("Audit payload is not valid JSON.") from exc
    if len(payload.encode("utf-8")) > MAX_AUDIT_BYTES:
        raise ValueError("Audit payload exceeds the storage limit.")
    return payload


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _article_key(article: Article) -> str:
    return hashlib.sha256(canonical_url(article.url).encode("utf-8")).hexdigest()


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
            legacy = dict(self._db.execute("SELECT key, value FROM settings"))
            document = import_preferences(env_path, legacy, values=values)
            # A successful secrets-only import may precede untouched preference import.
            old_profiles = {p["id"]: p for p in current["model_profiles"]}
            for profile in document["model_profiles"]:
                if profile["id"] in old_profiles:
                    profile["credential_ref"] = old_profiles[profile["id"]]["credential_ref"]
            document["bots"] = current["bots"]
            document["x_api"] = current["x_api"]
            self._save_config_tx(document, revision)
            self._db.execute("INSERT INTO migration_info VALUES ('legacy_imported', ?)", (_now(),))

    def get(self, key: str, default: str | None = None) -> str | None:
        check_version(self._db)
        row = self._db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row[0] if row else default

    def set(self, key: str, value: str) -> None:
        with self._write():
            self._db.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )

    def unseen(self, chat_id: int, articles: list[Article], scope: str = "news") -> list[Article]:
        check_version(self._db)
        self._validate_scope(scope)
        seen: set[str] = set()
        result = []
        for article in articles:
            key = _article_key(article)
            if key in seen:
                continue
            seen.add(key)
            row = self._db.execute(
                "SELECT 1 FROM deliveries_v2 WHERE chat_id = ? AND scope = ? AND article_key = ?",
                (chat_id, scope, key),
            ).fetchone()
            if row is None:
                result.append(article)
        return result

    @staticmethod
    def _validate_scope(scope: str) -> None:
        if not isinstance(scope, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,39}", scope):
            raise ValueError("Delivery scope must be a short identifier.")

    def mark_sent(self, chat_id: int, article: Article, scope: str = "news") -> None:
        self._validate_scope(scope)
        with self._write():
            self._db.execute(
                "INSERT OR IGNORE INTO deliveries_v2 (chat_id, scope, article_key) VALUES (?, ?, ?)",
                (chat_id, scope, _article_key(article)),
            )

    def save_collection(self, report: dict) -> str:
        """Persist successful or failed collection evidence before publishing."""
        if not isinstance(report, dict):
            raise ValueError("A collection report must be an object.")
        payload = _audit_json(report)
        collection_id = f"collection_{uuid4().hex}"
        with self._write():
            self._db.execute(
                "INSERT INTO collections (id, created_at, report_json) VALUES (?, ?, ?)",
                (collection_id, _now(), payload),
            )
            self._prune_audit(AUDIT_RETENTION)
        return collection_id

    def _prune_audit(self, keep: int) -> int:
        # Delete children first to preserve the foreign-key invariant on both
        # databases created now and those created before retention existed.
        oldest = "SELECT id FROM collections ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?"
        self._db.execute(f"DELETE FROM briefs WHERE collection_id IN ({oldest})", (keep,))
        return self._db.execute(f"DELETE FROM collections WHERE id IN ({oldest})", (keep,)).rowcount

    def prune_audit(self, keep: int = AUDIT_RETENTION) -> int:
        """Keep newest collection journals and their briefs; preserve receipts.

        Returns the number of removed collections. SQLite reuses freed pages;
        pruning does not force a blocking VACUUM or shrink the file immediately.
        """
        if not isinstance(keep, int) or isinstance(keep, bool) or keep < 0:
            raise ValueError("Audit retention must be a non-negative integer.")
        with self._write():
            return self._prune_audit(keep)

    def save_brief(
        self, collection_id: str, articles: list[Article], summary: str, kind: str = "manual"
    ) -> str:
        """Save exactly the selected source evidence before attempting delivery."""
        if len(articles) > MAX_AUDIT_ARTICLES or not all(
            isinstance(item, Article) for item in articles
        ):
            raise ValueError("A brief requires at most 200 Article records.")
        if not isinstance(summary, str):
            raise ValueError("A brief summary must be text.")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,39}", kind):
            raise ValueError("Brief kind must be a short identifier.")
        articles_json = _audit_json(articles)
        safe_summary = _safe_audit_value(summary)
        brief_id = f"brief_{uuid4().hex}"
        timestamp = _now()
        with self._write():
            if (
                self._db.execute(
                    "SELECT 1 FROM collections WHERE id = ?", (collection_id,)
                ).fetchone()
                is None
            ):
                raise ValueError("Collection does not exist.")
            self._db.execute(
                "INSERT INTO briefs "
                "(id, collection_id, created_at, updated_at, articles_json, summary, kind, status) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 'prepared')",
                (brief_id, collection_id, timestamp, timestamp, articles_json, safe_summary, kind),
            )
        return brief_id

    def mark_brief(self, brief_id: str, status: str, error_kind: str = "") -> None:
        """Record delivery outcome; a delivered brief cannot be downgraded."""
        if status not in _TRANSITIONS:
            raise ValueError("Unknown brief status.")
        if error_kind and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]{0,119}", error_kind):
            raise ValueError("error_kind must be an exception identifier, not an error message.")
        if status in {"prepared", "delivered"} and error_kind:
            raise ValueError("Prepared or delivered briefs cannot have an error kind.")
        with self._write():
            row = self._db.execute("SELECT status FROM briefs WHERE id = ?", (brief_id,)).fetchone()
            if row is None:
                raise ValueError("Brief does not exist.")
            if status not in _TRANSITIONS[row[0]]:
                raise ValueError(f"Invalid brief transition: {row[0]} to {status}.")
            self._db.execute(
                "UPDATE briefs SET status = ?, error_kind = ?, updated_at = ? WHERE id = ?",
                (status, error_kind, _now(), brief_id),
            )

    def get_collection(self, collection_id: str) -> dict | None:
        check_version(self._db)
        row = self._db.execute(
            "SELECT id, created_at, report_json FROM collections WHERE id = ?", (collection_id,)
        ).fetchone()
        return (
            {"collection_id": row[0], "created_at": row[1], "report": json.loads(row[2])}
            if row
            else None
        )

    def get_audit(self, limit: int = 5) -> list[dict]:
        """Return newest collections and their most recent brief, if any.

        Failed/empty collections remain visible even when no brief was created.
        Reads are capped at 100 collections; each payload is bounded on write.
        """
        check_version(self._db)
        if not isinstance(limit, int) or isinstance(limit, bool):
            raise ValueError("Audit limit must be an integer.")
        rows = self._db.execute(
            "SELECT c.id, c.created_at, c.report_json, b.id, b.created_at, b.updated_at, "
            "b.articles_json, b.summary, b.kind, b.status, b.error_kind "
            "FROM collections c LEFT JOIN briefs b ON b.id = "
            "(SELECT id FROM briefs WHERE collection_id = c.id ORDER BY created_at DESC, rowid DESC LIMIT 1) "
            "ORDER BY c.created_at DESC, c.rowid DESC LIMIT ?",
            (max(0, min(limit, 100)),),
        ).fetchall()
        return [
            {
                "collection_id": row[0],
                "created_at": row[1],
                "report": json.loads(row[2]),
                "brief": {
                    "brief_id": row[3],
                    "created_at": row[4],
                    "updated_at": row[5],
                    "articles": json.loads(row[6]),
                    "summary": row[7],
                    "kind": row[8],
                    "status": row[9],
                    "error_kind": row[10],
                }
                if row[3]
                else None,
            }
            for row in rows
        ]

    def close(self) -> None:
        self._db.close()
