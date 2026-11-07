from io import BytesIO

import httpx
import pytest
from test_outbox import system as outbox_system
from test_routing import configured
from test_telegram_registry import TOKEN

from newspaw.media.audio import MediaInputError, matching_voice, normalize_wav
from newspaw.media.speech_provider import TranscriptionProvider
from newspaw.telegram.client import TelegramClient, TelegramError

command_system = outbox_system


class MediaStream(httpx.AsyncByteStream):
    def __init__(self, parts):
        self.parts = parts
        self.closed = False

    async def __aiter__(self):
        for chunk in self.parts:
            yield chunk

    async def aclose(self):
        self.closed = True


@pytest.mark.parametrize(
    "malformed", ["https://evil.example/secret", "photos/../x.jpg", "photos/%2F.jpg"]
)
async def test_download_rejects_untrusted_file_path_before_second_request(malformed):
    requests = []

    def reply(request):
        requests.append(request)
        return httpx.Response(200, json={"ok": True, "result": {"file_path": malformed}})

    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=httpx.MockTransport(reply)))
    try:
        with pytest.raises(TelegramError, match="invalid_file_path"):
            await client.download_file("fixture_id", 10, lambda: True)
    finally:
        await client.close()
    assert len(requests) == 1 and requests[0].url.path.endswith("/getFile")


@pytest.mark.parametrize(("parts", "fails"), [([b"abc", b"de"], False), ([b"abc", b"def"], True)])
async def test_download_enforces_stream_cap_even_without_length(parts, fails):
    stream = MediaStream(parts)
    requests = []

    def reply(request):
        requests.append(request)
        if request.url.path.endswith("/getFile"):
            return httpx.Response(
                200, json={"ok": True, "result": {"file_path": "voice/file_7.oga"}}
            )
        assert request.url.host == "api.telegram.org"
        return httpx.Response(200, stream=stream)

    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=httpx.MockTransport(reply)))
    try:
        if fails:
            with pytest.raises(TelegramError, match="media_too_large"):
                await client.download_file("fixture", 5, lambda: True)
        else:
            assert await client.download_file("fixture", 5, lambda: True) == b"abcde"
    finally:
        await client.close()
    assert len(requests) == 2 and stream.closed


async def test_download_rechecks_guard_between_metadata_and_file():
    calls = []

    def reply(request):
        calls.append(request)
        return httpx.Response(200, json={"ok": True, "result": {"file_path": "voice/file_7.oga"}})

    client = TelegramClient(TOKEN, client=httpx.AsyncClient(transport=httpx.MockTransport(reply)))
    try:
        with pytest.raises(TelegramError, match="media_scope_changed"):
            await client.download_file("fixture", 5, lambda: not calls)
    finally:
        await client.close()
    assert len(calls) == 1


def _wav(seconds=1):
    import wave

    data = BytesIO()
    with wave.open(data, "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(16000)
        stream.writeframes(b"\0" * (32000 * seconds))
    return data.getvalue()


async def test_transcription_uses_exact_configured_model_and_bounded_wav():
    profile = configured()[0]["model_profiles"][0]
    profile["model"] = "fixture-transcribe"
    requests = []

    def reply(request):
        requests.append(request)
        assert request.url.host == "api.openai.com"
        assert request.url.path == "/v1/audio/transcriptions"
        assert b'filename="speech.wav"' in request.content
        assert b"fixture-transcribe" in request.content
        return httpx.Response(200, json={"text": "   news  query ", "usage": {"input_tokens": 2}})

    provider = TranscriptionProvider(
        profile, "synthetic-key", client=httpx.AsyncClient(transport=httpx.MockTransport(reply))
    )
    try:
        assert await provider.transcribe(_wav()) == ("news query", {"input_tokens": 2})
    finally:
        await provider.close()
    assert len(requests) == 1


@pytest.mark.parametrize("locale", ["en", "ja", "zh-Hans"])
def test_speech_never_substitutes_different_language(locale):
    inventory = "Samantha   en_US   # Test\nKyoko   ja_JP   # Test\nTingting   zh_CN   # Test"
    expected = {"en": "Samantha", "ja": "Kyoko", "zh-Hans": "Tingting"}[locale]
    assert matching_voice(inventory, locale) == expected
    assert (
        matching_voice("\n".join(x for x in inventory.splitlines() if expected not in x), locale)
        is None
    )


async def test_normalize_rejects_damaged_or_long_audio_and_cleans_private_files(
    tmp_path, monkeypatch
):
    import shutil
    import tempfile

    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg is unavailable")
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path))
    assert await normalize_wav(_wav())
    with pytest.raises(MediaInputError):
        await normalize_wav(b"not audio")
    with pytest.raises(MediaInputError, match="invalid_audio_duration"):
        await normalize_wav(_wav(181))
    assert not list(tmp_path.iterdir())


