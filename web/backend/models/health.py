"""Health monitoring-related data models"""

from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field

from utils.datetime_utils import utcnow


class HealthStatus(str, Enum):
    """Service health status"""

    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"


class ServiceHealth(BaseModel):
    """Health information for a single service"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine where service is running")
    status: HealthStatus = Field(..., description="Current health status")
    health_score: int = Field(..., description="Health score (0-100)")
    issues: List[str] = Field(default_factory=list, description="List of current issues")
    last_checked: datetime = Field(
        default_factory=utcnow, description="When health was last checked"
    )
    uptime_seconds: Optional[float] = Field(None, description="Service uptime in seconds")
    response_time_ms: Optional[float] = Field(
        None, description="Average response time in milliseconds"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "webapp",
                "machine": "prod-server-1",
                "status": "healthy",
                "health_score": 95,
                "issues": [],
                "last_checked": "2025-11-17T10:00:00Z",
                "uptime_seconds": 86400.0,
                "response_time_ms": 120.5,
            }
        }
    )


class MachineHealth(BaseModel):
    """Health information for a machine"""

    machine: str = Field(..., description="Machine name")
    status: HealthStatus = Field(..., description="Overall machine health status")
    services_count: int = Field(..., description="Number of services on this machine")
    healthy_services: int = Field(..., description="Number of healthy services")
    unhealthy_services: int = Field(..., description="Number of unhealthy services")
    cpu_usage: Optional[float] = Field(None, description="CPU usage percentage")
    memory_usage: Optional[float] = Field(None, description="Memory usage percentage")
    disk_usage: Optional[float] = Field(None, description="Disk usage percentage")
    last_checked: datetime = Field(
        default_factory=utcnow, description="When health was last checked"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "machine": "prod-server-1",
                "status": "healthy",
                "services_count": 5,
                "healthy_services": 4,
                "unhealthy_services": 1,
                "cpu_usage": 45.2,
                "memory_usage": 62.8,
                "disk_usage": 78.3,
                "last_checked": "2025-11-17T10:00:00Z",
            }
        }
    )


class ProblemFrequency(BaseModel):
    """Problem frequency statistics"""

    problem_type: str = Field(..., description="Type of problem")
    count: int = Field(..., description="Number of occurrences")
    last_seen: datetime = Field(..., description="When problem was last seen")
    services_affected: List[str] = Field(
        default_factory=list, description="Services affected by this problem"
    )
    severity: str = Field(..., description="Problem severity")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "problem_type": "port_conflict",
                "count": 12,
                "last_seen": "2025-11-17T10:00:00Z",
                "services_affected": ["webapp", "api"],
                "severity": "high",
            }
        }
    )


class HealthDashboard(BaseModel):
    """Complete health dashboard data"""

    overall_status: HealthStatus = Field(..., description="Overall cluster health status")
    overall_health_score: int = Field(..., description="Overall health score (0-100)")
    total_services: int = Field(..., description="Total number of services")
    healthy_services: int = Field(..., description="Number of healthy services")
    degraded_services: int = Field(..., description="Number of degraded services")
    unhealthy_services: int = Field(..., description="Number of unhealthy services")
    total_machines: int = Field(..., description="Total number of machines")
    services: List[ServiceHealth] = Field(
        default_factory=list, description="Health of all services"
    )
    machines: List[MachineHealth] = Field(
        default_factory=list, description="Health of all machines"
    )
    recent_problems: List[ProblemFrequency] = Field(
        default_factory=list, description="Recent problems"
    )
    last_updated: datetime = Field(
        default_factory=utcnow, description="When dashboard was last updated"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "overall_status": "healthy",
                "overall_health_score": 92,
                "total_services": 10,
                "healthy_services": 8,
                "degraded_services": 1,
                "unhealthy_services": 1,
                "total_machines": 3,
                "services": [],
                "machines": [],
                "recent_problems": [],
                "last_updated": "2025-11-17T10:00:00Z",
            }
        }
    )


class HealthEventType(str, Enum):
    """Type of health event"""

    STATUS_CHANGE = "status_change"
    PROBLEM_DETECTED = "problem_detected"
    PROBLEM_RESOLVED = "problem_resolved"
    SERVICE_DEPLOYED = "service_deployed"
    SERVICE_STOPPED = "service_stopped"
    DIAGNOSTIC_RUN = "diagnostic_run"


class HealthEvent(BaseModel):
    """Single health event in timeline"""

    id: str = Field(..., description="Unique event ID")
    event_type: HealthEventType = Field(..., description="Type of event")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine name")
    timestamp: datetime = Field(..., description="When event occurred")
    previous_status: Optional[HealthStatus] = Field(None, description="Previous health status")
    new_status: Optional[HealthStatus] = Field(None, description="New health status")
    message: str = Field(..., description="Event description")
    details: Dict[str, Any] = Field(default_factory=dict, description="Additional event details")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "id": "evt-001",
                "event_type": "status_change",
                "service": "webapp",
                "machine": "prod-server-1",
                "timestamp": "2025-11-17T10:00:00Z",
                "previous_status": "healthy",
                "new_status": "degraded",
                "message": "Service health degraded due to high response time",
                "details": {"response_time_ms": 2500},
            }
        }
    )


class HealthTimeline(BaseModel):
    """Timeline of health events"""

    events: List[HealthEvent] = Field(default_factory=list, description="List of health events")
    total_events: int = Field(..., description="Total number of events")
    start_time: datetime = Field(..., description="Timeline start time")
    end_time: datetime = Field(..., description="Timeline end time")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "events": [],
                "total_events": 0,
                "start_time": "2025-11-17T00:00:00Z",
                "end_time": "2025-11-17T23:59:59Z",
            }
        }
    )


class HeatmapDataPoint(BaseModel):
    """Single data point in heatmap"""

    date: str = Field(..., description="Date (YYYY-MM-DD)")
    service: str = Field(..., description="Service name")
    problem_count: int = Field(..., description="Number of problems on this date")
    severity_breakdown: Dict[str, int] = Field(
        default_factory=dict, description="Count by severity"
    )


class HealthHeatmap(BaseModel):
    """Problem frequency heatmap data"""

    dates: List[str] = Field(default_factory=list, description="List of dates")
    services: List[str] = Field(default_factory=list, description="List of services")
    data_points: List[HeatmapDataPoint] = Field(
        default_factory=list, description="Heatmap data points"
    )
    max_problems_per_day: int = Field(..., description="Maximum problems in a single day")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "dates": ["2025-11-01", "2025-11-02", "2025-11-03"],
                "services": ["webapp", "api", "database"],
                "data_points": [],
                "max_problems_per_day": 5,
            }
        }
    )


class DiagnosticHistory(BaseModel):
    """Historical diagnostic run"""

    id: str = Field(..., description="Diagnostic run ID")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine name")
    timestamp: datetime = Field(..., description="When diagnostic was run")
    health_score: int = Field(..., description="Health score at the time")
    problems_found: int = Field(..., description="Number of problems found")
    problems_resolved: int = Field(..., description="Number of problems resolved")
    duration_seconds: float = Field(..., description="Diagnostic duration")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "id": "diag-001",
                "service": "webapp",
                "machine": "prod-server-1",
                "timestamp": "2025-11-17T10:00:00Z",
                "health_score": 85,
                "problems_found": 2,
                "problems_resolved": 1,
                "duration_seconds": 15.3,
            }
        }
    )
