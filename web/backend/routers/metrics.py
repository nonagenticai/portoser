"""Router for metrics and resource monitoring endpoints - Async Optimized Version

This version implements:
1. Fully async route handlers
2. Parallel metrics fetching with asyncio.gather()
3. Request deduplication with caching
4. Streaming results as they arrive
5. Graceful partial failure handling
"""

import asyncio
import hashlib
import json
import logging
import time
from typing import Any, Dict, List, Optional, Tuple

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    Response,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import StreamingResponse

from auth.dependencies import require_any_role, require_role
from auth.models import KeycloakUser
from auth.websocket import authenticate_websocket
from models.metrics import (
    MachineMetrics,
    MetricsHistoryResponse,
    MetricsInterval,
    MetricsSnapshot,
    MetricsTimeRange,
    ServiceMetrics,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)

# Router instance
router = APIRouter(prefix="/api/metrics", tags=["metrics"])

# Global service instances (set by main.py)
metrics_service = None
metrics_collector = None
ws_manager = None

# Request deduplication cache
# Structure: {cache_key: (result, timestamp, asyncio.Event)}
_request_cache: Dict[str, Tuple[Any, float, asyncio.Event]] = {}
_cache_lock = asyncio.Lock()
_cache_ttl = 5.0  # Cache TTL in seconds

# In-flight request tracking to prevent duplicate requests
_inflight_requests: Dict[str, asyncio.Event] = {}
_inflight_lock = asyncio.Lock()


def _generate_cache_key(endpoint: str, **kwargs) -> str:
    """Generate cache key from endpoint and parameters"""
    params_str = json.dumps(kwargs, sort_keys=True)
    key_data = f"{endpoint}:{params_str}"
    return hashlib.sha256(key_data.encode()).hexdigest()


async def _get_or_fetch(cache_key: str, fetch_fn, ttl: float = None):
    """
    Deduplication wrapper: returns cached result or executes fetch_fn

    If the same request is already in-flight, waits for that request to complete
    instead of making a duplicate request.
    """
    if ttl is None:
        ttl = _cache_ttl

    current_time = time.time()

    # Check cache first
    async with _cache_lock:
        if cache_key in _request_cache:
            result, timestamp, event = _request_cache[cache_key]
            if current_time - timestamp < ttl:
                logger.debug(f"Cache hit for {cache_key}")
                return result
            else:
                # Expired, remove from cache
                del _request_cache[cache_key]

    # Check if request is already in-flight
    async with _inflight_lock:
        if cache_key in _inflight_requests:
            logger.debug(f"Request already in-flight for {cache_key}, waiting...")
            event = _inflight_requests[cache_key]
        else:
            # Create new event for this request
            event = asyncio.Event()
            _inflight_requests[cache_key] = event

    # If event was already set by another request, get from cache
    if event.is_set():
        async with _cache_lock:
            if cache_key in _request_cache:
                result, _, _ = _request_cache[cache_key]
                return result

    # We're the first request, execute the fetch
    try:
        result = await fetch_fn()

        # Store in cache
        async with _cache_lock:
            _request_cache[cache_key] = (result, current_time, event)

        # Signal waiting requests
        event.set()

        return result

    except Exception:
        # Signal error to waiting requests
        event.set()
        raise

    finally:
        # Remove from in-flight tracking
        async with _inflight_lock:
            _inflight_requests.pop(cache_key, None)


async def _fetch_service_metrics_async(
    service: str, machine: str, time_range: MetricsTimeRange
) -> ServiceMetrics:
    """Async wrapper for service metrics fetching"""
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    # Direct async call (no executor needed for async methods)
    metrics = await metrics_service.get_service_metrics(service, machine, time_range)

    if not metrics:
        raise HTTPException(
            status_code=404, detail=f"Metrics not found for service {service} on machine {machine}"
        )

    return metrics


async def _fetch_machine_metrics_async(machine: str) -> MachineMetrics:
    """Async wrapper for machine metrics fetching"""
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    # Direct async call (no executor needed for async methods)
    metrics = await metrics_service.get_machine_metrics(machine)

    if not metrics:
        raise HTTPException(status_code=404, detail=f"Metrics not found for machine {machine}")

    return metrics


