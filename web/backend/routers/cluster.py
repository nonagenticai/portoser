"""Cluster management router"""

import logging
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect

from auth.dependencies import require_any_role
from auth.models import KeycloakUser
from auth.websocket import authenticate_websocket
from models.cluster import (
    BuildRequest,
    BuildResponse,
    BuildStatus,
    BuildxResponse,
    CleanRequest,
    CleanResponse,
    ClusterHealth,
    ClusterStatus,
    DeployRequest,
    DeployResponse,
    DeployStatus,
    PiHealth,
    ServiceDiscovery,
    SyncRequest,
    SyncResponse,
)
from services.cluster_manager import ClusterManager, ClusterManagerError
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/cluster", tags=["cluster"])

# Global instances (will be set by main.py during startup)
cluster_manager: Optional[ClusterManager] = None
ws_manager: Optional[WebSocketManager] = None


def get_cluster_manager() -> ClusterManager:
    """Dependency to get cluster manager service."""
    if cluster_manager is None:
        raise HTTPException(status_code=503, detail="Cluster manager not initialized")
    return cluster_manager


def get_ws_manager() -> WebSocketManager:
    """Dependency to get WebSocket manager."""
    if ws_manager is None:
        raise HTTPException(status_code=503, detail="WebSocket manager not initialized")
    return ws_manager


# =============================================================================
# BUILD ENDPOINTS
# =============================================================================


@router.post("/build", response_model=BuildResponse, status_code=202)
async def trigger_build(
    request: BuildRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: ClusterManager = Depends(get_cluster_manager),
    ws: WebSocketManager = Depends(get_ws_manager),
):
    """
    Trigger build for Docker images.

    Builds Docker images for the specified services for arm64 architecture.
    Images are pushed to the local registry after successful build.

    Args:
        request: Build request with service list and options

    Returns:
        BuildResponse with build_id for tracking progress

    Requires:
        - Role: deployer or admin
        - Services must be defined in registry.yml
        - Docker buildx must be configured

    Example:
        ```
        POST /api/cluster/build
        {
            "services": ["myservice", "ingestion"],
            "rebuild": false,
            "batch_size": 4
        }
        ```
    """
    logger.info(f"Build triggered by {user.username}: {request.services}")

    try:
        # WebSocket callback for real-time updates
        async def ws_callback(message):
            await ws.broadcast(message)

        # Start build
        build_id = await manager.build_services(
            services=request.services,
            rebuild=request.rebuild,
            batch_size=request.batch_size,
            websocket_callback=ws_callback,
        )

        return BuildResponse(build_id=build_id, services=request.services, status="running")

    except ClusterManagerError as e:
        logger.error(f"Build failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/build/{build_id}", response_model=BuildStatus)
async def get_build_status(build_id: str, manager: ClusterManager = Depends(get_cluster_manager)):
    """
    Get build status and output.

    Retrieves the current status, output logs, and completion status
    for a specific build operation.

    Args:
        build_id: Unique build identifier from trigger_build

    Returns:
        BuildStatus with complete build information

    Example:
        ```
        GET /api/cluster/build/build-20251203-120000-abc123
        ```
    """
    status = manager.get_build_status(build_id)

    if not status:
        raise HTTPException(status_code=404, detail=f"Build {build_id} not found")

    return BuildStatus(
        build_id=status["build_id"],
        services=status["services"],
        status=status["status"],
        started_at=status["started_at"],
        completed_at=status.get("completed_at"),
        output=status.get("output", []),
        error=status.get("error"),
    )


# =============================================================================
# DEPLOYMENT ENDPOINTS
# =============================================================================


