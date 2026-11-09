"""What the owner still has to do before the first digest arrives.

Read-only: configuration, probe records, route resolution and two SQLite reads.
No network or Keychain access, so the settings app can poll it.
"""

from __future__ import annotations

import json

from .routing import resolve_route

_DELIVERED = ('%"state":"delivered"%', '%"state":"owner_confirmed"%')


def _step(step, entity_id=None, blocker=None, fix_op=None):
    return {
        "step": step,
        "state": "pending" if blocker else "done",
        "blocker_code": blocker,
        "entity_id": entity_id,
        "fix_op": fix_op,
    }


def _bot(config):
    bots = config["bots"]
    if not bots:
        return _step("bot", None, "no_bot", "credentials.set")
    paired = next((b for b in bots if b["verified"] and b["paired"]), None)
    if paired and config["owner_id"] is not None:
        return _step("bot", paired["id"])
    verified = next((b for b in bots if b["verified"]), None)
    if verified is None:
        return _step("bot", bots[0]["id"], "bot_unverified", "bots.verify")
    return _step("bot", verified["id"], "bot_unpaired", "bots.pair_code")


def _model(config, profiles):
    profile = next(
        (
            p
            for p in config["model_profiles"]
            if p["partition"] == "normal" and p["role"] == "primary"
        ),
        None,
    )
    if profile is None:
        return _step("model", None, "missing_primary", None)
    identity = profile["id"]
    if profile["credential_ref"] is None:
        return _step("model", identity, "missing_primary_credential", "credentials.set")
    state = profiles.status(identity)["text"]["state"]
    if state == "verified":
        return _step("model", identity)
    return _step(
        "model",
        identity,
        "model_failed" if state == "failed" else "model_unverified",
        "models.probe",
    )


def _digest(config, revision):
    enabled = [s for s in config["subscriptions"] if s["enabled"]]
    if not enabled:
        return _step("digest", None, "no_enabled_digest", "subscriptions.save")
    first = None
    for subscription in enabled:
        blockers = resolve_route(config, revision, subscription["id"]).blockers
        if not blockers:
            return _step("digest", subscription["id"])
        first = first or (subscription["id"], blockers[0])
    return _step("digest", first[0], first[1], "route.preview")


def _delivery(db):
    row = db.execute(
        "SELECT job_id FROM delivery_targets WHERE parts LIKE ? OR parts LIKE ? LIMIT 1",
        _DELIVERED,
    ).fetchone()
    if row is None:
        return _step("first_delivery", None, "no_delivery_yet")
    return _step("first_delivery", row[0])


def readiness(store, profiles):
    revision, config = store.load_config()
    steps = [
        _bot(config),
        _model(config, profiles),
        _digest(config, revision),
        _delivery(store._db),
    ]
    settings = store._db.execute("SELECT settings FROM schedule_policy WHERE id=1").fetchone()
    pending = next((s["step"] for s in steps if s["state"] == "pending"), None)
    return {
        "complete": pending is None,
        "next": pending,
        "scheduling_enabled": bool(settings and json.loads(settings[0])["enabled"]),
        "steps": steps,
    }
