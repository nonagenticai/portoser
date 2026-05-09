"""Service for tracking and managing service uptime"""

import json
import logging
import os
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

from models.uptime import (
    ServiceStatus,
    UptimeEvent,
    UptimeEventType,
    UptimeHistory,
    UptimeStats,
    UptimeSummary,
    UptimeTimelineEntry,
    UptimeTimelineResponse,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class UptimeCache:
    """Simple TTL cache for uptime data"""

    def __init__(self, ttl_seconds: int = 60):
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


class UptimeService:
    """Service for tracking and calculating service uptime"""

    def __init__(self, cli_path: str = None, cache_ttl: int = 60):
        """
        Initialize uptime service

        Args:
            cli_path: Path to portoser CLI executable
            cache_ttl: Cache time-to-live in seconds (default: 60)
        """
        # Default CLI path: <repo-root>/portoser. services/uptime_service.py ->
        # parents[2] is the repo root.
        default_cli = str(Path(__file__).resolve().parents[2] / "portoser")
        self.cli_path = cli_path or os.getenv("PORTOSER_CLI", default_cli)
        self.cache = UptimeCache(ttl_seconds=cache_ttl)
        self.events_dir = Path.home() / ".portoser" / "uptime_events"
        self.events_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"UptimeService initialized with CLI: {self.cli_path}")
        logger.info(f"Uptime events directory: {self.events_dir}")

    def _run_cli_command(self, args: List[str], timeout: int = 30) -> Dict[str, Any]:
        """
        Execute portoser CLI command

        Args:
            args: Command arguments
            timeout: Command timeout in seconds

        Returns:
            Command result with success, output, error
        """
        try:
            cmd = [self.cli_path] + args
            logger.debug(f"Running command: {' '.join(cmd)}")

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

            return {
                "success": result.returncode == 0,
                "output": result.stdout,
                "error": result.stderr if result.returncode != 0 else None,
                "returncode": result.returncode,
            }
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {' '.join(args)}")
            return {"success": False, "output": "", "error": "Command timed out", "returncode": -1}
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return {"success": False, "output": "", "error": str(e), "returncode": -1}

    def _parse_json(self, json_output: str) -> Optional[Dict[str, Any]]:
        """Parse JSON output from CLI"""
        try:
            return json.loads(json_output)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return None

    def record_uptime_event(
        self,
        service: str,
        machine: str,
        event_type: UptimeEventType,
        details: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> bool:
        """
        Record an uptime event

        Args:
            service: Service name
            machine: Machine hostname
            event_type: Type of event
            details: Optional event details
            metadata: Optional metadata

        Returns:
            True if event was recorded successfully
        """
        try:
            event = UptimeEvent(
                timestamp=utcnow(),
                event_type=event_type,
                service=service,
                machine=machine,
                details=details,
                metadata=metadata,
            )

            # Write to events file
            events_file = self.events_dir / f"{service}_{machine}_events.jsonl"
            with open(events_file, "a") as f:
                f.write(json.dumps(event.model_dump(), default=str) + "\n")

            logger.info(f"Recorded uptime event: {event_type} for {service}@{machine}")

            # Invalidate cache
            self.cache.invalidate(f"uptime:{service}:{machine}")
            self.cache.invalidate("uptime:all")

            return True

        except Exception as e:
            logger.error(f"Failed to record uptime event: {e}")
            return False

    def _load_events(self, service: str, machine: str, days: int = 30) -> List[UptimeEvent]:
        """
        Load uptime events from file

        Args:
            service: Service name
            machine: Machine hostname
            days: Number of days to load

        Returns:
            List of UptimeEvent
        """
        events_file = self.events_dir / f"{service}_{machine}_events.jsonl"
        if not events_file.exists():
            return []

        cutoff_time = utcnow() - timedelta(days=days)
        events = []

        try:
            with open(events_file, "r") as f:
                for line in f:
                    try:
                        event_data = json.loads(line.strip())
                        event = UptimeEvent(**event_data)

                        if event.timestamp >= cutoff_time:
                            events.append(event)
                    except Exception as e:
                        logger.warning(f"Failed to parse event line: {e}")
                        continue

            return sorted(events, key=lambda e: e.timestamp)

        except Exception as e:
            logger.error(f"Failed to load events: {e}")
            return []

    def calculate_availability(self, service: str, machine: str, days: int = 30) -> UptimeStats:
        """
        Calculate uptime statistics

        Args:
            service: Service name
            machine: Machine hostname
            days: Number of days to analyze

        Returns:
            UptimeStats
        """
        events = self._load_events(service, machine, days)

        if not events:
            # No events, assume service is up
            total_seconds = days * 24 * 3600
            return UptimeStats(
                service=service,
                machine=machine,
                uptime_seconds=total_seconds,
                downtime_seconds=0,
                total_seconds=total_seconds,
                availability_percent=100.0,
                mtbf=None,
                mttr=None,
                failure_count=0,
                recovery_count=0,
                current_status=ServiceStatus.UNKNOWN,
                last_status_change=None,
                current_uptime_seconds=total_seconds,
                current_downtime_seconds=None,
            )

        # Calculate statistics
        total_seconds = days * 24 * 3600
        uptime_seconds = 0
        downtime_seconds = 0
        failure_count = 0
        recovery_count = 0

        # Track periods between events
        failure_times = []
        recovery_times = []
        downtime_durations = []

        current_status = ServiceStatus.UP
        last_event_time = utcnow() - timedelta(days=days)

        for event in events:
            duration = (event.timestamp - last_event_time).total_seconds()

            if current_status == ServiceStatus.UP:
                uptime_seconds += duration
            else:
                downtime_seconds += duration

            # Update status based on event type
            if event.event_type in [UptimeEventType.FAILURE, UptimeEventType.STOP]:
                current_status = ServiceStatus.DOWN
                failure_count += 1
                failure_times.append(event.timestamp)
            elif event.event_type in [
                UptimeEventType.START,
                UptimeEventType.RECOVERY,
                UptimeEventType.RESTART,
            ]:
                if current_status == ServiceStatus.DOWN and failure_times:
                    # Calculate downtime duration
                    downtime_duration = (event.timestamp - failure_times[-1]).total_seconds()
                    downtime_durations.append(downtime_duration)
                current_status = ServiceStatus.UP
                recovery_count += 1
                recovery_times.append(event.timestamp)

            last_event_time = event.timestamp

        # Add time from last event to now
        duration_to_now = (utcnow() - last_event_time).total_seconds()
        if current_status == ServiceStatus.UP:
            uptime_seconds += duration_to_now
        else:
            downtime_seconds += duration_to_now

        # Calculate MTBF (Mean Time Between Failures)
        mtbf = None
        if failure_count > 1:
            time_between_failures = []
            for i in range(1, len(failure_times)):
                time_between_failures.append(
                    (failure_times[i] - failure_times[i - 1]).total_seconds()
                )
            if time_between_failures:
                mtbf = sum(time_between_failures) / len(time_between_failures)

        # Calculate MTTR (Mean Time To Recovery)
        mttr = None
        if downtime_durations:
            mttr = sum(downtime_durations) / len(downtime_durations)

        # Calculate availability percentage
        availability_percent = (uptime_seconds / total_seconds * 100) if total_seconds > 0 else 0

        # Current uptime/downtime
        current_uptime_seconds = None
        current_downtime_seconds = None
        if current_status == ServiceStatus.UP and recovery_times:
            current_uptime_seconds = int((utcnow() - recovery_times[-1]).total_seconds())
        elif current_status == ServiceStatus.DOWN and failure_times:
            current_downtime_seconds = int((utcnow() - failure_times[-1]).total_seconds())

        last_status_change = events[-1].timestamp if events else None

        return UptimeStats(
            service=service,
            machine=machine,
            uptime_seconds=int(uptime_seconds),
            downtime_seconds=int(downtime_seconds),
            total_seconds=total_seconds,
            availability_percent=round(availability_percent, 2),
            mtbf=round(mtbf, 2) if mtbf else None,
            mttr=round(mttr, 2) if mttr else None,
            failure_count=failure_count,
            recovery_count=recovery_count,
            current_status=current_status,
            last_status_change=last_status_change,
            current_uptime_seconds=current_uptime_seconds,
            current_downtime_seconds=current_downtime_seconds,
        )

    def get_service_uptime(self, service: str, machine: str, days: int = 30) -> UptimeStats:
        """
        Get uptime statistics for a service

        Args:
            service: Service name
            machine: Machine hostname
            days: Number of days to analyze

        Returns:
            UptimeStats
        """
        cache_key = f"uptime:{service}:{machine}:{days}"
        cached = self.cache.get(cache_key)
        if cached:
            logger.debug(f"Returning cached uptime for {cache_key}")
            return cached

        stats = self.calculate_availability(service, machine, days)
        self.cache.set(cache_key, stats)
        return stats

    def get_uptime_history(self, service: str, machine: str, days: int = 30) -> UptimeHistory:
        """
        Get uptime history with events and statistics

        Args:
            service: Service name
            machine: Machine hostname
            days: Number of days to query

        Returns:
            UptimeHistory
        """
        events = self._load_events(service, machine, days)
        stats = self.get_service_uptime(service, machine, days)

        return UptimeHistory(
            service=service, machine=machine, events=events, stats=stats, time_range_days=days
        )

    def get_all_uptime(self, days: int = 30) -> UptimeSummary:
        """
        Get uptime summary for all services

        Args:
            days: Number of days to analyze

        Returns:
            UptimeSummary
        """
        cache_key = f"uptime:all:{days}"
        cached = self.cache.get(cache_key)
        if cached:
            logger.debug(f"Returning cached all uptime for {cache_key}")
            return cached

        # Find all service event files
        service_stats = []
        services_up = 0
        services_down = 0

        try:
            for events_file in self.events_dir.glob("*_events.jsonl"):
                # Parse filename: service_machine_events.jsonl
                filename = events_file.stem  # Remove .jsonl
                parts = filename.rsplit("_events", 1)[0].rsplit("_", 1)

                if len(parts) == 2:
                    service, machine = parts
                    stats = self.get_service_uptime(service, machine, days)
                    service_stats.append(stats)

                    if stats.current_status == ServiceStatus.UP:
                        services_up += 1
                    elif stats.current_status == ServiceStatus.DOWN:
                        services_down += 1

        except Exception as e:
            logger.error(f"Failed to get all uptime: {e}")

        # Calculate overall availability
        if service_stats:
            overall_availability = sum(s.availability_percent for s in service_stats) / len(
                service_stats
            )
        else:
            overall_availability = 100.0

        summary = UptimeSummary(
            total_services=len(service_stats),
            services_up=services_up,
            services_down=services_down,
            overall_availability=round(overall_availability, 2),
            services=service_stats,
            timestamp=utcnow(),
        )

        self.cache.set(cache_key, summary)
        return summary

    def get_uptime_summary(self) -> UptimeSummary:
        """
        Get overall system uptime summary (30 days)

        Returns:
            UptimeSummary
        """
        return self.get_all_uptime(days=30)

    def get_timeline(
        self,
        days: int = 7,
        services: Optional[List[str]] = None,
        machines: Optional[List[str]] = None,
    ) -> UptimeTimelineResponse:
        """
        Get uptime timeline for visualization

        Args:
            days: Number of days to visualize
            services: Filter by specific services
            machines: Filter by specific machines

        Returns:
            UptimeTimelineResponse
        """
        end_time = utcnow()
        start_time = end_time - timedelta(days=days)

        timeline_entries = []
        all_services = set()
        all_machines = set()

        try:
            # Process each service
            for events_file in self.events_dir.glob("*_events.jsonl"):
                filename = events_file.stem
                parts = filename.rsplit("_events", 1)[0].rsplit("_", 1)

                if len(parts) != 2:
                    continue

                service, machine = parts

                # Apply filters
                if services and service not in services:
                    continue
                if machines and machine not in machines:
                    continue

                all_services.add(service)
                all_machines.add(machine)

                # Load events for this service
                events = self._load_events(service, machine, days)

                if not events:
                    # No events, assume up for entire period
                    timeline_entries.append(
                        UptimeTimelineEntry(
                            service=service,
                            machine=machine,
                            start_time=start_time,
                            end_time=end_time,
                            status=ServiceStatus.UP,
                            duration_seconds=int((end_time - start_time).total_seconds()),
                            event_type=None,
                        )
                    )
                    continue

                # Build timeline from events
                current_status = ServiceStatus.UP
                period_start = start_time

                for event in events:
                    # Create entry for period before this event
                    if event.timestamp > period_start:
                        timeline_entries.append(
                            UptimeTimelineEntry(
                                service=service,
                                machine=machine,
                                start_time=period_start,
                                end_time=event.timestamp,
                                status=current_status,
                                duration_seconds=int(
                                    (event.timestamp - period_start).total_seconds()
                                ),
                                event_type=None,
                            )
                        )

                    # Update status based on event
                    if event.event_type in [UptimeEventType.FAILURE, UptimeEventType.STOP]:
                        current_status = ServiceStatus.DOWN
                    elif event.event_type in [
                        UptimeEventType.START,
                        UptimeEventType.RECOVERY,
                        UptimeEventType.RESTART,
                    ]:
                        current_status = ServiceStatus.UP

                    period_start = event.timestamp

                # Add final period to now
                if period_start < end_time:
                    timeline_entries.append(
                        UptimeTimelineEntry(
                            service=service,
                            machine=machine,
                            start_time=period_start,
                            end_time=end_time,
                            status=current_status,
                            duration_seconds=int((end_time - period_start).total_seconds()),
                            event_type=None,
                        )
                    )

        except Exception as e:
            logger.error(f"Failed to build timeline: {e}")

        # Get summary
        summary = self.get_all_uptime(days)

        return UptimeTimelineResponse(
            services=sorted(list(all_services)),
            machines=sorted(list(all_machines)),
            entries=timeline_entries,
            start_time=start_time,
            end_time=end_time,
            summary=summary,
        )

    def calculate_mtbf(self, events: List[UptimeEvent]) -> Optional[float]:
        """
        Calculate Mean Time Between Failures

        Args:
            events: List of uptime events

        Returns:
            MTBF in seconds or None
        """
        failure_times = [
            e.timestamp
            for e in events
            if e.event_type in [UptimeEventType.FAILURE, UptimeEventType.STOP]
        ]

        if len(failure_times) < 2:
            return None

        time_between_failures = []
        for i in range(1, len(failure_times)):
            duration = (failure_times[i] - failure_times[i - 1]).total_seconds()
            time_between_failures.append(duration)

        return (
            sum(time_between_failures) / len(time_between_failures)
            if time_between_failures
            else None
        )

    def calculate_mttr(self, events: List[UptimeEvent]) -> Optional[float]:
        """
        Calculate Mean Time To Recovery

        Args:
            events: List of uptime events

        Returns:
            MTTR in seconds or None
        """
        downtime_durations = []
        last_failure_time = None

        for event in sorted(events, key=lambda e: e.timestamp):
            if event.event_type in [UptimeEventType.FAILURE, UptimeEventType.STOP]:
                last_failure_time = event.timestamp
            elif (
                event.event_type in [UptimeEventType.RECOVERY, UptimeEventType.START]
                and last_failure_time
            ):
                duration = (event.timestamp - last_failure_time).total_seconds()
                downtime_durations.append(duration)
                last_failure_time = None

        return sum(downtime_durations) / len(downtime_durations) if downtime_durations else None

    def invalidate_cache(self, service: str = None, machine: str = None):
        """
        Invalidate uptime cache

        Args:
            service: Specific service to invalidate (optional)
            machine: Specific machine to invalidate (optional)
        """
        if service and machine:
            # Invalidate all cache entries for this service
            keys_to_invalidate = [k for k in self.cache.cache.keys() if f"{service}:{machine}" in k]
            for key in keys_to_invalidate:
                self.cache.invalidate(key)
        else:
            self.cache.invalidate()
