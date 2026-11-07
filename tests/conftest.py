"""Offline fixtures. Never use developer credentials or real API transports."""

import os
import socket

import dotenv.main
import pytest


@pytest.fixture(autouse=True)
def offline_network(monkeypatch, tmp_path):
    """Block accidental Python internet I/O; retain Unix sockets for asyncio/IPC.

    This is not a malicious-code or subprocess sandbox. Service and media tests
    must continue to mock their subprocess boundaries explicitly.
    """
    def deny(*args, **kwargs):
        raise RuntimeError("Offline tests require a fake network transport")

    def guarded(original):
        def call(sock, *args, **kwargs):
            if sock.family != socket.AF_UNIX:
                return deny()
            return original(sock, *args, **kwargs)

        return call

    for name in ("connect", "connect_ex", "sendto"):
        monkeypatch.setattr(socket.socket, name, guarded(getattr(socket.socket, name)))
    for name in ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr"):
        monkeypatch.setattr(socket, name, deny)

    prefixes = ("TELEGRAM_", "OPENAI_", "DEEPSEEK_", "GROK_", "XAI_", "MIMO_", "X_")
    for name in list(os.environ):
        if name.startswith(prefixes) or name == "PAIRING_CODE":
            monkeypatch.delenv(name)
    monkeypatch.chdir(tmp_path)
    # Keep explicit dotenv_values(tmp_path / "fixture.env") tests functional.
    monkeypatch.setattr(dotenv.main, "find_dotenv", lambda *args, **kwargs: "")
    monkeypatch.setattr(dotenv, "find_dotenv", lambda *args, **kwargs: "")
