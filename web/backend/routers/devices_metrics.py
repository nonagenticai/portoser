"""
Device Metrics API Router - Prometheus metrics endpoint for device onboarding
"""

import logging

from fastapi import APIRouter, Response

from monitoring.device_metrics import get_metrics

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/devices", tags=["devices", "metrics"])


@router.get("/metrics")
async def device_metrics_endpoint():
    """
    Prometheus metrics endpoint for device onboarding system

    Returns metrics in Prometheus exposition format:
    - devices_registered_total: Counter of registered devices
    - devices_online: Gauge of currently online devices
    - registration_duration_seconds: Histogram of registration times
    - registry_lock_wait_seconds: Histogram of lock wait times
    - device_deregistrations_total: Counter of deregistrations
    - device_updates_total: Counter of device updates
    - registry_operations_total: Counter of registry operations
    - registry_validation_errors_total: Counter of validation errors
    - registry_size_bytes: Gauge of registry file size
    - registry_backup_age_seconds: Gauge of backup age
    - device_heartbeats_total: Counter of heartbeats
    - device_last_seen_seconds: Gauge of time since last seen
    - device_resources: Gauge of device resources
    """
    logger.info("Serving device metrics for Prometheus")

    metrics_output, content_type, status_code = get_metrics()

    return Response(content=metrics_output, media_type=content_type, status_code=status_code)
