import json
from contextlib import closing

import pytest
from test_routing import REF, configured

from newspaw.app_config import default_config
from newspaw.providers import ProfileRegistry
from newspaw.readiness import readiness
from newspaw.store import Store


class Probes:
    def __init__(self, state="untested"):
        self.state = state

    def status(self, profile_id):
        return {"text": {"state": self.state}}


@pytest.fixture
def store(tmp_path):
    with closing(Store(tmp_path / "state.db")) as value:
        yield value


def save(store, config):
    store.save_config(config, expected_revision=store.config_revision())


def steps(result):
    return {
        s["step"]: (s["state"], s["blocker_code"], s["entity_id"], s["fix_op"])
        for s in result["steps"]
    }


def test_fresh_database_points_at_the_bot_first(store):
    result = readiness(store, ProfileRegistry(store))
    assert [s["step"] for s in result["steps"]] == ["bot", "model", "digest", "first_delivery"]
    assert result["complete"] is False and result["next"] == "bot"
    assert result["scheduling_enabled"] is True  # E10 contract §2: on by default
    assert steps(result) == {
        "bot": ("pending", "no_bot", None, "credentials.set"),
        "model": ("pending", "missing_primary_credential", "normal_primary", "credentials.set"),
        "digest": ("pending", "no_enabled_digest", None, "subscriptions.save"),
        "first_delivery": ("pending", "no_delivery_yet", None, None),
    }


@pytest.mark.parametrize(
    ("verified", "paired", "owner", "expected"),
    [
        (False, False, None, ("pending", "bot_unverified", "bot1", "bots.verify")),
        (True, False, None, ("pending", "bot_unpaired", "bot1", "bots.pair_code")),
        (True, True, 123, ("done", None, "bot1", None)),
    ],
)
def test_bot_step_follows_verify_then_pair(store, verified, paired, owner, expected):
    config = default_config()
    config["owner_id"] = owner
    config["bots"] = [
        dict(
            id="bot1",
            name="Personal",
            credential_ref=REF,
            telegram_id=999 if verified else None,
            chat_id=123 if paired else None,
            verified=verified,
            paired=paired,
            adult_allowed=False,
        )
    ]
    save(store, config)
    assert steps(readiness(store, Probes()))["bot"] == expected


@pytest.mark.parametrize(
    ("probe", "expected"),
    [
        ("untested", ("pending", "model_unverified", "normal_primary", "models.probe")),
        ("outcome_unknown", ("pending", "model_unverified", "normal_primary", "models.probe")),
        ("failed", ("pending", "model_failed", "normal_primary", "models.probe")),
        ("verified", ("done", None, "normal_primary", None)),
    ],
)
def test_model_step_follows_the_text_probe(store, probe, expected):
    config = default_config()
    primary = next(p for p in config["model_profiles"] if p["id"] == "normal_primary")
    primary["credential_ref"] = REF
    save(store, config)
    assert steps(readiness(store, Probes(probe)))["model"] == expected


def test_enabled_but_unroutable_digest_names_its_first_blocker(store):
    config, sub = configured()
    config["sources"] = []
    sub["source_ids"] = []
    save(store, config)
    assert steps(readiness(store, Probes()))["digest"] == (
        "pending",
        "no_sources",
        sub["id"],
        "route.preview",
    )


def test_routable_digest_and_delivered_part_complete_setup(store):
    config, sub = configured()
    save(store, config)
    result = readiness(store, Probes("verified"))
    assert steps(result)["digest"] == ("done", None, sub["id"], None)
    assert result["next"] == "first_delivery"
    db = store._db
    db.execute(
        "INSERT INTO pipeline_jobs(id,subscription_id,account_key,edition_key,partition,payload,stage,created_at,updated_at)"
        " VALUES ('job1',?, '', 'e1','normal','{}','awaiting_delivery','t','t')",
        (sub["id"],),
    )
    db.execute(
        "INSERT INTO delivery_manifests(job_id,manifest,created_at) VALUES ('job1','{}','t')"
    )
    db.execute(
        "INSERT INTO delivery_targets(job_id,bot_id,selected,parts) VALUES ('job1','bot1',1,?)",
        (json.dumps([{"state": "delivered"}], separators=(",", ":")),),
    )
    result = readiness(store, Probes("verified"))
    assert result["complete"] is True and result["next"] is None
    assert steps(result)["first_delivery"] == ("done", None, "job1", None)


def test_missing_primary_profile_is_a_step_not_a_crash(store):
    config = default_config()
    config["model_profiles"] = [p for p in config["model_profiles"] if p["id"] != "normal_primary"]
    save(store, config)
    assert steps(readiness(store, Probes()))["model"] == ("pending", "missing_primary", None, None)
