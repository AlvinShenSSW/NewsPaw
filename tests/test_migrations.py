import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from threading import Barrier

import pytest

from newspaw.app_config import default_config
from newspaw.store import Store


def test_config_cas_and_restart(tmp_path):
    path = tmp_path / "state.db"
    a, b = Store(path), Store(path)
    revision, config = a.load_config()
    config["ui_locale"] = "en"
    assert a.save_config(config, expected_revision=revision) == revision + 1
    with pytest.raises(ValueError, match="changed"):
        b.save_config(default_config(), expected_revision=revision)
    a.close()
    b.close()
    reopened = Store(path)
    assert reopened.load_config()[1]["ui_locale"] == "en"
    reopened.close()


def test_old_database_backup_and_no_history_replay(tmp_path):
    path = tmp_path / "state.db"
    db = sqlite3.connect(path)
    db.executescript(
        "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);"
        "INSERT INTO settings VALUES ('last_slot', '2026-01-01T09:00');"
        "CREATE TABLE deliveries(chat_id INTEGER, article_key TEXT, sent_at TEXT);"
        "INSERT INTO deliveries VALUES (123, 'old', '2026-01-01');"
    )
    db.close()
    store = Store(path)
    assert store.get("last_slot") == "2026-01-01T09:00"
    assert all(not s["enabled"] for s in store.load_config()[1]["subscriptions"])
    assert store.migration_cutover()
    store.close()
    backups = list(tmp_path.glob("state.db.backup-*"))
    assert len(backups) == 1
    backup = sqlite3.connect(backups[0])
    assert backup.execute("pragma user_version").fetchone()[0] == 0
    assert backup.execute("select count(*) from deliveries").fetchone()[0] == 1
    backup.close()
    store = Store(path)
    store.close()
    assert list(tmp_path.glob("state.db.backup-*")) == backups


def test_future_and_corrupt_database_refuse_mutation(tmp_path):
    path = tmp_path / "future.db"
    db = sqlite3.connect(path)
    db.execute("pragma user_version=999")
    db.close()
    before = path.read_bytes()
    with pytest.raises(ValueError, match="newer"):
        Store(path)
    assert path.read_bytes() == before
    path = tmp_path / "corrupt.db"
    path.write_bytes(b"not sqlite")
    with pytest.raises(sqlite3.DatabaseError):
        Store(path)
    assert path.read_bytes() == b"not sqlite"


def test_migration_failure_rolls_back_and_retries(tmp_path, monkeypatch):
    import newspaw.migrations as migrations

    path = tmp_path / "state.db"
    db = sqlite3.connect(path)
    db.execute("create table fixture(value text)")
    db.close()
    original = migrations._initialize

    def fail(db):
        original(db)
        raise RuntimeError("injected")

    monkeypatch.setattr(migrations, "_initialize", fail)
    with pytest.raises(RuntimeError, match="injected"):
        Store(path)
    db = sqlite3.connect(path)
    assert db.execute("pragma user_version").fetchone()[0] == 0
    assert not db.execute(
        "select name from sqlite_master where name='app_configuration'"
    ).fetchall()
    db.close()
    monkeypatch.setattr(migrations, "_initialize", original)
    store = Store(path)
    store.close()


def test_concurrent_initializers_and_saves(tmp_path):
    path = tmp_path / "state.db"
    barrier = Barrier(2)

    def write(locale):
        store = Store(path)
        try:
            revision, config = store.load_config()
            config["ui_locale"] = locale
            barrier.wait(timeout=5)
            try:
                store.save_config(config, expected_revision=revision)
                return True
            except ValueError:
                return False
        finally:
            store.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(write, ["en", "ja"]))
        assert sum(results) == 1
    store = Store(path)
    assert store.load_config()[1]["ui_locale"] in {"en", "ja"}
    store.close()


def test_explicit_import_once_without_credentials(tmp_path):
    path = tmp_path / "legacy.env"
    path.write_text(
        "OPENAI_API_KEY=never-store\nTELEGRAM_BOT_TOKEN=never-store\nNEWS_LANGUAGE=English\n"
    )
    store = Store(tmp_path / "state.db")
    store.import_legacy_config(path)
    first = store.load_config()
    store.import_legacy_config(path)
    assert first == store.load_config()
    assert first[1]["news_output_locale"] == "en"
    assert "never-store" not in json.dumps(first)
    store.close()


def test_backup_failure_prevents_schema_mutation(tmp_path, monkeypatch):
    import newspaw.migrations as migrations

    path = tmp_path / "state.db"
    db = sqlite3.connect(path)
    db.execute("create table original(value text)")
    db.close()
    before = path.read_bytes()

    def fail(path):
        raise OSError("injected backup failure")

    monkeypatch.setattr(migrations, "_backup", fail)
    with pytest.raises(OSError, match="backup failure"):
        Store(path)
    assert path.read_bytes() == before


