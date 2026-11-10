"""R18: ElevenLabs reads a briefing aloud on request. Every provider call here is a fake."""

import asyncio
import json
import logging
import sqlite3
from contextlib import closing
from copy import deepcopy

import httpx
import pytest
from test_control import _resolve, raw_request
from test_control import control as control_fixture
from test_credentials import FakeKeychain
from test_credentials import credentials as credentials_fixture
from test_outbox import system as outbox_system

from newspaw.store import Store

command_system = outbox_system
control = control_fixture
credentials = credentials_fixture
KEY = "el-synthetic-key-9Zq1"
VOICE = "JBFqnCBsd6RMkjVDRZzb"
MP3 = b"ID3\x04\x00synthetic-speech"


def _v4(document):
    old = deepcopy(document)
    del old["speech_api"]
    old["schema_version"] = 4
    return old


# S1 — configuration and key


def test_a_version_4_document_gains_the_speech_block_with_the_preset_voice():
    from test_app_config import downgrade_to_v3

    from newspaw.app_config import SCHEMA_VERSION, default_config, upgrade_config

    current = default_config()
    assert SCHEMA_VERSION == 5
    assert current["speech_api"] == {"credential_ref": None, "voice_id": VOICE}
    old = _v4(current)
    upgraded = upgrade_config(old)
    assert upgraded == current and "speech_api" not in old
    # Older documents reach the same block through the whole chain.
    assert upgrade_config(downgrade_to_v3(current))["speech_api"] == current["speech_api"]
    with pytest.raises(ValueError):
        upgrade_config(dict(old, speech_api=current["speech_api"]))


@pytest.mark.parametrize(
    "block",
    [
        {"credential_ref": None, "voice_id": ""},
        {"credential_ref": None, "voice_id": "a" * 65},
        {"credential_ref": None, "voice_id": "voice-1"},
        {"credential_ref": None, "voice_id": "voicé"},
        {"credential_ref": None, "voice_id": "abc\n"},
        {"credential_ref": None, "voice_id": 7},
        {"credential_ref": None},
        {"credential_ref": None, "voice_id": VOICE, "key": "raw"},
        {"credential_ref": "raw-secret", "voice_id": VOICE},
        None,
    ],
)
def test_the_voice_id_is_1_to_64_ascii_letters_or_digits_and_no_raw_key_is_accepted(block):
    from newspaw.app_config import default_config, validate_config

    config = default_config()
    config["speech_api"] = block
    with pytest.raises(ValueError):
        validate_config(config)
    config["speech_api"] = {"credential_ref": None, "voice_id": "A1" * 32}
    validate_config(config)


def test_a_version_25_database_is_backed_up_then_upgraded(tmp_path):
    from newspaw.migrations import DATABASE_VERSION

    path = tmp_path / "state.db"
    with closing(Store(path)) as store:
        revision, document = store.load_config()
    with closing(sqlite3.connect(path)) as db:
        db.execute("UPDATE app_configuration SET document=?", (json.dumps(_v4(document)),))
        db.execute("DROP TABLE speech_checks")
        db.execute("PRAGMA user_version=25")
        db.commit()
    with closing(Store(path)) as store:
        upgraded_revision, upgraded = store.load_config()
        assert DATABASE_VERSION == 26
        assert store._db.execute("PRAGMA user_version").fetchone()[0] == DATABASE_VERSION
        assert upgraded["schema_version"] == 5
        assert upgraded["speech_api"] == {"credential_ref": None, "voice_id": VOICE}
        assert upgraded_revision == revision + 1
        assert store._db.execute("SELECT count(*) FROM speech_checks").fetchone() == (0,)
        # An untouched instance stays one after the upgrade (settings import still allowed).
        assert store._db.execute(
            "SELECT value FROM migration_info WHERE key='untouched_import_revision'"
        ).fetchone() == (str(upgraded_revision),)
    (backup,) = tmp_path.glob("state.db.backup-*")
    with closing(sqlite3.connect(backup)) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 25
        stored = json.loads(db.execute("SELECT document FROM app_configuration").fetchone()[0])
        assert stored["schema_version"] == 4 and "speech_api" not in stored


