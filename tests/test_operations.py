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
        assert status["business"]["scheduling"] == "enabled"
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


@pytest.mark.parametrize("legacy_in", ["live", "backup"])
def test_backup_verification_ignores_tables_of_the_removed_env_bot(tmp_path, legacy_in):
    """Upgraded v0.5.0 databases keep the old bot's tables; new ones never have them."""
    import sqlite3

    from test_migrations import add_v050_legacy_tables

    from newspaw.migrations import _backup

    directory = tmp_path / "private"
    path = directory / "state.db"
    with closing(Store(path)) as store:
        if legacy_in == "live":
            backup = _backup(path)
            add_v050_legacy_tables(store._db)
        else:
            add_v050_legacy_tables(store._db)
            backup = _backup(path)
            with closing(sqlite3.connect(path)) as live:
                live.executescript(
                    "DROP TABLE briefs; DROP TABLE collections; DROP TABLE deliveries_v2;"
                    "DROP TABLE deliveries; DROP TABLE settings;"
                )
        ops = Operations(store, directory)
        assert ops.verify_backup(backup.name)["integrity"] == "ok"


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
        ops = Operations(store, tmp_path, clock=lambda: now, log_directory=logs)
        assert ops.cleanup()["log_candidates"] == 1
        assert ops.cleanup(apply=True)["log_removed"] == 1
        assert active.exists() and link.is_symlink() and not old.exists()
        assert "private synthetic log" not in json.dumps(ops.support_snapshot())


def test_cleanup_preserves_readiness_and_only_removes_eligible_orphans(tmp_path):
    from newspaw.evidence import EvidenceStore, feed_scopes
    from newspaw.newsparse import Article

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


def test_diagnostics_counts_recent_schedule_outcomes_by_scope_without_identifiers(tmp_path):
    now = datetime(2026, 11, 8, tzinfo=UTC).isoformat()
    with closing(Store(tmp_path / "state.db")) as store:
        with store._write():
            for scope, account, status in (
                ("private-sub-scope", None, "delivered"),
                ("private-account-scope", "private-account", "outcome_unknown"),
            ):
                store._db.execute(
                    "INSERT INTO schedule_scopes VALUES (?, 'sub_world', ?, '{}', '[]', 1, ?, NULL, 1)",
                    (scope, account, now),
                )
                store._db.execute(
                    """INSERT INTO schedule_occurrences
                       (id,scope_id,slot,civil_date,status,generation,updated_at)
                       VALUES (?,?,1,'2026-11-08',?,1,?)""",
                    (scope + "-occurrence", scope, status, now),
                )
        status = Operations(store, tmp_path).support_snapshot()
        assert status["business"]["recent_schedule"] == {
            "subscriptions": {"delivered": 1},
            "special_accounts": {"outcome_unknown": 1},
        }
        assert "private-" not in json.dumps(status)


@pytest.mark.parametrize("independent_change", ["budget", "legacy", "web"])
def test_independent_policy_or_legacy_state_disables_portable_restore(tmp_path, independent_change):
    from newspaw.budget import BudgetLedger

    with closing(Store(tmp_path / "state.db")) as store:
        if independent_change == "legacy":
            # An upgraded v0.5.0 database keeps the removed bot's tables.
            from test_migrations import add_v050_legacy_tables

            add_v050_legacy_tables(store._db)
        ops = Operations(store, tmp_path)
        portable = ops.export_settings()
        preview = ops.preview_import(portable)
        if independent_change == "budget":
            ledger = BudgetLedger(store)
            revision, policy = ledger.policy()
            ledger.configure(policy, revision)
        else:
            with store._write():
                if independent_change == "legacy":
                    store._db.execute("INSERT INTO settings VALUES ('voice','true')")
                else:
                    store._db.execute("UPDATE web_search_policy SET revision=2 WHERE id=1")
        assert store.config_revision() == preview["revision"]
        with pytest.raises(OperationsError, match="restore_requires_fresh_instance"):
            ops.apply_import(portable, preview["digest"], preview["revision"])


