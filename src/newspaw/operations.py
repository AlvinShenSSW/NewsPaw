"""Private operational views, portable settings and bounded local cleanup."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
from collections import Counter
from contextlib import closing
from copy import deepcopy
from datetime import UTC, datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import unquote, urlsplit

from .app_config import default_config, upgrade_v2, uses_category_sources, validate_config
from .budget import BudgetLedger, default_policy
from .credentials import CredentialError
from .evidence import EvidenceError, EvidenceStore
from .media.input_service import _POLICY as MEDIA_DEFAULT
from .media.paper_service import _POLICY as NEWSPAPER_DEFAULT
from .media.source_images import AssetStore, ImageError
from .migrations import DATABASE_VERSION
from .providers import ProfileRegistry
from .scheduler import _LEASE_STATES, _TERMINAL
from .store import AUDIT_RETENTION
from .x.alerts import _DEFAULT as X_ALERT_DEFAULT
from .x.video import _DEFAULT as X_VIDEO_DEFAULT

_FORMAT = 1
_MAX_PORTABLE = 512 * 1024
_MAX_BACKUP = 64 * 1024 * 1024
# Each release adds these tables to the previous on-disk schema.
_BACKUP_TABLES = {
    0: "settings deliveries",
    1: "app_configuration migration_info deliveries_v2 collections briefs",
    3: "credential_intents",
    4: "budget_policy budget_periods budget_tasks budget_attempts",
    5: "feed_associations feed_attempts feed_cache feed_health_policy feed_snapshots",
    6: "profile_epochs model_probes",
    7: "model_attempts model_health model_tasks",
    8: "editorial_editions",
    9: "connector_identity",
    10: "bot_inbox bot_registrations",
    11: "source_readiness",
    12: "pipeline_jobs pipeline_events",
    13: "delivery_manifests delivery_targets",
    14: "schedule_policy schedule_scopes schedule_occurrences",
    15: "x_identities x_lists x_operations",
    16: "web_search_policy web_search_requests",
    17: "command_replies",
    18: "x_posts x_post_observations x_timeline_cursors x_timeline_scans x_timeline_steps",
    19: "x_digest_links",
    20: "newspaper_policy newspapers newspaper_effects",
    21: "telegram_media_policy telegram_media_effects",
    22: "bot_test_sends",
    23: "x_alert_policy x_alerts x_alert_posts x_alert_checked x_video_policy x_video_receipts",
}
_SETTINGS_DEFAULTS = {
    "newspaper_policy": NEWSPAPER_DEFAULT,
    "telegram_media_policy": MEDIA_DEFAULT,
    "x_alert_policy": X_ALERT_DEFAULT,
    "x_video_policy": X_VIDEO_DEFAULT,
}
_INITIAL_TABLES = {
    "app_configuration",
    "migration_info",
    "budget_policy",
    "schedule_policy",
    "web_search_policy",
    "source_readiness",
    "profile_epochs",
    *_SETTINGS_DEFAULTS,
}
_SCHEDULE_STATES = _LEASE_STATES | _TERMINAL | {"rescheduled"}

_ASSET_FILE = re.compile(r"(?:source|paper)_[a-f0-9]{64}\.jpg")
_GENERATED_ID = re.compile(
    r"(?:categories|subscriptions|sources|bots|accounts|model_profiles)_[a-f0-9]{32}"
)
_SECRET = re.compile(
    r"(?i)(keychain:|authorization\b|bearer\s|password|api[_-]?key|access[_-]?token|"
    r"sk-[a-z0-9_-]{12,}|[0-9]{5,}:[a-z0-9_-]{16,}|[a-f0-9]{32,}|[a-z0-9_-]{56,})"
)
_SOURCE_STATES = {
    "fresh",
    "stale",
    "empty",
    "no_eligible",
    "not_modified",
    "failed",
    "unverified",
    "never_attempted",
    "configuration_changed",
    "unsupported_source",
}
_JOB_STATES = {
    "collecting",
    "editing",
    "preparing_media",
    "awaiting_delivery",
    "no_news",
    "collection_failed",
    "stale",
    "cancelled",
    "blocked",
    "refused",
}
_ATTEMPT_STATES = {
    "inflight",
    "outcome_unknown",
    "completed",
    "failed",
    "refused",
    "succeeded",
    "pending",
    "waiting",
    "cancelled",
    "stale",
}
_DELIVERY_STATES = {
    "pending",
    "inflight",
    "delivered",
    "owner_confirmed",
    "skipped",
    "failed",
    "outcome_unknown",
    "rejected",
}


class OperationsError(CredentialError):
    pass


def _now():
    return datetime.now(UTC)


def _json(value):
    try:
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
        )
    except (TypeError, ValueError, RecursionError):
        raise OperationsError("invalid_portable_settings") from None


def _portable_url(value):
    parts = urlsplit(value)
    decoded = unquote(parts.path)
    return not (
        parts.query
        or parts.fragment
        or parts.username
        or parts.password
        or parts.port not in {None, 443}
        or _SECRET.search(decoded)
    )


def _safe_counts(values, allowed):
    return dict(Counter(value if value in allowed else "other" for value in values))


def _scrub_settings(document):
    config = deepcopy(document)
    omitted = Counter()
    config["owner_id"] = None
    config["x_api"] = {"credential_ref": None}
    defaults = {profile["provider"]: profile for profile in default_config()["model_profiles"]}
    sources = []
    for source in config["sources"]:
        if not _portable_url(source["url"]):
            omitted["source_urls"] += 1
            continue
        source["enabled"] = False
        sources.append(source)
    config["sources"] = sources
    available_sources = {source["id"] for source in sources}
    for sub in config["subscriptions"]:
        sub["enabled"] = False
        inherited = uses_category_sources(sub)
        sub["source_ids"] = [
            identity for identity in sub["source_ids"] if identity in available_sources
        ]
        if not inherited and not sub["source_ids"]:
            sub["source_mode"] = "explicit"
    profiles = []
    for profile in config["model_profiles"]:
        official = defaults.get(profile["provider"])
        if official is None:
            omitted["model_profiles"] += 1
            continue
        if profile["base_url"] != official["base_url"]:
            profile["base_url"] = official["base_url"]
            omitted["model_urls"] += 1
        if _SECRET.search(profile["model"]):
            profile["model"] = official["model"]
            omitted["model_names"] += 1
        profile.update(credential_ref=None, capabilities=[])
        profiles.append(profile)
    config["model_profiles"] = profiles
    available_profiles = {profile["id"] for profile in profiles}
    for category in config["categories"]:
        for key in ("primary_profile_id", "backup_profile_id"):
            if category[key] not in available_profiles:
                category[key] = None
    for bot in config["bots"]:
        bot.update(
            credential_ref=None, telegram_id=None, chat_id=None, paired=False, verified=False
        )
    for account in config["accounts"]:
        account["remote_id"] = None
    for group in ("categories", "subscriptions", "sources", "bots"):
        for entry in config[group]:
            if _SECRET.search(entry["name"]):
                entry["name"] = "NewsPaw " + group.rstrip("s")
                omitted["labels"] += 1
    for group in ("categories", "subscriptions", "sources", "bots", "accounts", "model_profiles"):
        if any(
            _SECRET.search(entry["id"]) and not _GENERATED_ID.fullmatch(entry["id"])
            for entry in config[group]
        ):
            raise OperationsError("settings_not_portable")
    validate_config(config)
    return config, dict(omitted)


class Operations:
    def __init__(
        self,
        store,
        directory,
        *,
        process_status=lambda: "stopped",
        clock=_now,
        purge_x=None,
        log_directory=None,
    ):
        self.store, self.db = store, store._db
        self.directory = Path(directory)
        self.database_name = Path(self.db.execute("PRAGMA database_list").fetchone()[2]).name
        self.process_status, self.clock = process_status, clock
        self.purge_x = purge_x
        self.log_directory = Path(log_directory) if log_directory is not None else None
        self.backup_tables = {
            name: self._columns(self.db, name)
            for (name,) in self.db.execute(
                "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"
            )
        }

    @staticmethod
    def _columns(db, name):
        return {row[0] for row in db.execute("SELECT name FROM pragma_table_info(?)", (name,))}

    def export_settings(self):
        config, omitted = _scrub_settings(self.store.load_config()[1])
        portable = dict(format=_FORMAT, settings=config, omitted=omitted)
        if len(_json(portable).encode()) > _MAX_PORTABLE:
            raise OperationsError("settings_not_portable")
        return portable

    def _fresh(self):
        revision, config = self.store.load_config()
        untouched = self.db.execute(
            "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
        ).fetchone()
        eligible_revision = int(untouched[0]) if untouched else 1
        if (
            revision != eligible_revision
            or config != default_config()
            or any(
                self.db.execute(
                    'SELECT 1 FROM "' + table.replace('"', '""') + '" LIMIT 1'
                ).fetchone()
                for table in sorted(self.backup_tables.keys() - _INITIAL_TABLES)
            )
        ):
            raise OperationsError("restore_requires_fresh_instance")
        schedule_revision, settings = self.db.execute(
            "SELECT revision,settings FROM schedule_policy WHERE id=1"
        ).fetchone()
        if (
            schedule_revision != 1
            or json.loads(settings)["enabled"]
            or BudgetLedger(self.store).policy() != (1, default_policy())
            or self.db.execute(
                "SELECT revision,profile_id FROM web_search_policy WHERE id=1"
            ).fetchone()
            != (1, None)
            or self.db.execute(
                "SELECT 1 FROM migration_info WHERE key='legacy_imported'"
            ).fetchone()
            or self.db.execute(
                "SELECT 1 FROM source_readiness WHERE epoch<>1 OR attempt_id IS NOT NULL LIMIT 1"
            ).fetchone()
            or self.db.execute(
                "SELECT 1 FROM profile_epochs WHERE generation<>1 LIMIT 1"
            ).fetchone()
        ):
            raise OperationsError("restore_requires_fresh_instance")
        for table, default in _SETTINGS_DEFAULTS.items():
            row = self.db.execute(f"SELECT revision,settings FROM {table} WHERE id=1").fetchone()
            if row is None or row[0] != 1 or json.loads(row[1]) != default:
                raise OperationsError("restore_requires_fresh_instance")
        return revision

    def _portable(self, value):
        if (
            not isinstance(value, dict)
            or set(value) != {"format", "settings", "omitted"}
            or type(value["format"]) is not int
            or value["format"] != _FORMAT
            or not isinstance(value["settings"], dict)
            or not isinstance(value["omitted"], dict)
            or len(_json(value).encode()) > _MAX_PORTABLE
        ):
            raise OperationsError("invalid_portable_settings")
        omitted = value["omitted"]
        if set(omitted) - {
            "source_urls",
            "model_urls",
            "model_names",
            "model_profiles",
            "labels",
        } or any(type(count) is not int or not 0 <= count <= 1000 for count in omitted.values()):
            raise OperationsError("invalid_portable_settings")
        settings = value["settings"]
        try:
            if settings.get("schema_version") == 2:
                settings = upgrade_v2(settings)
            validate_config(settings)
            if (
                settings["owner_id"] is not None
                or settings["x_api"]["credential_ref"] is not None
                or any(row["credential_ref"] is not None for row in settings["model_profiles"])
                or any(
                    row["credential_ref"] is not None
                    or row["telegram_id"] is not None
                    or row["chat_id"] is not None
                    or row["verified"]
                    or row["paired"]
                    for row in settings["bots"]
                )
                or any(row["remote_id"] is not None for row in settings["accounts"])
            ):
                raise OperationsError("invalid_portable_settings")
            normalized, additional = _scrub_settings(settings)
        except (TypeError, ValueError, KeyError):
            raise OperationsError("invalid_portable_settings") from None
        return normalized, dict(Counter(omitted) + Counter(additional))

    def _preview(self, value):
        revision = self._fresh()
        settings, omitted = self._portable(value)
        summary = {
            name: len(settings[name])
            for name in (
                "categories",
                "subscriptions",
                "sources",
                "bots",
                "accounts",
                "model_profiles",
            )
        }
        digest = hashlib.sha256(_json([revision, settings, omitted]).encode()).hexdigest()
        return dict(
            revision=revision,
            digest=digest,
            settings=settings,
            omitted=omitted,
            counts=summary,
            scheduling="disabled",
            requires_pairing=bool(settings["bots"]),
        )

    def preview_import(self, value):
        return self._preview(value)

    def apply_import(self, value, digest, revision):
        if type(revision) is not int or not isinstance(digest, str):
            raise OperationsError("invalid_portable_settings")
        with self.store._write():
            if revision != self.store.config_revision():
                raise OperationsError("configuration_changed")
            preview = self._preview(value)
            if digest != preview["digest"] or revision != preview["revision"]:
                raise OperationsError("preview_changed")
            updated = self.store._save_config_tx(preview["settings"], revision)
        return {
            "revision": updated,
            "scheduling": "disabled",
            "requires_pairing": preview["requires_pairing"],
        }

    def _business_budget(self, now):
        output = {}
        for meter in ("model", "x"):
            row = self.db.execute(
                """SELECT id FROM budget_periods WHERE meter=? AND start<=? AND end>?
                   ORDER BY id DESC LIMIT 1""",
                (meter, now.isoformat(), now.isoformat()),
            ).fetchone()
            if row is None:
                output[meter] = {"known": 0, "held": 0, "outcome_unknown": 0}
                continue
            known, held, unknown = self.db.execute(
                """SELECT COALESCE(SUM(settled_units),0),
                   COALESCE(SUM(CASE WHEN settled_units IS NULL THEN reserved_units ELSE 0 END),0),
                   COALESCE(SUM(state='outcome_unknown'),0)
                   FROM budget_attempts WHERE period_id=? AND state<>'released'""",
                row,
            ).fetchone()
            output[meter] = {"known": known, "held": held, "outcome_unknown": unknown}
        return output

    def diagnostics(self):
        _, config = self.store.load_config()
        now = self.clock()
        process = self.process_status()
        if process not in {"running", "stopping", "stopped"}:
            process = "other"
        policy = json.loads(
            self.db.execute("SELECT settings FROM schedule_policy WHERE id=1").fetchone()[0]
        )
        sources = [source for source in config["sources"] if source["enabled"]]
        evidence = EvidenceStore(self.store)
        freshness, retrieval = [], []
        for source in sources[:25]:
            try:
                health = evidence.health(source["id"], now=now)
            except (EvidenceError, KeyError, ValueError):
                freshness.append("unknown")
                retrieval.append("unsupported_source")
                continue
            freshness.append(health["freshness"])
            attempt = health["last_attempt"]
            retrieval.append(attempt["status"] if attempt else "never_attempted")
        profiles = ProfileRegistry(self.store)
        verification = [
            profiles.status(profile["id"])["text"]["state"]
            if profile["credential_ref"]
            else "unconfigured"
            for profile in config["model_profiles"][:50]
        ]
        jobs = [
            row[0]
            for row in self.db.execute(
                "SELECT stage FROM pipeline_jobs ORDER BY rowid DESC LIMIT 50"
            )
        ]
        model = [
            row[0]
            for row in self.db.execute(
                "SELECT state FROM model_attempts ORDER BY rowid DESC LIMIT 100"
            )
        ]
        occurrences = {"subscriptions": [], "special_accounts": []}
        for account, status in self.db.execute(
            """SELECT s.account_id IS NOT NULL,o.status FROM schedule_occurrences o
               JOIN schedule_scopes s ON s.id=o.scope_id
               ORDER BY o.updated_at DESC,o.rowid DESC LIMIT 50"""
        ):
            occurrences["special_accounts" if account else "subscriptions"].append(status)
        delivery = [
            row[0]
            for row in self.db.execute(
                """SELECT json_extract(p.value,'$.state')
               FROM (SELECT parts FROM delivery_targets ORDER BY rowid DESC LIMIT 50) d,json_each(d.parts) p"""
            )
        ]
        fallback_count = self.db.execute(
            """SELECT count(*) FROM (
               SELECT DISTINCT a.task_id FROM (SELECT task_id,profile_id FROM model_attempts ORDER BY rowid DESC LIMIT 100) a
               WHERE EXISTS(SELECT 1 FROM model_attempts b WHERE b.task_id=a.task_id AND b.profile_id<>a.profile_id))"""
        ).fetchone()[0]
        return {
            "process": process,
            "business": {
                "scheduling": "enabled" if policy["enabled"] else "disabled",
                "enabled_subscriptions": sum(sub["enabled"] for sub in config["subscriptions"]),
                "enabled_sources": len(sources),
                "sampled_sources": len(freshness),
                "source_freshness": _safe_counts(freshness, {"current", "stale", "unknown"}),
                "source_results": _safe_counts(retrieval, _SOURCE_STATES),
                "model_verification": _safe_counts(
                    verification,
                    {"verified", "failed", "unconfigured", "untested", "stale", "unsupported"},
                ),
                "model_attempts": _safe_counts(model, _ATTEMPT_STATES),
                "model_fallback_tasks": fallback_count,
                "recent_jobs": _safe_counts(jobs, _JOB_STATES),
                "recent_schedule": {
                    kind: _safe_counts(states, _SCHEDULE_STATES)
                    for kind, states in occurrences.items()
                },
                "recent_delivery_parts": _safe_counts(delivery, _DELIVERY_STATES),
                "budget": self._business_budget(now),
                "log_bytes": self._log_usage()[0],
            },
        }

    def support_snapshot(self):
        # Diagnostics contains only server-owned labels and aggregates; no raw nested projections.
        return {"format": _FORMAT, "database_version": DATABASE_VERSION, **self.diagnostics()}

    def verify_backup(self, name):
        database = self.database_name
        if not isinstance(name, str) or not re.fullmatch(
            re.escape(database) + r"\.backup-[a-f0-9]{32}", name
        ):
            raise OperationsError("invalid_backup")
        directory = None
        try:
            directory = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            directory_stat = os.fstat(directory)
            if directory_stat.st_uid != os.getuid() or directory_stat.st_mode & 0o077:
                raise OperationsError("invalid_backup")
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            with os.fdopen(fd, "rb") as file:
                metadata = os.fstat(file.fileno())
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or metadata.st_mode & 0o077
                    or not 1 <= metadata.st_size <= _MAX_BACKUP
                ):
                    raise OperationsError("invalid_backup")
                data = file.read(_MAX_BACKUP + 1)
            if len(data) != metadata.st_size or not data.startswith(b"SQLite format 3\0"):
                raise OperationsError("invalid_backup")
            with TemporaryDirectory(prefix="newspaw-backup-check-") as scratch:
                copy = Path(scratch) / "snapshot.sqlite3"
                fd = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as output:
                    output.write(data)
                with closing(
                    sqlite3.connect(copy.as_uri() + "?mode=ro&immutable=1", uri=True)
                ) as backup:
                    backup.execute("PRAGMA trusted_schema=OFF")
                    checks = 0

                    def limit_check():
                        nonlocal checks
                        checks += 1
                        return checks > 5000

                    backup.set_progress_handler(limit_check, 1000)
                    version = backup.execute("PRAGMA user_version").fetchone()[0]
                    if not 0 <= version <= DATABASE_VERSION or backup.execute(
                        "PRAGMA quick_check(1)"
                    ).fetchone() != ("ok",):
                        raise OperationsError("invalid_backup")
                    tables = {
                        row[0]
                        for row in backup.execute(
                            "SELECT name FROM sqlite_master WHERE type='table' LIMIT 200"
                        )
                    }
                    required = {
                        name
                        for introduced, names in _BACKUP_TABLES.items()
                        if introduced <= version
                        for name in names.split()
                    }
                    if not required <= tables:
                        raise OperationsError("invalid_backup")
                    if version == DATABASE_VERSION and any(
                        self._columns(backup, name) != columns
                        for name, columns in self.backup_tables.items()
                    ):
                        raise OperationsError("invalid_backup")
        except (OSError, sqlite3.Error, AttributeError):
            raise OperationsError("invalid_backup") from None
        finally:
            if directory is not None:
                os.close(directory)
        return {
            "schema_version": version,
            "size_bytes": metadata.st_size,
            "integrity": "ok",
            "restorable": False,
        }

    def _feed_candidates(self, cutoff, limit):
        return [
            row[0]
            for row in self.db.execute(
                """SELECT a.id FROM feed_attempts a WHERE a.completed_at<? AND a.status<>'running'
                   AND NOT EXISTS(SELECT 1 FROM source_readiness s WHERE s.attempt_id=a.id)
                   AND NOT EXISTS(SELECT 1 FROM feed_cache c WHERE c.snapshot_id=a.snapshot_id)
                   AND NOT EXISTS(
                       SELECT 1 FROM pipeline_jobs j WHERE j.id=json_extract(a.scope_json,'$.collection_id')
                       OR EXISTS(SELECT 1 FROM json_each(j.payload,'$.attempt_ids') p WHERE p.value=a.id))
                   AND NOT EXISTS(
                       SELECT 1 FROM editorial_editions e,json_each(e.payload,'$.input.attempt_ids') p
                       WHERE p.value=a.id)
                   ORDER BY a.completed_at LIMIT ?""",
                (cutoff, limit),
            )
        ]

    def _snapshot_candidates(self, cutoff, limit):
        return [
            row[0]
            for row in self.db.execute(
                """SELECT s.id FROM feed_snapshots s WHERE s.fetched_at<?
                   AND NOT EXISTS(SELECT 1 FROM feed_attempts a WHERE a.snapshot_id=s.id)
                   AND NOT EXISTS(SELECT 1 FROM feed_cache c WHERE c.snapshot_id=s.id)
                   ORDER BY s.fetched_at LIMIT ?""",
                (cutoff, limit),
            )
        ]

    def _media_referenced(self, identity):
        return (
            self.db.execute(
                """SELECT 1 FROM pipeline_jobs j,json_each(j.payload,'$.media.photos') p
               WHERE json_extract(p.value,'$.asset_id')=?
               UNION ALL SELECT 1 FROM delivery_manifests m,json_each(m.manifest,'$.parts') p
               WHERE json_extract(p.value,'$.asset_id')=?
               UNION ALL SELECT 1 FROM command_replies c,json_each(c.parts) p
               WHERE json_extract(p.value,'$.asset_id')=?
               UNION ALL SELECT 1 FROM newspaper_effects e
               WHERE json_extract(e.result,'$.asset_id')=?
               UNION ALL SELECT 1 FROM newspapers n,json_each(n.result) p
               WHERE json_extract(p.value,'$.asset_id')=? LIMIT 1""",
                (identity,) * 5,
            ).fetchone()
            is not None
        )

    def _media_cleanup(self, *, cutoff, limit, apply):
        if self.db.execute(
            """SELECT 1 FROM pipeline_jobs WHERE stage='preparing_media' AND lease_token IS NOT NULL LIMIT 1"""
        ).fetchone():
            return 0, 0, True
        candidates = removed = 0
        assets = AssetStore(self.directory / "media")
        try:
            with assets._directory() as directory, os.scandir(directory) as files:
                for index, file in enumerate(files):
                    if index >= 10 * limit or candidates >= limit:
                        break
                    if not _ASSET_FILE.fullmatch(file.name):
                        continue
                    try:
                        info = file.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if (
                        not stat.S_ISREG(info.st_mode)
                        or info.st_uid != os.getuid()
                        or info.st_mode & 0o077
                        or info.st_mtime >= cutoff
                        or self._media_referenced(file.name[:-4])
                    ):
                        continue
                    candidates += 1
                    if apply:
                        try:
                            current = os.stat(file.name, dir_fd=directory, follow_symlinks=False)
                            if (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino):
                                os.unlink(file.name, dir_fd=directory)
                                removed += 1
                        except OSError:
                            continue
        except (OSError, ImageError):
            return candidates, removed, False
        return candidates, removed, False

    def _log_usage(self, *, cutoff=None, apply=False):
        names = ("stdout.log", "stderr.log")
        rotations = tuple(f"{name}.{number}" for name in names for number in range(1, 4))
        total = candidates = removed = 0
        if self.log_directory is None:
            return total, candidates, removed
        try:
            fd = os.open(self.log_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError:
            return total, candidates, removed
        try:
            directory = os.fstat(fd)
            if directory.st_uid != os.getuid() or directory.st_mode & 0o077:
                return total, candidates, removed
            for name in (*names, *rotations):
                try:
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                except OSError:
                    continue
                if (
                    not stat.S_ISREG(info.st_mode)
                    or info.st_uid != os.getuid()
                    or info.st_mode & 0o077
                ):
                    continue
                total += info.st_size
                if name not in rotations or cutoff is None or info.st_mtime >= cutoff:
                    continue
                candidates += 1
                if apply:
                    try:
                        current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino):
                            os.unlink(name, dir_fd=fd)
                            removed += 1
                    except OSError:
                        continue
        finally:
            os.close(fd)
        return total, candidates, removed

    def cleanup(self, *, apply=False, limit=100):
        if type(apply) is not bool or type(limit) is not int or not 1 <= limit <= 200:
            raise OperationsError("invalid_cleanup")
        cutoff = self.clock() - timedelta(days=7)
        with self.store._write():
            attempts = self._feed_candidates(cutoff.isoformat(), limit)
            snapshots = self._snapshot_candidates(cutoff.isoformat(), limit)
            if apply and attempts:
                placeholders = ",".join("?" for _ in attempts)
                self.db.execute(
                    f"DELETE FROM feed_associations WHERE attempt_id IN ({placeholders})", attempts
                )
                self.db.execute(f"DELETE FROM feed_attempts WHERE id IN ({placeholders})", attempts)
            if apply and snapshots:
                placeholders = ",".join("?" for _ in snapshots)
                self.db.execute(
                    f"DELETE FROM feed_snapshots WHERE id IN ({placeholders})", snapshots
                )
            audit_count = self.db.execute("SELECT count(*) FROM collections").fetchone()[0]
            audit_candidates = min(limit, max(0, audit_count - AUDIT_RETENTION))
            if apply and audit_candidates:
                self.store._prune_audit(audit_count - audit_candidates)
            media, removed, deferred = self._media_cleanup(
                cutoff=cutoff.timestamp(), limit=limit, apply=apply
            )
        log_bytes, log_candidates, log_removed = self._log_usage(
            cutoff=cutoff.timestamp(), apply=apply
        )
        x = self.purge_x(limit=limit, apply=apply) if self.purge_x is not None else {}
        return {
            "apply": apply,
            "x": x,
            "log_bytes": log_bytes,
            "log_candidates": log_candidates,
            "log_removed": log_removed,
            "attempt_candidates": len(attempts),
            "snapshot_candidates": len(snapshots),
            "audit_candidates": audit_candidates,
            "media_candidates": media,
            "media_removed": removed,
            "media_deferred": deferred,
        }
