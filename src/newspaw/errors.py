"""Stable error codes for the private control socket and job records."""

from __future__ import annotations

import re

CODE = re.compile(r"[a-z][a-z0-9_]{0,63}")
# Repeating the same request later can succeed without any change by the owner.
RETRYABLE = frozenset({"rate_limited", "transport_error", "timeout"})


def code_of(exc, fallback):
    """The exception's message when it is a stable code, else ``fallback``."""
    text = str(exc)
    return text if CODE.fullmatch(text) else fallback


def detail(code, domain, field=None):
    value = {"code": code, "domain": domain, "retryable": code in RETRYABLE}
    if field is not None:
        value["field"] = field
    return value
