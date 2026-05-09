"""
Dependencies API router for service dependency visualization and management.
"""

from fastapi import APIRouter, Depends, HTTPException

from auth.dependencies import require_any_role
from auth.models import KeycloakUser
from models.dependencies import (
    AddDependencyRequest,
    DependencyGraph,
    DependencyList,
    DependencyOperationResponse,
    DependencyValidation,
    DeploymentOrder,
    ImpactAnalysis,
    RemoveDependencyRequest,
    ServiceDependencies,
)
from services.dependency_service import DependencyService

router = APIRouter(prefix="/api/dependencies", tags=["dependencies"])


def get_dependency_service() -> DependencyService:
    """Dependency injection for DependencyService."""
    return DependencyService()


@router.get("/graph", response_model=DependencyGraph)
async def get_dependency_graph(
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Get complete dependency graph with nodes and edges.

    Returns:
        DependencyGraph: Graph with all services (nodes) and their dependencies (edges)
    """
    try:
        return await service.get_dependency_graph()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/service/{name}", response_model=ServiceDependencies)
async def get_service_dependencies(
    name: str,
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Get dependencies for a specific service.

    Args:
        name: Service name

    Returns:
        ServiceDependencies: Service dependencies and dependents
    """
    try:
        return await service.get_service_dependencies(name)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/deployment-order/{service_name}", response_model=DeploymentOrder)
async def get_deployment_order(
    service_name: str,
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Get deployment order for a service and its dependencies.

    Uses topological sort to determine the correct order to deploy services.

    Args:
        service_name: Service name

    Returns:
        DeploymentOrder: Ordered list of services to deploy
    """
    try:
        return await service.calculate_deployment_order(service_name)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/validate", response_model=DependencyValidation)
async def validate_dependencies(
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Validate all dependencies.

    Checks for:
    - Circular dependencies
    - Missing services
    - Invalid dependency configurations

    Returns:
        DependencyValidation: Validation result with any errors
    """
    try:
        return await service.validate_dependencies()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/add", response_model=DependencyOperationResponse)
async def add_dependency(
    request: AddDependencyRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Add a dependency to a service.

    Args:
        request: Add dependency request with service and dependency names

    Returns:
        DependencyOperationResponse: Result of the operation
    """
    try:
        return await service.add_dependency(request.service, request.dependency)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/remove", response_model=DependencyOperationResponse)
async def remove_dependency(
    request: RemoveDependencyRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Remove a dependency from a service.

    Args:
        request: Remove dependency request with service and dependency names

    Returns:
        DependencyOperationResponse: Result of the operation
    """
    try:
        return await service.remove_dependency(request.service, request.dependency)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/impact/{service_name}", response_model=ImpactAnalysis)
async def get_impact_analysis(
    service_name: str,
    service: DependencyService = Depends(get_dependency_service),
):
    """
    Get impact analysis for a service.

    Shows what services depend on this service and the impact level
    if this service goes down.

    Args:
        service_name: Service name

    Returns:
        ImpactAnalysis: Impact analysis with affected services
    """
    try:
        return await service.get_impact_analysis(service_name)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/list", response_model=DependencyList)
async def list_all_dependencies(
    service: DependencyService = Depends(get_dependency_service),
):
    """
    List all services with their dependencies.

    Returns:
        DependencyList: Map of services to their dependencies
    """
    try:
        return await service.get_all_dependencies()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
