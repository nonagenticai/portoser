"""Models for resource metrics and monitoring"""

from datetime import datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator


class MetricsTimeRange(str, Enum):
    """Time range options for metrics queries"""

    HOUR = "1h"
    SIX_HOURS = "6h"
    DAY = "24h"
    WEEK = "7d"
    MONTH = "30d"


class MetricsInterval(str, Enum):
    """Interval options for historical data aggregation"""

    ONE_MINUTE = "1m"
    FIVE_MINUTES = "5m"
    FIFTEEN_MINUTES = "15m"
    ONE_HOUR = "1h"


class ResourceMetrics(BaseModel):
    """Resource metrics for a service at a point in time"""

    service: str = Field(default="", description="Service name")
    machine: str = Field(default="", description="Machine hostname")
    timestamp: datetime = Field(..., description="Measurement timestamp")
    cpu_percent: float = Field(default=0.0, ge=0.0, le=100.0, description="CPU usage percentage")
    memory_mb: float = Field(default=0.0, ge=0.0, description="Memory usage in MB")
    memory_total_mb: float = Field(default=0.0, ge=0.0, description="Total memory available in MB")
    disk_gb: float = Field(default=0.0, ge=0.0, description="Disk usage in GB")
    disk_total_gb: float = Field(default=0.0, ge=0.0, description="Total disk space in GB")
    network_rx_bytes: int = Field(default=0, ge=0, description="Network bytes received")
    network_tx_bytes: int = Field(default=0, ge=0, description="Network bytes transmitted")

    @field_validator("cpu_percent", mode="before")
    @classmethod
    def validate_cpu_percent(cls, v):
        """Ensure cpu_percent is never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, min(100.0, val))  # Clamp between 0 and 100
        except (ValueError, TypeError):
            return 0.0

    @field_validator("memory_mb", "memory_total_mb", "disk_gb", "disk_total_gb", mode="before")
    @classmethod
    def validate_positive_float(cls, v):
        """Ensure positive float fields are never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, val)  # Ensure non-negative
        except (ValueError, TypeError):
            return 0.0

    @field_validator("network_rx_bytes", "network_tx_bytes", mode="before")
    @classmethod
    def validate_positive_int(cls, v):
        """Ensure positive int fields are never None/undefined"""
        if v is None or v == "":
            return 0
        try:
            val = int(v)
            return max(0, val)  # Ensure non-negative
        except (ValueError, TypeError):
            return 0

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "timestamp": "2025-01-15T10:30:00Z",
                "cpu_percent": 15.5,
                "memory_mb": 256.0,
                "memory_total_mb": 2048.0,
                "disk_gb": 5.2,
                "disk_total_gb": 100.0,
                "network_rx_bytes": 1024000,
                "network_tx_bytes": 2048000,
            }
        }
    )


class ServiceMetrics(BaseModel):
    """Current and historical metrics for a service"""

    service: str = Field(default="", description="Service name")
    machine: str = Field(default="", description="Machine hostname")
    current: Optional[ResourceMetrics] = Field(default=None, description="Current metrics snapshot")
    history: List[ResourceMetrics] = Field(
        default_factory=list, description="Historical measurements"
    )
    avg_cpu: float = Field(
        default=0.0, ge=0.0, le=100.0, description="Average CPU usage percentage"
    )
    avg_memory: float = Field(default=0.0, ge=0.0, description="Average memory usage in MB")
    peak_cpu: float = Field(default=0.0, ge=0.0, le=100.0, description="Peak CPU usage percentage")
    peak_memory: float = Field(default=0.0, ge=0.0, description="Peak memory usage in MB")
    time_range: str = Field(default="1h", description="Time range for metrics")

    @field_validator("avg_cpu", "peak_cpu", mode="before")
    @classmethod
    def validate_cpu_metrics(cls, v):
        """Ensure CPU metrics are never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, min(100.0, val))  # Clamp between 0 and 100
        except (ValueError, TypeError):
            return 0.0

    @field_validator("avg_memory", "peak_memory", mode="before")
    @classmethod
    def validate_memory_metrics(cls, v):
        """Ensure memory metrics are never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, val)  # Ensure non-negative
        except (ValueError, TypeError):
            return 0.0

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "current": {
                    "service": "nginx",
                    "machine": "web01",
                    "timestamp": "2025-01-15T10:30:00Z",
                    "cpu_percent": 15.5,
                    "memory_mb": 256.0,
                    "memory_total_mb": 2048.0,
                    "disk_gb": 5.2,
                    "disk_total_gb": 100.0,
                },
                "history": [],
                "avg_cpu": 12.3,
                "avg_memory": 240.0,
                "peak_cpu": 25.0,
                "peak_memory": 320.0,
                "time_range": "1h",
            }
        }
    )