async def _attach(system, identity, *, caption=None, owner=123, bot="bot1", reply=None):
    from datetime import timedelta

    from test_model_runner import NOW
    from test_outbox import TOKEN2
    from test_telegram_registry import update

    _, targets, _, _, _ = system
    registry = targets.registry
    api = registry.client_factory(TOKEN if bot == "bot1" else TOKEN2)
    incoming = update("", identity, owner=owner, when=NOW)
    message = incoming["message"]
    message.pop("text")
    if caption:
        message["caption"] = caption
    message["photo"] = [dict(file_id="synthetic-photo-file", width=20, height=30)]
    if reply is not None:
        message["reply_to_message"] = {"message_id": reply}
    api.updates = [incoming]
    await registry.poll_once(bot, now=NOW + timedelta(seconds=identity))


def _enable_media(system, *, listen=False, speech=None, vision_factory=None):
    from newspaw.media.input_service import MediaCommands
    from newspaw.providers import ProfileRegistry

    pipeline, targets, _, _, _ = system
    store = pipeline.store
    kwargs = {"vision_factory": vision_factory} if vision_factory else {}
    media = MediaCommands(store, targets.credentials.backend, speech=speech, **kwargs)
    policy = media.policy()
    settings = {**policy["settings"], "listen_enabled": listen}
    if vision_factory:
        revision, config = store.load_config()
        default = next(p for p in config["model_profiles"] if p["id"] == "normal_primary")
        config["model_profiles"].append(dict(default, id="media_vision", capabilities=[]))
        store.save_config(config, expected_revision=revision)
        registry = ProfileRegistry(store)
        registry.begin("verify.media.vision", "media_vision", "vision", 100)
        registry.finish("verify.media.vision", {"status": "verified"})
        settings.update(vision_profile="media_vision", vision_hold=100)
    media.configure(settings, policy["revision"])
    return media


async def test_media_requires_explicit_ordinary_scope_or_exact_bot_briefing(command_system):
    from PIL import Image
    from test_model_runner import NOW
    from test_outbox import ready_response
    from test_telegram_commands import command_service

    fixture = BytesIO()
    Image.new("RGB", (20, 30), "white").save(fixture, "JPEG")
    data = fixture.getvalue()
    model_calls = []

    class Vision:
        def payload(self, request):
            assert request.partition == "normal"
            assert request.image and "Do not assert identity" in request.instructions

        async def generate(self, request):
            model_calls.append(request)
            return {"text": "GPT-6", "usage": {"input_tokens": 9}}

        async def close(self):
            pass

    async def reply(request):
        path = request.url.path
        if path.endswith("/getFile"):
            return httpx.Response(
                200, json={"ok": True, "result": {"file_path": "photos/file_1.jpg"}}
            )
        if "/file/bot" in path:
            return httpx.Response(200, content=data)
        return ready_response(len(sent))

    commands, outbox, sent = command_service(command_system, reply)
    commands.media = _enable_media(command_system, vision_factory=lambda *_: Vision())
    pipeline, _, job, _, _ = command_system
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)

    await _attach(command_system, 2, caption="/search s:sub_world", owner=456)
    await _attach(command_system, 3, caption="s:sub_world")
    await _attach(command_system, 2, bot="bot2", reply=1)
    await commands.tick()
    assert not model_calls
    assert not any(req.url.path.endswith("/getFile") for req in sent)

    await _attach(command_system, 4, caption="/search s:sub_world")
    await commands.tick()
    assert len(model_calls) == 1
    assert sum(req.url.path.endswith("/getFile") for req in sent) == 1
    assert b"https://example.com/a" in sent[-1].content
    assert "synthetic-photo-file" not in "\n".join(pipeline.db.iterdump())
    await commands.tick()
    assert len(model_calls) == 1


@pytest.mark.parametrize("missing_voice", [False, True])
async def test_listen_keeps_links_and_uses_frozen_locale_or_falls_back(
    command_system, missing_voice
):
    from test_model_runner import NOW
    from test_outbox import ready_response
    from test_telegram_commands import command_service, inbox

    locales = []

    class Speech:
        async def synthesize(self, text, locale):
            locales.append(locale)
            assert "GPT-6" in text
            if missing_voice:
                raise MediaInputError("voice_unavailable")
            return b"synthetic-mp3"

    async def reply(request):
        return ready_response(len(sent))

    commands, outbox, sent = command_service(command_system, reply)
    commands.media = _enable_media(command_system, listen=True, speech=Speech())
    pipeline, _, job, _, _ = command_system
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await inbox(command_system, "/listen", 2, reply=1)
    await commands.tick()
    await commands.tick()
    assert locales == [pipeline.get(job)["locale"]]
    assert b"https://example.com/a" in sent[1].content
    audio = [request for request in sent if request.url.path.endswith("/sendAudio")]
    assert len(audio) == int(not missing_voice)
    if audio:
        assert b"synthetic-mp3" in audio[0].content
    assert "c3ludGhldGljLW1wMw==" not in "\n".join(pipeline.db.iterdump())