async def test_the_speech_key_goes_to_the_keychain_and_only_its_reference_is_stored(credentials):
    from newspaw.credentials import CredentialError

    manager, store, backend = credentials
    with pytest.raises(CredentialError, match="invalid_credential_entity"):
        await manager.set("speech_api", "x", KEY, 1)
    result = await manager.set("speech_api", "elevenlabs", KEY, 1)
    revision, config = store.load_config()
    ref = config["speech_api"]["credential_ref"]
    assert result["revision"] == revision == 2 and backend.items == {ref: KEY}
    assert KEY not in json.dumps(config) and config["speech_api"]["voice_id"] == VOICE
    # Kept by orphan cleanup, named by its tail, unchanged by saving the same key again.
    assert (await manager.cleanup())["cleanup_pending"] == 0 and backend.items == {ref: KEY}
    assert (await manager.status())["tails"] == {ref: KEY[-4:]}
    assert (await manager.set("speech_api", "elevenlabs", KEY, 2))["revision"] == 2

    # The voice is an ordinary setting; the reference is not.
    config["speech_api"]["voice_id"] = "Voice2"
    assert (await manager.save_config(config, 2))["revision"] == 3
    forged = deepcopy(config)
    forged["speech_api"]["credential_ref"] = None
    with pytest.raises(CredentialError, match="protected_configuration_field"):
        await manager.save_config(forged, 3)

    await manager.set("speech_api", "elevenlabs", "el-synthetic-second-key", 3)
    replaced = store.load_config()[1]["speech_api"]
    assert replaced["credential_ref"] != ref and list(backend.items) == [replaced["credential_ref"]]
    assert replaced["voice_id"] == "Voice2"
    await manager.remove("speech_api", "elevenlabs", 4)
    assert store.load_config()[1]["speech_api"] == {"credential_ref": None, "voice_id": "Voice2"}
    assert not backend.items and not store.pending_credentials()


async def test_exported_settings_carry_the_voice_but_never_the_key_reference(tmp_path):
    from newspaw.credentials import CredentialManager
    from newspaw.operations import Operations, OperationsError

    with closing(Store(tmp_path / "source" / "state.db")) as source:
        manager = CredentialManager(source, FakeKeychain())
        await manager.set("speech_api", "elevenlabs", KEY, 1)
        revision, config = source.load_config()
        ref = config["speech_api"]["credential_ref"]
        config["speech_api"]["voice_id"] = "Voice2"
        await manager.save_config(config, revision)
        portable = Operations(source, tmp_path / "source").export_settings()
    assert portable["settings"]["speech_api"] == {"credential_ref": None, "voice_id": "Voice2"}
    assert ref not in json.dumps(portable) and KEY not in json.dumps(portable)

    with closing(Store(tmp_path / "restore" / "state.db")) as restored:
        ops = Operations(restored, tmp_path / "restore")
        carrying = deepcopy(portable)
        carrying["settings"]["speech_api"]["credential_ref"] = ref
        with pytest.raises(OperationsError, match="invalid_portable_settings"):
            ops.preview_import(carrying)
        # An export made before this version has no speech block; it still imports.
        older = deepcopy(portable)
        older["settings"] = _v4(older["settings"])
        assert ops.preview_import(older)["settings"]["speech_api"]["voice_id"] == VOICE
        preview = ops.preview_import(portable)
        ops.apply_import(portable, preview["digest"], preview["revision"])
        assert restored.load_config()[1]["speech_api"] == {
            "credential_ref": None,
            "voice_id": "Voice2",
        }


# S2 — the provider


def _provider(reply, *, key=KEY, voice=VOICE):
    from newspaw.media.elevenlabs import ElevenLabsSpeech

    return ElevenLabsSpeech(
        key, voice, client=httpx.AsyncClient(transport=httpx.MockTransport(reply))
    )


async def test_synthesis_posts_the_cleaned_text_to_the_voice_endpoint():
    requests = []

    def reply(request):
        requests.append(request)
        return httpx.Response(200, content=MP3)

    provider = _provider(reply)
    try:
        text = "Headline. [[slnc 500]] Body" + "x" * 2000
        assert await provider.synthesize(text) == MP3
    finally:
        await provider.close()
    (request,) = requests
    assert request.method == "POST"
    assert str(request.url) == (
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE}?output_format=mp3_44100_64"
    )
    assert request.headers["xi-api-key"] == KEY and "authorization" not in request.headers
    body = json.loads(request.content)
    assert set(body) == {"text", "model_id"} and body["model_id"] == "eleven_multilingual_v2"
    # The same cleaning and 1200-character cap as the local voice.
    assert body["text"].startswith("Headline.  Body") and len(body["text"]) == 1200


