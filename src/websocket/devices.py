"""
WebSocket server for real-time device status updates.
Implements device_online, device_offline, metrics_update, and deployment_progress events.
"""

import asyncio
import json
import logging
from typing import Dict, Set, Optional, Any
from datetime import datetime, timezone
from fastapi import WebSocket, WebSocketDisconnect
from dataclasses import dataclass, asdict

logger = logging.getLogger(__name__)


@dataclass
class DeviceEvent:
    """Base class for device events."""
    event: str
    device_id: str
    timestamp: str

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class DeviceOnlineEvent(DeviceEvent):
    """Device came online."""
    device_name: str
    ip_address: str

    def __init__(self, device_id: str, device_name: str, ip_address: str):
        super().__init__(
            event="device_online",
            device_id=device_id,
            timestamp=datetime.now(timezone.utc).isoformat() + "Z"
        )
        self.device_name = device_name
        self.ip_address = ip_address


@dataclass
class DeviceOfflineEvent(DeviceEvent):
    """Device went offline."""
    device_name: str
    last_seen: str

    def __init__(self, device_id: str, device_name: str, last_seen: str):
        super().__init__(
            event="device_offline",
            device_id=device_id,
            timestamp=datetime.now(timezone.utc).isoformat() + "Z"
        )
        self.device_name = device_name
        self.last_seen = last_seen


@dataclass
class MetricsUpdateEvent(DeviceEvent):
    """Device metrics update."""
    metrics: Dict[str, float]

    def __init__(self, device_id: str, metrics: Dict[str, float]):
        super().__init__(
            event="metrics_update",
            device_id=device_id,
            timestamp=datetime.now(timezone.utc).isoformat() + "Z"
        )
        self.metrics = metrics


@dataclass
class DeploymentProgressEvent(DeviceEvent):
    """Deployment progress update."""
    service_name: str
    deployment_id: str
    status: str
    progress: int
    message: Optional[str] = None

    def __init__(self, device_id: str, service_name: str, deployment_id: str,
                 status: str, progress: int, message: Optional[str] = None):
        super().__init__(
            event="deployment_progress",
            device_id=device_id,
            timestamp=datetime.now(timezone.utc).isoformat() + "Z"
        )
        self.service_name = service_name
        self.deployment_id = deployment_id
        self.status = status
        self.progress = progress
        self.message = message


