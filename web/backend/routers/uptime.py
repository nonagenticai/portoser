"""Router for uptime tracking and availability monitoring endpoints"""

import asyncio
import json
import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect

from auth.dependencies import require_role
from auth.models import KeycloakUser
from auth.websocket import authenticate_websocket
from models.uptime import (
    UptimeEvent,
    UptimeEventCreate,
    UptimeEventsResponse,
    UptimeEventType,
    UptimeHistory,
    UptimeStats,
    UptimeSummary,
    UptimeTimelineRequest,
    UptimeTimelineResponse,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)

# Router instance
router = APIRouter(prefix="/api/uptime", tags=["uptime"])

# Global service instances (set by main.py)
uptime_service = None
ws_manager = None


@router.get("/{service}/{machine}", response_model=UptimeStats)
async def get_service_uptime(
    service: str,
    machine: str,
    days: int = Query(30, ge=1, le=365, description="Number of days to analyze"),
):
    """
    Get uptime statistics for a service

    Args:
        service: Service name
        machine: Machine hostname
        days: Number of days to analyze (default: 30)

    Returns:
        UptimeStats with availability metrics
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        stats = uptime_service.get_service_uptime(service, machine, days)

        if not stats:
            raise HTTPException(
                status_code=404,
                detail=f"Uptime data not found for service {service} on machine {machine}",
            )

        return stats

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get service uptime: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get uptime: {str(e)}")


@router.get("/all", response_model=UptimeSummary)
async def get_all_uptime(
    days: int = Query(30, ge=1, le=365, description="Number of days to analyze"),
):
    """
    Get uptime statistics for all services

    Args:
        days: Number of days to analyze (default: 30)

    Returns:
        UptimeSummary with overall system availability
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        summary = uptime_service.get_all_uptime(days)
        return summary

    except Exception as e:
        logger.error(f"Failed to get all uptime: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get uptime: {str(e)}")