@router.get("/machine/{machine}", response_model=MachineMetrics)
async def get_machine_metrics(machine: str, response: Response):
    """
    Get aggregated metrics for all services on a machine (with request deduplication)

    Args:
        machine: Machine hostname

    Returns:
        MachineMetrics with all service metrics
    """
    cache_key = _generate_cache_key("machine_metrics", machine=machine)

    try:
        metrics = await _get_or_fetch(cache_key, lambda: _fetch_machine_metrics_async(machine))

        # Add Cache-Control headers
        response.headers["Cache-Control"] = "public, max-age=10, must-revalidate"
        response.headers["X-Cache-TTL"] = "10"

        return metrics

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get machine metrics: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get metrics: {str(e)}")


async def _fetch_all_machines_parallel() -> List[MachineMetrics]:
    """
    Fetch metrics for all machines in parallel with graceful failure handling

    Returns partial results even if some machines fail
    """
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    # Get list of all machines
    machines = await metrics_service.get_all_machines()

    if not machines:
        logger.warning("No machines found in metrics service")
        return []

    logger.info(f"Fetching metrics for {len(machines)} machines in parallel")

    # Create tasks for parallel fetching
    tasks = []
    for machine in machines:
        task = asyncio.create_task(_fetch_machine_metrics_safe(machine))
        tasks.append(task)

    # Gather results with exception handling
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Filter out failures and log them
    successful_results = []
    failed_count = 0

    for i, result in enumerate(results):
        if isinstance(result, Exception):
            logger.error(f"Failed to fetch metrics for machine {machines[i]}: {result}")
            failed_count += 1
        elif result is not None:
            successful_results.append(result)

    if failed_count > 0:
        logger.warning(f"Partial failure: {failed_count}/{len(machines)} machines failed")

    return successful_results


async def _fetch_machine_metrics_safe(machine: str) -> Optional[MachineMetrics]:
    """Safely fetch machine metrics, returning None on failure instead of raising"""
    try:
        return await _fetch_machine_metrics_async(machine)
    except Exception as e:
        logger.error(f"Error fetching metrics for machine {machine}: {e}")
        return None


# NOTE: route order matters. FastAPI matches in declaration order, and the
# generic /{service}/{machine} below would shadow specific 2-segment routes
# like /machine/{machine}, /services, /all, /collector/* if they were
# declared after it. /services and /all/.../*/status are 1-segment so they
# escape, but /machine/{machine} and /collector/{x} would not — keep the
# specific 2-segment routes (defined later in this file) above this one.
@router.get("/{service}/{machine}", response_model=ServiceMetrics)
async def get_service_metrics(
    service: str,
    machine: str,
    response: Response,
    timeRange: str = Query(  # noqa: N803  # JS frontend uses ?timeRange= camelCase
        "1h", description="Time range for historical data (1h, 6h, 24h, 7d, 30d)"
    ),
):
    """
    Get current and historical metrics for a service (with request deduplication)

    Args:
        service: Service name
        machine: Machine hostname
        timeRange: Time range for historical data (1h, 6h, 24h, 7d, 30d)

    Returns:
        ServiceMetrics with current and historical data

    Note: If background workers are disabled, returns stale/cached data with a warning
    """
    from config import config

    # Check if background workers are disabled
    workers_disabled = not config.enable_background_workers

    # Validate and convert timeRange string to enum
    try:
        time_range = MetricsTimeRange(timeRange)
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid timeRange value: {timeRange}. Valid values: 1h, 6h, 24h, 7d, 30d",
        )

    cache_key = _generate_cache_key(
        "service_metrics", service=service, machine=machine, time_range=time_range.value
    )

    try:
        metrics = await _get_or_fetch(
            cache_key, lambda: _fetch_service_metrics_async(service, machine, time_range)
        )

        # Add Cache-Control headers to reduce frontend polling
        response.headers["Cache-Control"] = "public, max-age=10, must-revalidate"
        response.headers["X-Cache-TTL"] = "10"

        # Add warning header if workers are disabled
        if workers_disabled:
            response.headers["X-Workers-Status"] = "disabled"
            response.headers["X-Warning"] = (
                "Background workers disabled - metrics may be stale or empty"
            )

        return metrics

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get service metrics: {e}")
        # If workers are disabled and we have an error, provide more context
        if workers_disabled:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": "Metrics unavailable",
                    "message": "Background workers are disabled. Enable ENABLE_BACKGROUND_WORKERS=true for live metrics.",
                    "original_error": str(e),
                },
            )
        raise HTTPException(status_code=500, detail=f"Failed to get metrics: {str(e)}")


