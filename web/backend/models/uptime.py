"""Models for uptime tracking and availability monitoring"""

from datetime import datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field


class UptimeEventType(str, Enum):
    """Types of uptime events"""

    START = "start"
    STOP = "stop"
    FAILURE = "failure"
    RECOVERY = "recovery"
    RESTART = "restart"
    DEPLOYMENT = "deployment"


class ServiceStatus(str, Enum):
    """Service status states"""

    UP = "up"
    DOWN = "down"
    UNKNOWN = "unknown"


class UptimeEvent(BaseModel):
    """Individual uptime event"""

    timestamp: datetime = Field(..., description="Event timestamp")
    event_type: UptimeEventType = Field(..., description="Type of event")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine hostname")
    details: Optional[str] = Field(None, description="Additional event details")
    metadata: Optional[dict] = Field(None, description="Additional metadata")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "timestamp": "2025-01-15T10:30:00Z",
                "event_type": "start",
                "service": "nginx",
                "machine": "web01",
                "details": "Service started successfully",
                "metadata": {"deployment_id": "dep-123", "version": "1.2.3"},
            }
        }
    )


class UptimeStats(BaseModel):
    """Uptime statistics for a service"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine hostname")
    uptime_seconds: int = Field(..., description="Total uptime in seconds")
    downtime_seconds: int = Field(..., description="Total downtime in seconds")
    total_seconds: int = Field(..., description="Total time period in seconds")
    availability_percent: float = Field(..., description="Availability percentage")
    mtbf: Optional[float] = Field(None, description="Mean Time Between Failures in seconds")
    mttr: Optional[float] = Field(None, description="Mean Time To Recovery in seconds")
    failure_count: int = Field(0, description="Number of failures")
    recovery_count: int = Field(0, description="Number of recoveries")
    current_status: ServiceStatus = Field(..., description="Current service status")
    last_status_change: Optional[datetime] = Field(
        None, description="Timestamp of last status change"
    )
    current_uptime_seconds: Optional[int] = Field(None, description="Current consecutive uptime")
    current_downtime_seconds: Optional[int] = Field(
        None, description="Current consecutive downtime"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "uptime_seconds": 86000,
                "downtime_seconds": 400,
                "total_seconds": 86400,
                "availability_percent": 99.54,
                "mtbf": 43000.0,
                "mttr": 200.0,
                "failure_count": 2,
                "recovery_count": 2,
                "current_status": "up",
                "last_status_change": "2025-01-15T10:30:00Z",
                "current_uptime_seconds": 3600,
                "current_downtime_seconds": None,
            }
        }
    )


class UptimeHistory(BaseModel):
    """Historical uptime events and statistics"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine hostname")
    events: List[UptimeEvent] = Field(..., description="Historical events")
    stats: UptimeStats = Field(..., description="Calculated statistics")
    time_range_days: int = Field(..., description="Time range for history in days")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "events": [],
                "stats": {
                    "service": "nginx",
                    "machine": "web01",
                    "uptime_seconds": 86000,
                    "downtime_seconds": 400,
                    "total_seconds": 86400,
                    "availability_percent": 99.54,
                    "failure_count": 2,
                    "recovery_count": 2,
                    "current_status": "up",
                },
                "time_range_days": 30,
            }
        }
    )


class UptimeSummary(BaseModel):
    """Overall system uptime summary"""

    total_services: int = Field(..., description="Total number of services")
    services_up: int = Field(..., description="Number of services currently up")
    services_down: int = Field(..., description="Number of services currently down")
    overall_availability: float = Field(..., description="Overall system availability percentage")
    services: List[UptimeStats] = Field(..., description="Per-service statistics")
    timestamp: datetime = Field(..., description="Summary timestamp")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "total_services": 10,
                "services_up": 9,
                "services_down": 1,
                "overall_availability": 99.2,
                "services": [],
                "timestamp": "2025-01-15T10:30:00Z",
            }
        }
    )


class UptimeTimelineRequest(BaseModel):
    """Request parameters for uptime timeline visualization"""

    days: int = Field(7, ge=1, le=90, description="Number of days to visualize")
    services: Optional[List[str]] = Field(None, description="Filter by specific services")
    machines: Optional[List[str]] = Field(None, description="Filter by specific machines")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {"days": 7, "services": ["nginx", "postgres"], "machines": ["web01", "db01"]}
        }
    )


class UptimeTimelineEntry(BaseModel):
    """Timeline entry for visualization"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine hostname")
    start_time: datetime = Field(..., description="Period start time")
    end_time: datetime = Field(..., description="Period end time")
    status: ServiceStatus = Field(..., description="Status during this period")
    duration_seconds: int = Field(..., description="Duration of this period")
    event_type: Optional[UptimeEventType] = Field(
        None, description="Event that started this period"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "start_time": "2025-01-15T10:00:00Z",
                "end_time": "2025-01-15T11:00:00Z",
                "status": "up",
                "duration_seconds": 3600,
                "event_type": "start",
            }
        }
    )


class UptimeTimelineResponse(BaseModel):
    """Timeline visualization data"""

    services: List[str] = Field(..., description="List of services in timeline")
    machines: List[str] = Field(..., description="List of machines in timeline")
    entries: List[UptimeTimelineEntry] = Field(..., description="Timeline entries")
    start_time: datetime = Field(..., description="Timeline start time")
    end_time: datetime = Field(..., description="Timeline end time")
    summary: UptimeSummary = Field(..., description="Summary statistics")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "services": ["nginx", "postgres"],
                "machines": ["web01", "db01"],
                "entries": [],
                "start_time": "2025-01-08T00:00:00Z",
                "end_time": "2025-01-15T00:00:00Z",
                "summary": {
                    "total_services": 2,
                    "services_up": 2,
                    "services_down": 0,
                    "overall_availability": 99.8,
                    "services": [],
                    "timestamp": "2025-01-15T10:30:00Z",
                },
            }
        }
    )


class UptimeEventCreate(BaseModel):
    """Request to create/record an uptime event"""

    event_type: UptimeEventType = Field(..., description="Type of event")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine hostname")
    details: Optional[str] = Field(None, description="Event details")
    metadata: Optional[dict] = Field(None, description="Additional metadata")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "event_type": "start",
                "service": "nginx",
                "machine": "web01",
                "details": "Service started after deployment",
                "metadata": {"deployment_id": "dep-123"},
            }
        }
    )


class UptimeEventsResponse(BaseModel):
    """Response for paginated uptime events"""

    events: List[UptimeEvent] = Field(..., description="List of uptime events")
    total: int = Field(..., description="Total number of events")
    limit: int = Field(..., description="Number of events per page")
    offset: int = Field(..., description="Offset for pagination")
    hasMore: bool = Field(  # noqa: N815  # JSON contract: serialized as `hasMore` for the JS frontend
        ..., description="Whether there are more events to load"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "events": [
                    {
                        "timestamp": "2025-01-15T10:30:00Z",
                        "event_type": "start",
                        "service": "nginx",
                        "machine": "web01",
                        "details": "Service started successfully",
                    }
                ],
                "total": 100,
                "limit": 50,
                "offset": 0,
                "hasMore": True,
            }
        }
    )
