import json
import sqlite3
from contextlib import closing

import pytest

from newspaw.config_history import KEEP, changes_since
from newspaw.credentials import CredentialError
from newspaw.store import Store


def _save(store, change):
    revision, document = store.load_config()
    change(document)
    return store.save_config(document, expected_revision=revision)


def test_changes_since_names_fields_and_collection_items(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        start = store.config_revision()

        def edit(document):
            document["ui_locale"] = "ja"
            world = next(s for s in document["subscriptions"] if s["category_id"] == "world")
            world["times"] = ["07:00"]
            world["max_items"] = 8
            document["subscriptions"] = [
                s for s in document["subscriptions"] if s["id"] != "sub_ai"
            ]

        _save(store, edit)
        result = changes_since(store, start)
        assert result["revision"] == start + 1
        assert {"field": "ui_locale"} in result["changes"]
        assert {
            "collection": "subscriptions",
            "id": "sub_world",
            "fields": ["max_items", "times"],
        } in result["changes"]
        assert {"collection": "subscriptions", "id": "sub_ai", "removed": True} in result["changes"]
        assert changes_since(store, result["revision"]) == {
            "revision": result["revision"],
            "changes": [],
        }


def test_a_write_from_any_module_is_recorded(tmp_path):
    # Bot verification and key bookkeeping write the row directly, not through save_config.
    with closing(Store(tmp_path / "state.db")) as store:
        revision, document = store.load_config()
        document["owner_id"] = 123
        with store._write():
            store._db.execute(
                "UPDATE app_configuration SET revision=revision+1,document=? WHERE id=1",
                (json.dumps(document),),
            )
        assert changes_since(store, revision)["changes"] == [{"field": "owner_id"}]


def test_history_older_than_the_kept_window_is_unavailable(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        start = store.config_revision()
        for index in range(KEEP + 2):
            _save(
                store,
                lambda document, index=index: document.update(ui_locale=["en", "ja"][index % 2]),
            )
        with pytest.raises(CredentialError, match="history_unavailable"):
            changes_since(store, start)
        assert (
            changes_since(store, store.config_revision() - KEEP + 1)["revision"]
            == store.config_revision()
        )
        for bad in (0, store.config_revision() + 1, "1", True):
            with pytest.raises(CredentialError, match="invalid_revision"):
                changes_since(store, bad)


def test_upgrading_from_v24_keeps_a_paused_schedule_and_starts_history(tmp_path):
    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        revision = store.config_revision()
    with closing(sqlite3.connect(path)) as db:
        db.execute("DROP TRIGGER app_configuration_history_record")
        db.execute("DROP TABLE app_configuration_history")
        # The owner paused all deliveries and has no digest enabled.
        settings = json.loads(db.execute("SELECT settings FROM schedule_policy").fetchone()[0])
        settings["enabled"] = False
        db.execute("UPDATE schedule_policy SET settings=?", (json.dumps(settings),))
        db.execute("PRAGMA user_version=24")
        db.commit()
    with closing(Store(path)) as store:
        settings = json.loads(
            store._db.execute("SELECT settings FROM schedule_policy").fetchone()[0]
        )
        assert settings["enabled"] is False
        assert store._db.execute("PRAGMA user_version").fetchone()[0] == 25
        assert changes_since(store, revision) == {"revision": revision, "changes": []}
