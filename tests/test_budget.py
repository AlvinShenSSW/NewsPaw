from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Barrier

import pytest

from newspaw.budget import BudgetError, BudgetLedger
from newspaw.store import Store

NOW = datetime(2026, 11, 7, 3, tzinfo=UTC)
UNKNOWN = {"known": False, "source": "manual_hold"}
READS = {"known": True, "source": "x_read_cap"}


@pytest.fixture
def budget(tmp_path):
    store = Store(tmp_path / "state.db")
    yield BudgetLedger(store), store
    store.close()


def reserve(ledger, identity="attempt1", *, task="task1", amount=40, now=NOW, **kwargs):
    return ledger.reserve(identity, task, max_units=amount, quote=UNKNOWN, now=now, **kwargs)


def test_shared_task_provider_image_caps_and_target_reuse(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["model"].update(monthly_limit=100, image_limit=50, provider_limits={"openai": 60})
    ledger.configure(policy, revision)
    first = reserve(ledger, task_limit=70)
    assert reserve(ledger, task_limit=70) == first
    with pytest.raises(BudgetError, match="provider_limit"):
        reserve(ledger, "attempt2", task="task2", amount=30)
    reserve(ledger, "attempt2", amount=20, provider="mimo", image=True, task_limit=70)
    with pytest.raises(BudgetError, match="task_limit"):
        reserve(ledger, "attempt3", amount=20, provider="mimo", task_limit=70)
    with pytest.raises(BudgetError, match="image_limit"):
        reserve(ledger, "attempt3", task="task3", amount=40, provider="mimo", image=True)
    with pytest.raises(BudgetError, match="model_limit"):
        reserve(ledger, "attempt3", task="task3", amount=50, provider="mimo")
    assert ledger.get("attempt1")["state"] == "reserved"


def test_two_connections_cannot_reserve_same_last_capacity(tmp_path):
    path = tmp_path / "state.db"
    store = Store(path)
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 60
    ledger.configure(policy, revision)
    store.close()
    barrier = Barrier(2)

    def worker(identity):
        local = Store(path)
        try:
            barrier.wait(5)
            try:
                reserve(BudgetLedger(local), identity, task=identity)
                return True
            except BudgetError:
                return False
        finally:
            local.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sum(pool.map(worker, ["a", "b"])) == 1


def test_inflight_crash_unknown_hold_and_explicit_reconciliation(budget):
    ledger, store = budget
    reserve(ledger)
    ledger.begin_attempt("attempt1", now=NOW)
    restarted = BudgetLedger(store)
    assert restarted.recover_inflight() == 1
    assert restarted.get("attempt1")["state"] == "outcome_unknown"
    with pytest.raises(BudgetError):
        restarted.release("attempt1")
    with pytest.raises(BudgetError):
        restarted.begin_attempt("attempt1", now=NOW)
    restarted.reconcile("attempt1", units=12, reason="provider_confirmation")
    assert restarted.get("attempt1")["settled_units"] == 12


def test_unknown_cost_differs_from_unknown_outcome_and_overrun_is_kept(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 50
    ledger.configure(policy, revision)
    reserve(ledger)
    ledger.begin_attempt("attempt1", now=NOW)
    ledger.settle("attempt1", units=None, usage={"input_tokens": 100})
    record = ledger.get("attempt1")
    assert record["state"] == "settled" and record["settled_units"] is None
    with pytest.raises(BudgetError, match="model_limit"):
        reserve(ledger, "another", task="other", amount=11)
    ledger.reconcile("attempt1", units=70, reason="provider_confirmation")
    report = ledger.report()
    assert report["periods"][0]["known_settled"] == 70
    assert report["periods"][0]["overrun"] == 30
    assert report["official_bill"] is False
    with pytest.raises(BudgetError, match="model_limit"):
        reserve(ledger, "another", task="other", amount=1)


def test_release_and_settlement_are_idempotent_but_not_conflicting(budget):
    ledger, _ = budget
    reserve(ledger)
    with pytest.raises(BudgetError):
        ledger.settle("attempt1", units=1)
    ledger.release("attempt1")
    ledger.release("attempt1")
    assert reserve(ledger)["state"] == "released"
    with pytest.raises(BudgetError):
        reserve(ledger, amount=42)
    reserve(ledger, "b")
    ledger.begin_attempt("b", now=NOW)
    ledger.settle("b", units=10, usage={"output_tokens": 5})
    ledger.settle("b", units=10, usage={"output_tokens": 5})
    with pytest.raises(BudgetError):
        ledger.settle("b", units=11)


def test_x_caps_are_independent_from_currency_and_cover_each_scope(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["x"].update(
        daily_limit=100, partition_limits={"normal": 60, "adult": 50}, account_limits={"acct": 30}
    )
    ledger.configure(policy, revision)

    def read(identity, amount, partition="normal", account="acct"):
        return ledger.reserve(
            identity,
            identity,
            meter="x",
            partition=partition,
            provider="x",
            account_id=account,
            max_units=amount,
            quote=READS,
            now=NOW,
        )

    read("x1", 20)
    with pytest.raises(BudgetError, match="account_limit"):
        read("x2", 11)
    read("x2", 40, account="other")
    with pytest.raises(BudgetError, match="partition_limit"):
        read("x3", 1, account="third")
    read("x3", 30, partition="adult", account="adult")
    with pytest.raises(BudgetError, match="x_limit"):
        read("x4", 11, partition="adult", account="adult")
    reserve(ledger, amount=10000)


def test_period_edit_does_not_reset_open_window_and_expired_cannot_begin(budget):
    ledger, _ = budget
    now = datetime(2026, 11, 7, 14, 59, tzinfo=UTC)  # Tokyo 23:59
    first = ledger.reserve(
        "x1", "task", meter="x", provider="x", max_units=10, quote=READS, now=now
    )
    revision, policy = ledger.policy()
    policy["x"]["timezone"] = "America/New_York"
    ledger.configure(policy, revision)
    same = ledger.reserve(
        "x2",
        "task",
        meter="x",
        provider="x",
        max_units=10,
        quote=READS,
        now=now + timedelta(seconds=20),
    )
    assert same["period_id"] == first["period_id"]
    after = now + timedelta(minutes=2)
    with pytest.raises(BudgetError, match="reservation_expired"):
        ledger.begin_attempt("x1", now=after)
    ledger.release("x1")
    fresh = ledger.reserve(
        "x3", "task", meter="x", provider="x", max_units=10, quote=READS, now=after
    )
    assert fresh["period_id"] != first["period_id"]


def test_month_rollover_late_settlement_and_task_cap(budget):
    ledger, _ = budget
    now = datetime(2026, 11, 30, 14, 59, tzinfo=UTC)
    old = reserve(ledger, now=now, task_limit=50)
    ledger.begin_attempt("attempt1", now=now)
    later = now + timedelta(minutes=2)
    with pytest.raises(BudgetError, match="task_limit"):
        reserve(ledger, "b", amount=20, now=later, task_limit=50)
    ledger.settle("attempt1", units=10)
    new = reserve(ledger, "b", amount=20, now=later, task_limit=50)
    assert new["period_id"] != old["period_id"]
    assert ledger.get("attempt1")["period_id"] == old["period_id"]


def test_price_versions_freeze_quotes_and_credit_is_not_cash_balance(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    rate = dict(
        id="rate1",
        provider="openai",
        model="fixture",
        input_per_million=100,
        output_per_million=500,
        updated_at=NOW.isoformat(),
    )
    policy["prices"] = [rate]
    ledger.configure(policy, revision)
    quote = ledger.quote("openai", "fixture", input_max=10000, output_max=2000)
    assert quote["max_units"] == 2
    ledger.reserve("priced", "task", max_units=2, quote=quote, now=NOW)
    revision, policy = ledger.policy()
    policy["prices"][0].update(id="rate2", input_per_million=200)
    ledger.configure(policy, revision)
    assert ledger.get("priced")["quote"] == quote
    with pytest.raises(BudgetError, match="price_changed"):
        ledger.reserve("stale", "task", max_units=2, quote=quote, now=NOW)
    credit = ledger.report()["openai_credit"]
    assert credit["source"] == "user_declared" and credit["verified"] is False
    assert credit["organization"] is None


@pytest.mark.parametrize("value", [-1, 1.2, True, "5"])
def test_invalid_units_rejected(budget, value):
    ledger, _ = budget
    with pytest.raises(BudgetError):
        reserve(ledger, amount=value)


@pytest.mark.parametrize("month,day,hours", [(3, 8, 23), (11, 1, 25)])
def test_x_calendar_day_handles_dst(budget, month, day, hours):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["x"]["timezone"] = "America/New_York"
    ledger.configure(policy, revision)
    now = datetime(2026, month, day, 12, tzinfo=UTC)
    ledger.reserve("dst", "day", meter="x", max_units=1, quote=READS, now=now)
    period = ledger.report()["periods"][0]
    assert (
        datetime.fromisoformat(period["end"]) - datetime.fromisoformat(period["start"])
    ).total_seconds() == hours * 3600


def test_cycle_day_policy_cas_clock_regression_and_unknown_quote(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["model"]["cycle_day"] = 15
    ledger.configure(policy, revision)
    with pytest.raises(BudgetError, match="conflict"):
        ledger.configure(policy, revision)
    with pytest.raises(BudgetError, match="pricing_unknown"):
        ledger.quote("openai", "unknown", input_max=1, output_max=1)
    with pytest.raises(BudgetError, match="unpriced_hold"):
        reserve(ledger, amount=0)
    with pytest.raises(BudgetError):
        reserve(ledger, amount=None)
    reserve(ledger)
    period = ledger.report()["periods"][0]
    assert (
        datetime.fromisoformat(period["start"])
        .astimezone(__import__("zoneinfo").ZoneInfo("Asia/Tokyo"))
        .day
        == 15
    )
    with pytest.raises(BudgetError, match="clock_before"):
        reserve(ledger, "backwards", now=datetime(2026, 1, 1, tzinfo=UTC))


def test_live_unknown_transition_preserves_hold_and_report_sources(budget):
    ledger, _ = budget
    reserve(ledger)
    ledger.begin_attempt("attempt1", now=NOW)
    ledger.mark_unknown("attempt1")
    assert ledger.report()["periods"][0]["unknown_outcomes"] == 1
    with pytest.raises(BudgetError):
        ledger.begin_attempt("attempt1", now=NOW)
    ledger.reconcile("attempt1", units=0, reason="operator_confirmed_unsent")
    reserve(ledger, "b", amount=20)
    ledger.begin_attempt("b", now=NOW)
    ledger.settle("b", units=12, cost_source="usage_derived", usage={"input_tokens": 100})
    report = ledger.report()["periods"][0]
    assert report["known_by_source"]["usage_derived"] == 12
    assert report["scopes"]["providers"]["openai"]["used"] == 12


def test_reservation_write_failure_rolls_back_period_and_task(budget):
    import sqlite3

    ledger, store = budget

    def deny(action, table, *args):
        return (
            sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_INSERT and table == "budget_attempts"
            else sqlite3.SQLITE_OK
        )

    store._db.set_authorizer(deny)
    try:
        with pytest.raises(sqlite3.DatabaseError):
            reserve(ledger)
    finally:
        store._db.set_authorizer(None)
    assert not store._db.execute("SELECT * FROM budget_tasks").fetchall()
    assert not ledger.report()["periods"]
    assert reserve(ledger)["state"] == "reserved"


def test_begin_rechecks_lowered_budget_and_keeps_reservation(budget):
    ledger, _ = budget
    reserve(ledger)
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 20
    ledger.configure(policy, revision)
    with pytest.raises(BudgetError, match="model_limit"):
        ledger.begin_attempt("attempt1", now=NOW)
    assert ledger.get("attempt1")["state"] == "reserved"


def test_begin_rechecks_overrun_before_another_pending_dispatch(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 100
    ledger.configure(policy, revision)
    reserve(ledger)
    reserve(ledger, "pending", task="another", amount=30)
    ledger.begin_attempt("attempt1", now=NOW)
    ledger.settle("attempt1", units=90)
    with pytest.raises(BudgetError, match="model_limit"):
        ledger.begin_attempt("pending", now=NOW)


def test_begin_refuses_superseded_configured_price(budget):
    ledger, _ = budget
    revision, policy = ledger.policy()
    policy["prices"] = [
        dict(
            id="v1",
            provider="openai",
            model="fixture",
            input_per_million=100,
            output_per_million=100,
            updated_at=NOW.isoformat(),
        )
    ]
    ledger.configure(policy, revision)
    quote = ledger.quote("openai", "fixture", input_max=1000000, output_max=0)
    ledger.reserve("price", "task", max_units=100, quote=quote, now=NOW)
    revision, policy = ledger.policy()
    policy["prices"][0].update(id="v2", input_per_million=200)
    ledger.configure(policy, revision)
    with pytest.raises(BudgetError, match="price_changed"):
        ledger.begin_attempt("price", now=NOW)


@pytest.mark.parametrize("meter", ["model", "x"])
def test_dispatch_rejects_regressed_clock_after_new_period_exists(budget, meter):
    ledger, _ = budget
    args = {"meter": meter, "quote": UNKNOWN if meter == "model" else READS}
    old_time = datetime(2026, 10, 31, 14, 59, tzinfo=UTC)
    new_time = datetime(2026, 10, 31, 15, 1, tzinfo=UTC)
    old = ledger.reserve("old", "old", max_units=10, now=old_time, **args)
    fresh = ledger.reserve("fresh", "fresh", max_units=10, now=new_time, **args)
    assert old["period_id"] != fresh["period_id"]
    with pytest.raises(BudgetError, match="clock_before_current_period"):
        ledger.begin_attempt("old", now=old_time)
    assert ledger.get("old")["state"] == "reserved"
    assert ledger.begin_attempt("fresh", now=new_time)["state"] == "inflight"
    ledger.release("old")


def test_operation_breakdown_separates_search_images_text_and_x_reads(budget):
    ledger, store = budget
    reserve(ledger, "text.fixture", task="text", amount=12)
    ledger.begin_attempt("text.fixture", now=NOW)
    ledger.settle("text.fixture", units=7, cost_source="reported")
    reserve(ledger, "search.fixture", task="search", amount=10)
    ledger.begin_attempt("search.fixture", now=NOW)
    ledger.settle("search.fixture", units=4, cost_source="usage_derived")
    reserve(ledger, "image.fixture", task="image", amount=15, image=True)
    ledger.begin_attempt("image.fixture", now=NOW)
    ledger.mark_unknown("image.fixture")
    ledger.reserve(
        "x.fixture", "x", max_units=3, meter="x", provider="x",
        quote={"known": True, "source": "x_read_cap"}, now=NOW,
    )
    with store._write():
        store._db.execute(
            "INSERT INTO web_search_requests VALUES ('request','{}','search.fixture','completed',?,NULL,NULL)",
            (NOW.isoformat(),),
        )
    periods = {row["meter"]: row for row in ledger.report()["periods"]}
    split = periods["model"]["operations"]
    assert split["text"] == {"known_settled": 7, "held": 0, "known_by_source": {"reported": 7}}
    assert split["search"] == {"known_settled": 4, "held": 0, "known_by_source": {"usage_derived": 4}}
    assert split["image"]["held"] == 15 and split["image"]["known_settled"] == 0
    assert periods["x"]["operations"]["x"]["held"] == 3
