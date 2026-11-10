"""One state vocabulary for jobs, schedule occurrences and delivery targets (E10 R05).

Each table keeps its own ``status``/``reason``; the control interface adds ``state`` from these
functions so every screen speaks the words of contract §3 (interaction-spec §2.5).
"""

STATES = (
    "waiting",
    "preparing",
    "late",
    "delivered",
    "partial",
    "model_unknown",
    "delivery_unknown",
    "skipped",
    "abandoned",
    "paused",
    "held",
    "failed",
)

_OCCURRENCE = {
    "planned": "waiting",
    "preparing": "preparing",
    "waiting": "preparing",
    "delivering": "preparing",
    "late": "late",
    "delivered": "delivered",
    "partial": "partial",
    "outcome_unknown": "delivery_unknown",
    "no_news": "skipped",
    "skipped": "skipped",
    "superseded": "skipped",
    # Moved to a later time; it returns to planned when that time's preparation starts.
    "rescheduled": "waiting",
    "held": "held",
    "blocked": "failed",
    "cancelled": "failed",
}

_JOB = {
    "outcome_unknown": "model_unknown",
    "paused": "paused",
    "cancelled": "failed",
    "blocked": "failed",
    "refused": "failed",
    "collection_failed": "failed",
    "no_news": "skipped",
    "stale": "skipped",
}

_TARGET = {
    "outcome_unknown": "delivery_unknown",
    "inflight": "preparing",
    "pending": "preparing",
    "delivered": "delivered",
    "partial": "partial",
    "skipped": "skipped",
    "revoked": "failed",
    "blocked": "failed",
}


def abandoned(parts):
    """The owner chose not to resend, and no part is left whose outcome is unknown."""
    return any(
        (part.get("resolution") or {}).get("action") == "skip" for part in parts
    ) and not any(part.get("state") == "outcome_unknown" for part in parts)


def occurrence_state(status, reason, *, parts=()):
    if abandoned(parts):
        return "abandoned"
    if status in {"waiting", "late"} and reason == "job_paused":
        return "paused"
    # Model and delivery unknowns need different recovery (jobs.resume vs delivery.resolve).
    if status in {"waiting", "late", "outcome_unknown"} and reason == "model_outcome_unknown":
        return "model_unknown"
    if status in {"waiting", "late"} and reason == "delivery_outcome_unknown":
        return "delivery_unknown"
    return _OCCURRENCE.get(status, "failed")


def job_state(status):
    """A pipeline job: any stage still moving toward a result is preparing."""
    return _JOB.get(status, "preparing")


def target_state(status, parts=(), reason=None):
    if abandoned(parts):
        return "abandoned"
    # A paused job holds only what is still to send: a settled target keeps its outcome, and an
    # uncertain send still needs resolving.
    if (
        reason == "job_paused"
        and status != "outcome_unknown"
        and (not parts or any(part.get("state") in {"pending", "inflight"} for part in parts))
    ):
        return "paused"
    return _TARGET.get(status, "failed")
