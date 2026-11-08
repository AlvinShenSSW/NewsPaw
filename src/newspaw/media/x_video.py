"""Bounded X media acquisition and local extraction of stills and audio."""

from __future__ import annotations

import asyncio
import json
import math
import re
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory

import httpx

from ..transport import checked_url, source_client
from .audio import MediaInputError, _ffmpeg, _read_output, _run, normalize_wav
from .source_images import ImageError, normalize_photo

MAX_BYTES = 8 * 1024 * 1024
MAX_SECONDS = 60
_MAX_PIXELS = 8_000_000
_VIDEO_PATH = re.compile(r"/(?:ext_tw_video|amplify_video|tweet_video)/[A-Za-z0-9_./-]+\.mp4")
_PIPE_INPUT = (
    "-protocol_whitelist",
    "pipe",
    "-format_whitelist",
    "mov",
    "-max_streams",
    "2",
    "-max_pixels",
    str(_MAX_PIXELS),
    "-i",
    "pipe:0",
)


def variant(metadata):
    duration = metadata.get("duration_ms")
    if type(duration) is not int or not 1 <= duration <= MAX_SECONDS * 1000:
        raise MediaInputError("video_duration_unsupported")
    variants = metadata.get("variants")
    if not isinstance(variants, list) or not 1 <= len(variants) <= 20:
        raise MediaInputError("video_variant_unavailable")
    options = []
    for item in variants:
        if not isinstance(item, dict) or item.get("content_type") != "video/mp4":
            continue
        value = item.get("url")
        bitrate = item.get("bit_rate", 2**31)
        if not isinstance(value, str) or type(bitrate) is not int or not 1 <= bitrate <= 2**31:
            continue
        try:
            url = checked_url(value)
        except httpx.RequestError:
            continue
        if (
            url.host == "video.twimg.com"
            and url.port is None
            and not url.fragment
            and _VIDEO_PATH.fullmatch(url.path)
            and ".." not in url.path.split("/")
        ):
            options.append((bitrate, str(url)))
    if not options:
        raise MediaInputError("video_variant_unavailable")
    return min(options)[1]


async def download(metadata, allowed, *, client_factory=source_client):
    url = variant(metadata)
    if not allowed():
        raise MediaInputError("video_scope_changed")
    try:
        async with (
            asyncio.timeout(20),
            client_factory(max_bytes=MAX_BYTES, deadline=18) as client,
            client.stream(
                "GET", url, headers={"Accept": "video/mp4"}, follow_redirects=False
            ) as response,
        ):
            if (
                response.status_code != 200
                or response.headers.get("content-type", "").split(";", 1)[0].strip() != "video/mp4"
            ):
                raise MediaInputError("video_download_unavailable")
            data = bytearray()
            async for chunk in response.aiter_bytes(chunk_size=65_536):
                if len(data) + len(chunk) > MAX_BYTES:
                    raise MediaInputError("video_too_large")
                data.extend(chunk)
    except (httpx.HTTPError, OSError, TimeoutError):
        raise MediaInputError("video_download_unavailable") from None
    if not data or not allowed():
        raise MediaInputError("video_scope_changed" if data else "video_download_unavailable")
    return bytes(data)


def _shape(raw):
    try:
        if len(raw) > 32_768:
            raise ValueError()
        document = json.loads(raw)
        streams = document["streams"]
        if not isinstance(streams, list) or not 1 <= len(streams) <= 2:
            raise ValueError()
        videos = [s for s in streams if s["codec_type"] == "video"]
        audios = [s for s in streams if s["codec_type"] == "audio"]
        if len(videos) != 1 or len(audios) + 1 != len(streams):
            raise ValueError()
        width, height = videos[0]["width"], videos[0]["height"]
        if (
            type(width) is not int
            or type(height) is not int
            or min(width, height) < 2
            or width * height > _MAX_PIXELS
            or max(width, height) > 12 * min(width, height)
        ):
            raise ValueError()
        duration = float(document["format"]["duration"])
        durations = [duration] + [
            float(stream["duration"]) for stream in streams if "duration" in stream
        ]
        if any(not math.isfinite(value) or not 0 < value <= MAX_SECONDS for value in durations):
            raise ValueError()
    except (KeyError, TypeError, ValueError, RecursionError):
        raise MediaInputError("video_format_or_duration_unsupported") from None
    return duration, bool(audios)


async def extract(data):
    if not isinstance(data, bytes) or not 1 <= len(data) <= MAX_BYTES:
        raise MediaInputError("video_too_large")
    probe = shutil.which("ffprobe")
    if not probe:
        raise MediaInputError("media_tool_unavailable")
    ffmpeg = _ffmpeg()
    result = await _run(
        (
            probe,
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type,width,height,duration",
            "-of",
            "json",
            *_PIPE_INPUT,
        ),
        data=data,
        capture=True,
        timeout=8,
    )
    duration, has_audio = _shape(result)
    positions = (duration * 0.25,) if duration < 3 else (duration * 0.25, duration * 0.7)
    frames = []
    with TemporaryDirectory(prefix="newspaw-x-video-") as tmp:
        for i, at in enumerate(positions):
            target = Path(tmp) / f"frame{i}.jpg"
            await _run(
                (
                    ffmpeg,
                    "-nostdin",
                    "-v",
                    "error",
                    "-threads",
                    "2",
                    *_PIPE_INPUT,
                    "-ss",
                    f"{at:.3f}",
                    "-map",
                    "0:v:0",
                    "-frames:v",
                    "1",
                    "-an",
                    "-vf",
                    "scale=640:640:force_original_aspect_ratio=decrease",
                    "-fs",
                    "1048576",
                    "-y",
                    str(target),
                ),
                data=data,
                timeout=10,
            )
            try:
                frames.append(
                    (
                        round(at, 2),
                        normalize_photo(_read_output(target, 1_048_576), "image/jpeg")[0],
                    )
                )
            except ImageError:
                raise MediaInputError("video_frame_invalid") from None
    audio = await normalize_wav(data) if has_audio else None
    return frames, audio