def test_the_real_client_is_bound_to_the_elevenlabs_origin_and_the_speech_size():
    from newspaw.media.audio import MAX_SPEECH
    from newspaw.media.elevenlabs import ElevenLabsSpeech
    from newspaw.providers import ProviderError

    client = ElevenLabsSpeech(KEY, VOICE).client
    transport = client._transport
    assert transport._trusted == ("https", "api.elevenlabs.io", 443)
    assert transport._max_bytes == MAX_SPEECH and client.follow_redirects is False
    for key, voice in ((KEY, "../v1/voices"), (KEY, ""), ("bad key\n", VOICE), (None, VOICE)):
        with pytest.raises(ProviderError):
            ElevenLabsSpeech(key, voice)


@pytest.mark.parametrize(
    ("status", "code"),
    [
        (401, "authentication_failed"),
        (403, "permission_denied"),
        (404, "invalid_voice_request"),
        (422, "invalid_voice_request"),
        (429, "rate_limited"),
        (500, "provider_failed"),
        (302, "provider_failed"),
    ],
)
async def test_each_refusal_has_its_own_known_reason_without_key_or_reply_text(status, code):
    from newspaw.providers import ProviderError

    provider = _provider(lambda request: httpx.Response(status, text="private-reply " + KEY))
    try:
        with pytest.raises(ProviderError) as error:
            await provider.synthesize("Headline.")
    finally:
        await provider.close()
    assert (str(error.value), error.value.outcome) == (code, "known")
    assert KEY not in repr(error.value) and "private-reply" not in repr(error.value)


@pytest.mark.parametrize("audio", [b"", b"<html>no audio</html>", b"ID3" + b"\0" * 1024 * 1024])
async def test_an_empty_oversized_or_non_mp3_reply_is_a_failure(audio):
    from newspaw.providers import ProviderError

    provider = _provider(lambda request: httpx.Response(200, content=audio))
    try:
        with pytest.raises(ProviderError, match="invalid_speech_audio") as error:
            await provider.synthesize("Headline.")
    finally:
        await provider.close()
    assert error.value.outcome == "known"


async def test_an_mp3_frame_without_a_tag_is_accepted_and_empty_text_is_never_sent():
    from newspaw.providers import ProviderError

    calls = []

    def reply(request):
        calls.append(request)
        return httpx.Response(200, content=b"\xff\xfb\x90\x00frame")

    provider = _provider(reply)
    try:
        assert await provider.synthesize("Headline.") == b"\xff\xfb\x90\x00frame"
        with pytest.raises(ProviderError) as error:
            await provider.synthesize("[[only markup]]")
    finally:
        await provider.close()
    assert error.value.outcome == "not_sent" and len(calls) == 1


@pytest.mark.parametrize(
    ("failure", "code", "outcome"),
    [
        ("connect", "connection_failed", "not_sent"),
        ("dns", "connection_failed", "not_sent"),
        ("read", "outcome_unknown", "unknown"),
        ("large", "invalid_speech_audio", "known"),
    ],
)
async def test_a_request_that_never_left_is_told_from_one_whose_result_is_unknown(
    failure, code, outcome
):
    from newspaw.providers import ProviderError
    from newspaw.transport import SafeHTTPError

    def reply(request):
        raise {
            "connect": httpx.ConnectError("synthetic"),
            "dns": SafeHTTPError("dns_failure"),
            "read": httpx.ReadTimeout("synthetic"),
            "large": SafeHTTPError("response_too_large"),
        }[failure]

    provider = _provider(reply)
    try:
        with pytest.raises(ProviderError) as error:
            await provider.synthesize("Headline.")
    finally:
        await provider.close()
    assert (str(error.value), error.value.outcome) == (code, outcome)


# S2 / S3 — /listen


class _Voice:
    """Stands in for `ElevenLabsSpeech`: records what it was given, never opens a connection."""

    def __init__(self, outcome=MP3):
        self.outcome, self.made, self.texts, self.closed = outcome, [], [], 0

    def __call__(self, key, voice_id):
        self.made.append((key, voice_id))
        return self

    async def synthesize(self, text):
        self.texts.append(text)
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self.outcome

    async def close(self):
        self.closed += 1


class _LocalVoice:
    def __init__(self):
        self.calls = []

    async def synthesize(self, text, locale):
        self.calls.append(locale)
        return b"local-mp3"