async def test_unknown_paid_transcription_cannot_be_replayed_after_policy_change(command_system):
    from newspaw.media.input_service import MediaCommands
    from newspaw.providers import ProfileRegistry, ProviderError

    pipeline, targets, _, _, _ = command_system
    store = pipeline.store
    registry = ProfileRegistry(store)
    registry.begin("verify.media.stt", "normal_primary", "stt", 100)
    registry.finish("verify.media.stt", {"status": "verified"})
    downloads, requests = [], []

    class Client:
        async def download_file(self, file_id, limit, guard):
            assert guard()
            downloads.append(file_id)
            return _wav()

    class STT:
        async def transcribe(self, data):
            requests.append(data)
            raise ProviderError("outcome_unknown", outcome="unknown")

        async def close(self):
            pass

    async def normalize(data):
        return data

    media = MediaCommands(
        store,
        targets.credentials.backend,
        stt_factory=lambda *_: STT(),
        normalize=normalize,
    )
    policy = media.policy()
    settings = {**policy["settings"], "stt_profile": "normal_primary", "stt_hold": 100}
    media.configure(settings, policy["revision"])
    attachment = dict(kind="voice", file_id="fixture-private-voice", duration=1)
    key = ("bot1", 1, 60)
    with pytest.raises(MediaInputError):
        await media.query(key, media.plan(attachment), Client(), lambda: True)
    policy = media.policy()
    media.configure({**settings, "stt_hold": 200}, policy["revision"])
    with pytest.raises(MediaInputError, match="media_outcome_unknown"):
        await media.query(key, media.plan(attachment), Client(), lambda: True)
    assert len(downloads) == len(requests) == 1
    assert store._db.execute("SELECT state FROM telegram_media_effects").fetchall() == [
        ("outcome_unknown",)
    ]


async def test_audio_cancellation_terminates_child_and_cleans_directory(tmp_path, monkeypatch):
    import asyncio
    import tempfile

    entered = asyncio.Event()
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path))

    class Child:
        returncode = None
        waited = False

        async def communicate(self, data):
            assert data.startswith(b"RIFF")
            entered.set()
            await asyncio.Event().wait()

        def kill(self):
            self.returncode = -9

        async def wait(self):
            self.waited = True

    child = Child()

    async def create(*args, **kwargs):
        assert Path(args[-1]).parent.is_dir()
        return child

    from pathlib import Path

    monkeypatch.setattr(asyncio, "create_subprocess_exec", create)
    monkeypatch.setattr("newspaw.media.audio.shutil.which", lambda _: "/fixture/ffmpeg")
    task = asyncio.create_task(normalize_wav(_wav()))
    await asyncio.wait_for(entered.wait(), 1)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert child.returncode == -9 and child.waited and not list(tmp_path.iterdir())


async def test_stt_probe_requires_recognition_and_never_repeats_same_identity(command_system):
    from newspaw.providers import ProbeService

    pipeline, targets, _, _, _ = command_system
    attempts = []

    class STT:
        async def transcribe(self, data):
            assert data == _wav()
            attempts.append(data)
            text = "Wrong phrase" if len(attempts) == 1 else "NewsPaw audio test."
            return text, {"input_tokens": 1}

        async def close(self):
            pass

    async def fixture():
        return _wav()

    probes = ProbeService(
        pipeline.store,
        targets.credentials.backend,
        stt_factory=lambda *_: STT(),
        stt_fixture=fixture,
    )
    invalid = await probes.probe("stt.invalid", "normal_primary", "stt", 100)
    assert invalid["status"] == "failed"
    assert probes.registry.status("normal_primary")["stt"]["state"] != "verified"
    valid = await probes.probe("stt.valid", "normal_primary", "stt", 100)
    assert valid["status"] == "verified"
    assert await probes.probe("stt.valid", "normal_primary", "stt", 100) == valid
    assert len(attempts) == 2


async def test_explicit_adult_media_scope_never_downloads_or_calls_normal_model(command_system):
    from test_outbox import ready_response
    from test_telegram_commands import command_service

    pipeline, _, _, _, _ = command_system
    store = pipeline.store
    revision, config = store.load_config()
    config["bots"][0]["adult_allowed"] = True
    sub = next(row for row in config["subscriptions"] if row["category_id"] == "av")
    sub.update(enabled=True, bot_ids=["bot1"])
    store.save_config(config, expected_revision=revision)

    def no_model(*args):
        pytest.fail("normal model must not receive adult-scoped media")

    async def reply(request):
        assert request.url.path.endswith("/sendMessage")
        return ready_response()

    commands, _, sent = command_service(command_system, reply)
    commands.media = _enable_media(command_system, vision_factory=no_model)
    await _attach(command_system, 2, caption="/search s:sub_av")
    await commands.tick()
    assert len(sent) == 1
    assert store._db.execute("SELECT count(*) FROM telegram_media_effects").fetchone() == (0,)
