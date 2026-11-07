import asyncio
from datetime import UTC, datetime, timedelta

import pytest
from test_outbox import system as telegram_system

from newspaw.media.newspaper import PaperError, bounded_preparation, make_plan, validate_ocr

telegram_delivery = telegram_system


def test_newspaper_tables_upgrade_x_timeline_database(tmp_path):
    from contextlib import closing

    from newspaw.store import Store

    path = tmp_path / "state.db"
    with closing(Store(path)) as previous, previous._write():
        previous._db.execute("DROP TABLE newspaper_effects")
        previous._db.execute("DROP TABLE newspapers")
        previous._db.execute("DROP TABLE newspaper_policy")
        previous._db.execute("PRAGMA user_version=18")
    with closing(Store(path)) as upgraded:
        assert upgraded._db.execute("PRAGMA user_version").fetchone() == (19,)
        for table in ("newspaper_policy", "newspapers", "newspaper_effects", "x_timeline_scans"):
            assert upgraded._db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
            ).fetchone()


def edition(locale="en"):
    labels = {
        "en": ("Published update", "The office reported 12 products."),
        "zh-Hans": ("产品发布", "该机构报道了 12 件产品。"),
        "ja": ("製品の発表", "同機関は 12 件の製品を報告しました。"),
    }
    title, body = labels[locale]
    return dict(
        locale=locale,
        items=[
            dict(
                title=title,
                body=body,
                event_key="evt",
                sources=[
                    {
                        "source": "Fixture",
                        "url": "https://example.com/a",
                        "published_at": "2026-11-07T15:00:00+00:00",
                    }
                ],
            )
        ],
    )


@pytest.mark.parametrize("locale", ["zh-Hans", "en", "ja"])
def test_frozen_page_plan_accepts_exact_ocr_and_rejects_changed_number(locale):
    plan = make_plan(edition(locale), page_count=1)
    assert len(plan["pages"]) == 1
    expected = plan["pages"][0]["lines"]
    assert validate_ocr(plan["pages"][0], expected)
    changed = [line.replace("12", "13") for line in expected]
    with pytest.raises(PaperError, match="ocr_mismatch"):
        validate_ocr(plan["pages"][0], changed)
    assert plan["citations"][0]["url"] == "https://example.com/a"


async def test_absolute_media_deadline_cancels_stalled_producer():
    started, cancelled = asyncio.Event(), asyncio.Event()

    async def producer():
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    with pytest.raises(PaperError, match="newspaper_deadline"):
        await bounded_preparation(producer, datetime.now(UTC) + timedelta(milliseconds=20))
    assert started.is_set() and cancelled.is_set()


async def test_generation_uses_verified_openai_images_endpoint_without_external_asset_url():
    import base64
    import json

    import httpx
    from test_routing import configured

    from newspaw.media.image_provider import ImageProvider

    config, _ = configured()
    profile = config["model_profiles"][0]
    profile["capabilities"] = ["image"]
    profile["model"] = "user-selected-image"
    photo = b"\xff\xd8\xff" + b"synthetic"
    calls = []

    def answer(request):
        calls.append(request)
        assert str(request.url) == "https://api.openai.com/v1/images/generations"
        payload = json.loads(request.content)
        assert payload["model"] == "user-selected-image" and payload["n"] == 1
        assert payload["output_format"] == "jpeg" and payload["stream"] is False
        return httpx.Response(
            200,
            json={
                "data": [{"b64_json": base64.b64encode(photo).decode()}],
                "usage": {"output_tokens": 45},
            },
        )

    adapter = ImageProvider(
        profile,
        "synthetic-key",
        client=httpx.AsyncClient(transport=httpx.MockTransport(answer)),
    )
    try:
        assert await adapter.generate("Exact synthetic page plan") == (
            photo,
            {"output_tokens": 45, "images": 1},
        )
    finally:
        await adapter.close()
    assert len(calls) == 1


