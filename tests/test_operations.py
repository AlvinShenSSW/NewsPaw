import json
import os
from contextlib import closing
from datetime import UTC, datetime, timedelta
from io import BytesIO

import pytest
from PIL import Image
from test_routing import REF, configured

from newspaw.media.source_images import AssetStore
from newspaw.operations import Operations, OperationsError
from newspaw.store import Store


def test_portable_restore_strips_bindings_and_leaves_schedule_inactive(tmp_path):
    with closing(Store(tmp_path / "source" / "state.db")) as source:
        config, sub = configured()
        config.update(ui_locale="ja", news_output_locale="en")
        config["sources"][0]["url"] = "https://example.com/feed?custom=private-fixture"
        config["model_profiles"][0]["base_url"] = "https://gateway.example/private-fixture"
        source.save_config(config, expected_revision=1)
        portable = Operations(source, tmp_path / "source").export_settings()
        serialized = json.dumps(portable)
        assert REF not in serialized and "private-fixture" not in serialized

    with closing(Store(tmp_path / "restore" / "state.db")) as restored:
        ops = Operations(restored, tmp_path / "restore")
        preview = ops.preview_import(portable)
        assert restored.config_revision() == preview["revision"]
        assert restored.load_config()[1]["ui_locale"] != "ja"
        ops.apply_import(portable, preview["digest"], preview["revision"])
        _, value = restored.load_config()
        assert value["ui_locale"] == "ja" and value["news_output_locale"] == "en"
        assert value["owner_id"] is None and not value["bots"][0]["paired"]
        assert not any(s["enabled"] for s in value["subscriptions"])
        assert not value["sources"]
        assert restored._db.execute("SELECT count(*) FROM delivery_targets").fetchone() == (0,)
        with pytest.raises(OperationsError, match="restore_requires_fresh_instance"):
            ops.preview_import(portable)


