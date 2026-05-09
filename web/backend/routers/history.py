"""History router for deployment tracking and rollback"""

import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from auth.dependencies import require_any_role
from auth.models import KeycloakUser
from models.history import (
    DeploymentListResponse,
    DeploymentRecord,
    DeploymentStats,
    DeploymentTimelineResponse,
    RollbackPreview,
    RollbackRequest,
    RollbackResult,
)
from services.history_manager import HistoryManager
from utils.validation import InputValidator

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/history", tags=["history"])

# Global instance (will be set by main.py)
history_manager: Optional[HistoryManager] = None


def get_history_manager() -> HistoryManager:
    """Dependency to get history manager"""
    if history_manager is None:
        raise HTTPException(status_code=503, detail="History manager not initialized")
    return history_manager


@router.get("/deployments", response_model=DeploymentListResponse)
async def list_deployments(
    service: Optional[str] = Query(None, description="Filter by service name"),
    machine: Optional[str] = Query(None, description="Filter by machine name"),
    status: Optional[str] = Query(
        None, description="Filter by status (success/failure/rolled_back)"
    ),
    limit: int = Query(50, ge=1, le=1000, description="Number of records to return"),
    offset: int = Query(0, ge=0, description="Number of records to skip"),
    from_date: Optional[str] = Query(None, description="Filter from date (ISO format)"),
    to_date: Optional[str] = Query(None, description="Filter to date (ISO format)"),
    manager: HistoryManager = Depends(get_history_manager),
):
    """
    List deployment history with pagination and filters

    Query parameters:
    - service: Filter by service name
    - machine: Filter by machine name
    - status: Filter by status (success, failure, rolled_back)
    - limit: Number of records (default: 50, max: 1000)
    - offset: Skip N records (for pagination)
    - from_date: Start date filter (ISO format)
    - to_date: End date filter (ISO format)
    """
    try:
        return manager.list_deployments(
            service=service,
            machine=machine,
            status=status,
            limit=limit,
            offset=offset,
            from_date=from_date,
            to_date=to_date,
        )
    except Exception as e:
        logger.error(f"Failed to list deployments: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/deployments/{deployment_id}", response_model=DeploymentRecord)
async def get_deployment(
    deployment_id: str, manager: HistoryManager = Depends(get_history_manager)
):
    """
    Get full details of a specific deployment

    Returns complete deployment record including:
    - All phases with timing
    - Observations made
    - Problems detected
    - Solutions applied
    - Configuration snapshot
    """
    deployment = manager.get_deployment(deployment_id)

    if not deployment:
        raise HTTPException(status_code=404, detail=f"Deployment {deployment_id} not found")

    return deployment


@router.get("/rollback/{deployment_id}/preview", response_model=RollbackPreview)
async def preview_rollback(
    deployment_id: str, manager: HistoryManager = Depends(get_history_manager)
):
    """
    Preview what will change during rollback

    Shows:
    - Current configuration
    - Target configuration (from deployment)
    - Differences between them
    - Warnings if rollback might be risky
    """
    preview = manager.preview_rollback(deployment_id)

    if not preview:
        raise HTTPException(status_code=404, detail=f"Deployment {deployment_id} not found")

    return preview


@router.post("/rollback/{deployment_id}", response_model=RollbackResult)
async def rollback_deployment(
    deployment_id: str,
    request: RollbackRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: HistoryManager = Depends(get_history_manager),
):
    """
    Execute rollback to a previous deployment

    Request body:
    - confirm: Must be true to execute (safety check)
    - dry_run: If true, shows what would happen without executing

    Process:
    1. Loads deployment configuration snapshot
    2. Updates registry.yml with old configuration
    3. Re-deploys service with old config
    4. Verifies deployment success
    5. Creates rollback record in history
    """
    # Validate deployment ID format
    InputValidator.validate_deployment_id(deployment_id)

    logger.info(
        f"Rollback requested for deployment {deployment_id} by user {user.preferred_username}"
    )

    try:
        result = manager.rollback_deployment(
            deployment_id=deployment_id, confirm=request.confirm, dry_run=request.dry_run
        )

        if not result.success and result.error:
            raise HTTPException(status_code=400, detail=result.error)

        return result

    except Exception as e:
        logger.error(f"Rollback failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/timeline", response_model=DeploymentTimelineResponse)
async def get_timeline(
    days: int = Query(30, ge=1, le=365, description="Number of days to include"),
    service: Optional[str] = Query(None, description="Filter by service name"),
    manager: HistoryManager = Depends(get_history_manager),
):
    """
    Get timeline view of deployments grouped by date

    Returns deployments organized by date for timeline visualization.
    Each entry includes summary information for display.

    Query parameters:
    - days: Number of days to include (default: 30)
    - service: Filter by service name
    """
    try:
        return manager.get_timeline(days=days, service=service)
    except Exception as e:
        logger.error(f"Failed to get timeline: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/stats", response_model=DeploymentStats)
async def get_stats(
    service: Optional[str] = Query(None, description="Filter by service name"),
    days: int = Query(30, ge=1, le=365, description="Number of days to analyze"),
    manager: HistoryManager = Depends(get_history_manager),
):
    """
    Get deployment statistics

    Returns:
    - Total deployments
    - Success count and rate
    - Failure count
    - Rollback count
    - Average duration
    - (Optional) Per-service breakdown

    Query parameters:
    - service: Filter by specific service (or all if omitted)
    - days: Number of days to analyze (default: 30)
    """
    try:
        return manager.get_stats(service=service, days=days)
    except Exception as e:
        logger.error(f"Failed to get stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))