@router.get("/services", response_model=Dict[str, List[str]])
async def get_services(response: Response):
    """
    Get mapping of services to machines they run on

    Returns:
        Dictionary mapping service names to list of machines
        Example: {"nginx": ["host-a", "host-b"], "postgres": ["host-a"], ...}

    This endpoint helps the frontend discover which services are available
    on which machines, eliminating 404 errors when trying to access services.
    """
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    try:
        service_mapping = await metrics_service.get_service_machine_mapping()

        # Add Cache-Control headers (5 minute cache to match service cache)
        response.headers["Cache-Control"] = "public, max-age=300, must-revalidate"
        response.headers["X-Cache-TTL"] = "300"

        return service_mapping

    except Exception as e:
        logger.error(f"Failed to get service machine mapping: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get service mapping: {str(e)}")


@router.get("/all", response_model=List[MachineMetrics])
async def get_all_metrics(response: Response):
    """
    Get metrics for all machines and services with parallel fetching

    Returns:
        List of MachineMetrics for all machines

    Raises:
        HTTPException 503: Metrics service not available
        HTTPException 502: Metrics unavailable (empty result from service)
        HTTPException 500: Internal error

    Note: Returns partial results if some machines fail
    Note: If background workers are disabled, returns stale/cached data with a warning
    """
    from config import config

    # Check if background workers are disabled
    workers_disabled = not config.enable_background_workers

    cache_key = _generate_cache_key("all_metrics")

    try:
        metrics = await _get_or_fetch(
            cache_key,
            _fetch_all_machines_parallel,
            ttl=3.0,  # Shorter TTL for all metrics
        )

        # Check if metrics collection returned empty list
        if not metrics:
            error_msg = "Metrics collection returned empty result - no metrics data available from any machine"
            logger.warning(error_msg)

            # If workers are disabled, provide more helpful error message
            if workers_disabled:
                raise HTTPException(
                    status_code=503,
                    detail={
                        "error": "Metrics Unavailable",
                        "message": "Background workers are disabled. No metrics data available. Enable ENABLE_BACKGROUND_WORKERS=true for live metrics.",
                        "code": "WORKERS_DISABLED",
                    },
                )

            raise HTTPException(
                status_code=502,
                detail={
                    "error": "Metrics Unavailable",
                    "message": error_msg,
                    "code": "NO_METRICS_DATA",
                },
            )

        # Add Cache-Control headers (shorter cache for aggregated data)
        response.headers["Cache-Control"] = "public, max-age=5, must-revalidate"
        response.headers["X-Cache-TTL"] = "5"

        # Add warning header if workers are disabled
        if workers_disabled:
            response.headers["X-Workers-Status"] = "disabled"
            response.headers["X-Warning"] = (
                "Background workers disabled - metrics may be stale or empty"
            )

        return metrics

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get all metrics: {e}")
        # If workers are disabled, provide more helpful error message
        if workers_disabled:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": "Metrics Unavailable",
                    "message": "Background workers are disabled. Enable ENABLE_BACKGROUND_WORKERS=true for live metrics.",
                    "code": "WORKERS_DISABLED",
                    "original_error": str(e),
                },
            )
        raise HTTPException(
            status_code=500,
            detail={
                "error": "Internal Error",
                "message": f"Failed to retrieve metrics: {str(e)}",
                "code": "METRICS_COLLECTION_ERROR",
            },
        )


