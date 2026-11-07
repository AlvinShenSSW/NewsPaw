"""Bounded local audio normalization and language-matched macOS speech."""

from __future__ import annotations

import asyncio
import re
import shutil
import sys
import wave
from contextlib import suppress
from pathlib import Path
from tempfile import TemporaryDirectory

from ..credentials import CredentialError

MAX_AUDIO_DOWNLOAD = 12 * 1024 * 1024
MAX_AUDIO_SECONDS = 180
MAX_WAV = 6 * 1024 * 1024
MAX_SPEECH = 1024 * 1024
_VOICE_LOCALES = {
    "en": ("en_US", "Samantha"),
    "ja": ("ja_JP", "Kyoko"),
    "zh-Hans": ("zh_CN", "Tingting"),
}
_VOICE_ROW = re.compile(r"^(.+?)\s+([a-z]{2,3}_[A-Z]{2})\s+#")


class MediaInputError(CredentialError):
    pass


def _read_output(path, limit):
    try:
        with path.open("rb") as file:
            data = file.read(limit + 1)
    except OSError:
        raise MediaInputError("media_processing_failed") from None
    if not 1 <= len(data) <= limit:
        raise MediaInputError("media_too_large")
    return data


async def _run(args, *, data=None, capture=False, timeout=30):
    try:
        child = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE if capture else asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except OSError:
        raise MediaInputError("media_tool_unavailable") from None
    try:
        async with asyncio.timeout(timeout):
            stdout, _ = await child.communicate(data)
    except (TimeoutError, asyncio.CancelledError) as exc:
        if child.returncode is None:
            with suppress(ProcessLookupError):
                child.kill()
        await child.wait()
        if isinstance(exc, asyncio.CancelledError):
            raise
        raise MediaInputError("media_processing_timeout") from None
    if child.returncode:
        raise MediaInputError("media_processing_failed")
    return stdout


def _ffmpeg():
    binary = shutil.which("ffmpeg")
    if not binary:
        raise MediaInputError("media_tool_unavailable")
    return binary


async def normalize_wav(data):
    if not isinstance(data, bytes) or not 1 <= len(data) <= MAX_AUDIO_DOWNLOAD:
        raise MediaInputError("media_too_large")
    binary = _ffmpeg()
    with TemporaryDirectory(prefix="newspaw-normalize-") as directory:
        target = Path(directory) / "normalized.wav"
        await _run(
            (
                binary,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-protocol_whitelist",
                "pipe",
                "-format_whitelist",
                "ogg,mp3,wav,mov,matroska,webm,aiff",
                "-i",
                "pipe:0",
                "-t",
                str(MAX_AUDIO_SECONDS + 1),
                "-vn",
                "-sn",
                "-dn",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-c:a",
                "pcm_s16le",
                "-y",
                str(target),
            ),
            data=data,
        )
        try:
            with wave.open(str(target), "rb") as result:
                frames = result.getnframes()
                if (result.getnchannels(), result.getframerate(), result.getsampwidth()) != (
                    1,
                    16000,
                    2,
                ):
                    raise MediaInputError("invalid_audio")
                if not 1 <= frames <= MAX_AUDIO_SECONDS * 16000:
                    raise MediaInputError("invalid_audio_duration")
                if len(result.readframes(frames)) != frames * 2:
                    raise MediaInputError("invalid_audio")
        except (OSError, EOFError, wave.Error):
            raise MediaInputError("invalid_audio") from None
        return _read_output(target, MAX_WAV)


def matching_voice(inventory, locale):
    pair = _VOICE_LOCALES.get(locale)
    if pair is None or not isinstance(inventory, str) or len(inventory) > 128 * 1024:
        return None
    tag, preferred = pair
    matching = [
        result[1].strip()
        for line in inventory.splitlines()[:1500]
        if (result := _VOICE_ROW.match(line)) and result[2] == tag
    ]
    return preferred if preferred in matching else next(iter(matching), None)


class LocalSpeech:
    async def _voice(self, locale):
        if sys.platform != "darwin":
            raise MediaInputError("voice_unavailable")
        raw = await _run(("/usr/bin/say", "-v", "?"), capture=True, timeout=10)
        voice = matching_voice(raw.decode("utf-8", errors="replace"), locale)
        if voice is None:
            raise MediaInputError("voice_unavailable")
        return voice

    async def _synthesize(self, text, locale, target):
        if not isinstance(text, str):
            raise MediaInputError("invalid_speech_text")
        clean = re.sub(r"\[\[.*?\]\]", "", text, flags=re.DOTALL)
        clean = clean.replace("[[", "").replace("]]", "").replace("\0", "").strip()[:1200]
        if not clean:
            raise MediaInputError("invalid_speech_text")
        voice = await self._voice(locale)
        script = target.with_suffix(".txt")
        script.write_text(clean, encoding="utf-8")
        await _run(("/usr/bin/say", "-v", voice, "-o", str(target), "-f", str(script)), timeout=50)

    async def probe_wav(self):
        with TemporaryDirectory(prefix="newspaw-speech-probe-") as directory:
            target = Path(directory) / "probe.aiff"
            await self._synthesize("News Paw audio test.", "en", target)
            return await normalize_wav(_read_output(target, MAX_AUDIO_DOWNLOAD))

    async def synthesize(self, text, locale):
        binary = _ffmpeg()
        with TemporaryDirectory(prefix="newspaw-speech-") as directory:
            source, target = Path(directory) / "speech.aiff", Path(directory) / "speech.mp3"
            await self._synthesize(text, locale, source)
            await _run(
                (
                    binary,
                    "-nostdin",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-protocol_whitelist",
                    "file",
                    "-i",
                    str(source),
                    "-t",
                    "120",
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "24000",
                    "-c:a",
                    "libmp3lame",
                    "-b:a",
                    "48k",
                    "-y",
                    str(target),
                ),
                timeout=25,
            )
            return _read_output(target, MAX_SPEECH)
