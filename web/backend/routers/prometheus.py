"""GET /metrics — Prometheus exposition.

Single-endpoint router. Reads from the existing prometheus_monitoring
helper in utils. Extracted from main.py inline routes.
"""

from __future__ import annotations

from fastapi import APIRouter, Response

from utils.prometheus_monitoring import metrics_endpoint

router = APIRouter(tags=["monitoring"])


@router.get("/metrics")
async def prometheus_metrics() -> Response:
    """Return metrics in Prometheus exposition format for scraping."""
    metrics_output, content_type, status_code = metrics_endpoint()
    return Response(content=metrics_output, media_type=content_type, status_code=status_code)