def test_backup_with_matching_version_but_missing_tables_is_rejected(tmp_path):
    import sqlite3

    from newspaw.migrations import _backup

    path = tmp_path / "private" / "state.db"
    with closing(Store(path)) as store:
        backup = _backup(path)
        with closing(sqlite3.connect(backup)) as database:
            database.execute("DROP TABLE pipeline_jobs")
            database.commit()
        with pytest.raises(OperationsError, match="invalid_backup"):
            Operations(store, path.parent).verify_backup(backup.name)


def test_export_omits_unsupported_profile_and_clears_subscription_override(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        config, subscription = configured()
        profile = config["model_profiles"][0]
        profile["provider"] = "valid-custom-provider"
        subscription["primary_profile_id"] = profile["id"]
        store.save_config(config, expected_revision=1)
        portable = Operations(store, tmp_path).export_settings()
        assert portable["omitted"]["model_profiles"] == 1
        exported = {s["id"]: s for s in portable["settings"]["subscriptions"]}
        assert exported[subscription["id"]]["primary_profile_id"] is None
        assert "valid-custom-provider" not in json.dumps(portable)


def test_export_refuses_document_that_would_exceed_own_import_limit(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        config, subscription = configured()
        config["sources"] = [
            dict(config["sources"][0], id=f"source_{number:04d}") for number in range(200)
        ]
        sources = [source["id"] for source in config["sources"]]
        config["subscriptions"] = [
            dict(subscription, id=f"sub_{number:04d}", source_ids=sources) for number in range(200)
        ]
        store.save_config(config, expected_revision=1)
        with pytest.raises(OperationsError, match="settings_not_portable"):
            Operations(store, tmp_path).export_settings()


def test_control_reads_actual_service_log_location(tmp_path):
    from test_credentials import FakeKeychain

    from newspaw.control import ControlServer, prepare_logs, service_log_directory
    from newspaw.credentials import CredentialManager

    home = tmp_path / "home"
    prepare_logs(service_log_directory(home))
    stdout = home / "Library/Logs/NewsPaw/stdout.log"
    assert stdout.parent.stat().st_mode & 0o777 == 0o700
    assert (stdout.parent / "stderr.log").stat().st_mode & 0o777 == 0o600
    stdout.write_bytes(b"fixture")
    data = tmp_path / "data"
    with closing(Store(data / "state.db")) as store:
        server = ControlServer(
            data, CredentialManager(store, FakeKeychain()), log_directory=stdout.parent
        )
        assert server.operations.support_snapshot()["business"]["log_bytes"] == 7


def test_log_preparation_refuses_a_linked_log_file(tmp_path):
    from newspaw.control import prepare_logs

    logs = tmp_path / "Logs"
    logs.mkdir()
    (tmp_path / "elsewhere.log").write_bytes(b"")
    (logs / "stdout.log").symlink_to(tmp_path / "elsewhere.log")
    with pytest.raises(OSError):
        prepare_logs(logs)


@pytest.mark.parametrize(
    "private_url",
    [
        "https://example.com/feed?custom=private-fixture",
        "https://sk-abcdefghijklmnop.example.com/feed",
        "https://192.168.1.10/feed",
        "https://news.internal/feed",
    ],
)
def test_export_preserves_explicit_empty_after_omitting_the_only_private_source(tmp_path, private_url):
    from newspaw.app_config import uses_category_sources

    with closing(Store(tmp_path / "state.db")) as store:
        config, sub = configured()
        source = config["sources"][0]
        source["url"] = private_url
        config["sources"].append(dict(source, id="public_feed", url="https://example.org/rss"))
        sub["source_ids"] = [source["id"]]
        store.save_config(config, expected_revision=1)
        exported = Operations(store, tmp_path).export_settings()
        subscription = next(
            s for s in exported["settings"]["subscriptions"] if s["id"] == sub["id"]
        )
        assert subscription["source_ids"] == [] and not uses_category_sources(subscription)
        assert exported["omitted"]["source_urls"] == 1
        assert private_url not in json.dumps(exported)
        assert [row["id"] for row in exported["settings"]["sources"]] == ["public_feed"]

        # Older portable settings can still contain an unsafe source.
        exported["settings"]["sources"].append(dict(source, enabled=False))
        subscription["source_ids"] = [source["id"]]
        destination = tmp_path / "restore"
        with closing(Store(destination / "state.db")) as restored:
            preview = Operations(restored, destination).preview_import(exported)
        restored_sub = next(s for s in preview["settings"]["subscriptions"] if s["id"] == sub["id"])
        assert restored_sub["source_ids"] == [] and not uses_category_sources(restored_sub)
        assert private_url not in json.dumps(preview)


def test_restore_is_fresh_with_default_new_policies_and_rejects_changed_policy(tmp_path):
    with closing(Store(tmp_path / "state.db")) as store:
        ops = Operations(store, tmp_path)
        portable = ops.export_settings()
        assert ops.preview_import(portable)["revision"] == 1
        with store._write():
            store._db.execute("UPDATE x_video_policy SET revision=2 WHERE id=1")
        with pytest.raises(OperationsError, match="restore_requires_fresh_instance"):
            ops.preview_import(portable)


def test_cleanup_preserves_referenced_paper_assets_and_cleans_old_orphans(tmp_path):
    now = datetime(2026, 11, 8, 2, tzinfo=UTC)
    with closing(Store(tmp_path / "state.db")) as store:
        assets = AssetStore(tmp_path / "media")

        def photo(color):
            content = BytesIO()
            Image.new("RGB", (20, 20), color).save(content, "JPEG")
            identity = assets.put(content.getvalue(), kind="paper")
            path = tmp_path / "media" / (identity + ".jpg")
            age = (now - timedelta(days=10)).timestamp()
            os.utime(path, (age, age))
            return identity, path

        identity, pinned = photo("black")
        _, orphan = photo("white")
        with store._write():
            store._db.execute(
                "INSERT INTO newspapers VALUES ('paper','normal','brief','{}','building',NULL)"
            )
            store._db.execute(
                "INSERT INTO newspaper_effects VALUES ('effect','paper','completed',?,NULL,'known')",
                (json.dumps({"asset_id": identity}),),
            )
        result = Operations(store, tmp_path, clock=lambda: now).cleanup(apply=True)
        assert result["media_removed"] == 1 and pinned.exists() and not orphan.exists()


def test_upgraded_untouched_instance_still_accepts_a_restore(tmp_path):
    """An install that only went through the v24 upgrade is still fresh for import."""
    import sqlite3

    from test_app_config import downgrade_to_v3

    from newspaw.budget import default_policy

    source = tmp_path / "source"
    source.mkdir()
    with closing(Store(source / "state.db")) as store:
        portable = Operations(store, source).export_settings()
    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        _, config = store.load_config()
    legacy_budget = default_policy()
    legacy_budget["model"]["monthly_limit"] = None
    legacy_budget["x"]["daily_limit"] = None
    legacy_schedule = dict(
        enabled=False,
        catchup_minutes=360,
        preparation_lead_minutes=15,
        holds={"normal": None, "adult": None},
    )
    with sqlite3.connect(path) as db:
        db.execute("UPDATE app_configuration SET document=?", (json.dumps(downgrade_to_v3(config)),))
        db.execute("UPDATE budget_policy SET document=?", (json.dumps(legacy_budget),))
        db.execute("UPDATE schedule_policy SET settings=?", (json.dumps(legacy_schedule),))
        db.execute("PRAGMA user_version=23")
    with closing(Store(path)) as upgraded:
        assert Operations(upgraded, tmp_path).preview_import(portable)["counts"] is not None
