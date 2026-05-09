"""Diagnostics router for service health and problem detection"""

import logging
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect

from auth.dependencies import require_any_role
from auth.models import KeycloakUser
from auth.websocket import authenticate_websocket
from models.diagnostic import (
    ApplyFixRequest,
    ApplyFixResult,
    DiagnosticRequest,
    DiagnosticResult,
    Observation,
    ObservationType,
    Problem,
    Severity,
    Solution,
)
from models.health import DiagnosticHistory, ProblemFrequency, ServiceHealth
from services.health_monitor import HealthMonitor
from services.portoser_cli import PortoserCLI, PortoserCLIError
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow
from utils.validation import InputValidator

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/diagnostics", tags=["diagnostics"])

# Global instances (will be set by main.py)
cli_service: Optional[PortoserCLI] = None
ws_manager: Optional[WebSocketManager] = None
health_monitor: Optional[HealthMonitor] = None


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


def get_health_monitor() -> HealthMonitor:
    """Dependency to get health monitor"""
    if health_monitor is None:
        raise HTTPException(status_code=503, detail="Health monitor not initialized")
    return health_monitor


# In-memory storage for diagnostic results (would use Redis/DB in production)
diagnostic_results: Dict[str, DiagnosticResult] = {}


@router.post("/run", response_model=DiagnosticResult)
async def run_diagnostics(
    request: DiagnosticRequest,
    cli: PortoserCLI = Depends(get_cli_service),
    ws: WebSocketManager = Depends(get_ws_manager),
):
    """
    Run diagnostics for a service

    Analyzes the service and machine to detect:
    - Port conflicts
    - Service health issues
    - Missing dependencies
    - Permission errors
    - Network connectivity
    - Resource constraints (disk, memory)
    - Configuration errors

    Returns:
        DiagnosticResult with observations, problems, and proposed solutions
    """
    # Validate input
    InputValidator.validate_service_name(request.service, "service")
    InputValidator.validate_machine_name(request.machine, "machine")

    started_at = utcnow()
    diagnostic_key = f"{request.service}:{request.machine}"

    logger.info(f"Running diagnostics for {diagnostic_key}")

    # WebSocket callback for streaming updates
    async def ws_callback(message: Dict[str, Any]):
        """Send updates via WebSocket"""
        await ws.send_diagnostic_update(
            service=request.service,
            machine=request.machine,
            message_type="diagnostic_update",
            data=message,
        )

    try:
        # Execute diagnostics via CLI
        cli_result = await cli.run_diagnostics(
            service=request.service, machine=request.machine, websocket_callback=ws_callback
        )

        completed_at = utcnow()
        duration = (completed_at - started_at).total_seconds()

        # Parse CLI result
        observations = []
        problems = []
        solutions = []
        health_score = 100

        if isinstance(cli_result, dict):
            # Parse observations
            for obs_data in cli_result.get("observations", []):
                observation = Observation(
                    type=ObservationType(obs_data.get("type", "other")),
                    severity=Severity(obs_data.get("severity", "info")),
                    message=obs_data.get("message", ""),
                    details=obs_data.get("details", {}),
                    timestamp=obs_data.get("timestamp", utcnow()),
                )
                observations.append(observation)

                # Send observation via WebSocket
                await ws.send_observation(
                    service=request.service,
                    machine=request.machine,
                    observation=observation.model_dump(),
                )

            # Parse problems
            for prob_data in cli_result.get("problems", []):
                problem = Problem(
                    id=prob_data.get("id", ""),
                    title=prob_data.get("title", ""),
                    description=prob_data.get("description", ""),
                    severity=Severity(prob_data.get("severity", "info")),
                    observations=[],
                    affected_components=prob_data.get("affected_components", []),
                    timestamp=prob_data.get("timestamp", utcnow()),
                )
                problems.append(problem)

            # Parse solutions
            for sol_data in cli_result.get("solutions", []):
                solution = Solution(
                    id=sol_data.get("id", ""),
                    problem_id=sol_data.get("problem_id", ""),
                    title=sol_data.get("title", ""),
                    description=sol_data.get("description", ""),
                    steps=sol_data.get("steps", []),
                    risk_level=sol_data.get("risk_level", "low"),
                    auto_apply=sol_data.get("auto_apply", False),
                    requires_confirmation=sol_data.get("requires_confirmation", True),
                    estimated_duration=sol_data.get("estimated_duration"),
                    command=sol_data.get("command"),
                )
                solutions.append(solution)

            health_score = cli_result.get("health_score", 100)

        # Create result
        result = DiagnosticResult(
            service=request.service,
            machine=request.machine,
            started_at=started_at,
            completed_at=completed_at,
            duration_seconds=duration,
            observations=observations,
            problems=problems,
            solutions=solutions,
            health_score=health_score,
            success=True,
        )

        # Store result
        diagnostic_results[diagnostic_key] = result

        # Send completion via WebSocket
        await ws.send_diagnostic_complete(
            service=request.service, machine=request.machine, result=result.model_dump()
        )

        return result

    except PortoserCLIError as e:
        logger.error(f"Diagnostics failed for {diagnostic_key}: {e}")

        completed_at = utcnow()
        duration = (completed_at - started_at).total_seconds()

        result = DiagnosticResult(
            service=request.service,
            machine=request.machine,
            started_at=started_at,
            completed_at=completed_at,
            duration_seconds=duration,
            observations=[],
            problems=[],
            solutions=[],
            health_score=0,
            success=False,
            error=str(e),
        )

        diagnostic_results[diagnostic_key] = result
        return result

    except Exception as e:
        logger.error(f"Unexpected error during diagnostics for {diagnostic_key}: {e}")
        raise HTTPException(status_code=500, detail=f"Diagnostics failed: {str(e)}")


