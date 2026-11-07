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