@pytest.fixture
def prepared_papers(tmp_path):
    from contextlib import closing
    from io import BytesIO

    from PIL import Image
    from test_model_runner import Keys
    from test_routing import configured

    from newspaw.media.paper_service import Newspapers
    from newspaw.media.source_images import AssetStore
    from newspaw.providers import ProfileRegistry
    from newspaw.store import Store

    class OCR:
        def __init__(self):
            self.lines = []
            self.calls = 0

        async def supports(self, locale):
            return True

        async def read(self, locale, data):
            result = self.lines[self.calls]
            self.calls += 1
            return result

    buffer = BytesIO()
    Image.new("RGB", (40, 60), "white").save(buffer, "JPEG")
    raw = buffer.getvalue()
    calls = []

    class ImageAdapter:
        async def generate(self, prompt):
            calls.append("generation")
            return raw, {"images": 1}

        async def close(self):
            pass

    class VisionAdapter:
        async def generate(self, request):
            calls.append("vision")
            assert request.image and request.partition == "normal"
            return {"arguments": {"pass": True}, "usage": {"input_tokens": 10}}

        async def close(self):
            pass

    with closing(Store(tmp_path / "state.db")) as store:
        config, _ = configured()
        store.save_config(config, expected_revision=1)
        registry = ProfileRegistry(store)
        for capability, profile in (("image", "normal_primary"), ("vision", "normal_backup")):
            registry.begin("verify." + capability, profile, capability, 100)
            registry.finish("verify." + capability, {"status": "verified"})
        assets = AssetStore(tmp_path / "media")
        ocr = OCR()
        service = Newspapers(
            store,
            Keys(),
            assets,
            ocr,
            image_factory=lambda *args: ImageAdapter(),
            vision_factory=lambda *args: VisionAdapter(),
        )
        policy = service.policy()
        settings = policy["settings"]
        settings.update(
            enabled=True,
            generation_profile="normal_primary",
            vision_profile="normal_backup",
            generation_hold=100,
            vision_hold=100,
            task_limit=1000,
        )
        service.configure(settings, policy["revision"])
        yield service, assets, ocr, calls


async def test_newspaper_shares_verified_cached_image_and_retains_clickable_sources(
    prepared_papers,
):
    service, assets, ocr, calls = prepared_papers
    frozen = edition()
    ocr.lines = [make_plan(frozen, page_count=1)["pages"][0]["lines"]]
    future = datetime.now(UTC) + timedelta(seconds=5)
    first = await service.prepare("brief.fixture", frozen, "normal", future, lambda: True)
    second = await service.prepare("brief.fixture", frozen, "normal", future, lambda: True)
    assert first == second and calls == ["generation", "vision"]
    assert "S1" in first[0]["caption"] and "https://example.com/a" in first[0]["caption"]
    assert assets.read(first[0]["asset_id"])
    assert service.db.execute(
        "SELECT count(DISTINCT task_id),count(*) FROM budget_attempts WHERE id LIKE 'paper-effect.%'"
    ).fetchone() == (1, 2)


async def test_second_page_ocr_failure_does_not_publish_first_page(prepared_papers):
    service, _, ocr, calls = prepared_papers
    frozen = edition()
    frozen["items"].append(dict(frozen["items"][0], title="Second update", event_key="evt2"))
    plan = make_plan(frozen, page_count=2)
    ocr.lines = [plan["pages"][0]["lines"], ["wrong second page"]]
    future = datetime.now(UTC) + timedelta(seconds=5)
    with pytest.raises(PaperError, match="ocr_mismatch"):
        await service.prepare("brief.two", frozen, "normal", future, lambda: True, page_count=2)
    assert calls == ["generation", "vision", "generation"]
    assert service.db.execute("SELECT state,result FROM newspapers").fetchall() == [
        ("building", None)
    ]


async def test_deadline_keeps_unknown_budget_and_does_not_repeat_generation(prepared_papers):
    service, _, _, calls = prepared_papers
    entered = asyncio.Event()

    class Stall:
        async def generate(self, prompt):
            calls.append("generation")
            entered.set()
            await asyncio.Event().wait()

        async def close(self):
            pass

    service.images = lambda *args: Stall()
    frozen = edition()
    future = datetime.now(UTC) + timedelta(milliseconds=60)
    with pytest.raises(PaperError, match="newspaper_deadline"):
        await service.prepare("brief.lost", frozen, "normal", future, lambda: True)
    assert entered.is_set()
    assert service.db.execute(
        "SELECT state,reserved_units FROM budget_attempts WHERE id LIKE 'paper-effect.%'"
    ).fetchall() == [("outcome_unknown", 100)]
    with pytest.raises(PaperError, match="newspaper_outcome_unknown"):
        await service.prepare(
            "brief.lost", frozen, "normal", datetime.now(UTC) + timedelta(seconds=5), lambda: True
        )
    assert calls == ["generation"]


