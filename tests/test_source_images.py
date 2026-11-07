import io
import os

import pytest
from test_outbox import system as outbox_system

from newspaw.media.source_images import AssetStore, ImageError, normalize_photo

system = outbox_system


def raw_image(size=(40, 25), *, format="PNG"):
    from PIL import Image

    buffer = io.BytesIO()
    with Image.new("RGBA", size, (0, 100, 200, 64)) as img:
        img.save(buffer, format=format)
    return buffer.getvalue()


def test_normalized_photo_strips_metadata_and_respects_declared_mime():
    from PIL import Image

    original = raw_image()
    data, width, height = normalize_photo(original, "image/png")
    assert (width, height) == (40, 25)
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "JPEG" and not image.getexif() and "icc_profile" not in image.info
    with pytest.raises(ImageError, match="invalid_image"):
        normalize_photo(original, "image/jpeg")


def test_raster_pixel_limit_checked_before_loading():
    with pytest.raises(ImageError, match="invalid_image"):
        normalize_photo(raw_image((3500, 3500)), "image/png")


def test_asset_content_hash_and_no_symlink_or_fifo_follow(tmp_path):
    directory = tmp_path / "media"
    store = AssetStore(directory)
    data, *_ = normalize_photo(raw_image(), "image/png")
    asset = store.put(data)
    assert asset == store.put(data) and store.read(asset) == data
    file = directory / f"{asset}.jpg"
    assert file.stat().st_mode & 0o777 == 0o600
    file.unlink()
    file.symlink_to(tmp_path / "secret")
    with pytest.raises((ImageError, OSError)):
        store.read(asset)
    file.unlink()
    os.mkfifo(file, mode=0o600)
    with pytest.raises(ImageError, match="media_unavailable"):
        store.read(asset)


def feed_photo(*, credit=True, video=False):
    from test_pipeline import FRESH

    content = b'<m:content url="https://images.example.com/photo.png" type="image/png">'
    if credit:
        content += b'<m:credit role="photographer">Fixture photographer</m:credit>'
    content += b"</m:content>"
    if video:
        content = (
            b'<m:content url="https://images.example.com/video.mp4" type="video/mp4">'
            b"<m:credit>Fixture video credit</m:credit></m:content>" + content
        )
    return FRESH.replace(
        b'<rss version="2.0">', b'<rss version="2.0" xmlns:m="http://search.yahoo.com/mrss/">'
    ).replace(b"</item>", content + b"</item>")


def test_publisher_credit_is_bound_to_the_exact_image_and_does_not_change_content_hash():
    from test_model_runner import NOW

    from newspaw.news import parse_evidence

    credited, _ = parse_evidence(feed_photo(video=True), "https://example.com/rss", NOW)
    no_credit, _ = parse_evidence(
        feed_photo(credit=False, video=True), "https://example.com/rss", NOW
    )
    assert credited[0].image_credit == "Fixture photographer"
    assert no_credit[0].image_credit == ""
    assert credited[0].content_sha256 == no_credit[0].content_sha256


