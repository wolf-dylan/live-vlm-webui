import socket

import pytest

from live_vlm_webui import server


def _occupied_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    return sock, sock.getsockname()[1]


def test_resolve_server_port_returns_requested_available_port():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

    assert server.resolve_server_port(port, host="127.0.0.1") == port


def test_resolve_server_port_rejects_occupied_fixed_port(monkeypatch):
    sock, port = _occupied_port()
    monkeypatch.setattr(server, "find_process_using_port", lambda unused: "test process")
    try:
        with pytest.raises(RuntimeError, match="test process"):
            server.resolve_server_port(port, host="127.0.0.1")
    finally:
        sock.close()


def test_resolve_server_port_honors_auto_port(monkeypatch):
    sock, port = _occupied_port()
    monkeypatch.setattr(server, "find_available_port", lambda start, max_attempts: start + 2)
    try:
        assert server.resolve_server_port(port, auto_port=True, host="127.0.0.1") == port + 3
    finally:
        sock.close()
