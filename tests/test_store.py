import sqlite3
from contextlib import closing

from newspaw.store import Store

LEGACY_TABLES = {"settings", "deliveries", "deliveries_v2", "collections", "briefs"}


def test_storage_and_sidecars_have_private_permissions(tmp_path):
    path = tmp_path / "private" / "state.sqlite3"
    store = Store(path)
    try:
        revision, config = store.load_config()
        config["ui_locale"] = "en"
        store.save_config(config, expected_revision=revision)
        assert path.parent.stat().st_mode & 0o777 == 0o700
        for file in path.parent.iterdir():
            assert file.stat().st_mode & 0o777 == 0o600
    finally:
        store.close()


def test_new_database_has_no_tables_of_the_removed_env_bot(tmp_path):
    path = tmp_path / "state.db"
    with closing(Store(path)):
        pass
    with closing(sqlite3.connect(path)) as db:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert "app_configuration" in tables
    assert not tables & LEGACY_TABLES