def test_redacted_diagnostics_do_not_copy_untrusted_text(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        config, _ = configured()
        config["bots"][0]["name"] = "private-fixture-name"
        store.save_config(config, expected_revision=1)
        ops = Operations(store, tmp_path, process_status=lambda: "running")
        status = ops.diagnostics()
        assert status["process"] == "running"
        assert status["business"]["scheduling"] == "disabled"
        encoded = json.dumps(ops.support_snapshot())
        assert "private-fixture-name" not in encoded and REF not in encoded
        assert "https://" not in encoded


def test_cleanup_cannot_remove_media_during_an_active_lease(tmp_path):
    now = datetime(2026, 11, 8, 2, tzinfo=UTC)
    with closing(Store(tmp_path / "state.db")) as store:
        image = BytesIO()
        Image.new("RGB", (12, 12)).save(image, "JPEG")
        asset = AssetStore(tmp_path / "media").put(image.getvalue())
        path = tmp_path / "media" / (asset + ".jpg")
        age = (now - timedelta(days=10)).timestamp()
        os.utime(path, (age, age))
        with store._write():
            store._db.execute(
                """INSERT INTO pipeline_jobs
                   (id,subscription_id,account_key,edition_key,partition,payload,stage,lease_token,created_at,updated_at)
                   VALUES ('job.fixture','sub_world','','daily','normal','{}','preparing_media','active',?,?)""",
                (now.isoformat(), now.isoformat()),
            )
        ops = Operations(store, tmp_path, clock=lambda: now)
        assert ops.cleanup(apply=True)["media_deferred"]
        assert path.exists()
        with store._write():
            store._db.execute("UPDATE pipeline_jobs SET lease_token=NULL WHERE id='job.fixture'")
        assert ops.cleanup(apply=True)["media_removed"] == 1
        assert not path.exists()


def test_private_backup_is_verified_without_exposing_any_restore_action(tmp_path):
    from newspaw.migrations import _backup

    directory = tmp_path / "private"
    path = directory / "state.db"
    with closing(Store(path)) as store:
        ops = Operations(store, directory)
        backup = _backup(path)
        verified = ops.verify_backup(backup.name)
        assert verified["integrity"] == "ok" and verified["restorable"] is False
        assert "path" not in verified
        broken = directory / ("state.db.backup-" + "1" * 32)
        broken.write_bytes(b"SQLite format 3\0broken")
        broken.chmod(0o600)
        with pytest.raises(OperationsError, match="invalid_backup"):
            ops.verify_backup(broken.name)
        with pytest.raises(OperationsError, match="invalid_backup"):
            ops.verify_backup("../" + backup.name)


def test_configuration_aba_disables_fresh_restore(tmp_path):
    from newspaw.app_config import default_config

    with closing(Store(tmp_path / "state.db")) as store:
        ops = Operations(store, tmp_path)
        portable = ops.export_settings()
        preview = ops.preview_import(portable)
        revision, settings = store.load_config()
        settings["ui_locale"] = "en"
        revised = store.save_config(settings, expected_revision=revision)
        store.save_config(default_config(), expected_revision=revised)
        with pytest.raises(OperationsError, match="configuration_changed"):
            ops.apply_import(portable, preview["digest"], preview["revision"])
        with pytest.raises(OperationsError, match="restore_requires_fresh_instance"):
            ops.preview_import(portable)


def test_rotated_log_cleanup_skips_active_files_and_symlinks(tmp_path):
    now = datetime(2026, 11, 8, 2, tzinfo=UTC)
    with closing(Store(tmp_path / "state.db")) as store:
        logs = tmp_path / "logs"
        logs.mkdir(mode=0o700)
        active = logs / "stdout.log"
        old = logs / "stderr.log.1"
        for file in (active, old):
            file.write_text("private synthetic log")
            file.chmod(0o600)
            age = (now - timedelta(days=10)).timestamp()
            os.utime(file, (age, age))
        link = logs / "stdout.log.1"
        link.symlink_to(active)
        ops = Operations(store, tmp_path, clock=lambda: now)
        assert ops.cleanup()["log_candidates"] == 1
        assert ops.cleanup(apply=True)["log_removed"] == 1
        assert active.exists() and link.is_symlink() and not old.exists()
        assert "private synthetic log" not in json.dumps(ops.support_snapshot())


def test_cleanup_preserves_readiness_and_only_removes_eligible_orphans(tmp_path):
    from newspaw.evidence import EvidenceStore, feed_scopes
    from newspaw.news import Article

    now = datetime(2026, 11, 8, 2, tzinfo=UTC)
    old = now - timedelta(days=10)
    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        store.save_config(config, expected_revision=1)
        source = config["sources"][0]
        scope = feed_scopes(config, [sub["id"]])[0]
        evidence = EvidenceStore(store)

        def recorded():
            key = evidence.begin(scope, old)
            evidence.finish(
                key,
                scope,
                {"status": "fresh", "accepted_count": 1},
                old,
                articles=[
                    Article("Fixture", "https://example.com/a", "Fixture", old, fetched_at=old)
                ],
                rejected={},
                cache=False,
            )
            return key

        pinned, removable = recorded(), recorded()
        with store._write():
            store._db.execute(
                "UPDATE source_readiness SET attempt_id=? WHERE id=?", (pinned, source["id"])
            )
        ops = Operations(store, tmp_path, clock=lambda: now)
        assert ops.cleanup()["attempt_candidates"] == 1
        assert ops.cleanup(apply=True)["attempt_candidates"] == 1
        assert store._db.execute("SELECT id FROM feed_attempts").fetchall() == [(pinned,)]
        assert removable != pinned
        assert ops.cleanup()["snapshot_candidates"] == 1
        assert ops.cleanup(apply=True)["snapshot_candidates"] == 1
        assert store._db.execute("SELECT count(*) FROM feed_snapshots").fetchone() == (1,)
