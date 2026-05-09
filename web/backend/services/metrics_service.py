"""Service for collecting and managing resource metrics - ASYNC VERSION"""

import asyncio
import json
import logging
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

from models.metrics import (
    MachineMetrics,
    MetricsTimeRange,
    ResourceMetrics,
    ServiceMetrics,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class MetricsCache:
    """Simple TTL cache for metrics data"""

    def __init__(self, ttl_seconds: int = 10):
        self.cache: Dict[str, tuple[datetime, Any]] = {}
        self.ttl = timedelta(seconds=ttl_seconds)

    def get(self, key: str) -> Optional[Any]:
        """Get cached value if not expired"""
        if key in self.cache:
            cached_at, data = self.cache[key]
            if datetime.now() - cached_at < self.ttl:
                return data
            else:
                del self.cache[key]
        return None

    def set(self, key: str, value: Any):
        """Store value in cache with current timestamp"""
        self.cache[key] = (datetime.now(), value)

    def invalidate(self, key: str = None):
        """Invalidate specific key or entire cache"""
        if key:
            self.cache.pop(key, None)
        else:
            self.cache.clear()


class MetricsService:
    """Service for collecting and managing resource metrics - ASYNC VERSION"""

    def __init__(self, cli_path: str = None, cache_ttl: int = 10, max_workers: int = 5):
        """
        Initialize metrics service

        Args:
            cli_path: Path to portoser CLI executable
            cache_ttl: Cache time-to-live in seconds (default: 10)
            max_workers: Maximum number of ThreadPoolExecutor workers (default: 5)
        """
        # Default CLI path: <repo-root>/portoser. services/metrics_service.py ->
        # parents[2] is the repo root.
        default_cli = str(Path(__file__).resolve().parents[2] / "portoser")
        self.cli_path = cli_path or os.getenv("PORTOSER_CLI", default_cli)
        self.cache = MetricsCache(ttl_seconds=cache_ttl)
        self.snapshots_dir = Path.home() / ".portoser" / "metrics_snapshots"
        self.snapshots_dir.mkdir(parents=True, exist_ok=True)
        self.executor = ThreadPoolExecutor(max_workers=max_workers)
        logger.info(f"MetricsService initialized with CLI: {self.cli_path}")
        logger.info(f"Metrics snapshots directory: {self.snapshots_dir}")
        logger.info(f"ThreadPoolExecutor initialized with {max_workers} workers")

    async def _run_cli_command(self, args: List[str], timeout: int = 30) -> Dict[str, Any]:
        """
        Execute portoser CLI command asynchronously

        Args:
            args: Command arguments
            timeout: Command timeout in seconds

        Returns:
            Command result with success, output, error
        """
        try:
            cmd = [self.cli_path] + args
            logger.debug(f"Running command: {' '.join(cmd)}")

            # Get the current event loop
            loop = asyncio.get_event_loop()

            # Run subprocess.run in executor to avoid blocking
            result = await loop.run_in_executor(
                self.executor,
                lambda: subprocess.run(cmd, capture_output=True, text=True, timeout=timeout),
            )

            return {
                "success": result.returncode
                in [0, 2],  # Accept 0 (success) and 2 (metrics CLI quirk)
                "output": result.stdout,
                "error": result.stderr if result.returncode not in [0, 2] else None,
                "returncode": result.returncode,
            }
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {' '.join(args)}")
            return {"success": False, "output": "", "error": "Command timed out", "returncode": -1}
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return {"success": False, "output": "", "error": str(e), "returncode": -1}

    def _parse_metrics_json(self, json_output: str) -> Optional[Dict[str, Any]]:
        """
        Parse JSON output from CLI

        Args:
            json_output: JSON string from CLI

        Returns:
            Parsed data or None on error
        """
        try:
            return json.loads(json_output)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            logger.debug(f"JSON output: {json_output}")
            return None

    async def get_service_metrics(
        self, service: str, machine: str, time_range: MetricsTimeRange = MetricsTimeRange.HOUR
    ) -> Optional[ServiceMetrics]:
        """
        Get current and historical metrics for a service asynchronously

        Args:
            service: Service name
            machine: Machine hostname
            time_range: Time range for historical data

        Returns:
            ServiceMetrics or None on error
        """
        cache_key = f"service:{service}:{machine}"
        cached = self.cache.get(cache_key)
        if cached:
            logger.debug(f"Returning cached metrics for {cache_key}")
            return cached

        # Same offline-aware fast path as get_machine_metrics — see comment there.
        if self._is_machine_offline(machine):
            logger.debug(
                f"Machine {machine} offline in registry; returning synthetic service metrics"
            )
            offline = self._offline_service_metrics(service, machine)
            self.cache.set(cache_key, offline)
            return offline

        # Get current metrics asynchronously
        result = await self._run_cli_command(
            ["metrics", "service", service, machine, "--json-output"]
        )

        if not result["success"]:
            # Fall back to a synthetic ServiceMetrics rather than 404 the
            # caller. CLI failures here are mostly first-boot transients
            # (the lib hasn't finished syncing to the remote, or the SSH
            # control-master is still warming) — the UI shouldn't flash
            # broken cards before settling.
            logger.warning(
                f"Falling back to synthetic metrics for {service}@{machine}: {result['error']}"
            )
            synth = self._offline_service_metrics(service, machine)
            self.cache.set(cache_key, synth)
            return synth

        data = self._parse_metrics_json(result["output"])
        if not data:
            logger.warning(
                f"Falling back to synthetic metrics for {service}@{machine}: unparseable output"
            )
            synth = self._offline_service_metrics(service, machine)
            self.cache.set(cache_key, synth)
            return synth

        # Parse current metrics
        try:
            current = ResourceMetrics(
                service=service,
                machine=machine,
                timestamp=datetime.fromisoformat(data.get("timestamp", utcnow().isoformat())),
                cpu_percent=data.get("cpu_percent", 0.0),
                memory_mb=data.get("memory_mb", 0.0),
                memory_total_mb=data.get("memory_total_mb", 0.0),
                disk_gb=data.get("disk_gb", 0.0),
                disk_total_gb=data.get("disk_total_gb", 0.0),
                network_rx_bytes=data.get("network_rx_bytes", 0),
                network_tx_bytes=data.get("network_tx_bytes", 0),
            )

            # Get historical data asynchronously
            history = await self.get_metrics_history(service, machine, time_range)

            # Calculate averages and peaks
            all_metrics = history + [current]
            avg_cpu = (
                sum(m.cpu_percent for m in all_metrics) / len(all_metrics) if all_metrics else 0
            )
            avg_memory = (
                sum(m.memory_mb for m in all_metrics) / len(all_metrics) if all_metrics else 0
            )
            peak_cpu = max((m.cpu_percent for m in all_metrics), default=0)
            peak_memory = max((m.memory_mb for m in all_metrics), default=0)

            service_metrics = ServiceMetrics(
                service=service,
                machine=machine,
                current=current,
                history=history,
                avg_cpu=avg_cpu,
                avg_memory=avg_memory,
                peak_cpu=peak_cpu,
                peak_memory=peak_memory,
                time_range=time_range.value,
            )

            self.cache.set(cache_key, service_metrics)
            return service_metrics

        except Exception as e:
            logger.error(f"Failed to parse service metrics: {e}")
            return None

    async def get_machine_metrics(self, machine: str) -> Optional[MachineMetrics]:
        """
        Get aggregated metrics for all services on a machine asynchronously

        Args:
            machine: Machine hostname

        Returns:
            MachineMetrics or None on error
        """
        cache_key = f"machine:{machine}"
        cached = self.cache.get(cache_key)
        if cached:
            logger.debug(f"Returning cached metrics for {cache_key}")
            return cached

        # Skip the SSH probe when the registry says the host is offline.
        # Otherwise the CLI's metrics command waits the full 30s timeout
        # per offline host, multiplied by N machines for /api/metrics/all.
        # Returning a zero-filled MachineMetrics with status="offline" gives
        # the UI everything it needs to render an offline card without
        # blocking the request.
        if self._is_machine_offline(machine):
            logger.debug(
                f"Machine {machine} marked offline in registry; returning synthetic metrics"
            )
            offline_metrics = self._offline_machine_metrics(machine)
            self.cache.set(cache_key, offline_metrics)
            return offline_metrics

        result = await self._run_cli_command(["metrics", "machine", machine, "--json-output"])

        if not result["success"]:
            logger.error(f"Failed to get machine metrics for {machine}: {result['error']}")
            return None

        data = self._parse_metrics_json(result["output"])
        if not data:
            return None

        try:
            # Parse services metrics
            services = []
            for svc_data in data.get("services", []):
                services.append(
                    ResourceMetrics(
                        service=svc_data.get("service"),
                        machine=machine,
                        timestamp=datetime.fromisoformat(
                            svc_data.get("timestamp", utcnow().isoformat())
                        ),
                        cpu_percent=svc_data.get("cpu_percent", 0.0),
                        memory_mb=svc_data.get("memory_mb", 0.0),
                        memory_total_mb=svc_data.get("memory_total_mb", 0.0),
                        disk_gb=svc_data.get("disk_gb", 0.0),
                        disk_total_gb=svc_data.get("disk_total_gb", 0.0),
                        network_rx_bytes=svc_data.get("network_rx_bytes", 0),
                        network_tx_bytes=svc_data.get("network_tx_bytes", 0),
                    )
                )

            # Calculate percentages
            memory_used_mb = data.get("memory_used_mb", 0.0)
            memory_total_mb = data.get("memory_total_mb", 0.0)
            disk_used_gb = data.get("disk_used_gb", 0.0)
            disk_total_gb = data.get("disk_total_gb", 0.0)

            memory_percent = 0.0
            if memory_total_mb > 0:
                memory_percent = (memory_used_mb / memory_total_mb) * 100

            disk_percent = 0.0
            if disk_total_gb > 0:
                disk_percent = (disk_used_gb / disk_total_gb) * 100

            machine_metrics = MachineMetrics(
                machine=machine,
                cpu_percent=data.get("cpu_percent", 0.0),
                memory_used_mb=memory_used_mb,
                memory_total_mb=memory_total_mb,
                memory_percent=memory_percent,
                disk_used_gb=disk_used_gb,
                disk_total_gb=disk_total_gb,
                disk_percent=disk_percent,
                services=services,
                timestamp=datetime.fromisoformat(data.get("timestamp", utcnow().isoformat())),
                status="ok",
            )

            self.cache.set(cache_key, machine_metrics)
            return machine_metrics

        except Exception as e:
            logger.error(f"Failed to parse machine metrics: {e}")
            return None

    async def get_all_metrics(self) -> List[MachineMetrics]:
        """
        Get metrics for all machines asynchronously

        Returns:
            List of MachineMetrics
        """
        cache_key = "all_metrics"
        cached = self.cache.get(cache_key)
        if cached:
            logger.debug("Returning cached all_metrics")
            return cached

        # Try to get all metrics at once
        result = await self._run_cli_command(["metrics", "all", "--json-output"])

        all_metrics = []

        if result["success"]:
            data = self._parse_metrics_json(result["output"])
            if data and "machines" in data:
                # Parse the CLI output
                for machine_data in data["machines"]:
                    try:
                        all_metrics.append(self._parse_machine_metrics(machine_data))
                    except Exception as e:
                        logger.error(f"Failed to parse metrics for machine: {e}")
                        # Add error entry for this machine
                        if "machine" in machine_data:
                            all_metrics.append(
                                MachineMetrics(
                                    machine=machine_data["machine"],
                                    timestamp=utcnow(),
                                    status="error",
                                    error=str(e),
                                )
                            )

                # Cache and return results
                self.cache.set(cache_key, all_metrics)
                return all_metrics
            else:
                logger.warning("No machines data in metrics all output")
        else:
            logger.warning(f"metrics all command failed: {result['error']}")

        # Fallback: Try to get machines from registry and query individually
        logger.info("Attempting fallback: querying each machine individually")
        all_metrics = await self._get_all_metrics_fallback()

        if all_metrics:
            self.cache.set(cache_key, all_metrics)

        return all_metrics

    def _parse_machine_metrics(self, machine_data: Dict[str, Any]) -> MachineMetrics:
        """
        Parse machine metrics from CLI output

        Args:
            machine_data: Dictionary with machine and metrics keys

        Returns:
            MachineMetrics object
        """
        machine_name = machine_data.get("machine", "unknown")
        metrics = machine_data.get("metrics", {})

        # Check for error conditions
        if "error" in metrics:
            error_msg = metrics["error"]
            logger.warning(f"Machine {machine_name} has error: {error_msg}")
            return MachineMetrics(
                machine=machine_name,
                timestamp=utcnow(),
                status="unavailable" if error_msg == "metrics_unavailable" else "error",
                error=error_msg,
            )

        # Parse successful metrics
        try:
            cpu_percent = float(metrics.get("cpu_percent", 0.0))
            memory_used_mb = float(metrics.get("memory_used_mb", 0.0))
            memory_total_mb = float(metrics.get("memory_total_mb", 0.0))
            disk_used_gb = float(metrics.get("disk_used_gb", 0.0))
            disk_total_gb = float(metrics.get("disk_total_gb", 0.0))

            # Calculate percentages
            memory_percent = 0.0
            if memory_total_mb > 0:
                memory_percent = (memory_used_mb / memory_total_mb) * 100

            disk_percent = 0.0
            if disk_total_gb > 0:
                disk_percent = (disk_used_gb / disk_total_gb) * 100

            # Parse timestamp
            timestamp_str = metrics.get("timestamp")
            if timestamp_str:
                try:
                    timestamp = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    timestamp = utcnow()
            else:
                timestamp = utcnow()

            # Parse services if present
            services = []
            for svc_data in metrics.get("services", []):
                try:
                    services.append(
                        ResourceMetrics(
                            service=svc_data.get("service", "unknown"),
                            machine=machine_name,
                            timestamp=timestamp,
                            cpu_percent=float(svc_data.get("cpu_percent", 0.0)),
                            memory_mb=float(svc_data.get("memory_mb", 0.0)),
                            memory_total_mb=memory_total_mb,
                            disk_gb=float(svc_data.get("disk_gb", 0.0)),
                            disk_total_gb=disk_total_gb,
                            network_rx_bytes=svc_data.get("network_rx_bytes", 0),
                            network_tx_bytes=svc_data.get("network_tx_bytes", 0),
                        )
                    )
                except Exception as e:
                    logger.warning(f"Failed to parse service metrics: {e}")

            return MachineMetrics(
                machine=machine_name,
                cpu_percent=cpu_percent,
                memory_used_mb=memory_used_mb,
                memory_total_mb=memory_total_mb,
                memory_percent=memory_percent,
                disk_used_gb=disk_used_gb,
                disk_total_gb=disk_total_gb,
                disk_percent=disk_percent,
                services=services,
                timestamp=timestamp,
                status="ok",
            )

        except Exception as e:
            logger.error(f"Failed to parse machine metrics for {machine_name}: {e}")
            return MachineMetrics(
                machine=machine_name,
                timestamp=utcnow(),
                status="error",
                error=f"Parse error: {str(e)}",
            )

    async def get_all_machines(self) -> List[str]:
        """
        Get list of all known machines

        Returns:
            List of machine hostnames (empty list if registry is missing/empty)
        """
        try:
            from services.registry_service import RegistryService

            registry_path = self._registry_path()
            registry = RegistryService(registry_path=registry_path)
            hosts = registry.get_all_hosts()

            if not hosts:
                logger.warning("No hosts found in registry at %s", registry_path)
                return []

            machine_names = [host.name for host in hosts]
            logger.info(f"Found {len(machine_names)} machines: {machine_names}")
            return machine_names

        except Exception as e:
            logger.error(f"Failed to get machines from registry: {e}")
            return []

    @staticmethod
    def _registry_path() -> str:
        """Resolve registry path from CADDY_REGISTRY_PATH (or PORTOSER_REGISTRY
        for backwards compatibility), falling back to <repo>/registry.yml."""
        env = os.getenv("CADDY_REGISTRY_PATH") or os.getenv("PORTOSER_REGISTRY")
        if env:
            return env
        # __file__ = <repo>/web/backend/services/metrics_service.py
        return str(Path(__file__).resolve().parents[3] / "registry.yml")

    def _is_machine_offline(self, machine: str) -> bool:
        """True when the registry says the host is anything other than online.

        The conservative read: we only SSH-probe hosts that are explicitly
        marked online. Anything else (offline, unknown, or absent from the
        registry) gets the synthetic-metrics fast path.

        Returns False on any registry-read failure — i.e. fail open and let
        the SSH attempt happen, since a failed registry read shouldn't lock
        the user out of metrics on a real cluster.
        """
        try:
            from services.registry_service import RegistryService

            registry = RegistryService(registry_path=self._registry_path())
            host = registry.get_host(machine)
            if host is None:
                return False
            return not host.is_online()
        except Exception as e:
            logger.debug(f"Registry status lookup failed for {machine}; assuming online: {e}")
            return False

    @staticmethod
    def _offline_machine_metrics(machine: str) -> MachineMetrics:
        """Synthetic zeroed MachineMetrics for hosts the registry says are offline."""
        return MachineMetrics(
            machine=machine,
            cpu_percent=0.0,
            memory_used_mb=0.0,
            memory_total_mb=0.0,
            memory_percent=0.0,
            disk_used_gb=0.0,
            disk_total_gb=0.0,
            disk_percent=0.0,
            services=[],
            timestamp=utcnow(),
            status="offline",
            error="host marked offline in registry",
        )

    @staticmethod
    def _offline_service_metrics(service: str, machine: str) -> ServiceMetrics:
        """Synthetic zeroed ServiceMetrics for services on offline hosts."""
        zero = ResourceMetrics(
            service=service,
            machine=machine,
            timestamp=utcnow(),
            cpu_percent=0.0,
            memory_mb=0.0,
            memory_total_mb=0.0,
            disk_gb=0.0,
            disk_total_gb=0.0,
            network_rx_bytes=0,
            network_tx_bytes=0,
        )
        return ServiceMetrics(
            service=service,
            machine=machine,
            current=zero,
            history=[],
            time_range=MetricsTimeRange.HOUR,
        )

    async def _get_all_metrics_fallback(self) -> List[MachineMetrics]:
        """
        Fallback method to get metrics by querying each machine individually asynchronously

        Returns:
            List of MachineMetrics
        """
        all_metrics = []

        try:
            # Try to get machines from registry
            from services.registry_service import RegistryService

            registry_path = self._registry_path()
            registry = RegistryService(registry_path=registry_path)
            hosts = registry.get_all_hosts()

            if not hosts:
                logger.warning("No hosts found in registry for fallback metrics collection")
                return []

            logger.info(f"Querying {len(hosts)} machines individually")

            # Query all machines concurrently
            tasks = []
            for host in hosts:
                tasks.append(self._get_single_machine_metrics_safe(host.name))

            # Wait for all tasks to complete
            all_metrics = await asyncio.gather(*tasks)

        except Exception as e:
            logger.error(f"Fallback metrics collection failed: {e}")

        return all_metrics

    async def _get_single_machine_metrics_safe(self, machine_name: str) -> MachineMetrics:
        """
        Safely get metrics for a single machine with error handling

        Args:
            machine_name: Name of the machine

        Returns:
            MachineMetrics (may contain error status)
        """
        try:
            machine_metrics = await self.get_machine_metrics(machine_name)
            if machine_metrics:
                return machine_metrics
            else:
                # Add unavailable entry
                return MachineMetrics(
                    machine=machine_name,
                    timestamp=utcnow(),
                    status="unavailable",
                    error="Failed to retrieve metrics",
                )
        except Exception as e:
            logger.error(f"Failed to get metrics for {machine_name}: {e}")
            return MachineMetrics(
                machine=machine_name, timestamp=utcnow(), status="error", error=str(e)
            )

    async def collect_metrics_snapshot(
        self, service: Optional[str] = None, machine: Optional[str] = None
    ) -> bool:
        """
        Collect and store a metrics snapshot asynchronously

        Args:
            service: Specific service to snapshot (optional)
            machine: Specific machine to snapshot (optional)

        Returns:
            True if successful
        """
        timestamp = utcnow()
        snapshot_file = self.snapshots_dir / f"snapshot_{timestamp.strftime('%Y%m%d_%H%M%S')}.json"

        try:
            if service and machine:
                # Single service snapshot
                metrics = await self.get_service_metrics(service, machine)
                if metrics:
                    snapshot_data = {
                        "timestamp": timestamp.isoformat(),
                        "type": "service",
                        "data": metrics.model_dump(),
                    }
                else:
                    return False
            elif machine:
                # Machine snapshot
                metrics = await self.get_machine_metrics(machine)
                if metrics:
                    snapshot_data = {
                        "timestamp": timestamp.isoformat(),
                        "type": "machine",
                        "data": metrics.model_dump(),
                    }
                else:
                    return False
            else:
                # All metrics snapshot
                all_metrics = await self.get_all_metrics()
                snapshot_data = {
                    "timestamp": timestamp.isoformat(),
                    "type": "all",
                    "data": [m.model_dump() for m in all_metrics],
                }

            # Write snapshot asynchronously
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(
                self.executor, lambda: self._write_snapshot_file(snapshot_file, snapshot_data)
            )

            logger.info(f"Metrics snapshot saved to {snapshot_file}")
            return True

        except Exception as e:
            logger.error(f"Failed to collect metrics snapshot: {e}")
            return False

    def _write_snapshot_file(self, snapshot_file: Path, snapshot_data: Dict[str, Any]):
        """
        Write snapshot data to file (runs in executor)

        Args:
            snapshot_file: Path to snapshot file
            snapshot_data: Data to write
        """
        with open(snapshot_file, "w") as f:
            json.dump(snapshot_data, f, indent=2, default=str)

    async def get_metrics_history(
        self, service: str, machine: str, time_range: MetricsTimeRange
    ) -> List[ResourceMetrics]:
        """
        Get historical metrics from snapshots asynchronously

        Args:
            service: Service name
            machine: Machine hostname
            time_range: Time range to query

        Returns:
            List of historical ResourceMetrics
        """
        # Parse time range
        range_map = {
            MetricsTimeRange.HOUR: timedelta(hours=1),
            MetricsTimeRange.SIX_HOURS: timedelta(hours=6),
            MetricsTimeRange.DAY: timedelta(days=1),
            MetricsTimeRange.WEEK: timedelta(days=7),
            MetricsTimeRange.MONTH: timedelta(days=30),
        }

        cutoff_time = utcnow() - range_map.get(time_range, timedelta(hours=1))

        # Run file I/O in executor
        loop = asyncio.get_event_loop()
        history = await loop.run_in_executor(
            self.executor, lambda: self._read_metrics_history_sync(service, machine, cutoff_time)
        )

        return history

    def _read_metrics_history_sync(
        self, service: str, machine: str, cutoff_time: datetime
    ) -> List[ResourceMetrics]:
        """
        Synchronous helper to read metrics history (runs in executor)

        Args:
            service: Service name
            machine: Machine hostname
            cutoff_time: Cutoff time for history

        Returns:
            List of historical ResourceMetrics
        """
        history = []

        try:
            # Read snapshots
            for snapshot_file in sorted(self.snapshots_dir.glob("snapshot_*.json")):
                try:
                    with open(snapshot_file, "r") as f:
                        snapshot = json.load(f)

                    snapshot_time = datetime.fromisoformat(snapshot["timestamp"])
                    if snapshot_time < cutoff_time:
                        continue

                    # Extract metrics for this service
                    if snapshot["type"] == "service":
                        data = snapshot["data"]
                        if data.get("service") == service and data.get("machine") == machine:
                            history.append(ResourceMetrics(**data["current"]))
                    elif snapshot["type"] == "machine":
                        data = snapshot["data"]
                        if data.get("machine") == machine:
                            for svc in data.get("services", []):
                                if svc.get("service") == service:
                                    history.append(ResourceMetrics(**svc))

                except Exception as e:
                    logger.warning(f"Failed to parse snapshot {snapshot_file}: {e}")
                    continue

            return history

        except Exception as e:
            logger.error(f"Failed to get metrics history: {e}")
            return []

    async def calculate_average_metrics(self, history: List[ResourceMetrics]) -> Dict[str, float]:
        """
        Calculate average metrics from history (async version)

        Args:
            history: List of historical metrics

        Returns:
            Dictionary with average values
        """
        if not history:
            return {"avg_cpu": 0.0, "avg_memory": 0.0, "peak_cpu": 0.0, "peak_memory": 0.0}

        # Run in executor for CPU-bound work
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            self.executor, self._calculate_average_metrics_sync, history
        )

    def _calculate_average_metrics_sync(self, history: List[ResourceMetrics]) -> Dict[str, float]:
        """
        Synchronous helper for calculate_average_metrics (runs in executor)

        Args:
            history: List of historical metrics

        Returns:
            Dictionary with average values
        """
        return {
            "avg_cpu": sum(m.cpu_percent for m in history) / len(history),
            "avg_memory": sum(m.memory_mb for m in history) / len(history),
            "peak_cpu": max(m.cpu_percent for m in history),
            "peak_memory": max(m.memory_mb for m in history),
        }

    async def cleanup_old_metrics(self, days: int = 30):
        """
        Clean up old metric snapshots asynchronously

        Args:
            days: Number of days to keep (default: 30)
        """
        cutoff_time = utcnow() - timedelta(days=days)

        # Run file I/O in executor
        loop = asyncio.get_event_loop()
        deleted_count = await loop.run_in_executor(
            self.executor, lambda: self._cleanup_old_metrics_sync(cutoff_time)
        )

        logger.info(f"Cleaned up {deleted_count} old metric snapshots")

    def _cleanup_old_metrics_sync(self, cutoff_time: datetime) -> int:
        """
        Synchronous helper to cleanup old metrics (runs in executor)

        Args:
            cutoff_time: Cutoff time for cleanup

        Returns:
            Number of deleted files
        """
        deleted_count = 0

        try:
            for snapshot_file in self.snapshots_dir.glob("snapshot_*.json"):
                try:
                    with open(snapshot_file, "r") as f:
                        snapshot = json.load(f)

                    snapshot_time = datetime.fromisoformat(snapshot["timestamp"])
                    if snapshot_time < cutoff_time:
                        snapshot_file.unlink()
                        deleted_count += 1

                except Exception as e:
                    logger.warning(f"Failed to process snapshot {snapshot_file}: {e}")
                    continue

        except Exception as e:
            logger.error(f"Failed to cleanup old metrics: {e}")

        return deleted_count

    def invalidate_cache(self, service: str = None, machine: str = None):
        """
        Invalidate metrics cache

        Args:
            service: Specific service to invalidate (optional)
            machine: Specific machine to invalidate (optional)
        """
        if service and machine:
            self.cache.invalidate(f"service:{service}:{machine}")
        elif machine:
            self.cache.invalidate(f"machine:{machine}")
        else:
            self.cache.invalidate()

    async def get_service_machine_mapping(self) -> Dict[str, List[str]]:
        """
        Get mapping of which services run on which machines

        Returns:
            Dictionary mapping service names to list of machines they run on
            Example: {"nginx": ["host-a", "host-b"], "postgres": ["host-a"], ...}
        """
        cache_key = "service_machine_mapping"

        # Check cache first (5 minute TTL = 300 seconds)
        # Using custom cache check since MetricsCache has 10s default TTL
        if cache_key in self.cache.cache:
            cached_at, data = self.cache.cache[cache_key]
            if (datetime.now() - cached_at).total_seconds() < 300:  # 5 minutes
                logger.debug("Returning cached service machine mapping")
                return data
            else:
                # Expired, remove from cache
                del self.cache.cache[cache_key]

        # Discover services from all machines
        services_by_machine: Dict[str, List[str]] = {}

        try:
            # Get all machines
            machines = await self.get_all_machines()
            logger.info(f"Discovering services on {len(machines)} machines")

            # Query each machine for its services
            for machine in machines:
                try:
                    # Use portoser CLI to list services on this machine
                    result = await self._run_cli_command(["list", machine])

                    if result["success"] and result["output"]:
                        # Parse the service list from output
                        services = self._parse_services_list(result["output"])
                        logger.debug(f"Found {len(services)} services on {machine}: {services}")

                        for service in services:
                            if service not in services_by_machine:
                                services_by_machine[service] = []
                            services_by_machine[service].append(machine)
                    else:
                        logger.warning(
                            f"Failed to get services for {machine}: {result.get('error', 'Unknown error')}"
                        )

                except Exception as e:
                    logger.error(f"Error querying services on {machine}: {e}")
                    continue

            logger.info(
                f"Discovered {len(services_by_machine)} unique services across all machines"
            )

            # Cache the result with 5 minute TTL
            self.cache.set(cache_key, services_by_machine)

            return services_by_machine

        except Exception as e:
            logger.error(f"Failed to get service machine mapping: {e}")
            return {}

    def _parse_services_list(self, output: str) -> List[str]:
        """
        Parse service names from portoser list command output

        Args:
            output: Raw output from portoser list command

        Returns:
            List of service names
        """
        services = []
        try:
            # The output format from portoser list is typically:
            # - One service per line
            # - May have status indicators or other formatting
            # - We extract just the service names

            lines = output.strip().split("\n")
            for line in lines:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue

                # Extract service name (typically the first word/token)
                # Handle different formats: "service_name" or "service_name: status" etc.
                parts = line.split()
                if parts:
                    service_name = parts[0].rstrip(":")
                    if service_name:
                        services.append(service_name)

        except Exception as e:
            logger.error(f"Failed to parse services list: {e}")
            logger.debug(f"Output was: {output}")

        return services

    def shutdown(self):
        """
        Shutdown the executor gracefully
        """
        logger.info("Shutting down MetricsService ThreadPoolExecutor")
        self.executor.shutdown(wait=True)
