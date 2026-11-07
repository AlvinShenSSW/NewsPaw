from copy import deepcopy

import pytest
from test_routing import account, configured

from newspaw.app_config import validate_config
from newspaw.routing import resolve_route
from newspaw.telegram.targets import _scopes


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