@router.post("/deploy", response_model=DeployResponse, status_code=202)
async def trigger_deployment(
    request: DeployRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: ClusterManager = Depends(get_cluster_manager),
    ws: WebSocketManager = Depends(get_ws_manager),
):
    """
    Deploy services to a Raspberry Pi.

    Deploys the specified services to a Pi by:
    1. Syncing service files (docker-compose.yml, .env, certs)
    2. Pulling latest images from registry
    3. Restarting services with docker compose

    Args:
        request: Deployment request with Pi and service list

    Returns:
        DeployResponse with deployment_id for tracking progress

    Requires:
        - Role: deployer or admin
        - Services must be built and pushed to registry
        - Target Pi must be accessible via SSH

    Example:
        ```
        POST /api/cluster/deploy
        {
            "pi": "pi1",
            "services": ["myservice", "ingestion"]
        }
        ```
    """
    logger.info(f"Deployment triggered by {user.username}: {request.services} -> {request.pi}")

    try:
        # WebSocket callback for real-time updates
        async def ws_callback(message):
            await ws.broadcast(message)

        # Start deployment
        deployment_id = await manager.deploy_to_pi(
            pi=request.pi, services=request.services, websocket_callback=ws_callback
        )

        return DeployResponse(
            deployment_id=deployment_id, pi=request.pi, services=request.services, status="running"
        )

    except ClusterManagerError as e:
        logger.error(f"Deployment failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/deploy/{deployment_id}", response_model=DeployStatus)
async def get_deployment_status(
    deployment_id: str, manager: ClusterManager = Depends(get_cluster_manager)
):
    """
    Get deployment status and output.

    Retrieves the current status, output logs, and completion status
    for a specific deployment operation.

    Args:
        deployment_id: Unique deployment identifier from trigger_deployment

    Returns:
        DeployStatus with complete deployment information

    Example:
        ```
        GET /api/cluster/deploy/deploy-20251203-120000-def456
        ```
    """
    status = manager.get_deployment_status(deployment_id)

    if not status:
        raise HTTPException(status_code=404, detail=f"Deployment {deployment_id} not found")

    return DeployStatus(
        deployment_id=status["deployment_id"],
        pi=status["pi"],
        services=status["services"],
        status=status["status"],
        started_at=status["started_at"],
        completed_at=status.get("completed_at"),
        output=status.get("output", []),
        error=status.get("error"),
    )


# =============================================================================
# SYNC ENDPOINTS
# =============================================================================