async def _listening(system, voice, *, key=True):
    from newspaw.media.input_service import MediaCommands

    pipeline, targets, _, _, _ = system
    store = pipeline.store
    if key:
        await targets.credentials.set("speech_api", "elevenlabs", KEY, store.config_revision())
    local = _LocalVoice()
    media = MediaCommands(store, targets.credentials.backend, speech=local, tts_factory=voice)
    policy = media.policy()
    media.configure({**policy["settings"], "listen_enabled": True}, policy["revision"])
    return media, local


async def _listen(system, media):
    from test_model_runner import NOW
    from test_outbox import ready_response
    from test_telegram_commands import command_service, inbox

    async def reply(request):
        return ready_response(len(sent))

    commands, outbox, sent = command_service(system, reply)
    commands.media = media
    _, _, job, _, _ = system
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await inbox(system, "/listen", 2, reply=1)
    await commands.tick()
    await commands.tick()
    return commands, sent


_ATTEMPT = ("id", "partition", "provider", "reserved", "settled", "state", "quote")


def _attempts(store):
    return [
        dict(zip(_ATTEMPT, row, strict=True))
        for row in store._db.execute(
            "SELECT id,partition,provider,reserved_units,settled_units,state,quote_json"
            " FROM budget_attempts WHERE provider='elevenlabs'"
        )
    ]


async def test_listen_uses_elevenlabs_once_its_key_is_set(command_system):
    from newspaw.budget import BudgetLedger

    voice = _Voice()
    media, local = await _listening(command_system, voice)
    commands, sent = await _listen(command_system, media)
    store = command_system[0].store

    assert voice.made == [(KEY, VOICE)] and voice.closed == 1 and not local.calls
    assert len(voice.texts) == 1 and "GPT-6" in voice.texts[0]
    (audio,) = [request for request in sent if request.url.path.endswith("/sendAudio")]
    assert MP3 in audio.content and b"https://example.com/a" in sent[1].content
    (attempt,) = _attempts(store)
    assert attempt["id"].startswith("speech.") and attempt["partition"] == "normal"
    assert (attempt["reserved"], attempt["settled"], attempt["state"]) == (50_000, None, "settled")
    assert json.loads(attempt["quote"]) == {
        "known": False,
        "operation": "tts",
        "source": "manual_hold",
    }
    period = next(p for p in BudgetLedger(store).report()["periods"] if p["meter"] == "model")
    assert period["operations"]["tts"]["held"] == 50_000
    # Delivering again never pays again.
    await commands.tick()
    assert len(voice.texts) == 1


@pytest.mark.parametrize(
    ("failure", "state", "units"),
    [
        ("authentication_failed", "settled", None),
        ("rate_limited", "settled", None),
        ("invalid_speech_audio", "settled", None),
        ("connection_failed", "settled", 0),
        ("outcome_unknown", "outcome_unknown", None),
    ],
)
async def test_any_elevenlabs_failure_sends_the_text_only_and_never_the_local_voice(
    command_system, caplog, failure, state, units
):
    from newspaw.providers import ProviderError

    outcome = {"connection_failed": "not_sent", "outcome_unknown": "unknown"}.get(failure, "known")
    voice = _Voice(ProviderError(failure, outcome=outcome))
    media, local = await _listening(command_system, voice)
    with caplog.at_level(logging.DEBUG):
        _, sent = await _listen(command_system, media)
    store = command_system[0].store

    assert len(voice.texts) == 1 and not local.calls
    assert not [request for request in sent if request.url.path.endswith("/sendAudio")]
    text = json.loads(sent[-1].content)["text"]
    assert text.startswith("语音暂时不可用") and "https://example.com/a" in text
    (attempt,) = _attempts(store)
    assert (attempt["state"], attempt["settled"]) == (state, units)
    # Neither the key nor the briefing reaches a log.
    assert KEY not in caplog.text and "GPT-6" not in caplog.text


async def test_a_budget_refusal_sends_no_request_and_only_the_text(command_system):
    from newspaw.budget import BudgetLedger

    voice = _Voice()
    media, local = await _listening(command_system, voice)
    ledger = BudgetLedger(command_system[0].store)
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 0
    ledger.configure(policy, revision)
    _, sent = await _listen(command_system, media)

    assert not voice.texts and not local.calls and not _attempts(command_system[0].store)
    assert not [request for request in sent if request.url.path.endswith("/sendAudio")]
    assert json.loads(sent[-1].content)["text"].startswith("语音暂时不可用")


