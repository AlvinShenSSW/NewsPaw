"""These tests require the guard fixture, so a RED run never contacts the network."""

import socket

import pytest


@pytest.mark.parametrize("method", ["connect", "connect_ex", "sendto"])
def test_internet_socket_operations_are_blocked(offline_network, method):
    kind = socket.SOCK_DGRAM if method == "sendto" else socket.SOCK_STREAM
    with (
        socket.socket(socket.AF_INET, kind) as sock,
        pytest.raises(RuntimeError, match="Offline tests"),
    ):
        if method == "sendto":
            sock.sendto(b"fixture", ("192.0.2.1", 443))
        else:
            getattr(sock, method)(("192.0.2.1", 443))


def test_dns_is_blocked(offline_network):
    with pytest.raises(RuntimeError, match="Offline tests"):
        socket.getaddrinfo("fixture.invalid", 443)


def test_unix_socketpair_remains_available(offline_network):
    left, right = socket.socketpair()
    try:
        left.sendall(b"local")
        assert right.recv(5) == b"local"
    finally:
        left.close()
        right.close()
