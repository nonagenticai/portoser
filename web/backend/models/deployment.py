"""Deployment-related data models"""

from datetime import datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field


class PhaseStatus(str, Enum):
    """Status of a deployment phase"""

    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"
    SKIPPED = "skipped"


class DeploymentRequest(BaseModel):
    """Request to execute intelligent deployment"""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "service": "webapp",
                "machine": "prod-server-1",
                "auto_heal": True,
                "dry_run": False,
            }
        }
    )

    service: str = Field(..., description="Service name to deploy")
    machine: str = Field(..., description="Target machine for deployment")
    auto_heal: bool = Field(default=False, description="Enable auto-healing if problems detected")
    dry_run: bool = Field(default=False, description="Preview deployment without executing")


class DryRunRequest(BaseModel):
    """Request to preview deployment"""

    model_config = ConfigDict(
        json_schema_extra={"example": {"service": "webapp", "machine": "prod-server-1"}}
    )

    service: str = Field(..., description="Service name to deploy")
    machine: str = Field(..., description="Target machine for deployment")


class DeploymentPhase(BaseModel):
    """Single phase of a deployment"""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "name": "Health Check",
                "status": "completed",
                "started_at": "2025-11-17T10:00:00Z",
                "completed_at": "2025-11-17T10:00:05Z",
                "duration_seconds": 5.2,
                "output": ["Checking service health...", "Service is healthy"],
                "steps": ["Connect to machine", "Check service status", "Verify health endpoint"],
            }
        }
    )

    name: str = Field(..., description="Phase name")
    status: PhaseStatus = Field(default=PhaseStatus.PENDING, description="Phase status")
    started_at: Optional[datetime] = Field(None, description="When phase started")
    completed_at: Optional[datetime] = Field(None, description="When phase completed")
    duration_seconds: Optional[float] = Field(None, description="Phase duration in seconds")
    output: List[str] = Field(default_factory=list, description="Phase output lines")
    error: Optional[str] = Field(None, description="Error message if phase failed")
    steps: List[str] = Field(default_factory=list, description="Steps executed in this phase")


class DeploymentResult(BaseModel):
    """Complete deployment result"""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "deployment_id": "deploy-20251117-100000",
                "service": "webapp",
                "machine": "prod-server-1",
                "status": "completed",
                "started_at": "2025-11-17T10:00:00Z",
                "completed_at": "2025-11-17T10:05:30Z",
                "duration_seconds": 330.5,
                "phases": [],
                "auto_heal_applied": False,
                "problems_detected": [],
                "solutions_applied": [],
                "dry_run": False,
                "success": True,
            }
        }
    )

    deployment_id: str = Field(..., description="Unique deployment identifier")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Target machine")
    status: str = Field(..., description="Overall deployment status")
    started_at: datetime = Field(..., description="Deployment start time")
    completed_at: Optional[datetime] = Field(None, description="Deployment completion time")
    duration_seconds: Optional[float] = Field(None, description="Total deployment duration")
    phases: List[DeploymentPhase] = Field(default_factory=list, description="Deployment phases")
    auto_heal_applied: bool = Field(default=False, description="Whether auto-healing was triggered")
    problems_detected: List[str] = Field(
        default_factory=list, description="Problems detected during deployment"
    )
    solutions_applied: List[str] = Field(
        default_factory=list, description="Solutions that were applied"
    )
    dry_run: bool = Field(default=False, description="Whether this was a dry run")
    success: bool = Field(..., description="Whether deployment succeeded")
    error: Optional[str] = Field(None, description="Error message if deployment failed")


class PhaseBreakdown(BaseModel):
    """Detailed phase breakdown for a deployment"""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "deployment_id": "deploy-20251117-100000",
                "service": "webapp",
                "machine": "prod-server-1",
                "total_phases": 4,
                "completed_phases": 2,
                "current_phase": "Deployment",
                "phases": [],
            }
        }
    )

    deployment_id: str = Field(..., description="Deployment identifier")
    service: str = Field(..., description="Service name")
    machine: str = Field(..., description="Target machine")
    total_phases: int = Field(..., description="Total number of phases")
    completed_phases: int = Field(..., description="Number of completed phases")
    current_phase: Optional[str] = Field(None, description="Currently executing phase")
    phases: List[DeploymentPhase] = Field(default_factory=list, description="All phases")
