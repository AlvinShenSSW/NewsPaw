"""Bounded, attributed publisher photos for an ordinary prepared edition."""

from __future__ import annotations

import asyncio
import hashlib
import io
import os
import re
import stat
from contextlib import contextmanager, suppress
from urllib.parse import urljoin
from uuid import uuid4

import httpx
from PIL import Image, ImageOps

from ..app_config import _url
from ..evidence import EvidenceError, EvidenceStore
from ..news import canonical_url, plain_text
from ..transport import SafeHTTPError, checked_url, source_client

_INPUT_MAX = 5 * 1024 * 1024
_FILE_MAX = 2 * 1024 * 1024
_PIXELS_MAX = 8_000_000
_ASSET = re.compile(r"(?:source|paper)_([a-f0-9]{64})")
_FORMATS = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
_CAPTIONS = {
    "en": ("Source", "Photo credit", "Unavailable"),
    "zh-Hans": ("来源", "图片署名", "未注明"),
    "ja": ("出典", "写真クレジット", "記載なし"),
}


class ImageError(ValueError):
    pass


def normalize_photo(data, mime):
    if mime not in _FORMATS or not isinstance(data, bytes) or not 1 <= len(data) <= _INPUT_MAX:
        raise ImageError("invalid_image")
    try:
        format_ = _FORMATS[mime]
        with Image.open(io.BytesIO(data), formats=[format_]) as image:
            width, height = image.size
            if (
                image.format != format_
                or getattr(image, "n_frames", 1) != 1
                or min(width, height) < 1
                or width * height > _PIXELS_MAX
                or max(width, height) > 20 * min(width, height)
            ):
                raise ImageError("invalid_image")
            image.verify()
        with Image.open(io.BytesIO(data), formats=[format_]) as image:
            oriented = ImageOps.exif_transpose(image)
            oriented.thumbnail((1920, 1920), Image.Resampling.LANCZOS)
            rgba = oriented.convert("RGBA")
            with Image.new("RGB", rgba.size, "white") as safe:
                safe.paste(rgba, mask=rgba.getchannel("A"))
                result = io.BytesIO()
                safe.save(result, format="JPEG", quality=85, optimize=True)
                width, height = safe.size
    except (
        Image.DecompressionBombError,
        OSError,
        ValueError,
        SyntaxError,
        TypeError,
        OverflowError,
    ):
        raise ImageError("invalid_image") from None
    clean = result.getvalue()
    if not 1 <= len(clean) <= _FILE_MAX or max(width, height) > 20 * min(width, height):
        raise ImageError("invalid_image")
    return clean, width, height


class AssetStore:
    def __init__(self, directory):
        self.directory = directory

    @contextmanager
    def _directory(self, *, create=False):
        if create:
            self.directory.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ImageError("media_unavailable")
            yield fd
        finally:
            os.close(fd)

    @staticmethod
    def _read(directory, identity, digest):
        fd = os.open(
            identity + ".jpg", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory
        )
        with os.fdopen(fd, "rb") as file:
            info = os.fstat(file.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_mode & 0o077
                or not 1 <= info.st_size <= _FILE_MAX
            ):
                raise ImageError("media_unavailable")
            data = file.read(_FILE_MAX + 1)
        if (
            len(data) != info.st_size
            or hashlib.sha256(data).hexdigest() != digest
            or not data.startswith(b"\xff\xd8\xff")
        ):
            raise ImageError("media_unavailable")
        return data

    def read(self, identity):
        match = _ASSET.fullmatch(identity) if isinstance(identity, str) else None
        if match is None:
            raise ImageError("media_unavailable")
        with self._directory() as directory:
            return self._read(directory, identity, match[1])

    def put(self, data, *, kind="source"):
        if (
            kind not in {"source", "paper"}
            or not isinstance(data, bytes)
            or not 1 <= len(data) <= _FILE_MAX
            or not data.startswith(b"\xff\xd8\xff")
        ):
            raise ImageError("media_unavailable")
        digest = hashlib.sha256(data).hexdigest()
        identity = kind + "_" + digest
        with self._directory(create=True) as directory:
            try:
                self._read(directory, identity, digest)
                return identity
            except FileNotFoundError:
                pass
            name = "temp_" + uuid4().hex
            fd = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory
            )
            try:
                with os.fdopen(fd, "wb") as file:
                    file.write(data)
                    file.flush()
                    os.fsync(file.fileno())
                os.replace(name, identity + ".jpg", src_dir_fd=directory, dst_dir_fd=directory)
                os.fsync(directory)
            finally:
                with suppress(FileNotFoundError):
                    os.unlink(name, dir_fd=directory)
        return identity


