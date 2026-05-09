"""Diagnostic-related data models"""

from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field

from utils.datetime_utils import utcnow


class Severity(str, Enum):
    """Severity level of a problem"""

    CRITICAL = "critical"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    INFO = "info"


class ObservationType(str, Enum):
    """Type of observation"""

    PORT_CONFLICT = "port_conflict"
    SERVICE_DOWN = "service_down"
    DEPENDENCY_MISSING = "dependency_missing"
    PERMISSION_ERROR = "permission_error"
    NETWORK_ISSUE = "network_issue"
    DISK_SPACE = "disk_space"
    MEMORY_ISSUE = "memory_issue"
    CONFIGURATION_ERROR = "configuration_error"
    OTHER = "other"


class DiagnosticRequest(BaseModel):
    """Request to run diagnostics"""

    model_config = ConfigDict(
        json_schema_extra={"example": {"service": "webapp", "machine": "prod-server-1"}}
    )

    service: str = Field(..., description="Service name to diagnose")
    machine: str = Field(..., description="Machine where service is running")


class Observation(BaseModel):
    """Single diagnostic observation"""

    type: ObservationType = Field(..., description="Type of observation")
    severity: Severity = Field(..., description="Severity level")
    message: str = Field(..., description="Human-readable observation message")
    details: Dict[str, Any] = Field(default_factory=dict, description="Additional details")
    timestamp: datetime = Field(default_factory=utcnow, description="When observation was made")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "type": "port_conflict",
                "severity": "high",
                "message": "Port 8080 is already in use by another process",
                "details": {"port": 8080, "process": "nginx", "pid": 1234},
                "timestamp": "2025-11-17T10:00:00Z",
            }
        }
    )


class Problem(BaseModel):
    """Identified problem with potential solutions"""

    id: str = Field(..., description="Unique problem identifier")
    title: str = Field(..., description="Problem title")
    description: str = Field(..., description="Detailed problem description")
    severity: Severity = Field(..., description="Severity level")
    observations: List[Observation] = Field(
        default_factory=list, description="Related observations"
    )
    affected_components: List[str] = Field(default_factory=list, description="Affected components")
    timestamp: datetime = Field(default_factory=utcnow, description="When problem was identified")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "id": "prob-001",
                "title": "Port Conflict Detected",
                "description": "Service cannot start because port 8080 is already in use",
                "severity": "high",
                "observations": [],
                "affected_components": ["webapp", "nginx"],
                "timestamp": "2025-11-17T10:00:00Z",
            }
        }
    )


class Solution(BaseModel):
    """Proposed solution to a problem"""

    id: str = Field(..., description="Unique solution identifier")
    problem_id: str = Field(..., description="ID of the problem this solves")
    title: str = Field(..., description="Solution title")
    description: str = Field(..., description="What this solution will do")
    steps: List[str] = Field(default_factory=list, description="Steps to apply solution")
    risk_level: str = Field(..., description="Risk level: low, medium, high")
    auto_apply: bool = Field(default=False, description="Whether solution can be auto-applied")
    requires_confirmation: bool = Field(
        default=True, description="Whether user confirmation is needed"
    )
    estimated_duration: Optional[int] = Field(None, description="Estimated duration in seconds")
    command: Optional[str] = Field(None, description="Command to execute (if applicable)")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "id": "sol-001",
                "problem_id": "prob-001",
                "title": "Stop conflicting process",
                "description": "Stop the nginx process using port 8080",
                "steps": [
                    "Identify process using port 8080",
                    "Stop the process gracefully",
                    "Verify port is available",
                ],
                "risk_level": "medium",
                "auto_apply": False,
                "requires_confirmation": True,
                "estimated_duration": 10,
                "command": "sudo systemctl stop nginx",
            }
        }
    )


class DiagnosticResult(BaseModel):
    """Complete diagnostic result"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine name")
    started_at: datetime = Field(..., description="When diagnostics started")
    completed_at: Optional[datetime] = Field(None, description="When diagnostics completed")
    duration_seconds: Optional[float] = Field(None, description="Diagnostic duration")
    observations: List[Observation] = Field(default_factory=list, description="All observations")
    problems: List[Problem] = Field(default_factory=list, description="Identified problems")
    solutions: List[Solution] = Field(default_factory=list, description="Proposed solutions")
    health_score: int = Field(..., description="Overall health score (0-100)")
    success: bool = Field(..., description="Whether diagnostics completed successfully")
    error: Optional[str] = Field(None, description="Error message if diagnostics failed")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "webapp",
                "machine": "prod-server-1",
                "started_at": "2025-11-17T10:00:00Z",
                "completed_at": "2025-11-17T10:00:15Z",
                "duration_seconds": 15.3,
                "observations": [],
                "problems": [],
                "solutions": [],
                "health_score": 85,
                "success": True,
            }
        }
    )


class ApplyFixRequest(BaseModel):
    """Request to apply a specific solution"""

    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Machine name")
    solution_id: str = Field(..., description="Solution ID to apply")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {"service": "webapp", "machine": "prod-server-1", "solution_id": "sol-001"}
        }
    )


class ApplyFixResult(BaseModel):
    """Result of applying a fix"""

    solution_id: str = Field(..., description="Solution ID that was applied")
    success: bool = Field(..., description="Whether fix was applied successfully")
    output: List[str] = Field(default_factory=list, description="Output from applying fix")
    error: Optional[str] = Field(None, description="Error message if fix failed")
    duration_seconds: Optional[float] = Field(None, description="Time taken to apply fix")
    verification_passed: bool = Field(
        default=False, description="Whether verification checks passed"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "solution_id": "sol-001",
                "success": True,
                "output": ["Stopping nginx...", "Port 8080 is now available"],
                "duration_seconds": 5.2,
                "verification_passed": True,
            }
        }
    )