@router.get("/{service}/{machine}/history", response_model=UptimeHistory)
async def get_uptime_history(
    service: str,
    machine: str,
    days: int = Query(30, ge=1, le=365, description="Number of days to query"),
    event_type: Optional[UptimeEventType] = Query(None, description="Filter by event type"),
):
    """
    Get uptime event history for a service

    Args:
        service: Service name
        machine: Machine hostname
        days: Number of days to query (default: 30)
        event_type: Filter by specific event type (optional)

    Returns:
        UptimeHistory with events and statistics
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        history = uptime_service.get_uptime_history(service, machine, days)

        # Filter by event type if specified
        if event_type:
            history.events = [e for e in history.events if e.event_type == event_type]

        return history

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get uptime history: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get history: {str(e)}")


@router.get("/{service}/{machine}/events", response_model=UptimeEventsResponse)
async def get_uptime_events(
    service: str,
    machine: str,
    limit: int = Query(50, ge=1, le=1000, description="Number of events to return"),
    offset: int = Query(0, ge=0, description="Offset for pagination"),
    eventType: Optional[str] = Query(  # noqa: N803  # JS frontend uses ?eventType= camelCase
        None, description="Filter by event type"
    ),
):
    """
    Get paginated uptime events for a service

    Args:
        service: Service name
        machine: Machine hostname
        limit: Number of events to return (default: 50, max: 1000)
        offset: Offset for pagination (default: 0)
        eventType: Filter by specific event type (optional)

    Returns:
        UptimeEventsResponse with paginated events
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        # Get history which contains all events
        # We'll use a large days value to get all historical events
        history = uptime_service.get_uptime_history(service, machine, days=365)

        # Filter by event type if specified
        events = history.events
        if eventType:
            try:
                event_filter = UptimeEventType(eventType)
                events = [e for e in events if e.event_type == event_filter]
            except ValueError:
                logger.warning(f"Invalid event type filter: {eventType}")

        # Sort events by timestamp descending (newest first)
        events = sorted(events, key=lambda e: e.timestamp, reverse=True)

        # Calculate pagination
        total = len(events)
        start = offset
        end = offset + limit
        paginated_events = events[start:end]
        has_more = end < total

        return UptimeEventsResponse(
            events=paginated_events, total=total, limit=limit, offset=offset, hasMore=has_more
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get uptime events: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get events: {str(e)}")


@router.get("/summary", response_model=UptimeSummary)
async def get_uptime_summary():
    """
    Get overall system uptime summary

    Returns:
        UptimeSummary with system-wide availability metrics
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        summary = uptime_service.get_uptime_summary()
        return summary

    except Exception as e:
        logger.error(f"Failed to get uptime summary: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get summary: {str(e)}")


@router.post("/event", response_model=UptimeEvent)
async def record_uptime_event(
    event: UptimeEventCreate,
    user: KeycloakUser = Depends(require_role("admin")),
):
    """
    Record an uptime event (called internally by deployment system)

    Args:
        event: Uptime event to record

    Returns:
        Created UptimeEvent
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        success = uptime_service.record_uptime_event(
            service=event.service,
            machine=event.machine,
            event_type=event.event_type,
            details=event.details,
            metadata=event.metadata,
        )

        if not success:
            raise HTTPException(status_code=500, detail="Failed to record event")

        # Create response
        created_event = UptimeEvent(
            timestamp=utcnow(),
            event_type=event.event_type,
            service=event.service,
            machine=event.machine,
            details=event.details,
            metadata=event.metadata,
        )

        # Broadcast event via WebSocket
        if ws_manager:
            try:
                await ws_manager.broadcast(
                    {"type": "uptime_event", "event": created_event.model_dump(mode="json")}
                )
            except Exception as e:
                logger.error(f"Failed to broadcast uptime event: {e}")

        return created_event

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to record uptime event: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to record event: {str(e)}")


@router.post("/timeline", response_model=UptimeTimelineResponse)
async def get_uptime_timeline(request: UptimeTimelineRequest):
    """
    Get uptime timeline for visualization

    Args:
        request: Timeline request with filters

    Returns:
        UptimeTimelineResponse with timeline entries
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        timeline = uptime_service.get_timeline(
            days=request.days, services=request.services, machines=request.machines
        )

        return timeline

    except Exception as e:
        logger.error(f"Failed to get uptime timeline: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get timeline: {str(e)}")


@router.get("/timeline", response_model=UptimeTimelineResponse)
async def get_uptime_timeline_get(
    days: int = Query(7, ge=1, le=90, description="Number of days to visualize"),
    services: Optional[str] = Query(None, description="Comma-separated list of services"),
    machines: Optional[str] = Query(None, description="Comma-separated list of machines"),
):
    """
    Get uptime timeline for visualization (GET method)

    Args:
        days: Number of days to visualize (default: 7)
        services: Comma-separated list of services to filter
        machines: Comma-separated list of machines to filter

    Returns:
        UptimeTimelineResponse with timeline entries
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        # Parse comma-separated lists
        services_list = services.split(",") if services else None
        machines_list = machines.split(",") if machines else None

        timeline = uptime_service.get_timeline(
            days=days, services=services_list, machines=machines_list
        )

        return timeline

    except Exception as e:
        logger.error(f"Failed to get uptime timeline: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get timeline: {str(e)}")


@router.get("/metrics/{service}/{machine}")
async def get_uptime_metrics(
    service: str,
    machine: str,
    days: int = Query(30, ge=1, le=365, description="Number of days to analyze"),
):
    """
    Get detailed uptime metrics including MTBF and MTTR

    Args:
        service: Service name
        machine: Machine hostname
        days: Number of days to analyze

    Returns:
        Detailed uptime metrics
    """
    if not uptime_service:
        raise HTTPException(status_code=503, detail="Uptime service not available")

    try:
        stats = uptime_service.get_service_uptime(service, machine, days)
        events = uptime_service._load_events(service, machine, days)

        # Calculate additional metrics
        mtbf = uptime_service.calculate_mtbf(events)
        mttr = uptime_service.calculate_mttr(events)

        return {
            "service": service,
            "machine": machine,
            "days": days,
            "stats": stats.model_dump(),
            "mtbf_seconds": mtbf,
            "mtbf_hours": round(mtbf / 3600, 2) if mtbf else None,
            "mttr_seconds": mttr,
            "mttr_minutes": round(mttr / 60, 2) if mttr else None,
            "total_events": len(events),
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get uptime metrics: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get metrics: {str(e)}")


@router.websocket("/ws")
async def uptime_websocket(websocket: WebSocket):
    """
    WebSocket endpoint for real-time uptime event streaming

    Streams uptime events as they occur

    Message format:
    {
        "type": "uptime_event",
        "event": {
            "timestamp": "2025-01-15T10:30:00Z",
            "event_type": "start",
            "service": "service_name",
            "machine": "machine_name",
            "details": "...",
            "metadata": { ... }
        }
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
                "message": "Connected to uptime events stream",
                "timestamp": utcnow().isoformat(),
            }
        )

        # Keep connection alive and listen for messages
        while True:
            try:
                # Wait for client messages
                data = await websocket.receive_json()

                # Handle subscription requests
                if data.get("action") == "subscribe":
                    service = data.get("service")
                    if service:
                        logger.info(f"Client subscribed to uptime for service: {service}")

                elif data.get("action") == "ping":
                    await websocket.send_json({"type": "pong"})

            except asyncio.TimeoutError:
                continue
            except json.JSONDecodeError:
                await websocket.send_json(
                    {"type": "error", "message": "Invalid JSON", "timestamp": utcnow().isoformat()}
                )

    except WebSocketDisconnect:
        logger.info("Uptime WebSocket client disconnected")
    except Exception as e:
        logger.error(f"Error in uptime WebSocket: {e}")
    finally:
        await ws_manager.disconnect(websocket)


# Export router
__all__ = ["router"]