async def test_scheduled_newspaper_deadline_delivers_frozen_text_only(telegram_delivery):
    from test_model_runner import NOW
    from test_outbox import sender
    from test_scheduler import prepare_scheduled, scheduled

    pipeline, targets, _, _, _ = telegram_delivery
    revision, config = pipeline.store.load_config()
    sub = next(row for row in config["subscriptions"] if row["id"] == "sub_world")
    sub["style"] = "newspaper"
    pipeline.store.save_config(config, expected_revision=revision)
    outbox, deliveries = sender(pipeline, targets)
    scheduler, clock, target = scheduled(pipeline, outbox, NOW)
    entered, cancelled = asyncio.Event(), asyncio.Event()

    class StalledPaper:
        def clock(self):
            return clock[0]

        async def prepare(self, edition_id, frozen, partition, deadline, guard):
            assert deadline == target
            assert frozen["items"] and partition == "normal"
            with pipeline.store._write():
                assert guard() is True

            async def render():
                entered.set()
                try:
                    await asyncio.Event().wait()
                finally:
                    cancelled.set()

            return await bounded_preparation(render, deadline, clock=self.clock)

    pipeline.newspapers = StalledPaper()
    row = await prepare_scheduled(scheduler, clock, steps=2)
    assert pipeline.get(row["job_id"])["stage"] == "preparing_media"
    clock[0] = target - timedelta(milliseconds=40)
    await scheduler.step(row)
    assert entered.is_set() and cancelled.is_set()
    job = pipeline.get(row["job_id"])
    assert job["stage"] == "awaiting_delivery"
    assert job["media"]["fallback_reason"] == "newspaper_deadline"
    assert not deliveries
    clock[0] = target
    await scheduler.step(scheduler.plan(clock[0])[0])
    assert len(deliveries) == 2
    assert all(request.url.path.endswith("/sendMessage") for request in deliveries)
    assert scheduler.status()["occurrences"][0]["status"] == "delivered"


@pytest.mark.parametrize("expire_before_photo", [False, True])
async def test_paper_command_reuses_exact_confirmed_receipt_and_never_sends_late_photo(
    telegram_delivery, tmp_path, expire_before_photo
):
    import hashlib
    from io import BytesIO

    from PIL import Image
    from test_telegram_commands import NOW, command_service, inbox

    from newspaw.media.source_images import AssetStore

    pipeline, _, job, _, _ = telegram_delivery
    commands, outbox, sent = command_service(telegram_delivery)
    assets = AssetStore(tmp_path / "paper-assets")
    output = BytesIO()
    Image.new("RGB", (40, 60), "white").save(output, "JPEG")
    jpg = output.getvalue()
    asset = assets.put(jpg, kind="paper")
    outbox.asset_resolver = assets.read
    calls = []

    class Builder:
        async def prepare(
            self, edition_id, frozen, partition, deadline, guard, *, item_number, page_count
        ):
            assert guard() and partition == "normal"
            calls.append((edition_id, item_number, page_count))
            return [
                dict(
                    asset_id=asset,
                    sha256=hashlib.sha256(jpg).hexdigest(),
                    mime="image/jpeg",
                    width=40,
                    height=60,
                    caption="AI generated · S1\nhttps://example.com/a",
                )
            ]

    pipeline.newspapers = Builder()
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    await inbox(telegram_delivery, "/paper 1 item:1", 2, bot="bot2", reply=1)
    await commands.tick()
    assert not calls
    await inbox(telegram_delivery, "/paper 1 item:1", 2, bot="bot1", reply=1)
    await commands.tick()
    assert calls == [(pipeline._edition_id(job), 1, 1)]
    if expire_before_photo:
        commands.clock = lambda: NOW + timedelta(minutes=2)
    await commands.tick()
    assert sum(request.url.path.endswith("/sendPhoto") for request in sent) == (
        0 if expire_before_photo else 1
    )
    assert sum(request.url.path.endswith("/sendMessage") for request in sent) == 3
