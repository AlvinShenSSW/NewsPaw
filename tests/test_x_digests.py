from copy import deepcopy

import pytest
from test_routing import account, configured
from test_x_timelines import system as timeline_fixture

from newspaw.app_config import validate_config
from newspaw.routing import resolve_route
from newspaw.telegram.targets import _scopes

timeline_system = timeline_fixture


@pytest.mark.parametrize("partition", ["normal", "adult"])
def test_special_digest_requires_explicit_opt_in_and_preserves_its_own_overrides(partition):
    config, _ = configured(partition)
    category = "x" if partition == "normal" else "x_adult"
    sub = next(row for row in config["subscriptions"] if row["category_id"] == category)
    sub.update(enabled=True, bot_ids=["bot1"], times=["08:00"], style="text")
    ordinary = account(config, sub, priority="normal")
    ordinary["partition"] = partition
    special = dict(
        ordinary,
        id="account2",
        remote_id="101",
        handle="special",
        priority="special",
        times=["07:00"],
        bot_ids=["bot2"],
        style="newspaper",
    )
    config["accounts"].append(special)
    config["bots"].append(dict(config["bots"][0], id="bot2", telegram_id=1000))
    regular = resolve_route(config, 1, sub["id"])
    daily = resolve_route(config, 1, sub["id"], account_id="account2")
    assert not regular.blockers and not daily.blockers
    assert [row["id"] for row in regular.effective["accounts"]] == ["account1"]
    assert daily.effective["times"] == ["07:00"] and daily.effective["style"] == "newspaper"
    assert [row["id"] for row in daily.effective["bots"]] == ["bot2"]
    unchanged = deepcopy(config)
    unchanged["accounts"][-1]["include_in_aggregate"] = False
    assert resolve_route(unchanged, 2, sub["id"]).fingerprint == regular.fingerprint

    special["include_in_aggregate"] = True
    opted_in = resolve_route(config, 2, sub["id"])
    assert [row["id"] for row in opted_in.effective["accounts"]] == ["account1", "account2"]
    assert [row["id"] for row in opted_in.effective["bots"]] == ["bot1"]
    assert opted_in.effective["partition"] == partition
    assert opted_in.effective["style"] == "text" and opted_in.effective["times"] == ["08:00"]
    assert (
        resolve_route(config, 2, sub["id"], account_id="account2").fingerprint == daily.fingerprint
    )
    assert _scopes(config)["subscription", sub["id"]][-1] == ("account1", "account2")
    ordinary["include_in_aggregate"] = True
    with pytest.raises(ValueError, match="aggregate"):
        validate_config(config)


async def test_managed_timeline_uses_one_paid_read_per_page_and_keeps_prior_complete_cursor(
    timeline_system,
):
    from test_x_timelines import page, post, setup

    from newspaw.x.timelines import TimelineError

    reads = []

    async def reply(request, _):
        reads.append(request)
        if len(reads) == 1:
            return page([post(110)])
        if len(reads) == 2:
            return page([post(150)], "continuation1")
        return page([post(135, minutes=2)], "continuation2")

    scans, directory, account, _ = await setup(timeline_system, reply)
    revision = directory.store.config_revision()
    scans.begin("scan.previous", "account", account, revision)
    assert (await scans.advance("scan.previous", "step.previous"))["complete_cursor"] == "110"
    scans.begin("scan.managed", "account", account, revision, max_pages=2)
    with pytest.raises(TimelineError, match="digest_scope_required"):
        await scans.advance("scan.managed", "manual.unscoped")

    async def advance(step):
        return await scans.advance("scan.managed", step, before_intent=lambda: True)

    denied = await scans.advance("scan.managed", "step.managed1", before_intent=lambda: False)
    assert denied["state"] == "pending" and len(reads) == 1
    first = await advance("step.managed1")
    assert first["completed_pages"] == 1
    assert (await advance("step.managed1")) == first
    second = await advance("step.managed2")
    assert second["state"] == "incomplete" and second["reason"] == "page_limit"
    assert second["complete_cursor"] == "110" and second["completed_pages"] == 2
    assert await advance("step.managed3") == second
    assert len(reads) == 3
    assert reads[1].url.params["since_id"] == "110"
    assert {row["observed_at"] for row in scans.posts("account", account)} == {
        scans.clock().isoformat(timespec="microseconds")
    }
