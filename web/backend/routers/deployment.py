"""Deployment router with intelligent deployment features.

Owns three groups of endpoints:

1. Intelligent deployment (POST /intelligent-execute, dry-run, phases, ws/...)
2. Plain deployment (POST /plan, POST /execute) — extracted from main.py
"""

import logging
import uuid
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect

from auth.dependencies import require_any_role
from auth.models import KeycloakUser
from auth.websocket import authenticate_websocket
from models.deployment import (
    DeploymentPhase,
    DeploymentRequest,
    DeploymentResult,
    DryRunRequest,
    PhaseBreakdown,
    PhaseStatus,
)
from models.registry_admin import DeploymentPlan
from models.uptime import UptimeEventType
from services.cli_runner import run_portoser_command
from services.portoser_cli import PortoserCLI, PortoserCLIError
from services.registry_helpers import load_registry
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow
from utils.validation import InputSanitizer, InputValidator

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/deployment", tags=["deployment"])

# Global instances (will be set by main.py)
cli_service: Optional[PortoserCLI] = None
ws_manager: Optional[WebSocketManager] = None
uptime_service = None  # Will be set by main.py


def get_cli_service() -> PortoserCLI:
    """Dependency to get CLI service"""
    if cli_service is None:
        raise HTTPException(status_code=503, detail="CLI service not initialized")
    return cli_service


def get_ws_manager() -> WebSocketManager:
    """Dependency to get WebSocket manager"""
    if ws_manager is None:
        raise HTTPException(status_code=503, detail="WebSocket manager not initialized")
    return ws_manager


# In-memory storage for deployment results (would use Redis/DB in production)
deployment_results: Dict[str, DeploymentResult] = {}


