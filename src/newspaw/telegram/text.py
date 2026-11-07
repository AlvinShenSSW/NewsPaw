"""Chunk plain news text at safe Telegram message boundaries."""


def split_text(text: str, limit: int = 3500) -> list[str]:
    """Keep Telegram's UTF-16 length limit, including emoji and astral glyphs."""
    chunks, chunk, size = [], [], 0
    for char in text:
        width = len(char.encode("utf-16-le")) // 2
        if size + width > limit:
            chunks.append("".join(chunk))
            chunk, size = [], 0
        chunk.append(char)
        size += width
    if chunk:
        chunks.append("".join(chunk))
    return chunks


def split_delivery_text(text, limit=3500):
    """Prefer complete lines and keep citation URLs intact."""
    parts, chunk, used = [], [], 0
    for line in text.splitlines(keepends=True):
        width = len(line.encode("utf-16-le")) // 2
        if width > limit and ("https://" in line or "http://" in line):
            raise ValueError("citation_line_too_long")
        for piece in split_text(line, limit):
            size = len(piece.encode("utf-16-le")) // 2
            if used + size > limit:
                parts.append("".join(chunk))
                chunk, used = [], 0
            chunk.append(piece)
            used += size
    return [part.strip() for part in [*parts, "".join(chunk)] if part.strip()]
