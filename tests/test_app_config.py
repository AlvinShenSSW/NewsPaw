import json

import pytest

from newspaw.app_config import default_config, import_preferences, validate_config


def test_defaults_are_private_disabled_and_use_confirmed_models():
    config = default_config()
    validate_config(config)
    assert config["ui_locale"] == config["news_output_locale"] == "zh-Hans"
    assert config["timezone"] == "Asia/Tokyo"
    assert {p["model"] for p in config["model_profiles"]} == {
        "gpt-6-luna",
        "mimo-v2.6-flash",
        "deepseek-flash",
        "grok-4.3",
    }
    assert all(p["credential_ref"] is None for p in config["model_profiles"])
    assert all(not s["enabled"] for s in config["subscriptions"])
    assert default_config() == config


def test_locales_independent_and_unknown_secret_fields_rejected():
    config = default_config()
    config["ui_locale"] = "en"
    config["news_output_locale"] = "ja"
    validate_config(config)
    config["model_profiles"][0]["api_key"] = "never-store"
    with pytest.raises(ValueError):
        validate_config(config)


def test_bad_references_and_credentials_in_urls_rejected():
    config = default_config()
    config["subscriptions"][0]["bot_ids"] = ["missing"]
    with pytest.raises(ValueError):
        validate_config(config)
    config = default_config()
    config["model_profiles"][0]["base_url"] = "https://user:password@example.com"
    with pytest.raises(ValueError):
        validate_config(config)


def test_legacy_preferences_never_interpolate_or_import_secrets(tmp_path, monkeypatch):
    path = tmp_path / "legacy.env"
    path.write_text(
        "OPENAI_API_KEY=private-key\nTELEGRAM_BOT_TOKEN=private-token\n"
        "OPENAI_MODEL=${PROBE_SECRET}\nNEWS_LANGUAGE=日本語\nDIGEST_TIMES=07:30\n"
    )
    monkeypatch.setenv("PROBE_SECRET", "private-environment")
    config = import_preferences(path, {"times": "08:15", "owner_id": "123"})
    assert config["news_output_locale"] == "ja"
    assert config["subscriptions"][0]["times"] == ["08:15"]
    assert config["owner_id"] == 123
    text = json.dumps(config)
    assert "private" not in text
    assert "${" not in text
    assert all(not s["enabled"] for s in config["subscriptions"])


@pytest.mark.parametrize(
    "field,value",
    [("ui_locale", []), ("owner_id", True), ("schema_version", True), ("timezone", "Invalid/Zone")],
)
def test_malformed_configuration_has_clear_validation_failure(field, value):
    config = default_config()
    config[field] = value
    with pytest.raises(ValueError):
        validate_config(config)


def test_import_preserves_topics_feeds_and_database_override(tmp_path):
    path = tmp_path / "old.env"
    path.write_text("NEWS_TOPICS=国际\nNEWS_FEEDS=https://example.com/rss\nDIGEST_SIZE=3\n")
    config = import_preferences(path, {"topics": "Apple;我的专题"})
    assert [s["name"] for s in config["subscriptions"]] == ["Apple", "我的专题"]
    assert all(s["max_items"] == 3 for s in config["subscriptions"])
    assert all(s["source_ids"] == [config["sources"][0]["id"]] for s in config["subscriptions"])
    assert import_preferences(path, {"topics": "Apple;我的专题"}) == config


def test_url_author_filter_is_not_a_credential_but_encoded_api_key_is(tmp_path):
    path = tmp_path / "old.env"
    path.write_text("NEWS_FEEDS=https://example.com/feed?author=123\n")
    assert import_preferences(path, {})["sources"][0]["url"].endswith("author=123")
    path.write_text("NEWS_FEEDS=https://example.com/feed?api%5Fkey=hidden\n")
    with pytest.raises(ValueError, match="without credentials"):
        import_preferences(path, {})