@router.get("/all/stream")
async def get_all_metrics_stream():
    """
    Stream metrics for all machines as they arrive (Server-Sent Events)

    Streams results as JSON objects separated by newlines.
    Each machine's metrics are sent as soon as they're available.

    Returns:
        StreamingResponse with metrics arriving in real-time
    """

    async def generate_metrics_stream():
        """Generator that yields metrics as they arrive"""
        if not metrics_service:
            yield (
                json.dumps(
                    {"error": "Metrics service not available", "code": "SERVICE_UNAVAILABLE"}
                )
                + "\n"
            )
            return

        try:
            # Get list of machines
            machines = await metrics_service.get_all_machines()

            if not machines:
                yield json.dumps({"error": "No machines found", "code": "NO_MACHINES"}) + "\n"
                return

            # Send initial status
            yield (
                json.dumps(
                    {
                        "type": "status",
                        "message": f"Fetching metrics for {len(machines)} machines",
                        "total": len(machines),
                    }
                )
                + "\n"
            )

            # Create tasks for parallel fetching
            tasks = []
            for machine in machines:
                task = asyncio.create_task(_fetch_machine_metrics_safe(machine))
                tasks.append((machine, task))

            # Stream results as they complete
            pending = {task for _, task in tasks}
            task_map = {task: machine for machine, task in tasks}
            completed_count = 0

            while pending:
                # Wait for next completion
                done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)

                for task in done:
                    machine = task_map[task]
                    completed_count += 1

                    try:
                        result = await task
                        if result:
                            # Convert to dict for JSON serialization
                            result_dict = (
                                result.model_dump() if hasattr(result, "model_dump") else result
                            )
                            yield (
                                json.dumps(
                                    {
                                        "type": "data",
                                        "machine": machine,
                                        "data": result_dict,
                                        "progress": completed_count,
                                        "total": len(machines),
                                    }
                                )
                                + "\n"
                            )
                        else:
                            yield (
                                json.dumps(
                                    {
                                        "type": "error",
                                        "machine": machine,
                                        "error": "No metrics available",
                                        "progress": completed_count,
                                        "total": len(machines),
                                    }
                                )
                                + "\n"
                            )
                    except Exception as e:
                        yield (
                            json.dumps(
                                {
                                    "type": "error",
                                    "machine": machine,
                                    "error": str(e),
                                    "progress": completed_count,
                                    "total": len(machines),
                                }
                            )
                            + "\n"
                        )

            # Send completion status
            yield (
                json.dumps(
                    {
                        "type": "complete",
                        "message": f"Completed fetching metrics for {completed_count} machines",
                    }
                )
                + "\n"
            )

        except Exception as e:
            logger.error(f"Error in metrics stream: {e}")
            yield json.dumps({"type": "error", "error": str(e), "code": "STREAM_ERROR"}) + "\n"

    return StreamingResponse(
        generate_metrics_stream(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.get("/{service}/{machine}/history", response_model=MetricsHistoryResponse)
async def get_metrics_history(
    service: str,
    machine: str,
    time_range: MetricsTimeRange = Query(MetricsTimeRange.DAY, description="Time range to query"),
    interval: MetricsInterval = Query(
        MetricsInterval.FIFTEEN_MINUTES, description="Data aggregation interval"
    ),
):
    """
    Get historical metrics data with aggregations (async optimized)

    Args:
        service: Service name
        machine: Machine hostname
        time_range: Time range to query (1h, 6h, 24h, 7d, 30d)
        interval: Data aggregation interval (1m, 5m, 15m, 1h)

    Returns:
        MetricsHistoryResponse with historical data points and summary
    """
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    cache_key = _generate_cache_key(
        "metrics_history",
        service=service,
        machine=machine,
        time_range=time_range.value,
        interval=interval.value,
    )

    async def fetch_history():
        # Fetch history and calculate summary in parallel
        # Get historical data
        history = await metrics_service.get_metrics_history(service, machine, time_range)

        if not history:
            raise HTTPException(
                status_code=404, detail=f"No historical data found for {service} on {machine}"
            )

        # Calculate summary
        summary = await metrics_service.calculate_average_metrics(history)

        # Add min/max values to summary
        if history:
            summary["min_cpu"] = min(m.cpu_percent for m in history)
            summary["min_memory"] = min(m.memory_mb for m in history)
            summary["max_cpu"] = summary["peak_cpu"]
            summary["max_memory"] = summary["peak_memory"]

        return MetricsHistoryResponse(
            service=service,
            machine=machine,
            time_range=time_range.value,
            interval=interval.value,
            data_points=history,
            summary=summary,
        )

    try:
        response = await _get_or_fetch(cache_key, fetch_history, ttl=10.0)
        return response

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get metrics history: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get history: {str(e)}")


@router.post("/snapshot", response_model=MetricsSnapshot)
async def trigger_metrics_snapshot(
    snapshot: MetricsSnapshot, user: KeycloakUser = Depends(require_any_role("operator", "admin"))
):
    """
    Trigger immediate metrics collection (async optimized)

    Args:
        snapshot: Snapshot request specifying what to collect

    Returns:
        MetricsSnapshot with collection status
    """
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    try:
        if snapshot.all:
            # Trigger collection for all services
            if metrics_collector:
                success = await metrics_collector.trigger_immediate_collection()
            else:
                success = await metrics_service.collect_metrics_snapshot()
        elif snapshot.service and snapshot.machine:
            # Single service snapshot
            success = await metrics_service.collect_metrics_snapshot(
                snapshot.service, snapshot.machine
            )
        elif snapshot.machine:
            # Machine snapshot
            success = await metrics_service.collect_metrics_snapshot(machine=snapshot.machine)
        else:
            raise HTTPException(
                status_code=400,
                detail="Must specify either 'all', or 'service' and 'machine', or just 'machine'",
            )

        # Invalidate relevant cache entries after snapshot
        await _invalidate_cache_for_snapshot(snapshot)

        if success:
            return MetricsSnapshot(
                service=snapshot.service,
                machine=snapshot.machine,
                all=snapshot.all,
                status="completed",
                message="Metrics snapshot collected successfully",
            )
        else:
            return MetricsSnapshot(
                service=snapshot.service,
                machine=snapshot.machine,
                all=snapshot.all,
                status="failed",
                message="Failed to collect metrics snapshot",
            )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to trigger snapshot: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to trigger snapshot: {str(e)}")


async def _invalidate_cache_for_snapshot(snapshot: MetricsSnapshot):
    """Invalidate cache entries affected by a snapshot"""
    async with _cache_lock:
        keys_to_remove = []

        if snapshot.all:
            # Clear all cache
            keys_to_remove = list(_request_cache.keys())
        elif snapshot.machine:
            # Clear cache for this machine
            for key in _request_cache.keys():
                if snapshot.machine in key or "all_metrics" in key:
                    keys_to_remove.append(key)

        for key in keys_to_remove:
            _request_cache.pop(key, None)

        if keys_to_remove:
            logger.debug(f"Invalidated {len(keys_to_remove)} cache entries")


@router.get("/workers/status")
async def get_workers_status():
    """
    Get status of all background workers

    Returns:
        Status information for all background workers including:
        - Whether workers are enabled
        - Status of each individual worker (metrics_queue, metrics_collector, metrics_prefetcher, device_monitor)
        - When workers are disabled, includes warning message
    """
    import os

    from config import config

    workers_enabled = config.enable_background_workers

    # Get individual worker flags
    metrics_queue_enabled = os.getenv("METRICS_QUEUE_ENABLED", "true").lower() == "true"
    metrics_collector_enabled = os.getenv("METRICS_COLLECTOR_ENABLED", "false").lower() == "true"
    prefetcher_enabled = os.getenv("METRICS_PREFETCHER_ENABLED", "true").lower() == "true"

    status_response = {
        "enabled": workers_enabled,
        "workers": {
            "device_health_monitor": {
                "enabled": workers_enabled,
                "status": "running" if workers_enabled else "disabled",
                "description": "Monitors device health and updates via WebSocket",
            },
            "metrics_queue": {
                "enabled": workers_enabled and metrics_queue_enabled,
                "status": "running" if (workers_enabled and metrics_queue_enabled) else "disabled",
                "description": "Background queue for processing metrics requests",
            },
            "metrics_collector": {
                "enabled": workers_enabled and metrics_collector_enabled,
                "status": "running"
                if (workers_enabled and metrics_collector_enabled)
                else "disabled",
                "description": "Background collector for periodic metrics gathering",
            },
            "metrics_prefetcher": {
                "enabled": workers_enabled and prefetcher_enabled,
                "status": "running" if (workers_enabled and prefetcher_enabled) else "disabled",
                "description": "Prefetches frequently accessed metrics",
            },
        },
    }

    if not workers_enabled:
        status_response["warning"] = (
            "Background workers are disabled. Metrics and device health monitoring will not update. Set ENABLE_BACKGROUND_WORKERS=true to enable live data."
        )

    return status_response


@router.get("/collector/status")
async def get_collector_status():
    """
    Get status of the background metrics collector

    Returns:
        Collector status information
    """
    if not metrics_collector:
        return {"available": False, "message": "Metrics collector not initialized"}

    try:
        loop = asyncio.get_event_loop()
        status = await loop.run_in_executor(None, metrics_collector.get_status)
        return {"available": True, **status}

    except Exception as e:
        logger.error(f"Failed to get collector status: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get status: {str(e)}")


@router.post("/collector/interval")
async def update_collector_interval(
    interval: int = Query(..., ge=1, le=300, description="Interval in seconds"),
    user: KeycloakUser = Depends(require_role("admin")),
):
    """
    Update the metrics collection interval

    Args:
        interval: New interval in seconds (1-300)

    Returns:
        Updated status
    """
    if not metrics_collector:
        raise HTTPException(status_code=503, detail="Metrics collector not available")

    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, metrics_collector.update_interval, interval)

        return {
            "success": True,
            "interval": interval,
            "message": f"Collection interval updated to {interval} seconds",
        }

    except Exception as e:
        logger.error(f"Failed to update interval: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to update interval: {str(e)}")


@router.delete("/cleanup")
async def cleanup_old_metrics(
    days: int = Query(30, ge=1, le=365, description="Keep metrics for this many days"),
    user: KeycloakUser = Depends(require_role("admin")),
):
    """
    Clean up old metrics snapshots (async optimized)

    Args:
        days: Keep metrics for this many days (1-365)

    Returns:
        Cleanup status
    """
    if not metrics_service:
        raise HTTPException(status_code=503, detail="Metrics service not available")

    try:
        await metrics_service.cleanup_old_metrics(days)

        # Clear cache after cleanup
        async with _cache_lock:
            _request_cache.clear()

        return {"success": True, "message": f"Cleaned up metrics older than {days} days"}

    except Exception as e:
        logger.error(f"Failed to cleanup metrics: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to cleanup: {str(e)}")


@router.websocket("/ws")
async def metrics_websocket(websocket: WebSocket):
    """
    WebSocket endpoint for real-time metrics streaming

    Streams metrics updates every collection interval (default: 10s)

    Message format:
    {
        "type": "metrics_update",
        "service": "service_name",
        "machine": "machine_name",
        "timestamp": "2025-01-15T10:30:00Z",
        "data": { ... ServiceMetrics ... }
    }
    """
    if await authenticate_websocket(websocket) is None:
        return
    if not ws_manager:
        await websocket.close(code=1011, reason="WebSocket manager not available")
        return

    await ws_manager.connect(websocket)

    try:
        # Send initial status
        await websocket.send_json(
            {
                "type": "connected",
                "message": "Connected to metrics stream",
                "timestamp": utcnow().isoformat(),
                "server": "portoser-metrics-ws",
            }
        )

        # Keep connection alive and listen for messages
        while True:
            try:
                # Wait for client messages (e.g., subscribe/unsubscribe)
                data = await websocket.receive_json()

                # Handle subscription requests
                action = data.get("action")

                if action == "subscribe":
                    # Handle subscription request with subscription patterns
                    subscriptions = data.get("subscriptions", [])

                    if not isinstance(subscriptions, list):
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": "subscriptions must be a list",
                                "timestamp": utcnow().isoformat(),
                            }
                        )
                        continue

                    # Validate subscription format (service@machine)
                    valid_subscriptions = []
                    for sub in subscriptions:
                        if "@" not in sub:
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "message": f"Invalid subscription format: {sub}. Use 'service@machine'",
                                    "timestamp": utcnow().isoformat(),
                                }
                            )
                            continue
                        valid_subscriptions.append(sub)

                    # Subscribe using enhanced WebSocket manager
                    if hasattr(ws_manager, "subscribe_metrics"):
                        await ws_manager.subscribe_metrics(websocket, valid_subscriptions)

                        # Send confirmation
                        await websocket.send_json(
                            {
                                "type": "subscribed",
                                "subscriptions": valid_subscriptions,
                                "timestamp": utcnow().isoformat(),
                            }
                        )
                        logger.info(f"Client subscribed to: {valid_subscriptions}")
                    else:
                        logger.warning("WebSocket manager does not support subscribe_metrics")

                elif action == "unsubscribe":
                    # Handle unsubscribe request
                    subscriptions = data.get("subscriptions")

                    if hasattr(ws_manager, "unsubscribe_metrics"):
                        await ws_manager.unsubscribe_metrics(websocket, subscriptions)

                        await websocket.send_json(
                            {
                                "type": "unsubscribed",
                                "subscriptions": subscriptions or "all",
                                "timestamp": utcnow().isoformat(),
                            }
                        )
                        logger.info(f"Client unsubscribed from: {subscriptions or 'all'}")

                elif action == "get_current":
                    # Handle request for current metrics
                    service = data.get("service")
                    machine = data.get("machine")

                    if not service or not machine:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": "service and machine required for get_current",
                                "timestamp": utcnow().isoformat(),
                            }
                        )
                        continue

                    try:
                        # Get current metrics
                        if metrics_service:
                            # Direct async call (no executor needed for async methods)
                            metrics = await metrics_service.get_service_metrics(service, machine)

                            if metrics:
                                await websocket.send_json(
                                    {
                                        "type": "metrics_current",
                                        "service": service,
                                        "machine": machine,
                                        "timestamp": utcnow().isoformat(),
                                        "data": metrics.model_dump()
                                        if hasattr(metrics, "model_dump")
                                        else metrics,
                                    }
                                )
                            else:
                                await websocket.send_json(
                                    {
                                        "type": "error",
                                        "message": f"No metrics found for {service}@{machine}",
                                        "timestamp": utcnow().isoformat(),
                                    }
                                )
                    except Exception as e:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": f"Failed to get metrics: {str(e)}",
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                elif action == "ping":
                    await websocket.send_json({"type": "pong", "timestamp": utcnow().isoformat()})

                elif action == "list_subscriptions":
                    # Debug: list all active subscriptions
                    if hasattr(ws_manager, "get_all_subscriptions"):
                        all_subs = ws_manager.get_all_subscriptions()
                        await websocket.send_json(
                            {
                                "type": "subscriptions_list",
                                "subscriptions": all_subs,
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                else:
                    # Unknown action
                    if action:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": f"Unknown action: {action}",
                                "timestamp": utcnow().isoformat(),
                            }
                        )

            except asyncio.TimeoutError:
                continue
            except json.JSONDecodeError:
                await websocket.send_json(
                    {"type": "error", "message": "Invalid JSON", "timestamp": utcnow().isoformat()}
                )

    except WebSocketDisconnect:
        logger.info("Metrics WebSocket client disconnected")
    except Exception as e:
        logger.error(f"Error in metrics WebSocket: {e}")
    finally:
        # Clean up subscriptions on disconnect
        if hasattr(ws_manager, "unsubscribe_metrics"):
            await ws_manager.unsubscribe_metrics(websocket)
        await ws_manager.disconnect(websocket)


