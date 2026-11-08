import shutil
import subprocess
from pathlib import Path

import httpx
import pytest
from test_routing import REF
from test_x_digests import _digest_fixture, timeline_system
from test_x_timelines import NOW, page, post

from newspaw.budget import BudgetError, BudgetLedger
from newspaw.media.audio import MediaInputError
from newspaw.media.x_video import download, extract, variant
from newspaw.providers import ProfileRegistry, ProviderError
from newspaw.x.client import XClient
from newspaw.x.video import Videos

assert timeline_system is not None

URL = "https://video.twimg.com/ext_tw_video/190/pu/vid/320x180/fixture.mp4?tag=12"
META = {
    "media_key": "13_190",
    "type": "video",
    "duration_ms": 4000,
    "variants": [{"content_type": "video/mp4", "url": URL}],
}


async def fixture(system, *, partition="normal", unknown=False):
    external = []

    async def reply(request, _):
        if request.url.path == "/2/tweets/190":
            external.append(request.url.path)
            return httpx.Response(
                200,
                json={
                    "data": dict(
                        post(190),
                        text="OpenAI released GPT-6.",
                        attachments={"media_keys": ["13_190"]},
                    ),
                    "includes": {
                        "users": [{"id": "12345", "protected": False, "username": "fixture"}],
                        "media": [META],
                    },
                },
            )
        return page([dict(post(190), text="OpenAI released GPT-6.")])

    build, scans, sub, _, holds, _ = await _digest_fixture(system, reply, partition)
    pipeline = build()
    store = pipeline.store
    revision, config = store.load_config()
    openai = config["model_profiles"][0]
    for identity, capability in [
        ("vision_primary", "vision"),
        ("vision_backup", "vision"),
        ("speech_primary", "stt"),
    ]:
        config["model_profiles"].append(
            dict(
                openai,
                id=identity,
                capabilities=[capability],
                model="fixture-" + capability,
            )
        )
    store.save_config(config, expected_revision=revision)
    scans.directory.credentials.backend.items[REF] = "fixture-model-key"
    registry = ProfileRegistry(store)
    for identity, capability in [
        ("vision_primary", "vision"),
        ("vision_backup", "vision"),
        ("speech_primary", "stt"),
    ]:
        registry.begin("verify." + identity, identity, capability, 1)
        registry.finish("verify." + identity, {"status": "verified"})

    class Adapter:
        def __init__(self, profile, _):
            self.identity = profile["id"]

        async def close(self):
            pass

        def payload(self, request):
            assert request.partition == "normal" and request.image == b"fixture-jpeg"

        async def generate(self, _):
            external.append(self.identity)
            if self.identity == "vision_primary":
                raise ProviderError("fixture", outcome="unknown" if unknown else "known")
            return {"text": "A screen with text", "usage": {"input_tokens": 1}}

        async def transcribe(self, data):
            assert data == b"fixture-wav"
            external.append(self.identity)
            return "Fixture audio", {"input_tokens": 1}

    async def load(meta, live):
        assert variant(meta) == URL and live()
        external.append("download")
        return b"fixture"

    async def decode(data):
        assert data == b"fixture"
        return [(1.0, b"fixture-jpeg"), (2.8, b"fixture-jpeg")], b"fixture-wav"

    videos = Videos(
        pipeline,
        scans.directory,
        clock=lambda: NOW,
        load=load,
        decode=decode,
        vision_factory=Adapter,
        stt_factory=Adapter,
    )
    job = pipeline.create(sub, "video-fixture", holds=holds, now=NOW)["job_id"]
    for _ in range(3):
        await pipeline.advance(job, now=NOW)
    assert pipeline.get(job)["stage"] == "awaiting_delivery"

    async def official(request):
        assert request.url.path == "/2/tweets/190"
        return await reply(request, 1)

    scans.directory.client_factory = lambda token: XClient(
        token, client=httpx.AsyncClient(transport=httpx.MockTransport(official))
    )
    settings = videos.policy()["settings"]
    settings.update(
        enabled=True,
        daily_limit=1,
        daily_model_limit=500,
        vision_profiles=["vision_primary", "vision_backup"],
        stt_profiles=["speech_primary"],
        vision_hold=10,
        stt_hold=20,
    )
    return videos, job, settings, external