class ConnectionManager:
    """Manages WebSocket connections and broadcasts events."""

    def __init__(self):
        self.active_connections: Set[WebSocket] = set()
        self.device_subscriptions: Dict[str, Set[WebSocket]] = {}
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        """Accept new WebSocket connection."""
        await websocket.accept()
        async with self._lock:
            self.active_connections.add(websocket)
        logger.info(f"WebSocket connected. Total connections: {len(self.active_connections)}")

    async def disconnect(self, websocket: WebSocket) -> None:
        """Remove WebSocket connection."""
        async with self._lock:
            self.active_connections.discard(websocket)
            # Remove from device subscriptions
            for device_id in list(self.device_subscriptions.keys()):
                self.device_subscriptions[device_id].discard(websocket)
                if not self.device_subscriptions[device_id]:
                    del self.device_subscriptions[device_id]
        logger.info(f"WebSocket disconnected. Total connections: {len(self.active_connections)}")

    async def subscribe_device(self, websocket: WebSocket, device_id: str) -> None:
        """Subscribe to specific device updates."""
        async with self._lock:
            if device_id not in self.device_subscriptions:
                self.device_subscriptions[device_id] = set()
            self.device_subscriptions[device_id].add(websocket)
        logger.debug(f"Client subscribed to device {device_id}")

    async def unsubscribe_device(self, websocket: WebSocket, device_id: str) -> None:
        """Unsubscribe from device updates."""
        async with self._lock:
            if device_id in self.device_subscriptions:
                self.device_subscriptions[device_id].discard(websocket)
                if not self.device_subscriptions[device_id]:
                    del self.device_subscriptions[device_id]
        logger.debug(f"Client unsubscribed from device {device_id}")

    async def broadcast(self, event: DeviceEvent) -> None:
        """Broadcast event to all connected clients."""
        message = json.dumps(event.to_dict())
        disconnected = set()

        for connection in self.active_connections:
            try:
                await connection.send_text(message)
            except Exception as e:
                logger.error(f"Error sending to client: {e}")
                disconnected.add(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            await self.disconnect(connection)

    async def send_to_device_subscribers(self, device_id: str, event: DeviceEvent) -> None:
        """Send event to clients subscribed to specific device."""
        if device_id not in self.device_subscriptions:
            return

        message = json.dumps(event.to_dict())
        disconnected = set()

        for connection in self.device_subscriptions[device_id]:
            try:
                await connection.send_text(message)
            except Exception as e:
                logger.error(f"Error sending to device subscriber: {e}")
                disconnected.add(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            await self.disconnect(connection)

    async def emit_device_online(self, device_id: str, device_name: str, ip_address: str) -> None:
        """Emit device online event."""
        event = DeviceOnlineEvent(device_id, device_name, ip_address)
        await self.broadcast(event)
        logger.info(f"Device online: {device_name} ({device_id})")

    async def emit_device_offline(self, device_id: str, device_name: str, last_seen: str) -> None:
        """Emit device offline event."""
        event = DeviceOfflineEvent(device_id, device_name, last_seen)
        await self.broadcast(event)
        logger.info(f"Device offline: {device_name} ({device_id})")

    async def emit_metrics_update(self, device_id: str, metrics: Dict[str, float]) -> None:
        """Emit metrics update event."""
        event = MetricsUpdateEvent(device_id, metrics)
        # Send to all clients and device-specific subscribers
        await self.broadcast(event)

    async def emit_deployment_progress(
        self,
        device_id: str,
        service_name: str,
        deployment_id: str,
        status: str,
        progress: int,
        message: Optional[str] = None
    ) -> None:
        """Emit deployment progress event."""
        event = DeploymentProgressEvent(
            device_id, service_name, deployment_id, status, progress, message
        )
        await self.broadcast(event)
        logger.info(f"Deployment progress: {service_name} on {device_id} - {progress}%")


# Global connection manager instance
manager = ConnectionManager()


async def websocket_endpoint(websocket: WebSocket) -> None:
    """
    Main WebSocket endpoint handler.
    Handles client connections, subscriptions, and keep-alive pings.
    """
    await manager.connect(websocket)

    try:
        # Send initial connection confirmation
        await websocket.send_json({
            "event": "connected",
            "timestamp": datetime.now(timezone.utc).isoformat() + "Z",
            "message": "WebSocket connection established"
        })

        # Handle incoming messages
        while True:
            try:
                data = await asyncio.wait_for(websocket.receive_text(), timeout=30.0)
                message = json.loads(data)

                # Handle subscription requests
                if message.get("action") == "subscribe":
                    device_id = message.get("device_id")
                    if device_id:
                        await manager.subscribe_device(websocket, device_id)
                        await websocket.send_json({
                            "event": "subscribed",
                            "device_id": device_id,
                            "timestamp": datetime.now(timezone.utc).isoformat() + "Z"
                        })

                elif message.get("action") == "unsubscribe":
                    device_id = message.get("device_id")
                    if device_id:
                        await manager.unsubscribe_device(websocket, device_id)
                        await websocket.send_json({
                            "event": "unsubscribed",
                            "device_id": device_id,
                            "timestamp": datetime.now(timezone.utc).isoformat() + "Z"
                        })

                elif message.get("action") == "ping":
                    # Respond to ping with pong
                    await websocket.send_json({
                        "event": "pong",
                        "timestamp": datetime.now(timezone.utc).isoformat() + "Z"
                    })

            except asyncio.TimeoutError:
                # Send keep-alive ping
                try:
                    await websocket.send_json({
                        "event": "ping",
                        "timestamp": datetime.now(timezone.utc).isoformat() + "Z"
                    })
                except:
                    break

    except WebSocketDisconnect:
        logger.info("Client disconnected normally")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        await manager.disconnect(websocket)


# Helper functions for external use
async def notify_device_online(device_id: str, device_name: str, ip_address: str) -> None:
    """Notify all clients that a device came online."""
    await manager.emit_device_online(device_id, device_name, ip_address)


async def notify_device_offline(device_id: str, device_name: str, last_seen: str) -> None:
    """Notify all clients that a device went offline."""
    await manager.emit_device_offline(device_id, device_name, last_seen)


async def notify_metrics_update(device_id: str, metrics: Dict[str, float]) -> None:
    """Notify all clients of device metrics update."""
    await manager.emit_metrics_update(device_id, metrics)


async def notify_deployment_progress(
    device_id: str,
    service_name: str,
    deployment_id: str,
    status: str,
    progress: int,
    message: Optional[str] = None
) -> None:
    """Notify all clients of deployment progress."""
    await manager.emit_deployment_progress(
        device_id, service_name, deployment_id, status, progress, message
    )
