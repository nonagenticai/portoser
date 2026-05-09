"""History models for deployment tracking and rollback"""

from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class DeploymentStatus(str, Enum):
    """Deployment status values"""

    SUCCESS = "success"
    FAILURE = "failure"
    ROLLED_BACK = "rolled_back"


class DeploymentAction(str, Enum):
    """Deployment action types"""

    DEPLOY = "deploy"
    RESTART = "restart"
    MIGRATE = "migrate"
    ROLLBACK = "rollback"


class DeploymentPhaseRecord(BaseModel):
    """Individual phase within a deployment"""

    name: str
    status: str
    duration_ms: int
    metadata: Dict[str, Any] = Field(default_factory=dict)


class DeploymentObservation(BaseModel):
    """Observation made during deployment"""

    type: str
    message: str
    severity: str = "info"
    timestamp: str


class DeploymentProblem(BaseModel):
    """Problem identified during deployment"""

    fingerprint: str
    description: str
    timestamp: str


class DeploymentSolution(BaseModel):
    """Solution applied during deployment"""

    fingerprint: str
    action: str
    result: str
    timestamp: str


class DeploymentRecord(BaseModel):
    """Complete deployment record"""

    id: str
    timestamp: str
    service: str
    machine: str
    action: DeploymentAction
    status: DeploymentStatus
    duration_ms: int
    phases: List[DeploymentPhaseRecord] = Field(default_factory=list)
    observations: List[DeploymentObservation] = Field(default_factory=list)
    problems: List[DeploymentProblem] = Field(default_factory=list)
    solutions_applied: List[DeploymentSolution] = Field(default_factory=list)
    config_snapshot: Dict[str, Any] = Field(default_factory=dict)
    exit_code: int = 0


class DeploymentListResponse(BaseModel):
    """Response for listing deployments"""

    deployments: List[DeploymentRecord]
    total: int
    filtered: int = 0
    service_filter: Optional[str] = None
    limit: int = 50
    offset: int = 0


class DeploymentTimeline(BaseModel):
    """Timeline entry for deployment"""

    id: str
    service: str
    machine: str
    action: DeploymentAction
    status: DeploymentStatus
    timestamp: str
    duration_ms: int
    problems_count: int = 0
    solutions_count: int = 0


class DeploymentTimelineResponse(BaseModel):
    """Timeline view of deployments grouped by date"""

    timeline: Dict[str, List[DeploymentTimeline]]
    total: int


class DeploymentStats(BaseModel):
    """Deployment statistics"""

    total: int
    success: int
    failure: int
    rolled_back: int = 0
    success_rate: float
    avg_duration_ms: int
    days: int = 30
    by_service: Optional[Dict[str, Dict[str, Any]]] = None
    recent_failures: Optional[List[str]] = None


class RollbackRequest(BaseModel):
    """Request to rollback to a deployment"""

    confirm: bool = False
    dry_run: bool = False


class ConfigDiff(BaseModel):
    """Configuration difference"""

    field: str
    current_value: Any
    target_value: Any
    change_type: str  # added, removed, modified


class RollbackPreview(BaseModel):
    """Preview of rollback changes"""

    deployment_id: str
    service: str
    machine: str
    current_config: Dict[str, Any]
    target_config: Dict[str, Any]
    differences: List[ConfigDiff]
    warnings: List[str] = Field(default_factory=list)
    safe_to_rollback: bool = True


class RollbackResult(BaseModel):
    """Result of rollback execution"""

    success: bool
    deployment_id: str
    rollback_deployment_id: Optional[str] = None
    message: str
    error: Optional[str] = None
