import os

import pytest

from newspaw.config import ConfigError, Settings, load_settings, parse_times, parse_topics
from newspaw.sources import load_sources


@pytest.fixture(autouse=True)
def clear_settings_environment(monkeypatch):
    # Test only fixture configuration, never developer credentials or settings.
    prefixes = ("TELEGRAM_", "OPENAI_", "NEWS_", "AV_")
    names = {
        "PAIRING_CODE",
        "TRANSCRIPTION_MODEL",
        "MACOS_VOICE",
        "DATA_DIR",
        "SOURCES_FILE",
        "DIGEST_SIZE",
        "DIGEST_TIMES",
        "TIMEZONE",
        "CATCHUP_HOURS",
        "VOICE_DIGEST",
    }
    for name in list(os.environ):
        if name.startswith(prefixes) or name in names:
            monkeypatch.delenv(name)


def test_settings_resolve_paths_from_config_location_and_environment_overrides(
    tmp_path, monkeypatch
):
    folder = tmp_path / "private config"
    folder.mkdir()
    config = folder / "news.env"
    config.write_text(
        "DATA_DIR=state\nSOURCES_FILE=publishers.toml\nNEWS_TOPICS=Apple;日本\n"
        "DIGEST_TIMES=18:00,09:00,18:00\nTELEGRAM_BOT_TOKEN=fixture-secret\n"
        "OPENAI_API_KEY=fixture-api-secret\nPAIRING_CODE=fixture-pairing-secret\n"
    )
    monkeypatch.setenv("NEWS_LANGUAGE", "English")
    settings = load_settings(config)
    assert settings.data_dir == folder / "state"
    assert settings.sources_file == folder / "publishers.toml"
    assert settings.times == ["09:00", "18:00"]
    assert settings.topics == ["Apple", "日本"]
    assert settings.language == "English"
    assert "fixture-secret" not in repr(settings)
    assert "fixture-api-secret" not in repr(settings)
    assert "fixture-pairing-secret" not in repr(settings)


@pytest.mark.parametrize(
    "entry",
    [
        "TIMEZONE=Not/AZone",
        "TELEGRAM_OWNER_ID=-1",
        "DIGEST_SIZE=11",
        "NEWS_MAX_AGE_HOURS=0",
        "CATCHUP_HOURS=25",
        "VOICE_DIGEST=sometimes",
        "DIGEST_TIMES=25:00",
        "DIGEST_SIZE=five",
    ],
)
def test_invalid_configuration_fails_before_starting_services(tmp_path, entry):
    config = tmp_path / "news.env"
    config.write_text(entry + "\n")
    with pytest.raises(ConfigError):
        load_settings(config)


def test_run_requires_token_and_owner_or_strong_pairing_code(tmp_path):
    base = {"config_path": tmp_path / ".env", "data_dir": tmp_path / "state"}
    with pytest.raises(ConfigError, match="TELEGRAM_BOT_TOKEN"):
        Settings(**base).validate_run()
    with pytest.raises(ConfigError, match="TELEGRAM_OWNER_ID"):
        Settings(**base, telegram_token="fixture", pairing_code="short").validate_run()
    Settings(
        **base, telegram_token="fixture", pairing_code="long-random-pairing-code"
    ).validate_run()
    Settings(**base, telegram_token="fixture", owner_id=123).validate_run()


def test_topic_and_time_limits_reject_empty_or_excessive_configuration():
    assert parse_topics("Apple; 日本 ;Apple") == ["Apple", "日本"]
    assert parse_times("18:00, 09:00,18:00") == ["09:00", "18:00"]
    for value in ("", "; ;", ";".join(str(i) for i in range(11)), "x" * 151):
        with pytest.raises(ConfigError):
            parse_topics(value)
    for value in ("", "9:00", "24:00", ",".join(f"{i:02}:00" for i in range(13))):
        with pytest.raises(ConfigError):
            parse_times(value)


def test_source_aliases_keep_explicit_publisher_feed_mapping(tmp_path):
    sources = tmp_path / "sources.toml"
    sources.write_text(
        '[topics.apple]\naliases = ["Apple", "苹果"]\n'
        'feeds = ["https://publisher.example/rss.xml"]\n'
    )
    result = load_sources(sources)
    assert result["apple"] == result["苹果"] == ["https://publisher.example/rss.xml"]


@pytest.mark.parametrize(
    "contents",
    [
        '[topics.a]\nfeeds = ["http://publisher.example/rss"]',
        '[topics.a]\nfeeds = ["https://127.0.0.1/rss"]',
        '[topics.a]\nfeeds = ["https://user:password@publisher.example/rss"]',
        "[topics.a]\nfeeds = []",
        '[topics.a]\nfeeds = ["https://publisher.example/rss"]\naliases = [1]',
        '[topics.a]\nfeeds = ["https://one.example/rss"]\naliases = ["same"]\n'
        '[topics.b]\nfeeds = ["https://two.example/rss"]\naliases = ["SAME"]',
    ],
)
def test_invalid_or_ambiguous_source_mapping_is_rejected(tmp_path, contents):
    sources = tmp_path / "sources.toml"
    sources.write_text(contents)
    with pytest.raises(ConfigError):
        load_sources(sources)