def attach_images(pipeline, directory, handler):
    import httpx

    from newspaw.evidence import FeedCollector
    from newspaw.media.source_images import SourceImages

    pipeline.feed_factory = lambda evidence: FeedCollector(
        evidence,
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, content=feed_photo()))
        ),
    )
    assets = AssetStore(directory)
    pipeline.source_images = SourceImages(
        pipeline.store,
        assets,
        client_factory=lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    return assets


async def test_one_attributed_asset_is_reused_for_two_bot_receipts(system, tmp_path):
    import httpx
    from test_model_runner import NOW
    from test_outbox import sender
    from test_pipeline import create, run_to_terminal

    pipeline, targets, _, _, _ = system
    reads = []

    def image(request):
        reads.append(str(request.url))
        assert request.method == "GET" and "authorization" not in request.headers
        return httpx.Response(200, content=raw_image(), headers={"Content-Type": "image/png"})

    assets = attach_images(pipeline, tmp_path / "media", image)
    outbox, sends = sender(pipeline, targets)
    outbox.asset_resolver = assets.read
    job = create(pipeline, "sub_world", "source-picture", style="source_image")
    status = await run_to_terminal(pipeline, job)
    media = status["media"]
    assert media["style"] == "source_image"
    (photo,) = media["photos"]
    assert (
        "Fixture photographer" in photo["caption"] and "https://example.com/a" in photo["caption"]
    )
    assert media["source_images"][0]["evidence_id"].startswith("e_")
    assert assets.read(photo["asset_id"]).startswith(b"\xff\xd8\xff")
    outbox.enqueue(job, now=NOW)
    for bot in ("bot1", "bot2", "bot1", "bot2"):
        await outbox.advance(job, bot, now=NOW)
    assert len(reads) == 1 and len(sends) == 4
    assert sends[2].url.path.endswith("sendPhoto") and sends[3].url.path.endswith("sendPhoto")
    assert (
        assets.read(photo["asset_id"]) in sends[2].content
        and assets.read(photo["asset_id"]) in sends[3].content
    )


@pytest.mark.parametrize(
    ("system", "style"), [("normal", "text"), ("adult", "source_image")], indirect=["system"]
)
async def test_text_and_adult_route_never_download_source_image(system, style, tmp_path):
    from test_model_runner import NOW
    from test_outbox import sender
    from test_pipeline import run_to_terminal

    pipeline, targets, previous, _, _ = system
    partition = pipeline.get(previous)["partition"]
    attach_images(pipeline, tmp_path / "media", lambda _: pytest.fail("forbidden image request"))
    job = pipeline.create(
        "sub_av" if partition == "adult" else "sub_world",
        "no-source-picture",
        style=style,
        now=NOW,
        holds={f"{partition}_primary": 100, f"{partition}_backup": 100},
    )["job_id"]
    status = await run_to_terminal(pipeline, job)
    assert status["media"]["style"] == "text"
    if partition == "adult":
        assert status["media"]["fallback_reason"] == "adult_source_media_disabled"
    outbox, sends = sender(pipeline, targets)
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    assert b'"is_disabled":true' in sends[0].content


@pytest.mark.parametrize(
    ("status_code", "headers", "reason"),
    [
        (403, {}, "image_unavailable"),
        (302, {"Location": "https://outside.example/photo.png"}, "image_redirect_rejected"),
    ],
)
async def test_image_failure_keeps_text_and_never_follows_an_outside_origin(
    system, tmp_path, status_code, headers, reason
):
    import httpx
    from test_pipeline import create, run_to_terminal

    pipeline, _, _, _, _ = system
    reads = []

    def image(request):
        reads.append(str(request.url))
        return httpx.Response(status_code, headers=headers)

    attach_images(pipeline, tmp_path / "media", image)
    job = create(pipeline, "sub_world", "image-unavailable", style="source_image")
    media = (await run_to_terminal(pipeline, job))["media"]
    assert media["style"] == "text" and media["fallback_reason"] == reason
    assert reads == ["https://images.example.com/photo.png"]
    assert "https://example.com/a" in pipeline.delivery_input(job)[1]


async def test_late_route_change_after_image_fetch_cannot_publish_asset(system, tmp_path):
    import asyncio

    import httpx
    from test_model_runner import NOW
    from test_pipeline import create

    pipeline, _, _, _, _ = system
    started, release = asyncio.Event(), asyncio.Event()

    async def image(_):
        started.set()
        await release.wait()
        return httpx.Response(200, content=raw_image(), headers={"Content-Type": "image/png"})

    directory = tmp_path / "media"
    attach_images(pipeline, directory, image)
    job = create(pipeline, "sub_world", "stale-image", style="source_image")
    await pipeline.advance(job, now=NOW)
    assert (await pipeline.advance(job, now=NOW))["stage"] == "preparing_media"
    task = asyncio.create_task(pipeline.advance(job, now=NOW))
    try:
        await asyncio.wait_for(started.wait(), 2)
        revision, config = pipeline.store.load_config()
        config["news_output_locale"] = "ja" if config["news_output_locale"] != "ja" else "en"
        pipeline.store.save_config(config, expected_revision=revision)
    finally:
        release.set()
        result = await task
    assert result["stage"] == "stale" and result["media"] is None and not directory.exists()


async def test_missing_local_photo_never_repeats_confirmed_text(system, tmp_path):
    import httpx
    from test_model_runner import NOW
    from test_outbox import sender
    from test_pipeline import create, run_to_terminal

    pipeline, targets, _, _, _ = system
    directory = tmp_path / "media"
    assets = attach_images(
        pipeline,
        directory,
        lambda _: httpx.Response(200, content=raw_image(), headers={"Content-Type": "image/png"}),
    )
    outbox, sends = sender(pipeline, targets)
    outbox.asset_resolver = assets.read
    job = create(pipeline, "sub_world", "lost-picture", style="source_image")
    media = (await run_to_terminal(pipeline, job))["media"]
    outbox.enqueue(job, now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    (directory / f"{media['photos'][0]['asset_id']}.jpg").unlink()
    await outbox.advance(job, "bot1", now=NOW)
    await outbox.advance(job, "bot1", now=NOW)
    view = outbox.status(job, bot_id="bot1")["targets"]["bot1"]
    assert len(sends) == 1
    assert view["parts"][0]["state"] == "delivered"
    assert view["parts"][1]["reason"] == "media_unavailable"


def test_jpeg_exif_orientation_is_applied_then_removed():
    from PIL import Image

    original = io.BytesIO()
    exif = Image.Exif()
    exif[274] = 6
    exif[315] = "Fixture private author metadata"
    with Image.new("RGB", (40, 25), "white") as image:
        image.save(original, format="JPEG", exif=exif)
    data, width, height = normalize_photo(original.getvalue(), "image/jpeg")
    assert (width, height) == (25, 40)
    with Image.open(io.BytesIO(data)) as image:
        assert not image.getexif()
    assert b"Fixture private author" not in data