@router.post("/intelligent-execute", response_model=DeploymentResult)
async def intelligent_execute(
    request: DeploymentRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    cli: PortoserCLI = Depends(get_cli_service),
    ws: WebSocketManager = Depends(get_ws_manager),
):
    """
    Execute deployment with 4-phase streaming via WebSocket

    Phases:
    1. Health Check - Verify service and machine status
    2. Pre-deployment Diagnostics - Check for potential issues
    3. Deployment - Execute the actual deployment
    4. Post-deployment Validation - Verify deployment success

    Returns:
        DeploymentResult with complete phase information
    """
    # Validate and sanitize input
    InputValidator.validate_service_name(request.service, "service")
    InputValidator.validate_machine_name(request.machine, "machine")

    # Sanitize inputs to prevent injection attacks
    service_name = InputSanitizer.sanitize_service_name(request.service)
    machine_name = InputSanitizer.sanitize_machine_name(request.machine)

    deployment_id = f"deploy-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    started_at = utcnow()

    logger.info(
        f"Starting intelligent deployment {deployment_id}: {request.service} -> {request.machine}"
    )

    # Initialize result (use sanitized values)
    result = DeploymentResult(
        deployment_id=deployment_id,
        service=service_name,
        machine=machine_name,
        status="in_progress",
        started_at=started_at,
        dry_run=request.dry_run,
        success=False,
        phases=[],
    )

    # Store result
    deployment_results[deployment_id] = result

    # WebSocket callback for streaming
    async def ws_callback(message: Dict[str, Any]):
        """Send updates via WebSocket"""
        message["deployment_id"] = deployment_id
        await ws.broadcast(message)

    try:
        # Record deployment start event
        if uptime_service and not request.dry_run:
            try:
                uptime_service.record_uptime_event(
                    service=service_name,
                    machine=machine_name,
                    event_type=UptimeEventType.DEPLOYMENT,
                    details="Deployment started",
                    metadata={"deployment_id": deployment_id},
                )
            except Exception as e:
                logger.warning(f"Failed to record deployment start event: {e}")

        # Execute intelligent deployment (using sanitized values)
        cli_result = await cli.deploy_intelligent(
            service=service_name,
            machine=machine_name,
            auto_heal=request.auto_heal,
            dry_run=request.dry_run,
            websocket_callback=ws_callback,
        )

        # Parse CLI result and update deployment
        if isinstance(cli_result, dict):
            # Extract phases from CLI result
            phases_data = cli_result.get("phases", [])
            phases = []

            for phase_data in phases_data:
                phase = DeploymentPhase(
                    name=phase_data.get("name", "Unknown"),
                    status=PhaseStatus(phase_data.get("status", "pending")),
                    started_at=phase_data.get("started_at"),
                    completed_at=phase_data.get("completed_at"),
                    duration_seconds=phase_data.get("duration_seconds"),
                    output=phase_data.get("output", []),
                    error=phase_data.get("error"),
                    steps=phase_data.get("steps", []),
                )
                phases.append(phase)

            result.phases = phases
            result.success = cli_result.get("success", False)
            result.auto_heal_applied = cli_result.get("auto_heal_applied", False)
            result.problems_detected = cli_result.get("problems_detected", [])
            result.solutions_applied = cli_result.get("solutions_applied", [])
        else:
            # Fallback if CLI doesn't return structured data
            result.success = True
            result.phases = [
                DeploymentPhase(
                    name="Deployment",
                    status=PhaseStatus.COMPLETED,
                    started_at=started_at,
                    completed_at=utcnow(),
                    output=[str(cli_result)],
                )
            ]

        result.completed_at = utcnow()
        result.duration_seconds = (result.completed_at - result.started_at).total_seconds()
        result.status = "completed" if result.success else "failed"

        # Record deployment completion/success event
        if uptime_service and not request.dry_run:
            try:
                if result.success:
                    uptime_service.record_uptime_event(
                        service=service_name,
                        machine=machine_name,
                        event_type=UptimeEventType.START,
                        details="Deployment completed successfully",
                        metadata={
                            "deployment_id": deployment_id,
                            "auto_heal_applied": result.auto_heal_applied,
                        },
                    )
                else:
                    uptime_service.record_uptime_event(
                        service=service_name,
                        machine=machine_name,
                        event_type=UptimeEventType.FAILURE,
                        details="Deployment failed",
                        metadata={"deployment_id": deployment_id},
                    )
            except Exception as e:
                logger.warning(f"Failed to record deployment completion event: {e}")

    except PortoserCLIError as e:
        logger.error(f"Deployment {deployment_id} failed: {e}")
        result.status = "failed"
        result.success = False
        result.error = str(e)
        result.completed_at = utcnow()
        result.duration_seconds = (result.completed_at - result.started_at).total_seconds()

        # Record failure event
        if uptime_service and not request.dry_run:
            try:
                uptime_service.record_uptime_event(
                    service=service_name,
                    machine=machine_name,
                    event_type=UptimeEventType.FAILURE,
                    details=f"Deployment failed: {str(e)}",
                    metadata={"deployment_id": deployment_id, "error": str(e)},
                )
            except Exception as ue:
                logger.warning(f"Failed to record failure event: {ue}")

    except Exception as e:
        logger.error(f"Unexpected error in deployment {deployment_id}: {e}")
        result.status = "failed"
        result.success = False
        result.error = f"Unexpected error: {str(e)}"
        result.completed_at = utcnow()
        result.duration_seconds = (result.completed_at - result.started_at).total_seconds()

        # Record failure event
        if uptime_service and not request.dry_run:
            try:
                uptime_service.record_uptime_event(
                    service=service_name,
                    machine=machine_name,
                    event_type=UptimeEventType.FAILURE,
                    details=f"Unexpected deployment error: {str(e)}",
                    metadata={"deployment_id": deployment_id, "error": str(e)},
                )
            except Exception as ue:
                logger.warning(f"Failed to record failure event: {ue}")

    # Update stored result
    deployment_results[deployment_id] = result

    # Send final update via WebSocket
    await ws.broadcast(
        {
            "type": "deployment_complete",
            "deployment_id": deployment_id,
            "status": result.status,
            "success": result.success,
        }
    )

    return result


