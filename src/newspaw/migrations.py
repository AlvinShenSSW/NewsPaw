"""Transactional schema upgrades for the one local NewsPaw database."""

from __future__ import annotations

import json
import os
import sqlite3
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from .app_config import default_config, upgrade_v1, upgrade_v2

DATABASE_VERSION = 18
_LEGACY_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS deliveries (
    chat_id INTEGER NOT NULL,
    article_key TEXT NOT NULL,
    sent_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (chat_id, article_key)
);
CREATE TABLE IF NOT EXISTS deliveries_v2 (
    chat_id INTEGER NOT NULL,
    scope TEXT NOT NULL,
    article_key TEXT NOT NULL,
    sent_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (chat_id, scope, article_key)
);
INSERT OR IGNORE INTO deliveries_v2 (chat_id, scope, article_key, sent_at)
    SELECT chat_id, 'news', article_key, sent_at FROM deliveries;
CREATE TABLE IF NOT EXISTS collections (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    report_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS briefs (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL REFERENCES collections(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    articles_json TEXT NOT NULL,
    summary TEXT NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('prepared', 'delivered', 'partial', 'failed')),
    error_kind TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS briefs_collection_created
    ON briefs(collection_id, created_at DESC);
CREATE INDEX IF NOT EXISTS collections_created
    ON collections(created_at DESC);
"""


def check_version(db: sqlite3.Connection) -> int:
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version < 0 or version > DATABASE_VERSION:
        raise ValueError(
            "Database was created by a newer NewsPaw; restore a matching backup to downgrade"
        )
    return version


def _backup(path: Path) -> Path:
    target = path.with_name(f"{path.name}.backup-{uuid4().hex}")
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    try:
        with (
            closing(sqlite3.connect(path, timeout=10)) as reader,
            closing(sqlite3.connect(target)) as destination,
        ):

            def progress(status, remaining, total):
                if status in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                    raise RuntimeError("Database backup is busy; upgrade not applied")

            reader.backup(destination, pages=128, progress=progress, sleep=0.01)
        return target
    except BaseException:
        target.unlink(missing_ok=True)
        raise


def _initialize(db: sqlite3.Connection) -> None:
    for statement in _LEGACY_SCHEMA.split(";"):
        if statement.strip():
            db.execute(statement)
    db.execute(
        "CREATE TABLE app_configuration (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, document TEXT NOT NULL)"
    )
    db.execute("CREATE TABLE migration_info (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    db.execute(
        "INSERT INTO app_configuration VALUES (1, 1, ?)",
        (json.dumps(default_config(), ensure_ascii=False),),
    )
    db.execute("INSERT INTO migration_info VALUES ('cutover', ?)", (datetime.now(UTC).isoformat(),))


def _upgrade_v2(db: sqlite3.Connection) -> None:
    revision, document = db.execute(
        "SELECT revision, document FROM app_configuration WHERE id=1"
    ).fetchone()
    updated = upgrade_v1(json.loads(document))
    if (
        revision == 1
        and not db.execute("SELECT 1 FROM migration_info WHERE key='legacy_imported'").fetchone()
    ):
        db.execute(
            "INSERT INTO migration_info VALUES ('untouched_import_revision', ?)",
            (str(revision + 1),),
        )
    db.execute(
        "UPDATE app_configuration SET revision=revision+1, document=? WHERE id=1",
        (json.dumps(updated, ensure_ascii=False),),
    )


def _upgrade_x_config(db: sqlite3.Connection) -> None:
    revision, raw = db.execute(
        "SELECT revision,document FROM app_configuration WHERE id=1"
    ).fetchone()
    document = json.loads(raw)
    if document["schema_version"] != 2:
        return
    updated = upgrade_v2(document)
    prior = db.execute(
        "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
    ).fetchone()
    if revision == (int(prior[0]) if prior else 1):
        db.execute(
            "INSERT OR REPLACE INTO migration_info VALUES ('untouched_import_revision', ?)",
            (str(revision + 1),),
        )
    db.execute(
        "UPDATE app_configuration SET revision=revision+1,document=? WHERE id=1",
        (json.dumps(updated, ensure_ascii=False),),
    )


def migrate(db: sqlite3.Connection, path: Path) -> None:
    if check_version(db) == DATABASE_VERSION:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        # Another initializer may have completed while this one waited.
        if check_version(db) == DATABASE_VERSION:
            db.commit()
            return
        populated = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' LIMIT 1").fetchone()
        if populated:
            _backup(path)
        version = check_version(db)
        if version == 0:
            _initialize(db)
        elif version == 1:
            _upgrade_v2(db)
        else:
            _upgrade_x_config(db)
        db.execute("CREATE TABLE IF NOT EXISTS credential_intents (ref TEXT PRIMARY KEY)")
        from .budget import initialize as initialize_budget

        initialize_budget(db)
        from .evidence import initialize as initialize_evidence

        initialize_evidence(db)
        from .providers import initialize as initialize_providers

        initialize_providers(db)
        from .model_runner import initialize as initialize_runner

        initialize_runner(db)
        from .editorial import initialize as initialize_editorial

        initialize_editorial(db)
        db.execute(
            "CREATE TABLE IF NOT EXISTS connector_identity (partition TEXT NOT NULL,kind TEXT NOT NULL,url TEXT NOT NULL,remote_id TEXT NOT NULL,canonical TEXT NOT NULL,PRIMARY KEY(partition,kind,url))"
        )
        from .telegram.registry import initialize as initialize_bots

        initialize_bots(db)
        from .source_manager import initialize as initialize_sources

        initialize_sources(db)
        from .pipeline import initialize as initialize_pipeline

        initialize_pipeline(db)
        from .connectors.web_search import initialize as initialize_web_search

        initialize_web_search(db)
        from .telegram.outbox import initialize as initialize_outbox

        initialize_outbox(db)
        from .scheduler import initialize as initialize_scheduler

        initialize_scheduler(db)
        from .telegram.commands import initialize as initialize_commands

        initialize_commands(db)
        from .x.accounts import initialize as initialize_x

        initialize_x(db)
        from .x.timelines import initialize as initialize_x_timelines

        initialize_x_timelines(db)
        db.execute(f"PRAGMA user_version={DATABASE_VERSION}")
        db.commit()
    except BaseException:
        db.rollback()
        raise
