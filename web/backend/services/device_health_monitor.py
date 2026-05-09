"""
Device Health Monitor Service

Background task that checks device heartbeats and marks stale devices as offline.
Emits WebSocket events for status changes.
"""

import asyncio
import fcntl
import logging
import os
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Optional

import yaml

from utils.datetime_utils import utcnow
from utils.validation import FilePathValidator

logger = logging.getLogger(__name__)

# Configuration
HEARTBEAT_TIMEOUT = int(os.getenv("DEVICE_HEARTBEAT_TIMEOUT_SECONDS", "300"))  # 5 minutes
CHECK_INTERVAL = int(os.getenv("DEVICE_HEALTH_CHECK_INTERVAL_SECONDS", "60"))  # 1 minute
# Default registry path computed from this file. services/device_health_monitor.py ->
# parents[2] is the repo root.
_DEFAULT_REGISTRY_PATH = str(Path(__file__).resolve().parents[2] / "registry.yml")
REGISTRY_PATH = os.getenv("CADDY_REGISTRY_PATH", _DEFAULT_REGISTRY_PATH)


class DeviceHealthMonitor:
    """
    Background service to monitor device health based on heartbeat timestamps.

    - Checks last_seen_at for all devices
    - Marks devices offline if no heartbeat for HEARTBEAT_TIMEOUT seconds
    - Emits WebSocket events for status changes
    """

    def __init__(self, ws_manager: Optional[Any] = None):
        self.ws_manager = ws_manager
        self.running = False
        self._task: Optional[asyncio.Task] = None

    async def start(self):
        """Start the health monitoring background task"""
        if self.running:
            logger.warning("Device health monitor already running")
            return

        self.running = True
        self._task = asyncio.create_task(self._monitor_loop())
        logger.info(
            f"Device health monitor started (timeout={HEARTBEAT_TIMEOUT}s, interval={CHECK_INTERVAL}s)"
        )

    async def stop(self):
        """Stop the health monitoring background task"""
        self.running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("Device health monitor stopped")

    async def _monitor_loop(self):
        """Main monitoring loop"""
        while self.running:
            try:
                await self._check_device_health()
                await asyncio.sleep(CHECK_INTERVAL)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Error in device health monitor: {e}", exc_info=True)
                await asyncio.sleep(CHECK_INTERVAL)

    async def _check_device_health(self):
        """Check all devices and mark stale ones as offline"""
        try:
            # Load registry
            registry = self._load_registry()
            if not registry or "hosts" not in registry:
                return

            now = utcnow()
            cutoff_time = now - timedelta(seconds=HEARTBEAT_TIMEOUT)
            status_changes = []

            # Check each device
            for hostname, config in registry["hosts"].items():
                last_seen_str = config.get("last_seen_at")
                current_status = config.get("status", "unknown")

                # Skip devices in maintenance mode
                if current_status == "maintenance":
                    continue

                # If no last_seen_at, mark as offline
                if not last_seen_str:
                    if current_status != "offline":
                        config["status"] = "offline"
                        status_changes.append(
                            {
                                "hostname": hostname,
                                "old_status": current_status,
                                "new_status": "offline",
                                "reason": "no_heartbeat_data",
                            }
                        )
                    continue

                # Parse last_seen_at timestamp
                try:
                    last_seen = datetime.fromisoformat(last_seen_str.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    logger.warning(
                        f"Invalid last_seen_at timestamp for {hostname}: {last_seen_str}"
                    )
                    continue

                # Check if device is stale
                if last_seen < cutoff_time:
                    if current_status != "offline":
                        config["status"] = "offline"
                        status_changes.append(
                            {
                                "hostname": hostname,
                                "old_status": current_status,
                                "new_status": "offline",
                                "reason": "heartbeat_timeout",
                                "last_seen": last_seen_str,
                            }
                        )
                        logger.warning(
                            f"Device {hostname} marked offline (last seen: {last_seen_str})"
                        )
                else:
                    # Device is healthy but might have been marked offline previously
                    if current_status == "offline":
                        config["status"] = "online"
                        status_changes.append(
                            {
                                "hostname": hostname,
                                "old_status": current_status,
                                "new_status": "online",
                                "reason": "heartbeat_recovered",
                            }
                        )
                        logger.info(f"Device {hostname} recovered (back online)")

            # Save registry if there were changes
            if status_changes:
                self._save_registry(registry)

                # Emit WebSocket events for status changes
                await self._emit_status_changes(status_changes)

                logger.info(f"Device health check completed: {len(status_changes)} status changes")

        except Exception as e:
            logger.error(f"Error checking device health: {e}", exc_info=True)

    def _load_registry(self) -> Optional[Dict]:
        """Load registry file"""
        try:
            # Check if registry file exists and is readable
            registry_path = FilePathValidator.check_file_exists(REGISTRY_PATH, "registry.yml")

            with open(registry_path, "r") as f:
                return yaml.safe_load(f)
        except Exception as e:
            logger.error(f"Error loading registry: {e}")
            return None

    def _save_registry(self, registry: Dict):
        """Save registry file"""
        try:
            registry_path = Path(REGISTRY_PATH)
            lock_path = Path(f"{REGISTRY_PATH}.lock")

            # Update metadata
            registry["last_updated"] = utcnow().isoformat()

            # Write atomically with a simple file lock to avoid races across workers
            lock_file = lock_path.open("w")
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

                temp_path = Path(f"{REGISTRY_PATH}.tmp")
                with open(temp_path, "w") as f:
                    yaml.dump(registry, f, default_flow_style=False, sort_keys=False)

                temp_path.replace(registry_path)
                logger.debug("Registry saved successfully")
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                lock_file.close()

        except Exception as e:
            logger.error(f"Error saving registry: {e}")

    async def _emit_status_changes(self, status_changes: list):
        """Emit WebSocket events for status changes"""
        if not self.ws_manager:
            return

        try:
            for change in status_changes:
                message = {
                    "type": "device_status_change",
                    "timestamp": utcnow().isoformat(),
                    "data": change,
                }

                # Broadcast to all connected WebSocket clients
                await self.ws_manager.broadcast(message)

        except Exception as e:
            logger.error(f"Error emitting status changes: {e}")

    def get_status(self) -> Dict[str, Any]:
        """Get monitor status"""
        return {
            "running": self.running,
            "heartbeat_timeout_seconds": HEARTBEAT_TIMEOUT,
            "check_interval_seconds": CHECK_INTERVAL,
            "registry_path": REGISTRY_PATH,
        }
