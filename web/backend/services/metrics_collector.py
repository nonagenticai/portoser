"""Fully async background metrics collector for continuous monitoring"""

import asyncio
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml

from services.metrics_service import MetricsService
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow
from utils.validation import FilePathValidator

logger = logging.getLogger(__name__)


class AsyncMetricsCollector:
    """Fully async background task for collecting metrics with concurrency control"""

    def __init__(
        self,
        interval: int = 60,
        metrics_service: Optional[MetricsService] = None,
        ws_manager: Optional[WebSocketManager] = None,
        registry_path: Optional[str] = None,
        max_concurrent: int = 10,
        task_timeout: int = 30,
    ):
        """
        Initialize async metrics collector

        Args:
            interval: Collection interval in seconds (default: 60)
            metrics_service: MetricsService instance
            ws_manager: WebSocketManager for broadcasting updates
            registry_path: Path to registry.yml file
            max_concurrent: Maximum concurrent metric collection tasks (default: 10)
            task_timeout: Timeout for individual metric collection tasks (default: 30s)
        """
        self.interval = interval
        self.running = False
        self.task: Optional[asyncio.Task] = None
        self.metrics_service = metrics_service or MetricsService()
        self.ws_manager = ws_manager
        # Default registry path computed from this file (parents[2] is repo root).
        default_registry = str(Path(__file__).resolve().parents[2] / "registry.yml")
        self.registry_path = registry_path or os.getenv("CADDY_REGISTRY_PATH", default_registry)

        # Concurrency control
        self.semaphore = asyncio.Semaphore(max_concurrent)
        self.task_timeout = task_timeout
        self.max_concurrent = max_concurrent

        # Statistics
        self.stats = {
            "total_collections": 0,
            "successful_collections": 0,
            "failed_collections": 0,
            "last_collection_duration": 0.0,
            "last_collection_time": None,
        }

        logger.info(
            f"AsyncMetricsCollector initialized: interval={interval}s, "
            f"max_concurrent={max_concurrent}, timeout={task_timeout}s"
        )

    async def start(self):
        """Start the background metrics collection"""
        if self.running:
            logger.warning("AsyncMetricsCollector is already running")
            return

        self.running = True
        self.task = asyncio.create_task(self._collection_loop())
        logger.info("AsyncMetricsCollector started")

    async def stop(self):
        """Stop the background metrics collection"""
        if not self.running:
            return

        self.running = False
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
        logger.info("AsyncMetricsCollector stopped")

    async def _load_registry_async(self) -> dict:
        """Load the registry configuration asynchronously"""
        try:
            # Use asyncio to run file I/O in executor to avoid blocking
            loop = asyncio.get_event_loop()
            registry_data = await loop.run_in_executor(None, self._load_registry_sync)
            return registry_data
        except Exception as e:
            logger.error(f"Failed to load registry asynchronously: {e}")
            return {"services": {}, "hosts": {}}

    def _load_registry_sync(self) -> dict:
        """Synchronous registry loading (called in executor)"""
        try:
            # Check if registry file exists and is readable
            FilePathValidator.check_file_exists(self.registry_path, "registry.yml")

            with open(self.registry_path, "r") as f:
                return yaml.safe_load(f)
        except Exception as e:
            logger.error(f"Failed to load registry: {e}")
            return {"services": {}, "hosts": {}}

    async def _collection_loop(self):
        """Main async collection loop - non-blocking"""
        logger.info("Starting async metrics collection loop")

        while self.running:
            try:
                # Collect metrics without blocking
                await self.collect_all_async()

                # Sleep without blocking other tasks
                await asyncio.sleep(self.interval)

            except asyncio.CancelledError:
                logger.info("Collection loop cancelled")
                break
            except Exception as e:
                logger.error(f"Error in collection loop: {e}", exc_info=True)
                # Still sleep on error to avoid tight error loops
                await asyncio.sleep(self.interval)

    async def collect_all_async(self):
        """
        Collect metrics for all services and machines in parallel

        Uses asyncio.gather() for parallel collection with semaphore-based
        rate limiting to prevent overwhelming the system.
        """
        start_time = datetime.now()

        try:
            # Load registry asynchronously
            registry = await self._load_registry_async()
            services = registry.get("services", {})
            hosts = registry.get("hosts", {})

            if not services and not hosts:
                logger.debug("No services or hosts found in registry")
                return

            logger.debug(
                f"Collecting metrics for {len(services)} services "
                f"and {len(hosts)} hosts in parallel"
            )

            # Create tasks for parallel collection
            service_tasks = []
            machine_tasks = []

            # Create service metric collection tasks
            for service_name, service_config in services.items():
                machine = service_config.get("current_host")
                if machine:
                    task = self._collect_service_metrics_safe(service_name, machine)
                    service_tasks.append(task)

            # Create machine metric collection tasks
            for machine_name in hosts.keys():
                task = self._collect_machine_metrics_safe(machine_name)
                machine_tasks.append(task)

            # Execute all tasks in parallel with gather
            # return_exceptions=True ensures one failure doesn't break all
            all_tasks = service_tasks + machine_tasks

            if all_tasks:
                results = await asyncio.gather(*all_tasks, return_exceptions=True)

                # Count successes and failures
                successes = sum(1 for r in results if r is True)
                failures = sum(1 for r in results if isinstance(r, Exception) or r is False)

                self.stats["total_collections"] += 1
                self.stats["successful_collections"] += successes
                self.stats["failed_collections"] += failures

                logger.debug(
                    f"Parallel collection completed: {successes} successful, "
                    f"{failures} failed out of {len(results)} total"
                )
            else:
                logger.debug("No metrics to collect")

            # Update timing stats
            duration = (datetime.now() - start_time).total_seconds()
            self.stats["last_collection_duration"] = duration
            self.stats["last_collection_time"] = utcnow()

            logger.debug(f"Metrics collection completed in {duration:.2f}s")

        except Exception as e:
            logger.error(f"Failed to collect all metrics: {e}", exc_info=True)

    async def _collect_service_metrics_safe(self, service: str, machine: str) -> bool:
        """
        Safely collect metrics for a service with timeout and concurrency control

        Args:
            service: Service name
            machine: Machine hostname

        Returns:
            True if successful, False otherwise
        """
        async with self.semaphore:  # Limit concurrent executions
            try:
                # Apply timeout to prevent hanging
                await asyncio.wait_for(
                    self._collect_service_metrics_async(service, machine), timeout=self.task_timeout
                )
                return True

            except asyncio.TimeoutError:
                logger.error(
                    f"Timeout collecting metrics for {service}@{machine} (>{self.task_timeout}s)"
                )
                return False

            except Exception as e:
                logger.error(f"Failed to collect service metrics for {service}@{machine}: {e}")
                return False

    async def _collect_service_metrics_async(self, service: str, machine: str):
        """
        Async implementation of service metrics collection

        Args:
            service: Service name
            machine: Machine hostname
        """
        # Get metrics using async metrics service
        metrics = await self.metrics_service.get_service_metrics(service, machine)

        if not metrics:
            logger.warning(f"No metrics returned for {service}@{machine}")
            return

        # Store snapshot asynchronously
        await self.metrics_service.collect_metrics_snapshot(service, machine)

        # Broadcast via WebSocket (already async)
        if self.ws_manager:
            await self._broadcast_metrics_update(service, machine, metrics)

    async def _collect_machine_metrics_safe(self, machine: str) -> bool:
        """
        Safely collect metrics for a machine with timeout and concurrency control

        Args:
            machine: Machine hostname

        Returns:
            True if successful, False otherwise
        """
        async with self.semaphore:  # Limit concurrent executions
            try:
                # Apply timeout to prevent hanging
                await asyncio.wait_for(
                    self._collect_machine_metrics_async(machine), timeout=self.task_timeout
                )
                return True

            except asyncio.TimeoutError:
                logger.error(
                    f"Timeout collecting machine metrics for {machine} (>{self.task_timeout}s)"
                )
                return False

            except Exception as e:
                logger.error(f"Failed to collect machine metrics for {machine}: {e}")
                return False

    async def _collect_machine_metrics_async(self, machine: str):
        """
        Async implementation of machine metrics collection

        Args:
            machine: Machine hostname
        """
        # Get machine metrics using async metrics service
        metrics = await self.metrics_service.get_machine_metrics(machine)

        if not metrics:
            logger.warning(f"No metrics returned for machine {machine}")
            return

        # Broadcast via WebSocket (already async)
        if self.ws_manager:
            await self._broadcast_machine_metrics(machine, metrics)

    async def _broadcast_metrics_update(self, service: str, machine: str, metrics):
        """
        Broadcast metrics update via WebSocket

        Args:
            service: Service name
            machine: Machine hostname
            metrics: ServiceMetrics object
        """
        try:
            message = {
                "type": "metrics_update",
                "service": service,
                "machine": machine,
                "timestamp": utcnow().isoformat(),
                "data": metrics.model_dump(),
            }

            # Broadcast to all connections
            await self.ws_manager.broadcast(message)

            # Also send to service-specific subscribers if supported
            topic = f"metrics:service:{service}"
            if hasattr(self.ws_manager, "send_to_topic"):
                await self.ws_manager.send_to_topic(topic, message)

        except Exception as e:
            logger.error(f"Failed to broadcast metrics update: {e}")

    async def _broadcast_machine_metrics(self, machine: str, metrics):
        """
        Broadcast machine metrics via WebSocket

        Args:
            machine: Machine hostname
            metrics: MachineMetrics object
        """
        try:
            message = {
                "type": "machine_metrics_update",
                "machine": machine,
                "timestamp": utcnow().isoformat(),
                "data": metrics.model_dump(),
            }

            await self.ws_manager.broadcast(message)

        except Exception as e:
            logger.error(f"Failed to broadcast machine metrics: {e}")

    def get_status(self) -> dict:
        """
        Get collector status including statistics

        Returns:
            Dictionary with collector status and stats
        """
        return {
            "running": self.running,
            "interval": self.interval,
            "max_concurrent": self.max_concurrent,
            "task_timeout": self.task_timeout,
            "metrics_service_available": self.metrics_service is not None,
            "websocket_manager_available": self.ws_manager is not None,
            "registry_path": self.registry_path,
            "statistics": self.stats.copy(),
        }

    async def trigger_immediate_collection(self) -> bool:
        """
        Trigger an immediate metrics collection (outside the regular interval)

        Returns:
            True if collection started successfully
        """
        if not self.running:
            logger.warning("Cannot trigger collection - collector is not running")
            return False

        try:
            logger.info("Triggering immediate metrics collection")
            # Run collection in background without blocking
            asyncio.create_task(self.collect_all_async())
            return True
        except Exception as e:
            logger.error(f"Failed to trigger immediate collection: {e}")
            return False

    def update_interval(self, new_interval: int):
        """
        Update collection interval

        Args:
            new_interval: New interval in seconds
        """
        if new_interval < 1:
            logger.warning(f"Invalid interval {new_interval}, must be >= 1")
            return

        old_interval = self.interval
        self.interval = new_interval
        logger.info(f"Updated collection interval from {old_interval}s to {new_interval}s")

    def update_concurrency(self, max_concurrent: int):
        """
        Update maximum concurrent tasks

        Args:
            max_concurrent: New max concurrent tasks
        """
        if max_concurrent < 1:
            logger.warning(f"Invalid max_concurrent {max_concurrent}, must be >= 1")
            return

        old_max = self.max_concurrent
        self.max_concurrent = max_concurrent
        self.semaphore = asyncio.Semaphore(max_concurrent)
        logger.info(f"Updated max concurrent tasks from {old_max} to {max_concurrent}")

    async def cleanup_old_data(self, days: int = 30):
        """
        Clean up old metrics data asynchronously

        Args:
            days: Keep data for this many days
        """
        try:
            logger.info(f"Cleaning up metrics older than {days} days")
            await self.metrics_service.cleanup_old_metrics(days)
            logger.info("Cleanup completed")
        except Exception as e:
            logger.error(f"Failed to cleanup old data: {e}")

    async def collect_batch_async(
        self, service_list: List[Tuple[str, str]], machine_list: List[str]
    ) -> Dict[str, Any]:
        """
        Collect metrics for specific services and machines in parallel

        Useful for on-demand batch collection outside the regular loop.

        Args:
            service_list: List of (service, machine) tuples
            machine_list: List of machine names

        Returns:
            Dictionary with results and statistics
        """
        start_time = datetime.now()

        # Create tasks
        service_tasks = [
            self._collect_service_metrics_safe(svc, machine) for svc, machine in service_list
        ]
        machine_tasks = [self._collect_machine_metrics_safe(machine) for machine in machine_list]

        all_tasks = service_tasks + machine_tasks

        # Execute in parallel
        results = await asyncio.gather(*all_tasks, return_exceptions=True)

        # Analyze results
        successes = sum(1 for r in results if r is True)
        failures = sum(1 for r in results if isinstance(r, Exception) or r is False)
        duration = (datetime.now() - start_time).total_seconds()

        return {
            "total": len(results),
            "successful": successes,
            "failed": failures,
            "duration_seconds": duration,
            "timestamp": utcnow().isoformat(),
        }

    def get_statistics(self) -> Dict[str, Any]:
        """
        Get detailed collection statistics

        Returns:
            Dictionary with collection statistics
        """
        stats = self.stats.copy()

        # Calculate success rate
        total = stats["successful_collections"] + stats["failed_collections"]
        if total > 0:
            stats["success_rate"] = stats["successful_collections"] / total
        else:
            stats["success_rate"] = 0.0

        return stats

    async def health_check(self) -> Dict[str, Any]:
        """
        Perform a health check on the collector

        Returns:
            Dictionary with health status
        """
        try:
            # Check if collector is running
            is_healthy = self.running

            # Check if metrics service is responsive
            try:
                # Try a simple cache check (non-blocking)
                _ = self.metrics_service.cache
            except Exception:
                is_healthy = False

            return {
                "healthy": is_healthy,
                "running": self.running,
                "last_collection": self.stats.get("last_collection_time"),
                "statistics": self.get_statistics(),
                "timestamp": utcnow().isoformat(),
            }

        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return {"healthy": False, "error": str(e), "timestamp": utcnow().isoformat()}

    # Backwards compatibility alias
    async def collect_all(self):
        """Backwards compatibility alias for collect_all_async"""
        await self.collect_all_async()


# Maintain backwards compatibility with the old class name
MetricsCollector = AsyncMetricsCollector