@router.get("/cache/stats")
async def get_cache_stats():
    """
    Get statistics about request cache (for monitoring/debugging)

    Returns:
        Cache statistics including size, hit rate, etc.
    """
    async with _cache_lock:
        cache_size = len(_request_cache)
        current_time = time.time()

        # Count expired entries
        expired_count = sum(
            1
            for _, timestamp, _ in _request_cache.values()
            if current_time - timestamp >= _cache_ttl
        )

        return {
            "cache_size": cache_size,
            "expired_entries": expired_count,
            "active_entries": cache_size - expired_count,
            "cache_ttl": _cache_ttl,
            "inflight_requests": len(_inflight_requests),
        }


@router.post("/cache/clear")
async def clear_cache(user: KeycloakUser = Depends(require_role("admin"))):
    """
    Clear all cache entries (admin only)

    Returns:
        Number of entries cleared
    """
    async with _cache_lock:
        count = len(_request_cache)
        _request_cache.clear()

    return {"success": True, "entries_cleared": count, "message": f"Cleared {count} cache entries"}


# Periodic cache cleanup task
async def periodic_cache_cleanup():
    """Background task to clean up expired cache entries"""
    while True:
        try:
            await asyncio.sleep(60)  # Run every minute

            current_time = time.time()
            async with _cache_lock:
                expired_keys = [
                    key
                    for key, (_, timestamp, _) in _request_cache.items()
                    if current_time - timestamp >= _cache_ttl
                ]

                for key in expired_keys:
                    del _request_cache[key]

                if expired_keys:
                    logger.debug(f"Cleaned up {len(expired_keys)} expired cache entries")

        except Exception as e:
            logger.error(f"Error in cache cleanup task: {e}")


# Export router
__all__ = ["router", "periodic_cache_cleanup"]
