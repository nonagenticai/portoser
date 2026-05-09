"""Tests for the device WebSocket subscription protocol."""

from typing import Any, Dict, List
from unittest.mock import AsyncMock

import pytest

from services.websocket_manager import WebSocketManager


def _fake_socket(record: List[Dict[str, Any]]):
    """A WebSocket double whose send_json appends to `record`."""
    sock = AsyncMock()
    sock.send_json = AsyncMock(side_effect=lambda msg: record.append(msg))
    return sock


@pytest.mark.asyncio
async def test_subscribe_specific_device_only_gets_matching_events() -> None:
    mgr = WebSocketManager()

    rec_kag: List[Dict[str, Any]] = []
    rec_viz: List[Dict[str, Any]] = []
    sock_kag = _fake_socket(rec_kag)
    sock_viz = _fake_socket(rec_viz)

    await mgr.subscribe_device(sock_kag, hostname="myservice")
    await mgr.subscribe_device(sock_viz, hostname="viz")

    await mgr.broadcast_device_event(
        {"type": "device_heartbeat", "hostname": "myservice", "status": "online"}
    )

    assert len(rec_kag) == 1
    assert rec_kag[0]["hostname"] == "myservice"
    assert rec_kag[0]["type"] == "device_heartbeat"
    assert "timestamp" in rec_kag[0]
    assert rec_viz == []  # viz subscriber must NOT see myservice's event


@pytest.mark.asyncio
async def test_subscribe_wildcard_gets_every_device_event() -> None:
    mgr = WebSocketManager()
    rec: List[Dict[str, Any]] = []
    sock = _fake_socket(rec)

    await mgr.subscribe_device(sock)  # no hostname → "*"

    await mgr.broadcast_device_event({"type": "device_registered", "hostname": "myservice"})
    await mgr.broadcast_device_event({"type": "device_heartbeat", "hostname": "viz"})

    assert {ev["hostname"] for ev in rec} == {"myservice", "viz"}


@pytest.mark.asyncio
async def test_event_without_hostname_only_reaches_wildcard_subscribers() -> None:
    """A topology-wide event (no hostname key) should still reach `*` subscribers."""
    mgr = WebSocketManager()
    rec_all: List[Dict[str, Any]] = []
    rec_kag: List[Dict[str, Any]] = []

    await mgr.subscribe_device(_fake_socket(rec_all))  # *
    await mgr.subscribe_device(_fake_socket(rec_kag), hostname="myservice")

    await mgr.broadcast_device_event({"type": "fleet_announcement", "message": "hello"})

    assert len(rec_all) == 1
    assert rec_all[0]["type"] == "fleet_announcement"
    assert rec_kag == []  # myservice-specific subscriber gets nothing without hostname


@pytest.mark.asyncio
async def test_unsubscribe_removes_from_all_or_specific() -> None:
    mgr = WebSocketManager()
    rec: List[Dict[str, Any]] = []
    sock = _fake_socket(rec)

    await mgr.subscribe_device(sock, hostname="myservice")
    await mgr.subscribe_device(sock, hostname="viz")

    # Unsubscribe from one only
    await mgr.unsubscribe_device(sock, hostname="myservice")
    await mgr.broadcast_device_event({"type": "device_heartbeat", "hostname": "myservice"})
    await mgr.broadcast_device_event({"type": "device_heartbeat", "hostname": "viz"})
    assert [ev["hostname"] for ev in rec] == ["viz"]

    # Unsubscribe from everything
    await mgr.unsubscribe_device(sock)
    rec.clear()
    await mgr.broadcast_device_event({"type": "device_heartbeat", "hostname": "viz"})
    assert rec == []


@pytest.mark.asyncio
async def test_failed_send_drops_subscriber() -> None:
    """A connection that errors on send is removed so future broadcasts skip it."""
    mgr = WebSocketManager()

    rec_ok: List[Dict[str, Any]] = []
    sock_ok = _fake_socket(rec_ok)
    sock_bad = AsyncMock()
    sock_bad.send_json = AsyncMock(side_effect=RuntimeError("connection gone"))

    await mgr.subscribe_device(sock_ok)
    await mgr.subscribe_device(sock_bad)

    await mgr.broadcast_device_event({"type": "device_registered", "hostname": "myservice"})

    # ok socket got the event; bad socket was attempted then evicted
    assert len(rec_ok) == 1

    # Second broadcast: bad socket should not be called again
    sock_bad.send_json.reset_mock()
    await mgr.broadcast_device_event({"type": "device_heartbeat", "hostname": "myservice"})
    sock_bad.send_json.assert_not_called()
    assert len(rec_ok) == 2
