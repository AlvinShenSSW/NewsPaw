"""Wall-clock scheduling with bounded catch-up and durable edition IDs."""

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo


def due_slot(now: datetime, times: list[str], timezone: str, catchup_hours: int) -> str | None:
    local = now.astimezone(ZoneInfo(timezone))
    candidates = []
    for date in (local.date(), local.date() - timedelta(days=1)):
        for time in times:
            hour, minute = map(int, time.split(":"))
            slot = datetime(date.year, date.month, date.day, hour, minute, tzinfo=local.tzinfo)
            age = now.astimezone(UTC) - slot.astimezone(UTC)
            # Always allow the current minute, even when catch-up is disabled.
            if timedelta(0) <= age <= timedelta(seconds=max(60, catchup_hours * 3600)):
                candidates.append(slot)
    if not candidates:
        return None
    return max(candidates).isoformat()