async def test_without_a_key_listen_still_uses_this_macs_voice(command_system):
    voice = _Voice()
    media, local = await _listening(command_system, voice, key=False)
    _, sent = await _listen(command_system, media)

    assert not voice.made and len(local.calls) == 1
    (audio,) = [request for request in sent if request.url.path.endswith("/sendAudio")]
    assert b"local-mp3" in audio.content and not _attempts(command_system[0].store)


@pytest.mark.parametrize("command_system", ["adult"], indirect=True)
async def test_an_adult_briefing_is_never_sent_to_elevenlabs(command_system):
    voice = _Voice()
    media, local = await _listening(command_system, voice)
    _, sent = await _listen(command_system, media)

    assert not voice.made and not voice.texts and not local.calls
    assert not [request for request in sent if request.url.path.endswith("/sendAudio")]
    assert not _attempts(command_system[0].store)


@pytest.mark.parametrize("locale", ["en", "zh-Hans", "ja"])
def test_the_text_only_notice_exists_in_each_language(locale):
    from newspaw.telegram.commands import _UI

    notice = _UI[locale]["speech_unavailable"]
    assert notice and notice != _UI[locale]["voice_unavailable"]
    assert len({_UI[key]["speech_unavailable"] for key in _UI}) == 3


def test_the_ledger_accepts_speech_and_still_refuses_unknown_operations(tmp_path):
    from newspaw.budget import BudgetError, BudgetLedger

    with closing(Store(tmp_path / "state.db")) as store:
        ledger = BudgetLedger(store)
        hold = {"known": False, "source": "manual_hold"}
        record = ledger.reserve(
            "speech.one",
            "speech.one",
            max_units=5,
            quote=hold,
            provider="elevenlabs",
            operation="tts",
        )
        assert record["operation"] == "tts" and record["provider"] == "elevenlabs"
        with pytest.raises(BudgetError, match="invalid_operation"):
            ledger.reserve("speech.two", "speech.two", max_units=5, quote=hold, operation="sing")


# S4 — testing the key and the voice


async def _keyed(server, store, voice):
    await server.credentials.set("speech_api", "elevenlabs", KEY, store.config_revision())
    server.media.elevenlabs.factory = voice


async def test_status_is_read_only_and_a_check_needs_a_key_and_a_request_id(control):
    server, store = control
    before = store.load_config()
    status = await raw_request(server, {"op": "speech.status"})
    assert status == {"ok": True, "result": {"has_key": False, "voice_id": VOICE, "check": None}}
    assert store.load_config() == before
    assert (await raw_request(server, {"op": "speech.check"}))["error"] == "invalid_request"
    missing = await raw_request(server, {"op": "speech.check", "request_id": "one"})
    assert missing["error"] == "credential_missing"
    assert missing["error_detail"]["domain"] == "speech"
    await _keyed(server, store, _Voice())
    odd = await raw_request(server, {"op": "speech.check", "request_id": "no spaces"})
    assert odd["error"] == "invalid_speech_check"
    assert store._db.execute("SELECT count(*) FROM speech_checks").fetchone() == (0,)


async def test_one_request_id_synthesizes_once_and_a_new_key_or_voice_makes_it_stale(control):
    server, store = control
    voice = _Voice()
    await _keyed(server, store, voice)

    first = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert first["ok"] and first["result"]["status"] == "verified"
    assert first["result"]["request_id"] == "check_1" and first["result"]["checked_at"]
    assert voice.made == [(KEY, VOICE)] and voice.texts == ["NewsPaw audio test."]
    again = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert again == first and len(voice.texts) == 1
    (attempt,) = _attempts(store)
    assert attempt["id"] == "speech.check.check_1" and attempt["partition"] == "normal"
    assert (attempt["reserved"], attempt["settled"], attempt["state"]) == (50_000, None, "settled")
    assert json.loads(attempt["quote"])["operation"] == "tts"
    status = (await raw_request(server, {"op": "speech.status"}))["result"]
    assert status["has_key"] and status["check"]["state"] == "verified"

    revision, config = store.load_config()
    config["speech_api"]["voice_id"] = "Voice2"
    await server.credentials.save_config(config, revision)
    status = (await raw_request(server, {"op": "speech.status"}))["result"]
    assert status["voice_id"] == "Voice2" and status["check"]["state"] == "stale"
    assert status["check"]["status"] == "verified"

    second = await raw_request(server, {"op": "speech.check", "request_id": "check_2"})
    assert second["result"]["status"] == "verified" and voice.made[-1] == (KEY, "Voice2")
    await server.credentials.set(
        "speech_api", "elevenlabs", "el-synthetic-second-key", store.config_revision()
    )
    status = (await raw_request(server, {"op": "speech.status"}))["result"]
    assert status["check"]["request_id"] == "check_2" and status["check"]["state"] == "stale"
    assert len(voice.texts) == 2