@router.post("/apply-fix", response_model=ApplyFixResult)
async def apply_fix(
    request: ApplyFixRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    cli: PortoserCLI = Depends(get_cli_service),
    ws: WebSocketManager = Depends(get_ws_manager),
):
    """
    Apply a specific solution to fix a problem

    Args:
        request: Fix application request with service, machine, and solution_id

    Returns:
        ApplyFixResult with success status and verification results
    """
    diagnostic_key = f"{request.service}:{request.machine}"
    logger.info(f"Applying fix {request.solution_id} for {diagnostic_key}")

    # Check if we have diagnostic results with this solution
    if diagnostic_key in diagnostic_results:
        result = diagnostic_results[diagnostic_key]
        solution = next((s for s in result.solutions if s.id == request.solution_id), None)

        if solution:
            logger.info(f"Found solution: {solution.title}")
            # Send notification that fix is being applied
            await ws.send_solution_applied(
                service=request.service, machine=request.machine, solution=solution.model_dump()
            )

    # WebSocket callback for streaming
    async def ws_callback(message: Dict[str, Any]):
        """Send updates via WebSocket"""
        await ws.send_diagnostic_update(
            service=request.service,
            machine=request.machine,
            message_type="fix_progress",
            data=message,
        )

    started_at = utcnow()

    try:
        # Execute fix via CLI
        cli_result = await cli.apply_fix(
            service=request.service,
            machine=request.machine,
            solution_id=request.solution_id,
            websocket_callback=ws_callback,
        )

        completed_at = utcnow()
        duration = (completed_at - started_at).total_seconds()

        # Parse result
        if isinstance(cli_result, dict):
            fix_result = ApplyFixResult(
                solution_id=request.solution_id,
                success=cli_result.get("success", False),
                output=cli_result.get("output", []),
                error=cli_result.get("error"),
                duration_seconds=duration,
                verification_passed=cli_result.get("verification_passed", False),
            )
        else:
            fix_result = ApplyFixResult(
                solution_id=request.solution_id,
                success=True,
                output=[str(cli_result)],
                duration_seconds=duration,
                verification_passed=False,
            )

        # Send completion notification
        await ws.send_diagnostic_update(
            service=request.service,
            machine=request.machine,
            message_type="fix_complete",
            data=fix_result.model_dump(),
        )

        return fix_result

    except PortoserCLIError as e:
        logger.error(f"Failed to apply fix {request.solution_id}: {e}")

        completed_at = utcnow()
        duration = (completed_at - started_at).total_seconds()

        return ApplyFixResult(
            solution_id=request.solution_id,
            success=False,
            output=[],
            error=str(e),
            duration_seconds=duration,
            verification_passed=False,
        )

    except Exception as e:
        logger.error(f"Unexpected error applying fix {request.solution_id}: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to apply fix: {str(e)}")


@router.get("/health/all", response_model=List[ServiceHealth])
async def get_all_health_checks(health: HealthMonitor = Depends(get_health_monitor)):
    """
    Health check for all services

    Returns:
        Array of ServiceHealth for all known services
    """
    all_health = health.get_all_service_health()

    # If no health data, populate from registry as fallback
    if not all_health:
        logger.info("No health data available, populating from registry...")
        try:
            import os
            from pathlib import Path

            from services.registry_service import RegistryService

            registry_path = (
                os.getenv("CADDY_REGISTRY_PATH")
                or os.getenv("PORTOSER_REGISTRY")
                or str(Path(__file__).resolve().parents[3] / "registry.yml")
            )
            registry_service = RegistryService(registry_path=registry_path)
            services = registry_service.get_all_services()

            for service in services:
                health.update_service_health(
                    service=service.name,
                    machine=service.current_host,
                    health_score=0,  # 0 = UNKNOWN status (gray indicator)
                    issues=["Health monitoring not yet configured - showing registry data"],
                    uptime_seconds=None,
                    response_time_ms=None,
                )

            all_health = health.get_all_service_health()
            logger.info(f"Populated health for {len(all_health)} services from registry")
        except Exception as e:
            logger.error(f"Failed to populate health from registry: {e}")

    return all_health