@router.get("/{deployment_id}/phases", response_model=PhaseBreakdown)
async def get_deployment_phases(deployment_id: str, cli: PortoserCLI = Depends(get_cli_service)):
    """
    Get detailed phase breakdown for a deployment

    Args:
        deployment_id: Unique deployment identifier

    Returns:
        PhaseBreakdown with detailed phase information
    """
    # First check in-memory storage
    if deployment_id in deployment_results:
        result = deployment_results[deployment_id]
        completed_phases = sum(1 for p in result.phases if p.status == PhaseStatus.COMPLETED)
        current_phase = next(
            (p.name for p in result.phases if p.status == PhaseStatus.IN_PROGRESS), None
        )

        return PhaseBreakdown(
            deployment_id=deployment_id,
            service=result.service,
            machine=result.machine,
            total_phases=len(result.phases),
            completed_phases=completed_phases,
            current_phase=current_phase,
            phases=result.phases,
        )

    # Try to get from CLI if not in memory
    try:
        cli_result = await cli.get_deployment_phases(deployment_id)

        if isinstance(cli_result, dict):
            phases_data = cli_result.get("phases", [])
            phases = []

            for phase_data in phases_data:
                phase = DeploymentPhase(
                    name=phase_data.get("name", "Unknown"),
                    status=PhaseStatus(phase_data.get("status", "pending")),
                    started_at=phase_data.get("started_at"),
                    completed_at=phase_data.get("completed_at"),
                    duration_seconds=phase_data.get("duration_seconds"),
                    output=phase_data.get("output", []),
                    error=phase_data.get("error"),
                    steps=phase_data.get("steps", []),
                )
                phases.append(phase)

            completed_phases = sum(1 for p in phases if p.status == PhaseStatus.COMPLETED)
            current_phase = next(
                (p.name for p in phases if p.status == PhaseStatus.IN_PROGRESS), None
            )

            return PhaseBreakdown(
                deployment_id=deployment_id,
                service=cli_result.get("service", "unknown"),
                machine=cli_result.get("machine", "unknown"),
                total_phases=len(phases),
                completed_phases=completed_phases,
                current_phase=current_phase,
                phases=phases,
            )

    except PortoserCLIError:
        pass

    # Not found
    raise HTTPException(status_code=404, detail=f"Deployment {deployment_id} not found")


@router.post("/dry-run", response_model=DeploymentResult)
async def dry_run_deployment(
    request: DryRunRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin", "viewer")),
    cli: PortoserCLI = Depends(get_cli_service),
):
    """
    Preview deployment without executing

    Args:
        request: Dry run request

    Returns:
        DeploymentResult showing what would happen
    """
    deployment_id = f"dryrun-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    started_at = utcnow()

    logger.info(f"Starting dry run {deployment_id}: {request.service} -> {request.machine}")

    try:
        cli_result = await cli.dry_run_deployment(service=request.service, machine=request.machine)

        # Parse result
        phases = []
        if isinstance(cli_result, dict):
            phases_data = cli_result.get("phases", [])
            for phase_data in phases_data:
                phase = DeploymentPhase(
                    name=phase_data.get("name", "Unknown"),
                    status=PhaseStatus(phase_data.get("status", "pending")),
                    output=phase_data.get("output", []),
                    steps=phase_data.get("steps", []),
                )
                phases.append(phase)

        completed_at = utcnow()
        duration = (completed_at - started_at).total_seconds()

        result = DeploymentResult(
            deployment_id=deployment_id,
            service=request.service,
            machine=request.machine,
            status="completed",
            started_at=started_at,
            completed_at=completed_at,
            duration_seconds=duration,
            phases=phases,
            dry_run=True,
            success=True,
        )

        return result

    except PortoserCLIError as e:
        logger.error(f"Dry run {deployment_id} failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{deployment_id}", response_model=DeploymentResult)
