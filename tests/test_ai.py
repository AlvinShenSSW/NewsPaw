from __future__ import annotations

import asyncio
import json
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

import newspaw.ai as ai_module
from newspaw.ai import MAX_AUDIO_SECONDS, MAX_IMAGE_BYTES, AIError, AIService


@pytest.fixture
def service(monkeypatch):
    client = SimpleNamespace(
        responses=SimpleNamespace(create=AsyncMock()),
        audio=SimpleNamespace(transcriptions=SimpleNamespace(create=AsyncMock())),
        close=AsyncMock(),
    )
    monkeypatch.setattr(ai_module, "AsyncOpenAI", lambda **kwargs: client)
    return AIService("test-key"), client


def article(title="Article", summary="A source excerpt."):
    return SimpleNamespace(title=title, source="Example", published_at=None, summary=summary)


@pytest.mark.asyncio
async def test_summary_uses_only_verified_source_indexes(service):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(
        status="completed",
        output_text=json.dumps(
            {
                "items": [
                    {"index": 2, "summary": "Second item."},
                    {"index": 1, "summary": "First item. [999] https://invented.test/fake"},
                ],
                "conflicts": [],
            }
        ),
    )
    result = await adapter.summarize([article("First"), article("Second")])
    assert result == "[1] First\nFirst item.\n\n[2] Second\nSecond item."
    request = client.responses.create.call_args.kwargs
    assert request["store"] is False
    assert "tools" not in request
    assert request["text"]["format"]["strict"] is True


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "items",
    [
        [{"index": 99, "summary": "Invented source."}],
        [{"index": 1, "summary": "One."}, {"index": 1, "summary": "Duplicate."}],
        [],
        [{"index": True, "summary": "Invalid source."}],
    ],
)
async def test_summary_rejects_unknown_duplicate_missing_indexes(service, items):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps({"items": items, "conflicts": []})
    )
    with pytest.raises(AIError):
        await adapter.summarize([article()])


@pytest.mark.asyncio
async def test_model_failure_never_leaks_provider_response(service):
    adapter, client = service
    client.responses.create.side_effect = RuntimeError("sensitive secret-key and request body")
    with pytest.raises(AIError) as error:
        await adapter.summarize([article()])
    assert "secret-key" not in str(error.value)


@pytest.mark.asyncio
async def test_explicit_conflicts_are_preserved_with_validated_source_references(service):
    adapter, client = service
    first = article("Launch date", "Publisher A says the launch is Monday.")
    first.source = "Publisher A"
    second = article("Launch date update", "Publisher B says the launch is Wednesday.")
    second.source = "Publisher B"
    note = "Publisher A reports Monday; Publisher B reports Wednesday. The dates disagree."
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps(
            {
                "items": [
                    {"index": 1, "summary": "Publisher A reports a Monday launch."},
                    {"index": 2, "summary": "Publisher B reports a Wednesday launch."},
                ],
                "conflicts": [{"indexes": [2, 1], "note": note}],
            }
        )
    )
    result = await adapter.summarize([first, second])
    assert "Publisher A reports a Monday launch." in result
    assert "Publisher B reports a Wednesday launch." in result
    assert "未独立核实" in result
    assert f"[1] [2] {note}" in result
    request = client.responses.create.call_args.kwargs
    evidence = json.loads(request["input"])["articles"]
    assert evidence[0]["published_at"] is None
    assert evidence[1]["snippet"] == second.summary
    assert "Do not reconcile disagreements" in request["instructions"]
    assert "never guess or replace it" in request["instructions"]


@pytest.mark.asyncio
@pytest.mark.parametrize("indexes", [[1, 99], [1, 1], [1], [], [True, 2], ["1", 2]])
async def test_conflicts_reject_invalid_or_repeated_source_references(service, indexes):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps(
            {
                "items": [{"index": 1, "summary": "One."}, {"index": 2, "summary": "Two."}],
                "conflicts": [{"indexes": indexes, "note": "The sources disagree."}],
            }
        )
    )
    with pytest.raises(AIError):
        await adapter.summarize([article(), article()])


@pytest.mark.asyncio
async def test_empty_conflicts_do_not_create_a_disagreement_section(service):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(
        output_text=json.dumps(
            {
                "items": [{"index": 1, "summary": "Based on the title, a launch was announced."}],
                "conflicts": [],
            }
        )
    )
    result = await adapter.summarize([article(summary="")])
    assert "来源分歧" not in result


