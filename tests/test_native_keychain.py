"""Explicit local smoke only; synthetic isolated item, never user credentials."""

import os
import sys
from uuid import uuid4

import pytest

from newspaw.credentials import MacKeychain


@pytest.mark.skipif(
    sys.platform != "darwin" or os.getenv("NEWSPAW_NATIVE_KEYCHAIN_TEST") != "1",
    reason="native Keychain smoke requires explicit local opt-in",
)
def test_native_keychain_synthetic_roundtrip():
    backend = MacKeychain(service=f"io.newspaw.tests.{uuid4()}")
    ref = f"keychain:{uuid4()}"
    value = f"synthetic-{uuid4()}"
    try:
        backend.write(ref, value)
        assert backend.read(ref) == value
    finally:
        backend.delete(ref)
    assert backend.read(ref) is None
