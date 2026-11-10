import pytest

from newspaw.vocabulary import STATES, abandoned, job_state, occurrence_state, target_state

SKIP = {"state": "skipped", "resolution": {"action": "skip"}}
UNKNOWN = {"state": "outcome_unknown"}
DELIVERED = {"state": "delivered"}


@pytest.mark.parametrize(
    ("status", "reason", "state"),
    [
        ("planned", None, "waiting"),
        ("preparing", None, "preparing"),
        ("waiting", "awaiting_target_time", "preparing"),
        ("delivering", None, "preparing"),
        ("late", None, "late"),
        ("delivered", None, "delivered"),
        ("partial", "targets_unavailable", "partial"),
        ("outcome_unknown", "model_outcome_unknown", "model_unknown"),
        ("outcome_unknown", "catchup_expired", "delivery_unknown"),
        ("outcome_unknown", None, "delivery_unknown"),
        ("waiting", "model_outcome_unknown", "model_unknown"),
        ("late", "delivery_outcome_unknown", "delivery_unknown"),
        ("waiting", "job_paused", "paused"),
        ("no_news", None, "skipped"),
        ("skipped", "catchup_expired", "skipped"),
        ("superseded", "newer_elapsed_slot", "skipped"),
        ("rescheduled", "schedule_changed", "waiting"),
        ("held", "partial_assignment_changed", "held"),
        ("blocked", "no_target", "failed"),
        ("cancelled", None, "failed"),
    ],
)
def test_every_occurrence_status_has_one_state(status, reason, state):
    assert occurrence_state(status, reason) == state


def test_a_skip_choice_reads_as_abandoned_only_once_nothing_is_unknown():
    assert abandoned([DELIVERED, SKIP])
    assert not abandoned([SKIP, UNKNOWN])
    assert not abandoned([{"state": "skipped"}])
    assert occurrence_state("partial", None, parts=[DELIVERED, SKIP]) == "abandoned"
    assert occurrence_state("partial", None, parts=[SKIP, UNKNOWN]) == "partial"
    assert target_state("skipped", [SKIP]) == "abandoned"


@pytest.mark.parametrize(
    ("status", "state"),
    [
        ("collecting", "preparing"),
        ("editing", "preparing"),
        ("inflight", "preparing"),
        ("waiting", "preparing"),
        ("awaiting_delivery", "preparing"),
        ("outcome_unknown", "model_unknown"),
        ("paused", "paused"),
        ("cancelled", "failed"),
        ("blocked", "failed"),
        ("refused", "failed"),
        ("collection_failed", "failed"),
        ("no_news", "skipped"),
        ("stale", "skipped"),
    ],
)
def test_job_statuses_use_the_same_words(status, state):
    assert job_state(status) == state


@pytest.mark.parametrize(
    ("status", "state"),
    [
        ("outcome_unknown", "delivery_unknown"),
        ("inflight", "preparing"),
        ("pending", "preparing"),
        ("delivered", "delivered"),
        ("partial", "partial"),
        ("skipped", "skipped"),
        ("revoked", "failed"),
        ("blocked", "failed"),
    ],
)
def test_delivery_targets_use_the_same_words(status, state):
    assert target_state(status) == state


def test_a_paused_jobs_targets_read_as_paused():
    assert target_state("blocked", reason="job_paused") == "paused"
    assert target_state("blocked", reason="token_revoked") == "failed"
    assert target_state("outcome_unknown", reason="job_paused") == "delivery_unknown"
    # Only what is still to send waits on the pause; a settled target keeps its outcome.
    pending, failed = {"state": "pending"}, {"state": "failed"}
    assert target_state("partial", [{"state": "delivered"}, pending], "job_paused") == "paused"
    assert target_state("delivered", [{"state": "delivered"}], "job_paused") == "delivered"
    assert target_state("blocked", [failed], "job_paused") == "failed"
    assert occurrence_state("blocked", "targets_unavailable", parts=[SKIP]) == "abandoned"


def test_every_state_is_in_the_vocabulary():
    produced = {
        occurrence_state(s, None) for s in ("planned", "late", "held", "blocked", "partial")
    }
    produced |= {job_state(s) for s in ("paused", "outcome_unknown", "no_news")}
    produced |= {target_state(s) for s in ("delivered",)} | {"abandoned"}
    assert produced <= set(STATES)