class MachineMetrics(BaseModel):
    """Aggregated metrics for all services on a machine"""

    machine: str = Field(default="", description="Machine hostname")
    cpu_percent: float = Field(
        default=0.0, ge=0.0, le=100.0, description="Total CPU usage percentage"
    )
    memory_used_mb: float = Field(default=0.0, ge=0.0, description="Total memory used in MB")
    memory_total_mb: float = Field(default=0.0, ge=0.0, description="Total memory available in MB")
    memory_percent: float = Field(
        default=0.0, ge=0.0, le=100.0, description="Memory usage percentage"
    )
    disk_used_gb: float = Field(default=0.0, ge=0.0, description="Total disk used in GB")
    disk_total_gb: float = Field(default=0.0, ge=0.0, description="Total disk space in GB")
    disk_percent: float = Field(default=0.0, ge=0.0, le=100.0, description="Disk usage percentage")
    services: List[ResourceMetrics] = Field(
        default_factory=list, description="Metrics for each service"
    )
    timestamp: datetime = Field(..., description="Measurement timestamp")
    status: str = Field(default="ok", description="Status: ok, error, unavailable")
    error: str = Field(default="", description="Error message if metrics unavailable")

    @field_validator("cpu_percent", "memory_percent", "disk_percent", mode="before")
    @classmethod
    def validate_percentage(cls, v):
        """Ensure percentage fields are never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, min(100.0, val))  # Clamp between 0 and 100
        except (ValueError, TypeError):
            return 0.0

    @field_validator(
        "memory_used_mb", "memory_total_mb", "disk_used_gb", "disk_total_gb", mode="before"
    )
    @classmethod
    def validate_positive_metrics(cls, v):
        """Ensure positive metric fields are never None/undefined"""
        if v is None or v == "":
            return 0.0
        try:
            val = float(v)
            return max(0.0, val)  # Ensure non-negative
        except (ValueError, TypeError):
            return 0.0

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "machine": "web01",
                "cpu_percent": 45.0,
                "memory_used_mb": 1024.0,
                "memory_total_mb": 2048.0,
                "memory_percent": 50.0,
                "disk_used_gb": 25.0,
                "disk_total_gb": 100.0,
                "disk_percent": 25.0,
                "services": [],
                "timestamp": "2025-01-15T10:30:00Z",
                "status": "ok",
                "error": "",
            }
        }
    )


class MetricsSnapshot(BaseModel):
    """Snapshot request/response for immediate metrics collection"""

    service: str = Field(default="", description="Service to snapshot (optional)")
    machine: str = Field(default="", description="Machine to snapshot (optional)")
    all: bool = Field(default=False, description="Snapshot all services")
    status: str = Field(default="pending", description="Snapshot status")
    message: str = Field(default="", description="Status message")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "all": False,
                "status": "completed",
                "message": "Metrics snapshot collected successfully",
            }
        }
    )


class MetricsHistoryRequest(BaseModel):
    """Request parameters for historical metrics query"""

    time_range: MetricsTimeRange = Field(MetricsTimeRange.DAY, description="Time range to query")
    interval: MetricsInterval = Field(
        MetricsInterval.FIFTEEN_MINUTES, description="Data aggregation interval"
    )

    model_config = ConfigDict(
        json_schema_extra={"example": {"time_range": "24h", "interval": "15m"}}
    )


class MetricsHistoryResponse(BaseModel):
    """Historical metrics data with aggregations"""

    service: str = Field(default="", description="Service name")
    machine: str = Field(default="", description="Machine hostname")
    time_range: str = Field(default="24h", description="Time range queried")
    interval: str = Field(default="15m", description="Data aggregation interval")
    data_points: List[ResourceMetrics] = Field(
        default_factory=list, description="Historical data points"
    )
    summary: dict = Field(default_factory=dict, description="Summary statistics")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "nginx",
                "machine": "web01",
                "time_range": "24h",
                "interval": "15m",
                "data_points": [],
                "summary": {
                    "avg_cpu": 15.5,
                    "max_cpu": 35.0,
                    "min_cpu": 5.0,
                    "avg_memory": 256.0,
                    "max_memory": 320.0,
                    "min_memory": 200.0,
                },
            }
        }
    )
