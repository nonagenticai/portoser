"""Health monitoring service for tracking service and machine health"""

import logging
import os
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

from models.diagnostic import Severity
from models.health import (
    DiagnosticHistory,
    HealthDashboard,
    HealthEvent,
    HealthEventType,
    HealthHeatmap,
    HealthStatus,
    HealthTimeline,
    HeatmapDataPoint,
    MachineHealth,
    ProblemFrequency,
    ServiceHealth,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class HealthMonitor:
    """Service for monitoring and tracking health across services and machines"""

    def __init__(self, cli_service=None):
        """Initialize health monitor with in-memory storage

        Args:
            cli_service: Optional PortoserCLI instance for fetching real health data
        """
        # In production, these would be stored in Redis or a database
        self.service_health: Dict[str, ServiceHealth] = {}
        self.machine_health: Dict[str, MachineHealth] = {}
        self.health_events: List[HealthEvent] = []
        self.problem_frequency: Dict[str, ProblemFrequency] = {}
        self.diagnostic_history: Dict[str, List[DiagnosticHistory]] = {}
        self.cli_service = cli_service

    def get_service_health(self, service: str, machine: str) -> Optional[ServiceHealth]:
        """
        Get health for a specific service

        Args:
            service: Service name
            machine: Machine name

        Returns:
            ServiceHealth or None if not found
        """
        key = f"{service}:{machine}"
        return self.service_health.get(key)

    def update_service_health(
        self,
        service: str,
        machine: str,
        health_score: int,
        issues: List[str] = None,
        uptime_seconds: Optional[float] = None,
        response_time_ms: Optional[float] = None,
    ) -> ServiceHealth:
        """
        Update health for a service

        Args:
            service: Service name
            machine: Machine name
            health_score: Health score (0-100)
            issues: List of current issues
            uptime_seconds: Service uptime
            response_time_ms: Average response time

        Returns:
            Updated ServiceHealth
        """
        key = f"{service}:{machine}"
        issues = issues or []

        # Determine status based on health score
        if health_score >= 90:
            status = HealthStatus.HEALTHY
        elif health_score >= 70:
            status = HealthStatus.DEGRADED
        elif health_score >= 1:
            status = HealthStatus.UNHEALTHY
        else:
            status = HealthStatus.UNKNOWN

        # Get previous health to detect changes
        previous_health = self.service_health.get(key)
        previous_status = previous_health.status if previous_health else None

        # Create updated health
        health = ServiceHealth(
            service=service,
            machine=machine,
            status=status,
            health_score=health_score,
            issues=issues,
            last_checked=utcnow(),
            uptime_seconds=uptime_seconds,
            response_time_ms=response_time_ms,
        )

        self.service_health[key] = health

        # Record status change event if status changed
        if previous_status and previous_status != status:
            self._record_event(
                event_type=HealthEventType.STATUS_CHANGE,
                service=service,
                machine=machine,
                message=f"Service health changed from {previous_status} to {status}",
                previous_status=previous_status,
                new_status=status,
                details={"health_score": health_score, "issues": issues},
            )

        return health

    def get_all_service_health(self) -> List[ServiceHealth]:
        """
        Get health for all services

        Returns:
            List of ServiceHealth for all services
        """
        return list(self.service_health.values())

    def get_machine_health(self, machine: str) -> Optional[MachineHealth]:
        """
        Get health for a specific machine

        Args:
            machine: Machine name

        Returns:
            MachineHealth or None if not found
        """
        return self.machine_health.get(machine)

    def update_machine_health(
        self,
        machine: str,
        cpu_usage: Optional[float] = None,
        memory_usage: Optional[float] = None,
        disk_usage: Optional[float] = None,
    ) -> MachineHealth:
        """
        Update health for a machine

        Args:
            machine: Machine name
            cpu_usage: CPU usage percentage
            memory_usage: Memory usage percentage
            disk_usage: Disk usage percentage

        Returns:
            Updated MachineHealth
        """
        # Get services on this machine
        services_on_machine = [h for h in self.service_health.values() if h.machine == machine]

        services_count = len(services_on_machine)
        healthy_services = sum(1 for h in services_on_machine if h.status == HealthStatus.HEALTHY)
        unhealthy_services = sum(
            1
            for h in services_on_machine
            if h.status in [HealthStatus.UNHEALTHY, HealthStatus.UNKNOWN]
        )

        # Determine overall machine status
        if unhealthy_services > 0:
            status = HealthStatus.UNHEALTHY
        elif services_count > 0 and healthy_services == services_count:
            status = HealthStatus.HEALTHY
        elif services_count > 0:
            status = HealthStatus.DEGRADED
        else:
            status = HealthStatus.UNKNOWN

        health = MachineHealth(
            machine=machine,
            status=status,
            services_count=services_count,
            healthy_services=healthy_services,
            unhealthy_services=unhealthy_services,
            cpu_usage=cpu_usage,
            memory_usage=memory_usage,
            disk_usage=disk_usage,
            last_checked=utcnow(),
        )

        self.machine_health[machine] = health
        return health

    def calculate_health_score(
        self,
        problems: List[Any],
        observations: List[Any] = None,
        base_score: int = 100,
    ) -> int:
        """
        Calculate health score based on problems and observations

        Args:
            problems: List of problems
            observations: List of observations
            base_score: Starting score (default 100)

        Returns:
            Health score (0-100)
        """
        score = base_score
        observations = observations or []

        # Deduct points based on problem severity
        severity_penalties = {
            Severity.CRITICAL: 30,
            Severity.HIGH: 20,
            Severity.MEDIUM: 10,
            Severity.LOW: 5,
            Severity.INFO: 0,
        }

        for problem in problems:
            severity = getattr(problem, "severity", Severity.INFO)
            penalty = severity_penalties.get(severity, 5)
            score -= penalty

        # Additional penalties for specific observation types
        for obs in observations:
            if hasattr(obs, "type"):
                if "service_down" in str(obs.type):
                    score -= 40
                elif "port_conflict" in str(obs.type):
                    score -= 15

        # Ensure score stays in valid range
        return max(0, min(100, score))

    def get_health_dashboard(self) -> HealthDashboard:
        """
        Get complete health dashboard data

        Returns:
            HealthDashboard with all health information
        """
        services = list(self.service_health.values())
        machines = list(self.machine_health.values())

        total_services = len(services)
        healthy_services = sum(1 for s in services if s.status == HealthStatus.HEALTHY)
        degraded_services = sum(1 for s in services if s.status == HealthStatus.DEGRADED)
        unhealthy_services = sum(
            1 for s in services if s.status in [HealthStatus.UNHEALTHY, HealthStatus.UNKNOWN]
        )

        # Calculate overall health score (average of all services)
        if total_services > 0:
            overall_health_score = sum(s.health_score for s in services) // total_services
        else:
            overall_health_score = 100

        # Determine overall status
        if unhealthy_services > 0:
            overall_status = HealthStatus.UNHEALTHY
        elif degraded_services > 0:
            overall_status = HealthStatus.DEGRADED
        elif healthy_services == total_services and total_services > 0:
            overall_status = HealthStatus.HEALTHY
        else:
            overall_status = HealthStatus.UNKNOWN

        # Get recent problems (top 10 by count)
        recent_problems = sorted(
            self.problem_frequency.values(), key=lambda p: p.count, reverse=True
        )[:10]

        return HealthDashboard(
            overall_status=overall_status,
            overall_health_score=overall_health_score,
            total_services=total_services,
            healthy_services=healthy_services,
            degraded_services=degraded_services,
            unhealthy_services=unhealthy_services,
            total_machines=len(machines),
            services=services,
            machines=machines,
            recent_problems=recent_problems,
            last_updated=utcnow(),
        )

    def get_health_timeline(
        self, start_time: Optional[datetime] = None, end_time: Optional[datetime] = None
    ) -> HealthTimeline:
        """
        Get timeline of health events

        Args:
            start_time: Timeline start time (default: 24 hours ago)
            end_time: Timeline end time (default: now)

        Returns:
            HealthTimeline with events in the time range
        """
        if end_time is None:
            end_time = utcnow()
        if start_time is None:
            start_time = end_time - timedelta(hours=24)

        # Filter events by time range
        filtered_events = [e for e in self.health_events if start_time <= e.timestamp <= end_time]

        # Sort by timestamp (newest first)
        filtered_events.sort(key=lambda e: e.timestamp, reverse=True)

        return HealthTimeline(
            events=filtered_events,
            total_events=len(filtered_events),
            start_time=start_time,
            end_time=end_time,
        )

    def get_problem_heatmap(self, days: int = 30) -> HealthHeatmap:
        """
        Get problem frequency heatmap data

        Args:
            days: Number of days to include (default: 30)

        Returns:
            HealthHeatmap with problem frequency data
        """
        end_date = utcnow()
        start_date = end_date - timedelta(days=days)

        # Generate date range
        dates = []
        current_date = start_date
        while current_date <= end_date:
            dates.append(current_date.strftime("%Y-%m-%d"))
            current_date += timedelta(days=1)

        # Get unique services
        services = list(set(s.service for s in self.service_health.values()))

        # Build heatmap data
        data_points = []
        max_problems = 0

        # Group events by date and service
        event_counts = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))

        for event in self.health_events:
            if event.event_type == HealthEventType.PROBLEM_DETECTED:
                date_str = event.timestamp.strftime("%Y-%m-%d")
                if date_str in dates:
                    severity = event.details.get("severity", "info")
                    event_counts[date_str][event.service][severity] += 1

        # Create data points
        for date_str in dates:
            for service in services:
                severity_breakdown = dict(event_counts[date_str][service])
                problem_count = sum(severity_breakdown.values())

                if problem_count > max_problems:
                    max_problems = problem_count

                data_points.append(
                    HeatmapDataPoint(
                        date=date_str,
                        service=service,
                        problem_count=problem_count,
                        severity_breakdown=severity_breakdown,
                    )
                )

        return HealthHeatmap(
            dates=dates,
            services=services,
            data_points=data_points,
            max_problems_per_day=max_problems,
        )

    def record_problem_frequency(self, problem_type: str, service: str, severity: str = "info"):
        """
        Record problem occurrence for frequency tracking

        Args:
            problem_type: Type of problem
            service: Service name
            severity: Problem severity
        """
        if problem_type in self.problem_frequency:
            freq = self.problem_frequency[problem_type]
            freq.count += 1
            freq.last_seen = utcnow()
            if service not in freq.services_affected:
                freq.services_affected.append(service)
        else:
            self.problem_frequency[problem_type] = ProblemFrequency(
                problem_type=problem_type,
                count=1,
                last_seen=utcnow(),
                services_affected=[service],
                severity=severity,
            )

    def get_problem_frequencies(self) -> List[ProblemFrequency]:
        """
        Get all problem frequencies. When the in-memory dict is empty (cold
        start, or demo / read-only deployments) we fall back to the on-disk
        ``~/.portoser/knowledge/problem_frequency.txt`` that the CLI's
        diagnostic runs append to. The format is pipe-separated:

            <iso-timestamp>|<problem_type>|<service>|<severity>

        Same shape KnowledgeBase reads, so the diagnostics page and the
        knowledge insights page agree without each having to seed the other.
        """
        if self.problem_frequency:
            return sorted(self.problem_frequency.values(), key=lambda p: p.count, reverse=True)

        return self._load_problem_frequency_from_disk()

    @staticmethod
    def _load_problem_frequency_from_disk() -> List[ProblemFrequency]:
        kb_dir = (
            os.getenv("KNOWLEDGE_BASE_DIR")
            or os.getenv("KNOWLEDGE_BASE_PATH")
            or str(Path.home() / ".portoser" / "knowledge")
        )
        path = Path(kb_dir) / "problem_frequency.txt"
        if not path.is_file():
            return []

        # problem_type -> {count, last_seen, services_affected, severity}
        agg: Dict[str, Dict[str, Any]] = {}
        try:
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                parts = line.split("|")
                if len(parts) < 3:
                    continue
                ts_raw, problem_type, service = parts[0], parts[1], parts[2]
                severity = parts[3] if len(parts) > 3 else "info"
                try:
                    ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                except ValueError:
                    ts = utcnow()

                entry = agg.setdefault(
                    problem_type,
                    {
                        "count": 0,
                        "last_seen": ts,
                        "services_affected": [],
                        "severity": severity,
                    },
                )
                entry["count"] += 1
                if ts > entry["last_seen"]:
                    entry["last_seen"] = ts
                if service not in entry["services_affected"]:
                    entry["services_affected"].append(service)
                # Promote to most-severe seen so far (info < warning < error).
                rank = {"info": 0, "warning": 1, "error": 2, "critical": 3}
                if rank.get(severity, 0) > rank.get(entry["severity"], 0):
                    entry["severity"] = severity
        except OSError as exc:
            logger.warning("Could not read problem_frequency.txt: %s", exc)
            return []

        rows = [
            ProblemFrequency(
                problem_type=name,
                count=v["count"],
                last_seen=v["last_seen"],
                services_affected=v["services_affected"],
                severity=v["severity"],
            )
            for name, v in agg.items()
        ]
        return sorted(rows, key=lambda p: p.count, reverse=True)

    def add_diagnostic_history(
        self,
        service: str,
        machine: str,
        diagnostic_id: str,
        health_score: int,
        problems_found: int,
        problems_resolved: int,
        duration_seconds: float,
    ):
        """
        Add a diagnostic run to history

        Args:
            service: Service name
            machine: Machine name
            diagnostic_id: Unique diagnostic run ID
            health_score: Health score from diagnostic
            problems_found: Number of problems found
            problems_resolved: Number of problems resolved
            duration_seconds: Diagnostic duration
        """
        key = f"{service}:{machine}"

        history = DiagnosticHistory(
            id=diagnostic_id,
            service=service,
            machine=machine,
            timestamp=utcnow(),
            health_score=health_score,
            problems_found=problems_found,
            problems_resolved=problems_resolved,
            duration_seconds=duration_seconds,
        )

        if key not in self.diagnostic_history:
            self.diagnostic_history[key] = []

        self.diagnostic_history[key].append(history)

        # Keep only last 100 entries per service
        self.diagnostic_history[key] = self.diagnostic_history[key][-100:]

    def get_diagnostic_history(
        self, service: str, machine: str, limit: int = 50
    ) -> List[DiagnosticHistory]:
        """
        Get diagnostic history for a service

        Args:
            service: Service name
            machine: Machine name
            limit: Maximum number of entries to return

        Returns:
            List of DiagnosticHistory entries (newest first)
        """
        key = f"{service}:{machine}"
        history = self.diagnostic_history.get(key, [])

        # Sort by timestamp (newest first) and limit
        history.sort(key=lambda h: h.timestamp, reverse=True)
        return history[:limit]

    def _record_event(
        self,
        event_type: HealthEventType,
        service: str,
        machine: str,
        message: str,
        previous_status: Optional[HealthStatus] = None,
        new_status: Optional[HealthStatus] = None,
        details: Optional[Dict[str, Any]] = None,
    ):
        """
        Record a health event

        Args:
            event_type: Type of event
            service: Service name
            machine: Machine name
            message: Event description
            previous_status: Previous health status (for status changes)
            new_status: New health status (for status changes)
            details: Additional event details
        """
        event = HealthEvent(
            id=f"evt-{len(self.health_events) + 1:06d}",
            event_type=event_type,
            service=service,
            machine=machine,
            timestamp=utcnow(),
            previous_status=previous_status,
            new_status=new_status,
            message=message,
            details=details or {},
        )

        self.health_events.append(event)

        # Keep only last 1000 events
        self.health_events = self.health_events[-1000:]

        logger.info(f"Health event recorded: {message}")

    def record_diagnostic_run(
        self, service: str, machine: str, problems: List[Any], health_score: int
    ):
        """
        Record that a diagnostic was run

        Args:
            service: Service name
            machine: Machine name
            problems: List of problems found
            health_score: Health score from diagnostic
        """
        self._record_event(
            event_type=HealthEventType.DIAGNOSTIC_RUN,
            service=service,
            machine=machine,
            message=f"Diagnostic completed: {len(problems)} problems found, health score: {health_score}",
            details={"problems_count": len(problems), "health_score": health_score},
        )

    def record_problem_detected(self, service: str, machine: str, problem_type: str, severity: str):
        """
        Record that a problem was detected

        Args:
            service: Service name
            machine: Machine name
            problem_type: Type of problem
            severity: Problem severity
        """
        self.record_problem_frequency(problem_type, service, severity)

        self._record_event(
            event_type=HealthEventType.PROBLEM_DETECTED,
            service=service,
            machine=machine,
            message=f"Problem detected: {problem_type}",
            details={"problem_type": problem_type, "severity": severity},
        )

    def record_problem_resolved(self, service: str, machine: str, problem_type: str):
        """
        Record that a problem was resolved

        Args:
            service: Service name
            machine: Machine name
            problem_type: Type of problem
        """
        self._record_event(
            event_type=HealthEventType.PROBLEM_RESOLVED,
            service=service,
            machine=machine,
            message=f"Problem resolved: {problem_type}",
            details={"problem_type": problem_type},
        )

    async def fetch_health_from_cli(
        self, service: Optional[str] = None, machine: Optional[str] = None
    ):
        """
        Fetch health data from CLI and update internal state

        Args:
            service: Optional specific service to check
            machine: Optional specific machine to check

        Returns:
            True if health data was updated, False otherwise
        """
        if not self.cli_service:
            logger.warning("CLI service not available for health checks")
            return False

        try:
            if service and machine:
                # Check specific service on specific machine
                args = ["health", service, machine, "--json-output"]
            elif service:
                # Check all instances of a service
                args = ["health", service, "--json-output"]
            else:
                # Check all services
                args = ["health", "--all", "--json-output"]

            result = await self.cli_service.execute_command(args, parse_json=True)

            if result["success"] and result["parsed_output"]:
                self._process_cli_health_data(result["parsed_output"])
                return True
            else:
                logger.warning(f"Failed to fetch health data: {result.get('error')}")
                return False

        except Exception as e:
            logger.error(f"Error fetching health from CLI: {e}")
            return False

    def _process_cli_health_data(self, health_data: Dict[str, Any]):
        """
        Process health data from CLI and update internal state

        Args:
            health_data: Parsed JSON output from CLI health command
        """
        # Expected format from CLI:
        # {
        #   "services": [
        #     {
        #       "service": "service_name",
        #       "machine": "machine_name",
        #       "status": "healthy|degraded|unhealthy|unknown",
        #       "health_score": 100,
        #       "issues": ["issue1", "issue2"],
        #       "uptime_seconds": 12345,
        #       "response_time_ms": 50
        #     }
        #   ],
        #   "machines": [
        #     {
        #       "machine": "machine_name",
        #       "cpu_usage": 45.2,
        #       "memory_usage": 67.5,
        #       "disk_usage": 30.1
        #     }
        #   ]
        # }

        # Process service health
        for svc_data in health_data.get("services", []):
            self.update_service_health(
                service=svc_data.get("service"),
                machine=svc_data.get("machine"),
                health_score=svc_data.get("health_score", 0),
                issues=svc_data.get("issues", []),
                uptime_seconds=svc_data.get("uptime_seconds"),
                response_time_ms=svc_data.get("response_time_ms"),
            )

        # Process machine health
        for machine_data in health_data.get("machines", []):
            self.update_machine_health(
                machine=machine_data.get("machine"),
                cpu_usage=machine_data.get("cpu_usage"),
                memory_usage=machine_data.get("memory_usage"),
                disk_usage=machine_data.get("disk_usage"),
            )