async def test_video_uses_exact_x_item_with_verified_same_capability_backup(timeline_system):
    videos, job, settings, external = await fixture(timeline_system)
    with pytest.raises(MediaInputError, match="video_disabled"):
        await videos.inspect("vid.one", job, "190")
    videos.configure(settings, videos.policy()["revision"])
    ledger = BudgetLedger(videos.store)
    prior_x = next(row["known_settled"] for row in ledger.report()["periods"] if row["meter"] == "x")
    result = await videos.inspect("vid.one", job, "190")
    assert result["state"] == "complete"
    assert len(result["frames"]) == 2 and result["transcript"] == "Fixture audio"
    assert external == [
        "/2/tweets/190",
        "download",
        "vision_primary",
        "vision_backup",
        "vision_primary",
        "vision_backup",
        "speech_primary",
    ]
    assert await videos.inspect("vid.one", job, "190") == result
    periods = {row["meter"]: row["operations"] for row in ledger.report()["periods"]}
    assert {"vision", "stt"} <= set(periods["model"])
    assert "image" not in periods["model"] and periods["x"]["x"]["known_settled"] == prior_x + 1
    with pytest.raises(MediaInputError, match="video_daily_budget"):
        await videos.inspect("vid.two", job, "190")
    assert len(external) == 7
    revision, config = videos.store.load_config()
    next(profile for profile in config["model_profiles"] if profile["id"] == "vision_backup")[
        "model"
    ] = "replaced"
    videos.store.save_config(config, expected_revision=revision)
    with pytest.raises(MediaInputError, match="video_scope_changed"):
        videos.status("vid.one")


async def test_unknown_vision_outcome_does_not_fall_back_and_releases_unused_reservations(
    timeline_system,
):
    videos, job, settings, external = await fixture(timeline_system, unknown=True)
    videos.configure(settings, videos.policy()["revision"])
    result = await videos.inspect("vid.one", job, "190")
    assert result["state"] == "outcome_unknown" and external[-1] == "vision_primary"
    states = videos.db.execute(
        "SELECT state,count(*) FROM budget_attempts WHERE task_id=? GROUP BY state",
        (videos._task("vid.one"),),
    ).fetchall()
    assert dict(states) == {"settled": 1, "released": 4, "outcome_unknown": 1}
    assert await videos.inspect("vid.one", job, "190") == result
    assert len(external) == 3


async def test_adult_video_is_rejected_before_x_or_normal_models(timeline_system):
    videos, job, settings, external = await fixture(timeline_system, partition="adult")
    videos.configure(settings, videos.policy()["revision"])
    with pytest.raises(MediaInputError, match="video_scope_unavailable"):
        await videos.inspect("vid.adult", job, "190")
    assert not external


async def test_model_budget_fails_before_x_or_video_download(timeline_system):
    videos, job, settings, external = await fixture(timeline_system)
    videos.configure(settings, videos.policy()["revision"])
    budget = BudgetLedger(videos.store)
    revision, policy = budget.policy()
    policy["model"]["monthly_limit"] = 0
    budget.configure(policy, revision)
    with pytest.raises(BudgetError, match="model_limit"):
        await videos.inspect("vid.one", job, "190")
    assert not external and videos._receipt("vid.one") is None


@pytest.mark.parametrize(
    "url",
    [
        "https://evil.example/ext_tw_video/1/fixture.mp4",
        "https://video.twimg.com:8443/ext_tw_video/1/fixture.mp4",
        "https://x@video.twimg.com/ext_tw_video/1/fixture.mp4",
        "https://video.twimg.com/ext_tw_video/1/fixture.m3u8",
    ],
)
def test_untrusted_variants_are_rejected(url):
    with pytest.raises(MediaInputError, match="video_variant_unavailable"):
        variant(dict(META, variants=[{"content_type": "video/mp4", "url": url}]))
    with pytest.raises(MediaInputError, match="video_duration_unsupported"):
        variant(dict(META, duration_ms=61_000))


async def test_media_download_does_not_follow_redirect():
    calls = []

    def reply(request):
        calls.append(request.url)
        return httpx.Response(302, headers={"location": "https://example.com/redirect.mp4"})

    def factory(**_):
        return httpx.AsyncClient(transport=httpx.MockTransport(reply))

    with pytest.raises(MediaInputError, match="video_download_unavailable"):
        await download(META, lambda: True, client_factory=factory)
    assert [str(url) for url in calls] == [URL]


@pytest.mark.skipif(
    not shutil.which("ffmpeg") or not shutil.which("ffprobe"), reason="ffmpeg optional"
)
async def test_local_extracts_real_stills_and_audio_and_rejects_long_video(tmp_path):
    fixture = Path(tmp_path) / "fixture.mp4"
    for seconds in (4, 61):
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=navy:s=160x90:r=4",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=16000",
                "-t",
                str(seconds),
                "-c:v",
                "mpeg4",
                "-c:a",
                "aac",
                "-movflags",
                "+faststart",
                "-y",
                str(fixture),
            ],
            check=True,
            timeout=20,
        )
        if seconds == 61:
            with pytest.raises(MediaInputError, match="video_format_or_duration_unsupported"):
                await extract(fixture.read_bytes())
        else:
            frames, audio = await extract(fixture.read_bytes())
            assert len(frames) == 2 and all(data.startswith(b"\xff\xd8") for _, data in frames)
            assert audio[:4] == b"RIFF"
