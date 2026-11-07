import pytest

from newspaw.importers.opml import parse_opml
from newspaw.source_manager import SourceError


def test_opml_does_not_fetch_include_and_reports_unsafe_without_echo():
    result = parse_opml(
        '<opml><body><outline type="include" url="https://example.com/x"/><outline text="bad" xmlUrl="https://example.com/?token=secret"/><outline text="Good" xmlUrl="https://example.com/feed"/></body></opml>'
    )
    assert len(result["feeds"]) == 1 and result["rejected"] == [
        {"index": 1, "reason": "unsafe_url"}
    ]
    assert "secret" not in str(result)


@pytest.mark.parametrize(
    "xml",
    [
        '<!DOCTYPE opml [<!ENTITY x SYSTEM "file:///etc/passwd">]><opml><body>&x;</body></opml>',
        "<opml><body>" + "<outline>" * 17 + "</outline>" * 17 + "</body></opml>",
        "<opml><body>" + '<outline xmlUrl="https://example.com/"/>' * 201 + "</body></opml>",
        "<opml>" + "x" * (1024 * 1024) + "</opml>",
        "<html><body/></html>",
    ],
)
def test_opml_limits_before_any_save(xml):
    with pytest.raises(SourceError):
        parse_opml(xml)
