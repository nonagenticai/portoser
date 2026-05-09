"""WebSocket manager for real-time updates"""

import asyncio
import logging
from typing import Any, Dict, List, Optional, Set

from fastapi import WebSocket

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class WebSocketManager:
    """Manages WebSocket connections and broadcasts"""

    def __init__(self, max_connections: int = 100):
        """Initialize the WebSocket manager

        Args:
            max_connections: Maximum number of concurrent WebSocket connections (default: 100)
        """
        self.active_connections: List[WebSocket] = []
        self.deployment_subscribers: Dict[str, Set[WebSocket]] = {}
        self.diagnostic_subscribers: Dict[str, Set[WebSocket]] = {}
        # Initialise eagerly so concurrent subscribe/unsubscribe calls can't
        # race on the `if not hasattr(...)` check that used to guard this.
        self.metrics_subscribers: Dict[str, Set[WebSocket]] = {}
        # Device-event subscribers keyed by hostname; "*" means all devices.
        self.device_subscribers: Dict[str, Set[WebSocket]] = {}
        self._lock = asyncio.Lock()  # Protect shared state from race conditions
        self.max_connections = max_connections

    async def connect(self, websocket: WebSocket):
        """
        Accept and register a new WebSocket connection

        Args:
            websocket: WebSocket connection to register

        Raises:
            RuntimeError: If maximum connection limit is reached
        """
        async with self._lock:
            # Check connection limit before accepting
            if len(self.active_connections) >= self.max_connections:
                logger.warning(f"WebSocket connection limit reached ({self.max_connections})")
                try:
                    await websocket.close(code=1008, reason="Server connection limit reached")
                except Exception as e:
                    logger.error(f"Error closing WebSocket: {e}")
                raise RuntimeError(
                    f"Maximum WebSocket connections ({self.max_connections}) reached"
                )

            try:
                await websocket.accept()
                self.active_connections.append(websocket)
                logger.info(
                    f"WebSocket connected. Total connections: {len(self.active_connections)}"
                )
            except Exception as e:
                logger.error(f"Error accepting WebSocket connection: {e}")
                raise

    async def disconnect(self, websocket: WebSocket):
        """
        Remove a WebSocket connection

        Args:
            websocket: WebSocket connection to remove
        """
        async with self._lock:
            if websocket in self.active_connections:
                self.active_connections.remove(websocket)

            # Clean up subscriptions
            for deployment_id, subscribers in self.deployment_subscribers.items():
                if websocket in subscribers:
                    subscribers.remove(websocket)

            for diagnostic_key, subscribers in self.diagnostic_subscribers.items():
                if websocket in subscribers:
                    subscribers.remove(websocket)

            # Also drop from any metrics / device subscriber sets so a
            # disconnect doesn't leave stale references that error on send.
            for subscribers in self.metrics_subscribers.values():
                subscribers.discard(websocket)
            for subscribers in self.device_subscribers.values():
                subscribers.discard(websocket)

            logger.info(
                f"WebSocket disconnected. Total connections: {len(self.active_connections)}"
            )

    async def broadcast(self, message: Dict[str, Any]):
        """
        Broadcast message to all connected clients

        Args:
            message: Message to broadcast
        """
        disconnected = []

        # Get a copy of connections to iterate safely
        async with self._lock:
            connections = list(self.active_connections)

        for connection in connections:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send message to client: {e}")
                disconnected.append(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            await self.disconnect(connection)

    async def subscribe_deployment(self, websocket: WebSocket, deployment_id: str):
        """
        Subscribe a WebSocket to deployment updates

        Args:
            websocket: WebSocket connection
            deployment_id: Deployment to subscribe to
        """
        async with self._lock:
            if deployment_id not in self.deployment_subscribers:
                self.deployment_subscribers[deployment_id] = set()

            self.deployment_subscribers[deployment_id].add(websocket)
            logger.info(f"WebSocket subscribed to deployment {deployment_id}")

    async def unsubscribe_deployment(self, websocket: WebSocket, deployment_id: str):
        """
        Unsubscribe a WebSocket from deployment updates

        Args:
            websocket: WebSocket connection
            deployment_id: Deployment to unsubscribe from
        """
        async with self._lock:
            if deployment_id in self.deployment_subscribers:
                self.deployment_subscribers[deployment_id].discard(websocket)

    async def send_deployment_update(
        self, deployment_id: str, message_type: str, data: Dict[str, Any]
    ):
        """
        Send update to deployment subscribers

        Args:
            deployment_id: Deployment identifier
            message_type: Type of update (phase_start, phase_complete, error, etc.)
            data: Update data
        """
        message = {
            "type": message_type,
            "deployment_id": deployment_id,
            "timestamp": utcnow().isoformat(),
            **data,
        }

        subscribers = self.deployment_subscribers.get(deployment_id, set())
        disconnected = []

        for connection in subscribers:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send deployment update: {e}")
                disconnected.append(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            subscribers.discard(connection)

    async def stream_deployment_phase(
        self,
        deployment_id: str,
        phase_name: str,
        status: str,
        output: Optional[str] = None,
        error: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ):
        """
        Stream deployment phase updates

        Args:
            deployment_id: Deployment identifier
            phase_name: Name of the phase
            status: Phase status (pending, in_progress, completed, failed)
            output: Phase output
            error: Error message if failed
            metadata: Additional metadata
        """
        data = {
            "phase": phase_name,
            "status": status,
        }

        if output:
            data["output"] = output

        if error:
            data["error"] = error

        if metadata:
            data["metadata"] = metadata

        await self.send_deployment_update(
            deployment_id=deployment_id, message_type="deployment_phase_update", data=data
        )

    async def send_problem_detected(self, deployment_id: str, problem: Dict[str, Any]):
        """
        Send problem detection notification

        Args:
            deployment_id: Deployment identifier
            problem: Problem details
        """
        await self.send_deployment_update(
            deployment_id=deployment_id, message_type="problem_detected", data={"problem": problem}
        )

    async def send_solution_applied(self, deployment_id: str, solution: Dict[str, Any]):
        """
        Send solution application notification

        Args:
            deployment_id: Deployment identifier
            solution: Solution details
        """
        await self.send_deployment_update(
            deployment_id=deployment_id,
            message_type="solution_applied",
            data={"solution": solution},
        )

    async def send_progress_update(
        self, deployment_id: str, current_step: int, total_steps: int, message: str
    ):
        """
        Send progress update

        Args:
            deployment_id: Deployment identifier
            current_step: Current step number
            total_steps: Total number of steps
            message: Progress message
        """
        await self.send_deployment_update(
            deployment_id=deployment_id,
            message_type="progress_update",
            data={
                "current_step": current_step,
                "total_steps": total_steps,
                "progress_percent": (current_step / total_steps * 100) if total_steps > 0 else 0,
                "message": message,
            },
        )

    async def subscribe_diagnostics(self, websocket: WebSocket, service: str, machine: str):
        """
        Subscribe to diagnostic updates

        Args:
            websocket: WebSocket connection
            service: Service name
            machine: Machine name
        """
        key = f"{service}:{machine}"
        async with self._lock:
            if key not in self.diagnostic_subscribers:
                self.diagnostic_subscribers[key] = set()

            self.diagnostic_subscribers[key].add(websocket)
            logger.info(f"WebSocket subscribed to diagnostics {key}")

    async def send_diagnostic_update(
        self, service: str, machine: str, message_type: str, data: Dict[str, Any]
    ):
        """
        Send diagnostic update to subscribers

        Args:
            service: Service name
            machine: Machine name
            message_type: Type of update
            data: Update data
        """
        key = f"{service}:{machine}"
        message = {
            "type": message_type,
            "service": service,
            "machine": machine,
            "timestamp": utcnow().isoformat(),
            **data,
        }

        subscribers = self.diagnostic_subscribers.get(key, set())
        disconnected = []

        for connection in subscribers:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send diagnostic update: {e}")
                disconnected.append(connection)

        # Clean up disconnected clients
        for connection in disconnected:
            subscribers.discard(connection)

    async def send_observation(self, service: str, machine: str, observation: Dict[str, Any]):
        """
        Send observation notification

        Args:
            service: Service name
            machine: Machine name
            observation: Observation details
        """
        await self.send_diagnostic_update(
            service=service,
            machine=machine,
            message_type="observation",
            data={"observation": observation},
        )

    async def send_diagnostic_complete(self, service: str, machine: str, result: Dict[str, Any]):
        """
        Send diagnostic completion notification

        Args:
            service: Service name
            machine: Machine name
            result: Diagnostic result
        """
        await self.send_diagnostic_update(
            service=service,
            machine=machine,
            message_type="diagnostic_complete",
            data={"result": result},
        )

    def get_connection_count(self) -> int:
        """Get number of active connections"""
        return len(self.active_connections)

    def get_deployment_subscriber_count(self, deployment_id: str) -> int:
        """Get number of subscribers for a deployment"""
        return len(self.deployment_subscribers.get(deployment_id, set()))

    def get_diagnostic_subscriber_count(self, service: str, machine: str) -> int:
        """Get number of subscribers for diagnostics"""
        key = f"{service}:{machine}"
        return len(self.diagnostic_subscribers.get(key, set()))

    async def broadcast_metrics(self, metrics: Dict[str, Any]):
        """
        Broadcast metrics update to all connected clients

        Args:
            metrics: Metrics data to broadcast
        """
        message = {"type": "metrics_update", "timestamp": utcnow().isoformat(), **metrics}
        await self.broadcast(message)

    async def broadcast_uptime_event(self, event: Dict[str, Any]):
        """
        Broadcast uptime event to all connected clients

        Args:
            event: Uptime event to broadcast
        """
        message = {"type": "uptime_event", "timestamp": utcnow().isoformat(), **event}
        await self.broadcast(message)

    async def send_to_topic(self, topic: str, message: Dict[str, Any]):
        """
        Send message to subscribers of a specific topic

        Args:
            topic: Topic identifier (e.g., "metrics:service:nginx")
            message: Message to send

        Note: Currently broadcasts to all clients. Topic-based filtering
        can be implemented by maintaining topic-specific subscriber sets.
        """
        # For now, broadcast to all (client-side filtering)
        # Future enhancement: maintain topic-based subscriber sets
        await self.broadcast(message)

    # ========================================================================
    # Metrics-specific subscription management
    # ========================================================================

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

    # ========================================================================
    # Device-event subscription management
    # ========================================================================

    async def subscribe_device(self, websocket: WebSocket, hostname: Optional[str] = None) -> None:
        """Subscribe a connection to device events.

        Args:
            websocket: connection to register
            hostname: hostname to receive events for, or None to receive all.
        """
        key = hostname or "*"
        async with self._lock:
            self.device_subscribers.setdefault(key, set()).add(websocket)
            logger.info(f"WebSocket subscribed to device events: {key}")

    async def unsubscribe_device(
        self, websocket: WebSocket, hostname: Optional[str] = None
    ) -> None:
        """Unsubscribe from device events.

        If hostname is None, removes the connection from every device
        subscription so the caller doesn't have to remember which it joined.
        """
        async with self._lock:
            if hostname is None:
                for subscribers in self.device_subscribers.values():
                    subscribers.discard(websocket)
            else:
                subscribers = self.device_subscribers.get(hostname)
                if subscribers is not None:
                    subscribers.discard(websocket)

    async def broadcast_device_event(self, event: Dict[str, Any]) -> None:
        """Broadcast a device event to matching subscribers.

        Subscribers join either ``"*"`` (all devices) or a specific hostname;
        every event is delivered to ``"*"`` plus the per-hostname set named
        in ``event["hostname"]``.
        """
        hostname = event.get("hostname")
        message = {**event, "timestamp": event.get("timestamp") or utcnow().isoformat()}

        targets: Set[WebSocket] = set()
        async with self._lock:
            targets.update(self.device_subscribers.get("*", set()))
            if hostname:
                targets.update(self.device_subscribers.get(hostname, set()))

        if not targets:
            return

        disconnected = []
        for connection in targets:
            try:
                await connection.send_json(message)
            except Exception as e:
                logger.error(f"Failed to send device event: {e}")
                disconnected.append(connection)

        if disconnected:
            async with self._lock:
                for subscribers in self.device_subscribers.values():
                    for conn in disconnected:
                        subscribers.discard(conn)
