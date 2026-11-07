from datetime import UTC, datetime

from newspaw.schedule import due_slot


def test_tokyo_schedule_uses_local_time_and_picks_only_latest_missed_slot():
    assert (
        due_slot(datetime(2026, 11, 7, 9, 20, tzinfo=UTC), ["09:00", "18:00"], "Asia/Tokyo", 12)
        == "2026-11-07T18:00:00+09:00"
    )


def test_previous_day_slot_can_be_caught_up_after_midnight():
    assert (
        due_slot(datetime(2026, 11, 7, 15, 10, tzinfo=UTC), ["23:50"], "Asia/Tokyo", 1)
        == "2026-11-07T23:50:00+09:00"
    )


def test_old_and_future_slots_are_not_replayed():
    assert (
        due_slot(datetime(2026, 11, 7, 7, 1, tzinfo=UTC), ["09:00", "18:00"], "Asia/Tokyo", 6)
        is None
    )


def test_no_catchup_still_allows_current_minute_but_not_old_editions():
    assert (
        due_slot(datetime(2026, 11, 7, 0, 0, 30, tzinfo=UTC), ["09:00"], "Asia/Tokyo", 0)
        == "2026-11-07T09:00:00+09:00"
    )
    assert due_slot(datetime(2026, 11, 7, 0, 2, tzinfo=UTC), ["09:00"], "Asia/Tokyo", 0) is None
