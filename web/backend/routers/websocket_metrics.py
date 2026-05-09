"""
WebSocket real-time metrics updates: replaces polling with server push.

This module implements:
1. WebSocket endpoint: /ws/metrics
2. Subscription management for specific services
3. Server-side push when metrics change
4. Connection management and cleanup
5. Integration with existing WebSocketManager

Architecture:
- Extends the existing WebSocketManager with subscription tracking
- Integrates with MetricsCollector to push updates
- Client subscribes to specific service@machine combinations
- Server filters and pushes only relevant updates
"""

import asyncio
import json
import logging
from typing import Any, Dict, List, Optional, Set

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from auth.websocket import authenticate_websocket
from services.metrics_collector import MetricsCollector
from services.metrics_service import MetricsService
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


# ============================================================================
# Enhanced WebSocket Manager with Metrics Subscriptions
# ============================================================================


class MetricsWebSocketManager(WebSocketManager):
    """
    Extended WebSocketManager with metrics-specific subscription management.

    Maintains topic-based subscriptions where clients can subscribe to:
    - Specific services: "nginx@web01"
    - All services on a machine: "*@web01"
    - All machines for a service: "nginx@*"
    - All metrics: "*@*"
    """

    def __init__(self, max_connections: int = 100):
        super().__init__(max_connections)
        # metrics_subscribers: Dict[subscription_key, Set[WebSocket]]
        # subscription_key format: "service@machine" or "*@machine" or "service@*" or "*@*"
        self.metrics_subscribers: Dict[str, Set[WebSocket]] = {}

    async def subscribe_metrics(self, websocket: WebSocket, subscriptions: List[str]):
        """
        Subscribe a WebSocket to specific metrics updates.

        Args:
            websocket: WebSocket connection
            subscriptions: List of subscription patterns like ["nginx@web01", "postgres@*"]
        """
        async with self._lock:
            for subscription in subscriptions:
                if subscription not in self.metrics_subscribers:
                    self.metrics_subscribers[subscription] = set()

                self.metrics_subscribers[subscription].add(websocket)
                logger.info(f"WebSocket subscribed to metrics: {subscription}")

    async def unsubscribe_metrics(
        self, websocket: WebSocket, subscriptions: Optional[List[str]] = None
    ):
        """
        Unsubscribe from metrics updates.

        Args:
            websocket: WebSocket connection
            subscriptions: Specific subscriptions to remove, or None to remove all
        """
        async with self._lock:
            if subscriptions is None:
                # Remove from all subscriptions
                for key, subscribers in self.metrics_subscribers.items():
                    subscribers.discard(websocket)
            else:
                # Remove from specific subscriptions
                for subscription in subscriptions:
                    if subscription in self.metrics_subscribers:
                        self.metrics_subscribers[subscription].discard(websocket)

    async def send_metrics_update(self, service: str, machine: str, metrics_data: Dict[str, Any]):
        """
        Send metrics update to subscribed clients.

        Matches against subscription patterns and only sends to relevant clients.

        Args:
            service: Service name
            machine: Machine hostname
            metrics_data: Metrics data dictionary
        """
        # Build message
        message = {
            "type": "metrics_update",
            "service": service,
            "machine": machine,
            "timestamp": utcnow().isoformat(),
            "data": metrics_data,
        }

        # Find matching subscribers
        subscribers = set()

        # Exact match: "service@machine"
        exact_key = f"{service}@{machine}"
        subscribers.update(self.metrics_subscribers.get(exact_key, set()))

        # Wildcard matches
        service_wildcard = f"{service}@*"
        subscribers.update(self.metrics_subscribers.get(service_wildcard, set()))

        machine_wildcard = f"*@{machine}"
        subscribers.update(self.metrics_subscribers.get(machine_wildcard, set()))

        # All metrics
        subscribers.update(self.metrics_subscribers.get("*@*", set()))

        # Send to matching subscribers
        disconnected = []
        for connection in subscribers:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send metrics update: {e}")
                disconnected.append(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            await self.unsubscribe_metrics(connection)

    async def send_machine_metrics_update(self, machine: str, metrics_data: Dict[str, Any]):
        """
        Send machine-level metrics update.

        Args:
            machine: Machine hostname
            metrics_data: Machine metrics data
        """
        message = {
            "type": "machine_metrics_update",
            "machine": machine,
            "timestamp": utcnow().isoformat(),
            "data": metrics_data,
        }

        # Find subscribers for this machine
        subscribers = set()

        # Machine-specific: "*@machine"
        machine_key = f"*@{machine}"
        subscribers.update(self.metrics_subscribers.get(machine_key, set()))

        # All metrics
        subscribers.update(self.metrics_subscribers.get("*@*", set()))

        # Send to subscribers
        disconnected = []
        for connection in subscribers:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send machine metrics: {e}")
                disconnected.append(connection)

        # Clean up disconnected
        for connection in disconnected:
            await self.unsubscribe_metrics(connection)

    def get_metrics_subscriber_count(self, subscription: str) -> int:
        """Get number of subscribers for a metrics subscription."""
        return len(self.metrics_subscribers.get(subscription, set()))

    def get_all_subscriptions(self) -> Dict[str, int]:
        """Get all active subscriptions and their subscriber counts."""
        return {
            key: len(subscribers)
            for key, subscribers in self.metrics_subscribers.items()
            if subscribers  # Only include non-empty subscriptions
        }


# ============================================================================
# WebSocket Route Handler
# ============================================================================


def create_metrics_websocket_router(
    ws_manager: MetricsWebSocketManager, metrics_service: MetricsService
) -> APIRouter:
    """
    Create the metrics WebSocket router with proper dependency injection.

    Args:
        ws_manager: MetricsWebSocketManager instance
        metrics_service: MetricsService instance

    Returns:
        Configured APIRouter
    """
    router = APIRouter(prefix="/api/ws", tags=["websocket"])

    @router.websocket("/metrics")
    async def metrics_websocket_endpoint(websocket: WebSocket):
        """
        WebSocket endpoint for real-time metrics updates.

        Protocol:

        Client -> Server (Subscribe):
        {
            "action": "subscribe",
            "subscriptions": ["nginx@web01", "postgres@db01"]
        }

        Client -> Server (Unsubscribe):
        {
            "action": "unsubscribe",
            "subscriptions": ["nginx@web01"]
        }

        Client -> Server (Get Current):
        {
            "action": "get_current",
            "service": "nginx",
            "machine": "web01"
        }

        Client -> Server (Ping):
        {
            "action": "ping"
        }

        Server -> Client (Metrics Update):
        {
            "type": "metrics_update",
            "service": "nginx",
            "machine": "web01",
            "timestamp": "2025-11-27T10:30:00Z",
            "data": {
                "service": "nginx",
                "machine": "web01",
                "current": { ... },
                "avg_cpu": 15.5,
                ...
            }
        }

        Server -> Client (Connected):
        {
            "type": "connected",
            "message": "Connected to metrics stream",
            "timestamp": "2025-11-27T10:30:00Z"
        }

        Server -> Client (Pong):
        {
            "type": "pong",
            "timestamp": "2025-11-27T10:30:00Z"
        }

        Server -> Client (Error):
        {
            "type": "error",
            "message": "Invalid subscription format",
            "timestamp": "2025-11-27T10:30:00Z"
        }
        """
        if await authenticate_websocket(websocket) is None:
            return
        # Accept connection
        await ws_manager.connect(websocket)

        try:
            # Send connection confirmation
            await websocket.send_json(
                {
                    "type": "connected",
                    "message": "Connected to metrics stream",
                    "timestamp": utcnow().isoformat(),
                    "server": "portoser-metrics-ws",
                }
            )

            # Message handling loop
            while True:
                try:
                    # Receive message from client
                    data = await websocket.receive_json()
                    action = data.get("action")

                    if action == "subscribe":
                        # Handle subscription request
                        subscriptions = data.get("subscriptions", [])

                        if not isinstance(subscriptions, list):
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "message": "subscriptions must be a list",
                                    "timestamp": utcnow().isoformat(),
                                }
                            )
                            continue

                        # Validate subscription format
                        valid_subscriptions = []
                        for sub in subscriptions:
                            if "@" not in sub:
                                await websocket.send_json(
                                    {
                                        "type": "error",
                                        "message": f"Invalid subscription format: {sub}. Use 'service@machine'",
                                        "timestamp": utcnow().isoformat(),
                                    }
                                )
                                continue
                            valid_subscriptions.append(sub)

                        # Subscribe to metrics
                        await ws_manager.subscribe_metrics(websocket, valid_subscriptions)

                        # Send confirmation
                        await websocket.send_json(
                            {
                                "type": "subscribed",
                                "subscriptions": valid_subscriptions,
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                        logger.info(f"Client subscribed to: {valid_subscriptions}")

                    elif action == "unsubscribe":
                        # Handle unsubscribe request
                        subscriptions = data.get("subscriptions")

                        await ws_manager.unsubscribe_metrics(websocket, subscriptions)

                        await websocket.send_json(
                            {
                                "type": "unsubscribed",
                                "subscriptions": subscriptions or "all",
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                        logger.info(f"Client unsubscribed from: {subscriptions or 'all'}")

                    elif action == "get_current":
                        # Handle request for current metrics
                        service = data.get("service")
                        machine = data.get("machine")

                        if not service or not machine:
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "message": "service and machine required for get_current",
                                    "timestamp": utcnow().isoformat(),
                                }
                            )
                            continue

                        try:
                            # Get current metrics
                            metrics = metrics_service.get_service_metrics(service, machine)

                            if metrics:
                                await websocket.send_json(
                                    {
                                        "type": "metrics_current",
                                        "service": service,
                                        "machine": machine,
                                        "timestamp": utcnow().isoformat(),
                                        "data": metrics.model_dump(),
                                    }
                                )
                            else:
                                await websocket.send_json(
                                    {
                                        "type": "error",
                                        "message": f"No metrics found for {service}@{machine}",
                                        "timestamp": utcnow().isoformat(),
                                    }
                                )
                        except Exception as e:
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "message": f"Failed to get metrics: {str(e)}",
                                    "timestamp": utcnow().isoformat(),
                                }
                            )

                    elif action == "ping":
                        # Handle ping (keepalive)
                        await websocket.send_json(
                            {"type": "pong", "timestamp": utcnow().isoformat()}
                        )

                    elif action == "list_subscriptions":
                        # Debug: list all active subscriptions
                        all_subs = ws_manager.get_all_subscriptions()
                        await websocket.send_json(
                            {
                                "type": "subscriptions_list",
                                "subscriptions": all_subs,
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                    else:
                        # Unknown action
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": f"Unknown action: {action}",
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                except asyncio.TimeoutError:
                    continue
                except json.JSONDecodeError:
                    await websocket.send_json(
                        {
                            "type": "error",
                            "message": "Invalid JSON",
                            "timestamp": utcnow().isoformat(),
                        }
                    )

        except WebSocketDisconnect:
            logger.info("Metrics WebSocket client disconnected")
        except Exception as e:
            logger.error(f"Error in metrics WebSocket: {e}")
        finally:
            # Clean up on disconnect
            await ws_manager.unsubscribe_metrics(websocket)
            await ws_manager.disconnect(websocket)

    return router


# ============================================================================
# Enhanced Metrics Collector with WebSocket Integration
# ============================================================================


class MetricsCollectorWithWebSocket(MetricsCollector):
    """
    Enhanced MetricsCollector that uses the MetricsWebSocketManager
    to push updates to subscribed clients.
    """

    def __init__(
        self,
        interval: int = 60,
        metrics_service: Optional[MetricsService] = None,
        ws_manager: Optional[MetricsWebSocketManager] = None,
        registry_path: Optional[str] = None,
    ):
        super().__init__(interval, metrics_service, None, registry_path)
        self.ws_manager = ws_manager  # MetricsWebSocketManager instance

    async def _broadcast_metrics_update(self, service: str, machine: str, metrics):
        """
        Broadcast metrics update using the enhanced WebSocket manager.

        Args:
            service: Service name
            machine: Machine hostname
            metrics: ServiceMetrics object
        """
        if not self.ws_manager:
            return

        try:
            # Convert metrics to dict
            metrics_dict = metrics.model_dump() if hasattr(metrics, "model_dump") else metrics

            # Send to subscribed clients only
            await self.ws_manager.send_metrics_update(service, machine, metrics_dict)

        except Exception as e:
            logger.error(f"Failed to broadcast metrics update: {e}")

    async def _broadcast_machine_metrics(self, machine: str, metrics):
        """
        Broadcast machine metrics using the enhanced WebSocket manager.

        Args:
            machine: Machine hostname
            metrics: MachineMetrics object
        """
        if not self.ws_manager:
            return

        try:
            # Convert metrics to dict
            metrics_dict = metrics.model_dump() if hasattr(metrics, "model_dump") else metrics

            # Send to subscribed clients
            await self.ws_manager.send_machine_metrics_update(machine, metrics_dict)

        except Exception as e:
            logger.error(f"Failed to broadcast machine metrics: {e}")


# Export router
__all__ = [
    "MetricsWebSocketManager",
    "MetricsCollectorWithWebSocket",
    "create_metrics_websocket_router",
]