def _safe_image_url(value):
    try:
        _url(value)
        url = checked_url(value)
        if url.port not in {None, 443}:
            raise ValueError()
    except (ValueError, SafeHTTPError):
        raise ImageError("unsafe_image_url") from None
    return url


def _matches(article, anchor):
    return (
        canonical_url(article.url) == anchor["url"]
        and article.content_sha256 == anchor["content_hash"]
        and article.source == anchor["source"]
        and article.published_at is not None
        and article.published_at.isoformat() == anchor["published_at"]
        and article.fetched_at is not None
        and article.fetched_at.isoformat() == anchor["fetched_at"]
    )


def _caption(article, locale):
    source, credit, missing = _CAPTIONS[locale]
    name = plain_text(article.source, 150)
    label = plain_text(article.image_credit, 150) or missing
    result = f"{source} · {name}\n{canonical_url(article.url)}\n{credit} · {label}"
    return result if len(result.encode("utf-16-le")) <= 2048 else None


class SourceImages:
    def __init__(self, store, assets, *, client_factory=None):
        self.evidence = EvidenceStore(store)
        self.assets = assets
        self.client_factory = client_factory or (
            lambda: source_client(max_bytes=_INPUT_MAX, deadline=15)
        )

    def candidates(self, route, attempts, anchors):
        if route.effective["partition"] != "normal" or route.effective["style"] != "source_image":
            return []
        entries = []
        for identity in attempts:
            try:
                entries.extend(
                    self.evidence.articles(
                        identity,
                        partition="normal",
                        subscription_id=route.subscription_id,
                        fresh_only=False,
                    )
                )
            except EvidenceError:
                continue
        result = []
        seen = set()
        for anchor in anchors:
            matched = [item for item in entries if _matches(item, anchor)]
            photos = {(item.image_url, item.image_credit) for item in matched}
            if len(photos) != 1:
                continue
            article = matched[0]
            if article.image_url and article.image_url not in seen:
                seen.add(article.image_url)
                result.append((anchor, article))
            if len(result) == 2:
                break
        return result

    async def _fetch(self, client, value, authorize):
        url = _safe_image_url(value)
        host = url.host
        for hop in range(3):
            if authorize() is False:
                return None
            request = client.build_request("GET", url, headers={"Accept": ", ".join(_FORMATS)})
            request.headers.pop("cookie", None)
            response = await client.send(request, auth=None, follow_redirects=False)
            if response.is_redirect:
                location = response.headers.get("location")
                if not location or hop == 2:
                    raise ImageError("image_redirect_rejected")
                try:
                    target = _safe_image_url(urljoin(str(url), location))
                except (ValueError, ImageError):
                    raise ImageError("image_redirect_rejected") from None
                if target.host != host or target == url:
                    raise ImageError("image_redirect_rejected")
                url = target
                continue
            if response.status_code != 200:
                raise ImageError("image_unavailable")
            mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
            return response.content, mime
        raise ImageError("image_redirect_rejected")

    async def prepare(self, route, attempts, anchors, authorize):
        candidates = self.candidates(route, attempts, anchors)
        photos, provenance, gaps = [], [], []
        if candidates:
            async with self.client_factory() as client:
                try:
                    async with asyncio.timeout(40):
                        for anchor, article in candidates:
                            caption = _caption(article, route.effective["locale"])
                            if caption is None:
                                gaps.append("image_caption_too_long")
                                continue
                            try:
                                fetched = await self._fetch(client, article.image_url, authorize)
                                if fetched is None:
                                    return None
                                data, width, height = await asyncio.to_thread(
                                    normalize_photo, *fetched
                                )
                                if authorize() is False:
                                    return None
                                asset = await asyncio.to_thread(self.assets.put, data)
                                if authorize() is False:
                                    return None
                            except ImageError as exc:
                                gaps.append(str(exc))
                                continue
                            except (httpx.RequestError, OSError):
                                gaps.append("image_unavailable")
                                continue
                            photos.append(
                                dict(
                                    asset_id=asset,
                                    sha256=asset.removeprefix("source_"),
                                    mime="image/jpeg",
                                    width=width,
                                    height=height,
                                    caption=caption,
                                )
                            )
                            provenance.append(
                                dict(
                                    asset_id=asset,
                                    evidence_id=anchor["id"],
                                    article_url=anchor["url"],
                                    publisher=article.source,
                                    credit=article.image_credit or None,
                                )
                            )
                except TimeoutError:
                    gaps.append("image_timeout")
        return dict(
            style="source_image" if photos else "text",
            photos=photos,
            source_images=provenance,
            image_gaps=list(dict.fromkeys(gaps)),
            fallback_reason=None if photos else gaps[0] if gaps else "no_source_image",
        )