@pytest.mark.asyncio
async def test_text_query_is_bounded_and_not_a_tool_request(service):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(output_text="AI 新闻 " * 100)
    query = await adapter.text_query("帮我找今天的 AI 新闻")
    assert len(query) <= 200
    assert "tools" not in client.responses.create.call_args.kwargs


@pytest.mark.asyncio
async def test_image_query_transports_bytes_as_data_url(service):
    adapter, client = service
    client.responses.create.return_value = SimpleNamespace(output_text="new chip announcement")
    assert await adapter.image_query(b"image", "image/png") == "new chip announcement"
    image = client.responses.create.call_args.kwargs["input"][0]["content"][1]
    assert image["image_url"] == "data:image/png;base64,aW1hZ2U="


@pytest.mark.asyncio
async def test_image_limits_apply_before_api_call(service):
    adapter, client = service
    with pytest.raises(AIError):
        await adapter.image_query(b"x" * (MAX_IMAGE_BYTES + 1), "image/png")
    with pytest.raises(AIError):
        await adapter.image_query(b"x", "text/html")
    client.responses.create.assert_not_called()


@pytest.mark.asyncio
async def test_no_api_key_still_allows_construction_and_local_speech(monkeypatch):
    monkeypatch.setattr(ai_module.shutil, "which", lambda name: f"/test/{name}")
    directories = []

    async def media(*args, **kwargs):
        if args[0].endswith("/say"):
            script = Path(args[args.index("-f") + 1])
            assert "[[" not in script.read_text()
            directories.append(script.parent)
        else:
            Path(args[-1]).write_bytes(b"ID3-test-mp3")

    monkeypatch.setattr(ai_module, "_run_media", media)
    adapter = AIService()
    assert adapter.enabled is False
    assert await adapter.speak("新闻摘要 [[rate 999]]") == b"ID3-test-mp3"
    assert all(not path.exists() for path in directories)
    with pytest.raises(AIError):
        await adapter.text_query("news")


def write_wav(path, duration):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\x00\x00" * (16000 * duration))


@pytest.mark.asyncio
async def test_ogg_is_normalized_and_temp_files_removed(service, monkeypatch):
    adapter, client = service
    monkeypatch.setattr(ai_module.shutil, "which", lambda _: "/test/ffmpeg")
    paths = []

    async def media(*args, **kwargs):
        assert "-protocol_whitelist" in args
        source = Path(args[args.index("-i") + 1])
        assert source.name == "input.ogg"
        assert source.read_bytes() == b"voice-data"
        paths.append(source.parent)
        write_wav(Path(args[-1]), 1)

    async def transcribe(**kwargs):
        name, stream, mime = kwargs["file"]
        assert (name, mime) == ("voice.wav", "audio/wav")
        assert stream.read(4) == b"RIFF"
        return SimpleNamespace(text="AI news")

    monkeypatch.setattr(ai_module, "_run_media", media)
    client.audio.transcriptions.create.side_effect = transcribe
    assert await adapter.transcribe(b"voice-data", "../../filename.ogg") == "AI news"
    assert all(not path.exists() for path in paths)


@pytest.mark.asyncio
async def test_too_long_audio_is_rejected_before_model_upload(service, monkeypatch):
    adapter, client = service
    monkeypatch.setattr(ai_module.shutil, "which", lambda _: "/test/ffmpeg")

    async def media(*args, **kwargs):
        write_wav(Path(args[-1]), MAX_AUDIO_SECONDS + 1)

    monkeypatch.setattr(ai_module, "_run_media", media)
    with pytest.raises(AIError, match="3 分钟"):
        await adapter.transcribe(b"voice-data", "voice.ogg")
    client.audio.transcriptions.create.assert_not_called()


@pytest.mark.asyncio
async def test_media_timeout_kills_child(monkeypatch):
    process = SimpleNamespace(returncode=None)
    process.wait = AsyncMock(side_effect=[TimeoutError(), 0])
    process.kill = lambda: setattr(process, "returncode", -9)
    monkeypatch.setattr(asyncio, "create_subprocess_exec", AsyncMock(return_value=process))
    with pytest.raises(AIError, match="超时"):
        await ai_module._run_media("ffmpeg")
    assert process.returncode == -9