async def get_deployment_result(deployment_id: str):
    """
    Get deployment result

    Args:
        deployment_id: Unique deployment identifier

    Returns:
        DeploymentResult
    """
    if deployment_id not in deployment_results:
        raise HTTPException(status_code=404, detail=f"Deployment {deployment_id} not found")

    return deployment_results[deployment_id]


@router.websocket("/ws/{deployment_id}")
async def deployment_websocket(
    websocket: WebSocket, deployment_id: str, ws: WebSocketManager = Depends(get_ws_manager)
):
    """
    WebSocket endpoint for real-time deployment updates

    Args:
        websocket: WebSocket connection
        deployment_id: Deployment to subscribe to
    """
    if await authenticate_websocket(websocket) is None:
        return
    await ws.connect(websocket)

    try:
        # Subscribe to deployment updates
        await ws.subscribe_deployment(websocket, deployment_id)

        # Send initial state
        if deployment_id in deployment_results:
            result = deployment_results[deployment_id]
            await websocket.send_json({"type": "initial_state", "deployment": result.model_dump()})

        # Keep connection alive
        while True:
            await websocket.receive_text()
            # Echo back for keepalive
            await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        await ws.disconnect(websocket)
        await ws.unsubscribe_deployment(websocket, deployment_id)


# ============================================================================
# Plain Deployment Endpoints (extracted from main.py)
# ============================================================================


async def _broadcast(message: Dict[str, Any]) -> None:
    """Best-effort broadcast — used by /plan, /execute legacy paths."""
    if ws_manager is not None:
        await ws_manager.broadcast(message)


@router.post("/plan")
async def create_deployment_plan(plan: DeploymentPlan) -> Dict[str, Any]:
    """Create and preview a deployment plan."""
    registry = load_registry()

    for move in plan.moves:
        if move.service_name not in registry.get("services", {}):
            raise HTTPException(status_code=400, detail=f"Service not found: {move.service_name}")
        if move.to_machine not in registry.get("hosts", {}):
            raise HTTPException(
                status_code=400, detail=f"Target machine not found: {move.to_machine}"
            )

    deployment_commands: List[Dict[str, Any]] = []
    for move in plan.moves:
        current_host = registry["services"][move.service_name].get("current_host")
        if current_host == move.to_machine:
            action = "RESTART IN PLACE"
        elif not current_host or current_host == "null":
            action = "FRESH DEPLOY"
        else:
            action = f"MIGRATE from {current_host}"

        deployment_commands.append(
            {
                "service": move.service_name,
                "target_machine": move.to_machine,
                "action": action,
                "command": f"portoser deploy {move.to_machine} {move.service_name}",
            }
        )

    return {"plan": deployment_commands, "total_operations": len(deployment_commands)}


@router.post("/execute")
async def execute_deployment_plan(plan: DeploymentPlan, request: Request) -> Dict[str, Any]:
    """Execute a previously-planned deployment via the portoser CLI."""
    if await request.is_disconnected():
        raise HTTPException(status_code=408, detail="Client disconnected")

    await _broadcast({"type": "deployment_started", "total_operations": len(plan.moves)})
    load_registry()  # legacy: surfaces 404/500 early
    results: List[Dict[str, Any]] = []

    for idx, move in enumerate(plan.moves):
        await _broadcast(
            {
                "type": "deployment_progress",
                "current_operation": idx + 1,
                "total_operations": len(plan.moves),
                "service": move.service_name,
                "target": move.to_machine,
            }
        )

        result = await run_portoser_command(
            ["deploy", move.to_machine, move.service_name], stream=True, timeout=120
        )
        results.append(
            {
                "service": move.service_name,
                "target": move.to_machine,
                "success": result["success"],
                "error": result.get("error"),
            }
        )

        if not result["success"]:
            await _broadcast(
                {
                    "type": "deployment_failed",
                    "service": move.service_name,
                    "error": result.get("error"),
                }
            )
            break

    all_success = all(r["success"] for r in results)
    await _broadcast(
        {"type": "deployment_completed" if all_success else "deployment_failed", "results": results}
    )
    return {"success": all_success, "results": results}
