import sqlite3
from contextlib import closing

import pytest

from newspaw.bundle_runtime import check_upgrade
from newspaw.control import acquire_control_lock
from newspaw.migrations import DATABASE_VERSION
from newspaw.store import Store


def test_upgrade_preflight_does_not_mutate_original_or_take_an_active_worker_lock(tmp_path):
    import os

    directory = tmp_path / "private"
    path = directory / "newspaw.sqlite3"
    assert check_upgrade(directory) == {"state": "fresh", "target_version": DATABASE_VERSION}
    with closing(Store(path)) as store, store._write():
        store._db.execute("PRAGMA user_version=17")
    lock = acquire_control_lock(directory)
    try:
        with pytest.raises(ValueError, match="already_running"):
            check_upgrade(directory)
    finally:
        os.close(lock)
    assert check_upgrade(directory) == {
        "state": "compatible",
        "source_version": 17,
        "target_version": DATABASE_VERSION,
    }
    with closing(sqlite3.connect(path)) as source:
        assert source.execute("PRAGMA user_version").fetchone() == (17,)
    assert not list(directory.glob("newspaw.sqlite3.backup-*"))


def test_failed_migration_of_copy_leaves_original_and_releases_worker_lock(tmp_path, monkeypatch):
    import os

    from newspaw import migrations

    directory = tmp_path / "private"
    path = directory / "newspaw.sqlite3"
    with closing(Store(path)) as store, store._write():
        store._db.execute("PRAGMA user_version=17")

    def broken(_):
        raise RuntimeError("injected preflight migration failure")

    monkeypatch.setattr(migrations, "_backup", broken)
    with pytest.raises(RuntimeError, match="injected preflight"):
        check_upgrade(directory)
    with closing(sqlite3.connect(path)) as source:
        assert source.execute("PRAGMA user_version").fetchone() == (17,)
    os.close(acquire_control_lock(directory))
