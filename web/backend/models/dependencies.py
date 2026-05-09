"""
Dependency models for service dependency graph visualization and management.
"""

from typing import List, Literal

from pydantic import BaseModel, ConfigDict, Field


class DependencyNode(BaseModel):
    """Node in the dependency graph representing a service."""

    id: str = Field(..., description="Service unique identifier")
    label: str = Field(..., description="Display label for the node")
    type: str = Field(..., description="Deployment type (docker, native, local)")
    host: str = Field(..., description="Current host machine")
    hostname: str = Field(..., description="Service hostname (e.g., service.internal)")
    health: str = Field(
        default="unknown",
        description="Health status (healthy, degraded, unhealthy, stopped, unknown)",
    )


class DependencyEdge(BaseModel):
    """Edge in the dependency graph representing a dependency relationship."""

    from_service: str = Field(..., alias="from", description="Source service (depends on target)")
    to_service: str = Field(..., alias="to", description="Target service (dependency)")
    type: Literal["required", "optional"] = Field(default="required", description="Dependency type")

    model_config = ConfigDict(populate_by_name=True)


class DependencyGraph(BaseModel):
    """Complete dependency graph with nodes and edges."""

    nodes: List[DependencyNode] = Field(..., description="List of service nodes")
    edges: List[DependencyEdge] = Field(..., description="List of dependency edges")


class ServiceDependencyInfo(BaseModel):
    """Dependency information for a specific service."""

    name: str = Field(..., description="Service name")
    host: str = Field(..., description="Current host")
    type: str = Field(..., description="Deployment type")


class ServiceDependencies(BaseModel):
    """Dependencies and dependents for a specific service."""

    service: str = Field(..., description="Service name")
    dependencies: List[ServiceDependencyInfo] = Field(
        ..., description="Services this service depends on"
    )
    dependents: List[ServiceDependencyInfo] = Field(
        ..., description="Services that depend on this service"
    )


class DeploymentOrder(BaseModel):
    """Deployment order for a service and its dependencies."""

    service: str = Field(..., description="Target service name")
    deployment_order: List[str] = Field(..., description="Ordered list of services to deploy")
    total_services: int = Field(..., description="Total number of services in deployment order")


class ImpactAnalysis(BaseModel):
    """Impact analysis showing what services are affected if a service goes down."""

    service: str = Field(..., description="Service being analyzed")
    direct_dependents: List[str] = Field(
        ..., description="Services that directly depend on this service"
    )
    all_dependents: List[str] = Field(..., description="All services affected (recursive)")
    impact_level: Literal["low", "medium", "high"] = Field(
        ..., description="Impact level based on dependent count"
    )
    total_affected: int = Field(..., description="Total number of affected services")


class DependencyValidation(BaseModel):
    """Result of dependency validation."""

    valid: bool = Field(..., description="Whether dependencies are valid")
    errors: List[str] = Field(default_factory=list, description="List of validation errors")
    total_errors: int = Field(..., description="Total number of errors")


class AddDependencyRequest(BaseModel):
    """Request to add a dependency."""

    service: str = Field(..., description="Service to add dependency to")
    dependency: str = Field(..., description="Dependency service to add")


class RemoveDependencyRequest(BaseModel):
    """Request to remove a dependency."""

    service: str = Field(..., description="Service to remove dependency from")
    dependency: str = Field(..., description="Dependency service to remove")


class DependencyOperationResponse(BaseModel):
    """Response for add/remove dependency operations."""

    success: bool = Field(..., description="Whether operation succeeded")
    service: str = Field(..., description="Service name")
    dependency: str = Field(..., description="Dependency name")
    message: str = Field(..., description="Result message")


class DependencyList(BaseModel):
    """List of all service dependencies."""

    dependencies: dict[str, List[str]] = Field(
        ..., description="Map of service to its dependencies"
    )
    total_services: int = Field(..., description="Total number of services")
