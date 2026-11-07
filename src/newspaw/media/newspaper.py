"""Freeze and verify the text of a generated newspaper before delivery."""

from __future__ import annotations

import asyncio
import json
import unicodedata
from datetime import UTC, datetime
from pathlib import Path

from ..credentials import CredentialError
from ..news import public_url

_LOCALES = {
    "zh-Hans": ("NewsPaw 简报", "AI 生成示意", "第{page}/{total}页", "zh-Hans"),
    "en": ("NewsPaw Brief", "AI-generated illustration", "Page {page}/{total}", "en-US"),
    "ja": ("NewsPaw ニュース", "AI によるイメージ", "{page}/{total} ページ", "ja-JP"),
}
_MAX_IMAGE = 2 * 1024 * 1024


class PaperError(CredentialError):
    pass


def _line(text, limit):
    if not isinstance(text, str) or not 1 <= len(text) <= limit or "://" in text:
        raise PaperError("newspaper_plan_unavailable")
    normalized = " ".join(text.split())
    if not normalized or any(unicodedata.category(c).startswith("C") for c in normalized):
        raise PaperError("newspaper_plan_unavailable")
    return normalized


def make_plan(edition, *, page_count, item_number=None):
    locale = edition["locale"]
    if (
        locale not in _LOCALES
        or type(page_count) is not int
        or page_count not in {1, 2}
        or (item_number is not None and (type(item_number) is not int or item_number < 1))
    ):
        raise PaperError("newspaper_plan_unavailable")
    items = edition["items"]
    if item_number is not None:
        items = items[item_number - 1 : item_number]
    else:
        items = items[: 2 * page_count]
    if len(items) < page_count:
        raise PaperError("newspaper_plan_unavailable")
    masthead, disclosure, page_label, _ = _LOCALES[locale]
    citations, pages = {}, []
    for i in range(page_count):
        start = i * len(items) // page_count
        stop = (i + 1) * len(items) // page_count
        page = i + 1
        lines = [masthead, page_label.format(page=page, total=page_count), disclosure]
        sources = []
        for story in items[start:stop]:
            title, body = _line(story["title"], 120), _line(story["body"], 240)
            refs = []
            for source in story["sources"][:4]:
                url = public_url(source.get("url", ""))
                if not url:
                    raise PaperError("newspaper_plan_unavailable")
                if url not in citations:
                    citations[url] = dict(
                        id=f"S{len(citations) + 1}",
                        source=_line(source["source"], 100),
                        url=url,
                        published_at=source["published_at"],
                    )
                refs.append(citations[url]["id"])
            if not refs:
                raise PaperError("newspaper_plan_unavailable")
            sources.extend(refs)
            lines.extend((title, body, " ".join(refs)))
        pages.append(
            dict(page=page, total=page_count, lines=lines, sources=list(dict.fromkeys(sources)))
        )
    return dict(locale=locale, pages=pages, citations=list(citations.values()))


def _ocr_text(lines):
    characters = []
    for char in " ".join(lines):
        decomposition = unicodedata.decomposition(char).split()
        if decomposition and decomposition[0] in {"<wide>", "<narrow>"}:
            characters.extend(chr(int(code, 16)) for code in decomposition[1:])
        else:
            characters.append(char)
    normalized = unicodedata.normalize("NFC", "".join(characters))
    return " ".join(normalized.split())


def validate_ocr(page, observed):
    if (
        not isinstance(observed, list)
        or len(observed) > 100
        or any(not isinstance(line, str) or len(line) > 1000 for line in observed)
        or _ocr_text(page["lines"]) != _ocr_text(observed)
    ):
        raise PaperError("ocr_mismatch")
    return True


async def bounded_preparation(operation, deadline, *, clock=lambda: datetime.now(UTC)):
    remaining = (deadline - clock()).total_seconds()
    if remaining <= 0:
        raise PaperError("newspaper_deadline")
    try:
        async with asyncio.timeout(remaining):
            result = await operation()
    except TimeoutError:
        raise PaperError("newspaper_deadline") from None
    if clock() >= deadline:
        raise PaperError("newspaper_deadline")
    return result


class MacOCR:
    def __init__(self, helper: Path):
        self.helper = helper

    async def _run(self, arg, data=b""):
        if not self.helper.is_absolute():
            raise PaperError("ocr_unavailable")
        try:
            proc = await asyncio.create_subprocess_exec(
                str(self.helper),
                arg,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except OSError:
            raise PaperError("ocr_unavailable") from None
        try:
            stdout, _ = await proc.communicate(data)
        except asyncio.CancelledError:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
            raise
        if proc.returncode != 0 or len(stdout) > 64 * 1024:
            raise PaperError("ocr_unavailable")
        try:
            value = json.loads(stdout)
        except (ValueError, RecursionError):
            raise PaperError("ocr_unavailable") from None
        if not isinstance(value, list) or any(not isinstance(line, str) for line in value):
            raise PaperError("ocr_unavailable")
        return value

    async def supports(self, locale):
        return locale in _LOCALES and _LOCALES[locale][3] in await self._run("--languages")

    async def read(self, locale, data):
        if (
            locale not in _LOCALES
            or not isinstance(data, bytes)
            or not 1 <= len(data) <= _MAX_IMAGE
        ):
            raise PaperError("ocr_unavailable")
        return await self._run(_LOCALES[locale][3], data)