def test_existing_connection_cannot_write_after_schema_upgrade(tmp_path):
    path = tmp_path / "state.db"
    store = Store(path)
    with sqlite3.connect(path) as newer:
        newer.execute("pragma user_version=999")
    with pytest.raises(ValueError, match="newer"):
        store.set("topics", "must-not-write")
    with pytest.raises(ValueError, match="newer"):
        store.save_config(default_config(), expected_revision=1)
    store.close()
    with sqlite3.connect(path) as db:
        assert not db.execute("select value from settings where key='topics'").fetchall()


def test_import_refuses_to_overwrite_user_configuration(tmp_path):
    store = Store(tmp_path / "state.db")
    revision, config = store.load_config()
    config["ui_locale"] = "en"
    store.save_config(config, expected_revision=revision)
    with pytest.raises(ValueError, match="untouched"):
        store.import_legacy_config()
    assert store.load_config()[1]["ui_locale"] == "en"
    store.close()


def test_process_exit_during_migration_recovers_original_schema(tmp_path):
    import os
    import subprocess
    import sys

    path = tmp_path / "state.db"
    with sqlite3.connect(path) as db:
        db.execute("create table original(value text)")
        db.execute("insert into original values ('keep')")
    script = """
import os, sys
from pathlib import Path
import newspaw.migrations as migrations
from newspaw.store import Store
initialize = migrations._initialize
def crash(db):
    initialize(db)
    os._exit(17)
migrations._initialize = crash
Store(Path(sys.argv[1]))
"""
    result = subprocess.run(
        [sys.executable, "-c", script, str(path)],
        env={"PATH": os.defpath},
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 17, result.stderr.decode()
    with sqlite3.connect(path) as db:
        assert db.execute("pragma user_version").fetchone()[0] == 0
        assert db.execute("select value from original").fetchone() == ("keep",)
        assert not db.execute(
            "select name from sqlite_master where name='app_configuration'"
        ).fetchall()
    store = Store(path)
    assert store.load_config()[0] == 1
    store.close()


def version1_database(path, *, revision=1):
    store = Store(path)
    _, config = store.load_config()
    store.close()
    config["schema_version"] = 1
    del config["group_styles"]
    for kind in ("categories", "accounts"):
        for entry in config[kind]:
            del entry["style"]
    with sqlite3.connect(path) as db:
        db.execute("PRAGMA user_version=1")
        db.execute(
            "UPDATE app_configuration SET revision=?, document=?", (revision, json.dumps(config))
        )
    return config


@pytest.mark.parametrize("revision", [1, 2])
def test_v1_upgrade_preserves_import_eligibility_and_preferences(tmp_path, revision):
    path = tmp_path / "state.db"
    original = version1_database(path, revision=revision)
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO settings VALUES ('last_slot', 'historic')")
    store = Store(path)
    new_revision, config = store.load_config()
    assert new_revision == revision + 1
    assert config["schema_version"] == 2
    assert config["model_profiles"] == original["model_profiles"]
    assert store.get("last_slot") == "historic"
    env = tmp_path / "legacy.env"
    env.write_text("NEWS_LANGUAGE=English\n")
    if revision == 1:
        store.import_legacy_config(env)
        assert store.load_config()[1]["news_output_locale"] == "en"
    else:
        with pytest.raises(ValueError, match="untouched"):
            store.import_legacy_config(env)
    final = store.load_config()
    store.close()
    backup = list(tmp_path.glob("state.db.backup-*"))
    assert len(backup) == 1
    with closing(sqlite3.connect(backup[0])) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 1
        assert (
            json.loads(db.execute("SELECT document FROM app_configuration").fetchone()[0])
            == original
        )
    reopened = Store(path)
    assert reopened.load_config() == final
    assert len(list(tmp_path.glob("state.db.backup-*"))) == 1
    reopened.close()


def test_v2_upgrade_failure_rolls_back_document_and_eligibility(tmp_path, monkeypatch):
    import newspaw.migrations as migrations

    path = tmp_path / "state.db"
    original = version1_database(path)
    upgrade = migrations._upgrade_v2

    def fail(db):
        upgrade(db)
        raise RuntimeError("injected after config write")

    monkeypatch.setattr(migrations, "_upgrade_v2", fail)
    with pytest.raises(RuntimeError):
        Store(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 1
        revision, doc = db.execute("SELECT revision, document FROM app_configuration").fetchone()
        assert revision == 1 and json.loads(doc) == original
        assert not db.execute(
            "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
        ).fetchone()
    monkeypatch.setattr(migrations, "_upgrade_v2", upgrade)
    store = Store(path)
    assert store.load_config()[0] == 2
    store.close()


def test_save_after_upgrade_revokes_legacy_import_eligibility(tmp_path):
    path = tmp_path / "state.db"
    version1_database(path)
    store = Store(path)
    revision, config = store.load_config()
    config["ui_locale"] = "en"
    store.save_config(config, expected_revision=revision)
    with pytest.raises(ValueError, match="untouched"):
        store.import_legacy_config()
    store.close()


def test_v2_upgrade_adds_only_credential_journal(tmp_path):
    path = tmp_path / "state.db"
    store = Store(path)
    original = store.load_config()
    store.close()
    with sqlite3.connect(path) as db:
        db.execute("DROP TABLE credential_intents")
        db.execute("PRAGMA user_version=2")
    upgraded = Store(path)
    assert upgraded.load_config() == original
    assert upgraded.pending_credentials() == []
    upgraded.close()
    backups = list(tmp_path.glob("state.db.backup-*"))
    assert len(backups) == 1
    with closing(sqlite3.connect(backups[0])) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 2
        assert not db.execute(
            "SELECT name FROM sqlite_master WHERE name='credential_intents'"
        ).fetchall()


def test_v3_budget_upgrade_failure_rolls_back_and_retries(tmp_path, monkeypatch):
    import newspaw.budget as budget

    path = tmp_path / "state.db"
    store = Store(path)
    original = store.load_config()
    store.close()
    with sqlite3.connect(path) as db:
        for table in ("budget_attempts", "budget_tasks", "budget_periods", "budget_policy"):
            db.execute(f"DROP TABLE {table}")
        db.execute("PRAGMA user_version=3")
    initialize = budget.initialize

    def fail(db):
        initialize(db)
        raise RuntimeError("injected budget migration failure")

    monkeypatch.setattr(budget, "initialize", fail)
    with pytest.raises(RuntimeError):
        Store(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 3
        assert not db.execute(
            "SELECT name FROM sqlite_master WHERE name='budget_policy'"
        ).fetchall()
    monkeypatch.setattr(budget, "initialize", initialize)
    reopened = Store(path)
    assert reopened.load_config() == original
    assert budget.BudgetLedger(reopened).policy()[0] == 1
    reopened.close()


def test_v4_evidence_upgrade_failure_rolls_back_and_retries(tmp_path, monkeypatch):
    import newspaw.evidence as evidence

    path = tmp_path / "state.db"
    store = Store(path)
    original = store.load_config()
    store.close()
    with closing(sqlite3.connect(path)) as db:
        for table in (
            "feed_associations",
            "feed_attempts",
            "feed_cache",
            "feed_snapshots",
            "feed_health_policy",
        ):
            db.execute(f"DROP TABLE {table}")
        db.execute("PRAGMA user_version=4")
        db.commit()
    initialize = evidence.initialize

    def fail(db):
        initialize(db)
        raise RuntimeError("injected evidence migration failure")

    monkeypatch.setattr(evidence, "initialize", fail)
    with pytest.raises(RuntimeError):
        Store(path)
    with closing(sqlite3.connect(path)) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 4
        assert not db.execute(
            "SELECT name FROM sqlite_master WHERE name='feed_snapshots'"
        ).fetchall()
    monkeypatch.setattr(evidence, "initialize", initialize)
    reopened = Store(path)
    assert reopened.load_config() == original
    assert reopened._db.execute("SELECT COUNT(*) FROM feed_attempts").fetchone()[0] == 0
    reopened.close()


def test_v5_provider_upgrade_failure_rolls_back_and_retries(tmp_path, monkeypatch):
    import newspaw.providers as providers

    path = tmp_path / "state.db"
    store = Store(path)
    original = store.load_config()
    store.close()
    with closing(sqlite3.connect(path)) as db:
        db.execute("DROP TABLE model_probes")
        db.execute("DROP TABLE profile_epochs")
        db.execute("PRAGMA user_version=5")
        db.commit()
    initialize = providers.initialize

    def fail(db):
        initialize(db)
        raise RuntimeError("injected provider migration failure")

    monkeypatch.setattr(providers, "initialize", fail)
    with pytest.raises(RuntimeError):
        Store(path)
    with closing(sqlite3.connect(path)) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 5
        assert not db.execute(
            "SELECT name FROM sqlite_master WHERE name='profile_epochs'"
        ).fetchall()
    monkeypatch.setattr(providers, "initialize", initialize)
    reopened = Store(path)
    assert reopened.load_config() == original
    assert (
        providers.ProfileRegistry(reopened).status("normal_primary")["text"]["state"] == "untested"
    )
    reopened.close()


def test_v5_upgrade_removes_unverified_legacy_capabilities(tmp_path):
    from newspaw.providers import ProfileRegistry, initialize

    path = tmp_path / "state.db"
    store = Store(path)
    revision, config = store.load_config()
    store.close()
    config["model_profiles"][0]["capabilities"] = ["text", "image"]
    with closing(sqlite3.connect(path)) as db:
        db.execute("DROP TABLE model_probes")
        db.execute("DROP TABLE profile_epochs")
        db.execute("PRAGMA user_version=5")
        db.execute("UPDATE app_configuration SET document=?", (json.dumps(config),))
        db.commit()
    reopened = Store(path)
    registry = ProfileRegistry(reopened)
    assert registry.status("normal_primary")["text"]["state"] == "untested"
    assert reopened.load_config()[1]["model_profiles"][0]["capabilities"] == []
    assert reopened.config_revision() == revision + 1
    registry.begin("pass", "normal_primary", "text", 100)
    registry.finish("pass", {"status": "verified"})
    current = reopened.load_config()
    with reopened._write():
        initialize(reopened._db)
    assert reopened.load_config() == current  # Later schema upgrades do not clear evidence.
    reopened.close()
