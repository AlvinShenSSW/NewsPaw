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
        ("outcome_unknown", "model_outcome_unknown", "unknown"),
        ("waiting", "model_outcome_unknown", "unknown"),
        ("late", "delivery_outcome_unknown", "unknown"),
        ("waiting", "job_paused", "paused"),
        ("no_news", None, "skipped"),
        ("skipped", "catchup_expired", "skipped"),
        ("superseded", "newer_elapsed_slot", "skipped"),
        ("rescheduled", "schedule_changed", "skipped"),
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
        ("outcome_unknown", "unknown"),
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
        ("outcome_unknown", "unknown"),
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


def test_every_state_is_in_the_vocabulary():
    produced = {
        occurrence_state(s, None) for s in ("planned", "late", "held", "blocked", "partial")
    }
    produced |= {job_state(s) for s in ("paused", "outcome_unknown", "no_news")}
    produced |= {target_state(s) for s in ("delivered",)} | {"abandoned"}
    assert produced <= set(STATES)