@pytest.mark.parametrize(
    "query",
    [
        "Signature=private&Key-Pair-Id=ABC",
        "sig=private",
        "provider-sig=private",
        "X-Amz-Signature=private",
        "X-Goog-Credential=private",
        "AWSAccessKeyId=private",
        "subscription-key=private",
    ],
)
def test_signed_feed_credentials_are_never_imported(tmp_path, query):
    path = tmp_path / "old.env"
    path.write_text(f"NEWS_FEEDS=https://example.com/feed?{query}\n")
    with pytest.raises(ValueError, match="without credentials"):
        import_preferences(path, {})


def downgrade_to_v3(config):
    """A genuine schema-3 document for upgrade tests: category-level overrides and styles,
    partition group styles, and no subscription-level model overrides."""
    from copy import deepcopy

    old = deepcopy(config)
    old["schema_version"] = 3
    old["group_styles"] = {"normal": "text", "adult": "text"}
    for category in old["categories"]:
        first = next(s for s in old["subscriptions"] if s["category_id"] == category["id"])
        category.update(
            style=None,
            primary_profile_id=first["primary_profile_id"],
            backup_profile_id=first["backup_profile_id"],
        )
    for subscription in old["subscriptions"]:
        del subscription["primary_profile_id"], subscription["backup_profile_id"]
    return old


@pytest.mark.parametrize(
    ("own", "category", "group", "expected"),
    [
        ("source_image", "newspaper", "text", "source_image"),
        (None, "newspaper", "source_image", "newspaper"),
        (None, None, "source_image", "source_image"),
        (None, None, "text", "text"),
    ],
)
def test_v3_upgrade_keeps_each_subscriptions_effective_style(own, category, group, expected):
    from newspaw.app_config import default_config, upgrade_v3

    old = downgrade_to_v3(default_config())
    world = next(c for c in old["categories"] if c["id"] == "world")
    world["style"] = category
    old["group_styles"]["normal"] = group
    sub = next(s for s in old["subscriptions"] if s["category_id"] == "world")
    sub["style"] = own
    upgraded = upgrade_v3(old)
    assert next(s for s in upgraded["subscriptions"] if s["id"] == sub["id"])["style"] == expected
    assert "group_styles" not in upgraded
    assert set(upgraded["categories"][0]) == {"id", "name", "partition"}


def test_v3_upgrade_moves_category_model_overrides_to_its_subscriptions():
    from newspaw.app_config import default_config, upgrade_config

    old = downgrade_to_v3(default_config())
    world = next(c for c in old["categories"] if c["id"] == "world")
    world["backup_profile_id"] = "normal_backup"
    upgraded = upgrade_config(old)
    assert upgraded["schema_version"] == 4
    world_subs = [s for s in upgraded["subscriptions"] if s["category_id"] == "world"]
    assert world_subs and all(s["backup_profile_id"] == "normal_backup" for s in world_subs)
    others = [s for s in upgraded["subscriptions"] if s["category_id"] != "world"]
    assert all(s["backup_profile_id"] is None for s in others)
    assert upgrade_config(upgraded) == upgraded


@pytest.mark.parametrize(
    ("tz", "link", "expected"),
    [
        ("Europe/Paris", "/var/db/timezone/zoneinfo/Asia/Tokyo", "Europe/Paris"),
        ("", "/var/db/timezone/zoneinfo/Australia/Sydney", "Australia/Sydney"),
        ("Not/AZone", "/usr/share/zoneinfo/UTC", "UTC"),
        ("", "", "Asia/Tokyo"),
    ],
)
def test_system_timezone_prefers_tz_then_localtime_link(monkeypatch, tz, link, expected):
    import newspaw.app_config as app_config

    monkeypatch.setenv("TZ", tz)

    def readlink(path):
        if not link:
            raise OSError("no link")
        return link

    monkeypatch.setattr(app_config.os, "readlink", readlink)
    assert app_config.system_timezone() == expected