# Must be declared *before* /{service}/{machine}: FastAPI matches routes in
# declaration order, and the parameterized two-segment route below would
# otherwise swallow /problems/frequency (treating it as service=problems,
# machine=frequency) and 404. Same constraint for any future static
# two-segment GET route under this router.
@router.get("/problems/frequency", response_model=List[ProblemFrequency])
async def get_problem_frequency(health: HealthMonitor = Depends(get_health_monitor)):
    """
    Problem frequency across all services

    Returns:
        List of ProblemFrequency showing problem types, counts, and affected services
    """
    return health.get_problem_frequencies()


@router.get("/{service}/{machine}", response_model=DiagnosticResult)
async def get_diagnostic_result(service: str, machine: str):
    """
    Get cached diagnostic result

    Args:
        service: Service name
        machine: Machine name

    Returns:
        DiagnosticResult if available
    """
    diagnostic_key = f"{service}:{machine}"

    if diagnostic_key not in diagnostic_results:
        raise HTTPException(
            status_code=404, detail=f"No diagnostic results found for {service} on {machine}"
        )

    return diagnostic_results[diagnostic_key]


@router.get("/{service}/{machine}/problems", response_model=List[Problem])
async def get_problems(service: str, machine: str):
    """
    Get list of problems for a service

    Args:
        service: Service name
        machine: Machine name

    Returns:
        List of identified problems
    """
    diagnostic_key = f"{service}:{machine}"

    if diagnostic_key not in diagnostic_results:
        raise HTTPException(
            status_code=404, detail=f"No diagnostic results found for {service} on {machine}"
        )

    return diagnostic_results[diagnostic_key].problems


@router.get("/{service}/{machine}/solutions", response_model=List[Solution])
async def get_solutions(service: str, machine: str):
    """
    Get list of solutions for a service

    Args:
        service: Service name
        machine: Machine name

    Returns:
        List of proposed solutions
    """
    diagnostic_key = f"{service}:{machine}"

    if diagnostic_key not in diagnostic_results:
        raise HTTPException(
            status_code=404, detail=f"No diagnostic results found for {service} on {machine}"
        )

    return diagnostic_results[diagnostic_key].solutions


@router.websocket("/ws/{service}/{machine}")
async def diagnostics_websocket(
    websocket: WebSocket, service: str, machine: str, ws: WebSocketManager = Depends(get_ws_manager)
):
    """
    WebSocket endpoint for real-time diagnostic updates

    Args:
        websocket: WebSocket connection
        service: Service name
        machine: Machine name
    """
    if await authenticate_websocket(websocket) is None:
        return
    await ws.connect(websocket)

    try:
        # Subscribe to diagnostic updates
        await ws.subscribe_diagnostics(websocket, service, machine)

        # Send initial state if available
        diagnostic_key = f"{service}:{machine}"
        if diagnostic_key in diagnostic_results:
            result = diagnostic_results[diagnostic_key]
            await websocket.send_json({"type": "initial_state", "diagnostic": result.model_dump()})

        # Keep connection alive
        while True:
            await websocket.receive_text()
            # Echo back for keepalive
            await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        await ws.disconnect(websocket)


@router.get("/health/{service}/{machine}", response_model=ServiceHealth)
async def get_service_health_check(
    service: str, machine: str, health: HealthMonitor = Depends(get_health_monitor)
):
    """
    Quick health check for a service (lighter than full diagnostics)

    Args:
        service: Service name
        machine: Machine name

    Returns:
        ServiceHealth with status, health score, and issues
    """
    service_health = health.get_service_health(service, machine)

    if service_health is None:
        # If no health data exists, return unknown status
        return ServiceHealth(
            service=service,
            machine=machine,
            status="unknown",
            health_score=0,
            issues=["No health data available - run diagnostics first"],
            last_checked=utcnow(),
        )

    return service_health


@router.get("/history/{service}/{machine}", response_model=List[DiagnosticHistory])
async def get_diagnostic_history(
    service: str, machine: str, limit: int = 50, health: HealthMonitor = Depends(get_health_monitor)
):
    """
    Diagnostic history for a service

    Args:
        service: Service name
        machine: Machine name
        limit: Maximum number of history entries to return

    Returns:
        Array of past diagnostic runs (newest first)
    """
    return health.get_diagnostic_history(service, machine, limit)