@router.post("/sync", response_model=SyncResponse)
async def sync_pis(
    request: SyncRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: ClusterManager = Depends(get_cluster_manager),
):
    """
    Sync Pi directories.

    Syncs the per-host base directory (compose files, .env, certificates) to
    the specified Pis so they have the latest configuration before deployment.

    Args:
        request: List of Pis to sync

    Returns:
        SyncResponse with sync results for each Pi

    Requires:
        - Role: deployer or admin
        - Pis must be accessible via SSH

    Example:
        ```
        POST /api/cluster/sync
        {
            "pis": ["pi1", "pi2"]
        }
        ```
    """
    logger.info(f"Sync triggered by {user.username}: {request.pis}")

    try:
        result = await manager.sync_pis(pis=request.pis)

        sync_id = f"sync-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"

        return SyncResponse(
            sync_id=sync_id,
            pis=request.pis,
            status="completed" if result["success"] else "failed",
            results=result["results"],
        )

    except ClusterManagerError as e:
        logger.error(f"Sync failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# CLEAN ENDPOINTS
# =============================================================================


@router.post("/clean", response_model=CleanResponse)
async def clean_pis(
    request: CleanRequest,
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: ClusterManager = Depends(get_cluster_manager),
):
    """
    Clean Pi Docker resources.

    Removes unused Docker images, containers, and volumes on specified Pis.
    This frees up disk space on Pis with limited storage.

    Args:
        request: List of Pis to clean and dry_run flag

    Returns:
        CleanResponse with clean results for each Pi

    Requires:
        - Role: deployer or admin
        - Pis must be accessible via SSH

    Example:
        ```
        POST /api/cluster/clean
        {
            "pis": ["pi1"],
            "dry_run": true
        }
        ```
    """
    logger.info(f"Clean triggered by {user.username}: {request.pis} (dry_run={request.dry_run})")

    try:
        result = await manager.clean_pis(pis=request.pis, dry_run=request.dry_run)

        clean_id = f"clean-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"

        return CleanResponse(
            clean_id=clean_id,
            pis=request.pis,
            dry_run=request.dry_run,
            status="completed" if result["success"] else "failed",
            results=result["results"],
        )

    except ClusterManagerError as e:
        logger.error(f"Clean failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# HEALTH ENDPOINTS
# =============================================================================


@router.get("/health", response_model=ClusterHealth)
async def get_cluster_health(manager: ClusterManager = Depends(get_cluster_manager)):
    """
    Get cluster health status.

    Checks the health of all Pis and services in the cluster.
    Returns overall cluster health and per-Pi details.

    Returns:
        ClusterHealth with health status for all Pis

    Example:
        ```
        GET /api/cluster/health
        ```
    """
    logger.info("Cluster health check requested")

    try:
        result = await manager.check_health()
        health = result.get("health") or {}
        services = health.get("services") or []

        # Group per-service results into PiHealth entries keyed on hostname.
        # The shell health check reports {service, hostname, port, status},
        # so we collapse same-host services into a single entry whose status
        # reflects the worst observed state on that host.
        from collections import defaultdict

        per_host: dict[str, dict] = defaultdict(lambda: {"services": [], "statuses": []})
        for svc in services:
            hostname = svc.get("hostname") or "unknown"
            per_host[hostname]["services"].append(svc.get("service") or "")
            per_host[hostname]["statuses"].append(svc.get("status") or "unknown")

        def _worst(statuses: list[str]) -> str:
            # "offline" outranks "unknown" because it carries more info — we
            # know the host is down (registry says so) rather than just not
            # having probed it. Below "down" because we only land on offline
            # when nothing was actually probed; if we did probe and got
            # "down", that's a different (real) failure.
            #
            # "healthy" outranks "skipped": skipped is a per-service "we
            # don't probe TCP-only services" marker, not a host-level
            # verdict. A host with 2 healthy + 1 skipped service is
            # operationally healthy, not "skipped".
            for level in (
                "down",
                "unhealthy",
                "degraded",
                "offline",
                "unknown",
                "healthy",
                "skipped",
            ):
                if level in statuses:
                    return "unhealthy" if level == "down" else level
            return "unknown"

        timestamp = health.get("timestamp") or utcnow().isoformat()
        pis = [
            PiHealth(
                pi=hostname,
                status=_worst(data["statuses"]),
                services=[s for s in data["services"] if s],
                last_checked=timestamp,
            )
            for hostname, data in per_host.items()
        ]

        # Top-level rollup mirrors the worst per-host state. If we got back
        # neither a JSON payload nor any services, surface that honestly.
        if not health and not services:
            overall = "unknown"
        elif health.get("down", 0) > 0:
            overall = "unhealthy"
        elif health.get("degraded", 0) > 0:
            overall = "degraded"
        elif health.get("offline", 0) > 0 and health.get("healthy", 0) == 0:
            # Registry-says-offline cluster (typical dev/dummy registry).
            overall = "offline"
        else:
            overall = "healthy"

        return ClusterHealth(overall_status=overall, pis=pis, timestamp=timestamp)

    except ClusterManagerError as e:
        logger.error(f"Health check failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# DISCOVERY ENDPOINTS
# =============================================================================


@router.get("/services", response_model=ServiceDiscovery)
async def discover_services(manager: ClusterManager = Depends(get_cluster_manager)):
    """
    Discover services from registry.

    Reads the registry.yml file and returns a list of all configured services
    with their deployment information.

    Returns:
        ServiceDiscovery with list of all services

    Example:
        ```
        GET /api/cluster/services
        ```
    """
    logger.info("Service discovery requested")

    try:
        result = await manager.discover_services()

        # discover_services() swallows internal errors into {success: False,
        # error: "..."}; surface that as a 500 instead of a misleading
        # 200-with-empty-list. Without this, a misconfigured lib_path
        # (e.g. CLUSTER_LIB_PATH unset in the container) silently looks
        # like "no services exist".
        if not result.get("success", False):
            err = result.get("error") or "service discovery failed"
            logger.error(f"Service discovery failed: {err}")
            raise HTTPException(status_code=500, detail=str(err))

        services = result.get("services", [])
        return ServiceDiscovery(services=services, total=len(services))

    except ClusterManagerError as e:
        logger.error(f"Service discovery failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# BUILDX ENDPOINTS
# =============================================================================


@router.post("/setup-buildx", response_model=BuildxResponse)
async def setup_buildx(
    user: KeycloakUser = Depends(require_any_role("deployer", "admin")),
    manager: ClusterManager = Depends(get_cluster_manager),
):
    """
    Setup Docker buildx for multi-architecture builds.

    Configures Docker buildx to build arm64 images on Mac (amd64) hosts.
    This is required before building images for Raspberry Pis.

    Returns:
        BuildxResponse with setup status

    Requires:
        - Role: deployer or admin
        - Docker Desktop with buildx support

    Example:
        ```
        POST /api/cluster/setup-buildx
        ```
    """
    logger.info(f"Buildx setup triggered by {user.username}")

    try:
        result = await manager.setup_buildx()

        return BuildxResponse(
            success=result["success"], output=result.get("output"), error=result.get("error")
        )

    except ClusterManagerError as e:
        logger.error(f"Buildx setup failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# STATUS ENDPOINTS
# =============================================================================


@router.get("/status", response_model=ClusterStatus)
async def get_cluster_status(manager: ClusterManager = Depends(get_cluster_manager)):
    """
    Get overall cluster status.

    Returns comprehensive cluster status including:
    - Build capacity and running builds
    - Deployment status
    - Health information
    - Service discovery

    Returns:
        ClusterStatus with complete cluster information

    Example:
        ```
        GET /api/cluster/status
        ```
    """
    logger.info("Cluster status requested")

    try:
        status = await manager.get_cluster_status()

        return ClusterStatus(
            build_capacity=status["build_capacity"],
            deployment_status=status["deployment_status"],
            health=status["health"],
            services=status["services"],
            timestamp=status["timestamp"],
        )

    except ClusterManagerError as e:
        logger.error(f"Status check failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# =============================================================================
# WEBSOCKET ENDPOINTS
# =============================================================================


@router.websocket("/ws/build/{build_id}")
async def build_websocket(
    websocket: WebSocket, build_id: str, ws: WebSocketManager = Depends(get_ws_manager)
):
    """
    WebSocket endpoint for real-time build output.

    Subscribe to build updates and receive real-time output as the build progresses.

    Args:
        build_id: Build ID to subscribe to

    Message types:
        - build_started: Build has started
        - build_progress: Progress update
        - build_log: Log line from build output
        - build_completed: Build completed successfully
        - build_failed: Build failed with error
    """
    if await authenticate_websocket(websocket) is None:
        return
    await ws.connect(websocket)

    try:
        # Send initial message
        await websocket.send_json(
            {"type": "connected", "build_id": build_id, "timestamp": utcnow().isoformat()}
        )

        # Keep connection alive
        while True:
            await websocket.receive_text()
            # Echo back for keepalive
            await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        await ws.disconnect(websocket)


@router.websocket("/ws/deploy/{deployment_id}")
async def deployment_websocket(
    websocket: WebSocket, deployment_id: str, ws: WebSocketManager = Depends(get_ws_manager)
):
    """
    WebSocket endpoint for real-time deployment output.

    Subscribe to deployment updates and receive real-time output as the deployment progresses.

    Args:
        deployment_id: Deployment ID to subscribe to

    Message types:
        - deploy_started: Deployment has started
        - deploy_progress: Progress update
        - deploy_log: Log line from deployment output
        - deploy_completed: Deployment completed successfully
        - deploy_failed: Deployment failed with error
    """
    if await authenticate_websocket(websocket) is None:
        return
    await ws.connect(websocket)

    try:
        # Send initial message
        await websocket.send_json(
            {"type": "connected", "deployment_id": deployment_id, "timestamp": utcnow().isoformat()}
        )

        # Keep connection alive
        while True:
            await websocket.receive_text()
            # Echo back for keepalive
            await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        await ws.disconnect(websocket)


@router.websocket("/ws/health")
async def health_websocket(websocket: WebSocket, ws: WebSocketManager = Depends(get_ws_manager)):
    """
    WebSocket endpoint for real-time health monitoring.

    Subscribe to cluster health updates and receive notifications when
    Pi or service health status changes.

    Message types:
        - health_update: Periodic health update
        - pi_status_change: Pi status changed
        - service_status_change: Service status changed
    """
    if await authenticate_websocket(websocket) is None:
        return
    await ws.connect(websocket)

    try:
        # Send initial message
        await websocket.send_json({"type": "connected", "timestamp": utcnow().isoformat()})

        # Keep connection alive
        while True:
            await websocket.receive_text()
            # Echo back for keepalive
            await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        await ws.disconnect(websocket)
