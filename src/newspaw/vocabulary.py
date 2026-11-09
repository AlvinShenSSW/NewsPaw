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
    "unknown",
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
    "outcome_unknown": "unknown",
    "no_news": "skipped",
    "skipped": "skipped",
    "superseded": "skipped",
    "rescheduled": "skipped",
    "held": "held",
    "blocked": "failed",
    "cancelled": "failed",
}

_JOB = {
    "outcome_unknown": "unknown",
    "paused": "paused",
    "cancelled": "failed",
    "blocked": "failed",
    "refused": "failed",
    "collection_failed": "failed",
    "no_news": "skipped",
    "stale": "skipped",
}

_TARGET = {
    "outcome_unknown": "unknown",
    "inflight": "preparing",
    "pending": "preparing",
    "delivered": "delivered",
    "partial": "partial",
    "skipped": "skipped",
    "revoked": "failed",
    "blocked": "failed",
}

_UNKNOWN_REASONS = {"model_outcome_unknown", "delivery_outcome_unknown"}


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
    if status in {"waiting", "late", "outcome_unknown"} and reason in _UNKNOWN_REASONS:
        return "unknown"
    return _OCCURRENCE.get(status, "failed")


def job_state(status):
    """A pipeline job: any stage still moving toward a result is preparing."""
    return _JOB.get(status, "preparing")


def target_state(status, parts=()):
    if abandoned(parts):
        return "abandoned"
    return _TARGET.get(status, "failed")
