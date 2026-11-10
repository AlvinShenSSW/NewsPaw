"""Bounded OPML subscription import, with no file or network resolution."""

from xml.parsers import expat

from ..newsparse import plain_text
from ..source_manager import SourceError, normalize_url


def parse_opml(content):
    try:
        data = content.encode("utf-8") if isinstance(content, str) else content
    except UnicodeError:
        raise SourceError("invalid_opml") from None
    if not isinstance(data, bytes) or len(data) > 1024 * 1024:
        raise SourceError("opml_size_limit")
    parser = expat.ParserCreate()
    stack = []
    feeds = []
    rejected = []
    nodes = outlines = 0

    def reject(*args):
        raise SourceError("unsafe_xml")

    def start(name, attrs):
        nonlocal nodes, outlines
        nodes += 1
        stack.append(name)
        if nodes > 2000 or len(stack) > 16:
            raise SourceError("opml_structure_limit")
        if len(stack) == 1 and name != "opml":
            raise SourceError("invalid_opml")
        if (
            name != "outline"
            or "body" not in stack
            or "xmlUrl" not in attrs
            or attrs.get("type", "rss").lower() != "rss"
        ):
            return
        outlines += 1
        if outlines > 200:
            raise SourceError("opml_feed_limit")
        try:
            url = normalize_url(attrs["xmlUrl"])
        except SourceError:
            rejected.append(dict(index=outlines, reason="unsafe_url"))
            return
        feeds.append(
            dict(
                url=url,
                name=plain_text(attrs.get("text") or attrs.get("title") or "Feed", 150) or "Feed",
            )
        )

    parser.StartElementHandler = start
    parser.EndElementHandler = lambda name: stack.pop()
    parser.StartDoctypeDeclHandler = reject
    parser.EntityDeclHandler = reject
    parser.ExternalEntityRefHandler = reject
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    try:
        parser.Parse(data, True)
    except expat.ExpatError:
        raise SourceError("invalid_opml") from None
    return dict(feeds=feeds, rejected=rejected)
