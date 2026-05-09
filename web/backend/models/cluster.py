"""Pydantic models for Cluster API"""

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field

# =============================================================================
# BUILD MODELS
# =============================================================================


class BuildRequest(BaseModel):
    """Request to build Docker images."""

    services: List[str] = Field(..., description="List of service names to build", min_length=1)
    rebuild: bool = Field(False, description="Whether to rebuild without cache")
    batch_size: int = Field(4, description="Number of parallel builds", ge=1, le=8)


class BuildResponse(BaseModel):
    """Response when build is triggered."""

    build_id: str = Field(..., description="Unique build identifier")
    services: List[str] = Field(..., description="Services being built")
    status: str = Field(..., description="Build status: pending, running, completed, failed")


class BuildStatus(BaseModel):
    """Detailed build status."""

    build_id: str = Field(..., description="Build identifier")
    services: List[str] = Field(..., description="Services in this build")
    status: str = Field(..., description="Current status")
    started_at: str = Field(..., description="ISO timestamp when build started")
    completed_at: Optional[str] = Field(None, description="ISO timestamp when build completed")
    output: List[str] = Field(default_factory=list, description="Build output lines")
    error: Optional[str] = Field(None, description="Error message if failed")


# =============================================================================
# DEPLOYMENT MODELS
# =============================================================================


class DeployRequest(BaseModel):
    """Request to deploy services to Pi."""

    pi: str = Field(..., description="Target Pi: pi1, pi2, pi3, pi4", pattern="^pi[1-4]$")
    services: List[str] = Field(..., description="List of service names to deploy", min_length=1)


class DeployResponse(BaseModel):
    """Response when deployment is triggered."""

    deployment_id: str = Field(..., description="Unique deployment identifier")
    pi: str = Field(..., description="Target Pi")
    services: List[str] = Field(..., description="Services being deployed")
    status: str = Field(..., description="Deployment status: pending, running, completed, failed")


class DeployStatus(BaseModel):
    """Detailed deployment status."""

    deployment_id: str = Field(..., description="Deployment identifier")
    pi: str = Field(..., description="Target Pi")
    services: List[str] = Field(..., description="Services in this deployment")
    status: str = Field(..., description="Current status")
    started_at: str = Field(..., description="ISO timestamp when deployment started")
    completed_at: Optional[str] = Field(None, description="ISO timestamp when deployment completed")
    output: List[str] = Field(default_factory=list, description="Deployment output lines")
    error: Optional[str] = Field(None, description="Error message if failed")


# =============================================================================
# SYNC MODELS
# =============================================================================


class SyncRequest(BaseModel):
    """Request to sync Pi directories."""

    pis: List[str] = Field(..., description="List of Pis to sync", min_length=1)

    model_config = ConfigDict(json_schema_extra={"example": {"pis": ["pi1", "pi2"]}})


class SyncResponse(BaseModel):
    """Response from sync operation."""

    sync_id: str = Field(..., description="Unique sync identifier")
    pis: List[str] = Field(..., description="Pis being synced")
    status: str = Field(..., description="Sync status")
    results: Dict[str, Any] = Field(default_factory=dict, description="Per-Pi sync results")


# =============================================================================
# CLEAN MODELS
# =============================================================================


class CleanRequest(BaseModel):
    """Request to clean Pi Docker resources."""

    pis: List[str] = Field(..., description="List of Pis to clean", min_length=1)
    dry_run: bool = Field(False, description="If true, only show what would be cleaned")

    model_config = ConfigDict(json_schema_extra={"example": {"pis": ["pi1"], "dry_run": True}})


class CleanResponse(BaseModel):
    """Response from clean operation."""

    clean_id: str = Field(..., description="Unique clean identifier")
    pis: List[str] = Field(..., description="Pis being cleaned")
    dry_run: bool = Field(..., description="Whether this was a dry run")
    status: str = Field(..., description="Clean status")
    results: Dict[str, Any] = Field(default_factory=dict, description="Per-Pi clean results")


# =============================================================================
# HEALTH MODELS
# =============================================================================


class PiHealth(BaseModel):
    """Health status for a single Pi."""

    pi: str = Field(..., description="Pi identifier")
    status: str = Field(..., description="Status: healthy, degraded, unhealthy, unknown")
    services: List[str] = Field(default_factory=list, description="Services running on this Pi")
    last_checked: Optional[str] = Field(None, description="ISO timestamp of last check")


class ClusterHealth(BaseModel):
    """Overall cluster health status."""

    overall_status: str = Field(..., description="Overall health: healthy, degraded, unhealthy")
    pis: List[PiHealth] = Field(default_factory=list, description="Health of each Pi")
    timestamp: str = Field(..., description="ISO timestamp of this health check")


# =============================================================================
# DISCOVERY MODELS
# =============================================================================


class ServiceInfo(BaseModel):
    """Information about a discovered service."""

    name: str = Field(..., description="Service name")
    hostname: Optional[str] = Field(None, description="Service hostname")
    current_host: Optional[str] = Field(None, description="Current host machine")
    deployment_type: str = Field(..., description="Deployment type: docker, native, local")
    docker_compose: Optional[str] = Field(None, description="Path to docker-compose file")
    service_file: Optional[str] = Field(None, description="Path to systemd service file")


class ServiceDiscovery(BaseModel):
    """List of discovered services."""

    services: List[ServiceInfo] = Field(default_factory=list, description="Discovered services")
    total: int = Field(..., description="Total number of services")


# =============================================================================
# BUILDX MODELS
# =============================================================================


class BuildxResponse(BaseModel):
    """Response from buildx setup."""

    success: bool = Field(..., description="Whether setup was successful")
    output: Optional[str] = Field(None, description="Setup output")
    error: Optional[str] = Field(None, description="Error message if failed")


# =============================================================================
# STATUS MODELS
# =============================================================================


class BuildCapacity(BaseModel):
    """Build capacity information."""

    running_builds: int = Field(..., description="Number of currently running builds")
    max_parallel: int = Field(..., description="Maximum parallel builds allowed")


class DeploymentStatus(BaseModel):
    """Deployment status information."""

    running_deployments: int = Field(..., description="Number of currently running deployments")


class ClusterStatus(BaseModel):
    """Overall cluster status."""

    build_capacity: BuildCapacity = Field(..., description="Build capacity information")
    deployment_status: DeploymentStatus = Field(..., description="Deployment status information")
    health: Dict[str, Any] = Field(default_factory=dict, description="Health information")
    services: Dict[str, Any] = Field(default_factory=dict, description="Service information")
    timestamp: str = Field(..., description="ISO timestamp")