@pytest.mark.parametrize(
    ("failure", "outcome", "status", "state", "units"),
    [
        ("authentication_failed", "known", "failed", "settled", None),
        ("permission_denied", "known", "failed", "settled", None),
        ("invalid_voice_request", "known", "failed", "settled", None),
        ("rate_limited", "known", "failed", "settled", None),
        ("connection_failed", "not_sent", "failed", "settled", 0),
        ("outcome_unknown", "unknown", "outcome_unknown", "outcome_unknown", None),
    ],
)
async def test_a_check_tells_rejected_invalid_limited_unreachable_and_unknown_apart(
    control, failure, outcome, status, state, units
):
    from newspaw.providers import ProviderError

    server, store = control
    await _keyed(server, store, _Voice(ProviderError(failure, outcome=outcome)))
    reply = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert reply["ok"] and reply["result"]["status"] == status
    assert reply["result"]["error_kind"] == failure
    (attempt,) = _attempts(store)
    assert (attempt["state"], attempt["settled"]) == (state, units)
    assert (await raw_request(server, {"op": "speech.status"}))["result"]["check"][
        "state"
    ] == status
    assert KEY not in json.dumps(reply)


async def test_a_check_the_budget_refuses_sends_nothing(control):
    from newspaw.budget import BudgetLedger

    server, store = control
    voice = _Voice()
    await _keyed(server, store, voice)
    ledger = BudgetLedger(store)
    revision, policy = ledger.policy()
    policy["model"]["monthly_limit"] = 49_999
    ledger.configure(policy, revision)
    reply = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert reply["result"]["status"] == "budget_blocked" and not voice.texts
    assert reply["result"]["error_kind"] == "model_limit" and not _attempts(store)


async def test_a_slow_check_answers_with_a_handle_and_an_interrupted_one_is_unknown(
    control, monkeypatch
):
    from newspaw import control as module

    server, store = control
    assert module.LONG_OPERATIONS["speech.check"] >= 60
    monkeypatch.setattr(module, "REQUEST_WAIT", 0.02)
    release = asyncio.Event()

    class Slow(_Voice):
        async def synthesize(self, text):
            await release.wait()
            return MP3

    await _keyed(server, store, Slow())
    first = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert first["result"]["pending"] is True
    running = (await raw_request(server, {"op": "speech.status"}))["result"]["check"]
    assert running["state"] == "pending"
    # Asking by the same id while it runs returns its record, not a second synthesis.
    same = await raw_request(server, {"op": "speech.check", "request_id": "check_1"})
    assert same["result"]["status"] == "pending"
    release.set()
    assert (await _resolve(server, first))["result"]["status"] == "verified"

    # A check cut off by a restart may have been charged.
    with store._write():
        store._db.execute(
            "UPDATE speech_checks SET finished_at=NULL,result_json=? WHERE request_id='check_1'",
            (json.dumps({"request_id": "check_1", "status": "pending"}),),
        )
    await server.close()
    await server.start()
    check = (await raw_request(server, {"op": "speech.status"}))["result"]["check"]
    assert (check["state"], check["error_kind"]) == ("outcome_unknown", "interrupted")


@pytest.mark.parametrize("sent", [False, True])
async def test_a_cancelled_check_is_unknown_only_if_its_request_may_have_left(control, sent):
    server, store = control
    entered = asyncio.Event()

    class Hanging(_Voice):
        async def synthesize(self, text):
            entered.set()
            await asyncio.Event().wait()

    await _keyed(server, store, Hanging())
    if not sent:
        # Cancelled while the key is still being read: nothing was reserved or sent.
        def read(ref):
            entered.set()
            raise asyncio.CancelledError

        server.media.elevenlabs.backend = type("Keys", (), {"read": staticmethod(read)})()
    task = asyncio.create_task(server.media.elevenlabs.check("check_1"))
    await asyncio.wait_for(entered.wait(), 2)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    check = server.media.elevenlabs.status()["check"]
    assert check["error_kind"] == "cancelled"
    assert check["state"] == ("outcome_unknown" if sent else "cancelled")
    assert [a["state"] for a in _attempts(store)] == (["outcome_unknown"] if sent else [])
