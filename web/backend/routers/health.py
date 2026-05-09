"""Health-check router.

Owns:
  - GET /health                    — quick status (no external deps)
  - GET /api/health                — service identification (registry/vault/keycloak)
  - GET /api/health/comprehensive  — full dependency probe with timings
  - GET /api/health/dashboard      — aggregated cluster/service health for the UI
  - GET /api/health/timeline       — per-service health changes over time
  - GET /api/health/heatmap        — problem-frequency heatmap
"""

from __future__ import annotations

import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import yaml
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from config import config
from services.health_monitor import HealthMonitor
from services.registry_service import RegistryService

logger = logging.getLogger(__name__)

router = APIRouter()

# Set during lifespan startup by main.py. The /api/health probes report on
# whether these are available.
vault_client: Optional[Any] = None
keycloak_client: Optional[Any] = None
ws_manager: Optional[Any] = None
health_monitor: Optional[HealthMonitor] = None
SERVICE_NAME: str = "portoser-web"
VERSION: str = "1.0.0"
REGISTRY_PATH: Optional[str] = None
PORTOSER_CLI: Optional[str] = None


def _get_health_monitor() -> HealthMonitor:
    """Dependency-style accessor for the module-level singleton."""
    if health_monitor is None:
        raise HTTPException(status_code=503, detail="Health monitor not initialized")
    return health_monitor


def _ensure_registry_seeded(monitor: HealthMonitor) -> None:
    """If the in-memory health map is empty, seed it from the registry so
    the dashboard isn't a blank page on cold start. Mirrors the same fallback
    in routers/diagnostics.py:get_all_health_checks. Idempotent — once
    diagnostics or probes populate real entries, this is a no-op."""
    if monitor.get_all_service_health():
        return
    try:
        registry_path = (
            os.getenv("CADDY_REGISTRY_PATH")
            or os.getenv("PORTOSER_REGISTRY")
            or REGISTRY_PATH
            or str(Path(__file__).resolve().parents[3] / "registry.yml")
        )
        registry = RegistryService(registry_path=registry_path)
        for svc in registry.get_all_services():
            monitor.update_service_health(
                service=svc.name,
                machine=svc.current_host,
                health_score=0,
                issues=["Health monitoring not yet configured - showing registry data"],
                uptime_seconds=None,
                response_time_ms=None,
            )
    except Exception as e:
        logger.warning(f"Could not seed health from registry: {e}")


class HealthResponse(BaseModel):
    """Health check response model."""

    status: str
    service: str
    version: str
    environment: str
    timestamp: str
    vault: str = "not_configured"
    keycloak: str = "not_configured"
    registry: str = "not_configured"


@router.get("/health")
async def health_check(request: Request) -> Dict[str, Any]:
    """Quick health check — no external dependencies."""
    try:
        registry_exists = os.path.exists(config.registry_path)
        background_workers = {
            "enabled": config.enable_background_workers,
            "metrics_queue": "unknown",
            "metrics_collector": "unknown",
            "metrics_prefetcher": "unknown",
            "device_monitor": "unknown",
        }

        if hasattr(request.app.state, "worker_manager"):
            import asyncio

            worker_manager = request.app.state.worker_manager
            if hasattr(worker_manager, "workers"):
                workers_status = {}
                for worker_name, task in worker_manager.workers.items():
                    if isinstance(task, asyncio.Task):
                        workers_status[worker_name] = "running" if not task.done() else "stopped"
                    else:
                        workers_status[worker_name] = "unknown"

                background_workers.update(
                    {
                        "metrics_queue": workers_status.get("metrics_queue", "disabled"),
                        "metrics_collector": workers_status.get("metrics_collector", "disabled"),
                        "metrics_prefetcher": workers_status.get("metrics_prefetcher", "disabled"),
                        "device_monitor": workers_status.get("device_health_monitor", "disabled"),
                    }
                )

        config_warnings = config.validate_startup_config()

        return {
            "status": "healthy",
            "registry_exists": registry_exists,
            "background_workers": background_workers,
            "config_status": {
                "valid": len(config_warnings) == 0,
                "warnings_count": len(config_warnings),
                "environment": config.environment,
                "keycloak_enabled": config.keycloak_enabled,
                "background_workers_enabled": config.enable_background_workers,
            },
        }
    except Exception as e:
        return {"status": "degraded", "error": str(e)}


@router.get("/api/health", response_model=HealthResponse)
async def api_health() -> Dict[str, Any]:
    """API health check — reports presence of vault/keycloak/registry."""
    return {
        "status": "healthy",
        "service": SERVICE_NAME,
        "version": VERSION,
        "environment": config.environment,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "vault": "connected" if vault_client else "disabled",
        "keycloak": "connected" if keycloak_client else "disabled",
        "registry": (
            "connected" if (REGISTRY_PATH and Path(REGISTRY_PATH).exists()) else "not_found"
        ),
    }


@router.get("/api/health/comprehensive")
async def comprehensive_health_check(request: Request):
    """Comprehensive health check that probes all dependencies.

    Probes vault, keycloak, registry, portoser CLI, MCP database, redis,
    metrics queue, and the circuit-breaker registry. Each check includes
    response_time_ms. Returns 503 when any required dependency is degraded.
    """
    health_results: Dict[str, Any] = {
        "status": "healthy",
        "service": SERVICE_NAME,
        "version": VERSION,
        "environment": config.environment,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "checks": {},
    }
    overall_healthy = True

    # Vault
    vault_start = time.time()
    if config.vault_enabled:
        try:
            if vault_client:
                vault_client.client.sys.read_health_status()
                health_results["checks"]["vault"] = {
                    "status": "healthy",
                    "message": "Vault is connected and responding",
                    "response_time_ms": round((time.time() - vault_start) * 1000, 2),
                }
            else:
                health_results["checks"]["vault"] = {
                    "status": "unhealthy",
                    "message": "Vault is enabled but client not initialized",
                    "response_time_ms": round((time.time() - vault_start) * 1000, 2),
                }
                overall_healthy = False
        except Exception as e:
            health_results["checks"]["vault"] = {
                "status": "unhealthy",
                "message": f"Vault connection failed: {str(e)}",
                "response_time_ms": round((time.time() - vault_start) * 1000, 2),
            }
            overall_healthy = False
    else:
        health_results["checks"]["vault"] = {
            "status": "disabled",
            "message": "Vault is not enabled",
            "response_time_ms": 0,
        }

    # Keycloak
    keycloak_start = time.time()
    if config.keycloak_enabled:
        try:
            if keycloak_client:
                keycloak_client.get_realm_info()
                health_results["checks"]["keycloak"] = {
                    "status": "healthy",
                    "message": f"Keycloak is connected (realm: {config.keycloak_realm})",
                    "response_time_ms": round((time.time() - keycloak_start) * 1000, 2),
                }
            else:
                health_results["checks"]["keycloak"] = {
                    "status": "unhealthy",
                    "message": "Keycloak is enabled but client not initialized",
                    "response_time_ms": round((time.time() - keycloak_start) * 1000, 2),
                }
                overall_healthy = False
        except Exception as e:
            health_results["checks"]["keycloak"] = {
                "status": "unhealthy",
                "message": f"Keycloak connection failed: {str(e)}",
                "response_time_ms": round((time.time() - keycloak_start) * 1000, 2),
            }
            overall_healthy = False
    else:
        health_results["checks"]["keycloak"] = {
            "status": "disabled",
            "message": "Keycloak is not enabled",
            "response_time_ms": 0,
        }

    # Registry file
    registry_start = time.time()
    try:
        rp = Path(REGISTRY_PATH) if REGISTRY_PATH else None
        if rp and rp.exists():
            with open(rp, "r") as f:
                yaml.safe_load(f)
            health_results["checks"]["registry"] = {
                "status": "healthy",
                "message": f"Registry file is accessible at {REGISTRY_PATH}",
                "response_time_ms": round((time.time() - registry_start) * 1000, 2),
            }
        else:
            health_results["checks"]["registry"] = {
                "status": "unhealthy",
                "message": f"Registry file not found at {REGISTRY_PATH}",
                "response_time_ms": round((time.time() - registry_start) * 1000, 2),
            }
            overall_healthy = False
    except Exception as e:
        health_results["checks"]["registry"] = {
            "status": "unhealthy",
            "message": f"Registry file error: {str(e)}",
            "response_time_ms": round((time.time() - registry_start) * 1000, 2),
        }
        overall_healthy = False

    # Portoser CLI
    cli_start = time.time()
    try:
        cp = Path(PORTOSER_CLI) if PORTOSER_CLI else None
        if cp and cp.exists() and os.access(cp, os.X_OK):
            health_results["checks"]["portoser_cli"] = {
                "status": "healthy",
                "message": f"Portoser CLI is accessible at {PORTOSER_CLI}",
                "response_time_ms": round((time.time() - cli_start) * 1000, 2),
            }
        else:
            health_results["checks"]["portoser_cli"] = {
                "status": "unhealthy",
                "message": f"Portoser CLI not found or not executable at {PORTOSER_CLI}",
                "response_time_ms": round((time.time() - cli_start) * 1000, 2),
            }
            overall_healthy = False
    except Exception as e:
        health_results["checks"]["portoser_cli"] = {
            "status": "unhealthy",
            "message": f"Portoser CLI check failed: {str(e)}",
            "response_time_ms": round((time.time() - cli_start) * 1000, 2),
        }
        overall_healthy = False

    # MCP Database
    mcp_start = time.time()
    if hasattr(request.app.state, "mcp_enabled") and request.app.state.mcp_enabled:
        try:
            if hasattr(request.app.state, "mcp_db"):
                await request.app.state.mcp_db.execute("SELECT 1")
                health_results["checks"]["mcp_database"] = {
                    "status": "healthy",
                    "message": "MCP database is connected and responding",
                    "response_time_ms": round((time.time() - mcp_start) * 1000, 2),
                }
            else:
                health_results["checks"]["mcp_database"] = {
                    "status": "unhealthy",
                    "message": "MCP is enabled but database not initialized",
                    "response_time_ms": round((time.time() - mcp_start) * 1000, 2),
                }
                overall_healthy = False
        except Exception as e:
            health_results["checks"]["mcp_database"] = {
                "status": "unhealthy",
                "message": f"MCP database connection failed: {str(e)}",
                "response_time_ms": round((time.time() - mcp_start) * 1000, 2),
            }
            overall_healthy = False
    else:
        health_results["checks"]["mcp_database"] = {
            "status": "disabled",
            "message": "MCP is not enabled",
            "response_time_ms": 0,
        }

    # Redis (if enabled)
    redis_start = time.time()
    redis_enabled = os.getenv("REDIS_ENABLED", "false").lower() == "true"
    if redis_enabled:
        try:
            import redis.asyncio as redis

            redis_host = os.getenv("REDIS_HOST", "localhost")
            redis_port = int(os.getenv("REDIS_PORT", "8987"))
            redis_client = redis.Redis(
                host=redis_host,
                port=redis_port,
                decode_responses=False,
                socket_connect_timeout=2,
                socket_timeout=2,
            )
            await redis_client.ping()
            await redis_client.close()
            health_results["checks"]["redis"] = {
                "status": "healthy",
                "message": f"Redis is connected at {redis_host}:{redis_port}",
                "response_time_ms": round((time.time() - redis_start) * 1000, 2),
            }
        except Exception as e:
            health_results["checks"]["redis"] = {
                "status": "unhealthy",
                "message": f"Redis connection failed: {str(e)}",
                "response_time_ms": round((time.time() - redis_start) * 1000, 2),
            }
            overall_healthy = False
    else:
        health_results["checks"]["redis"] = {
            "status": "disabled",
            "message": "Redis is not enabled",
            "response_time_ms": 0,
        }

    # Metrics queue
    queue_start = time.time()
    if hasattr(request.app.state, "metrics_queue"):
        try:
            queue = request.app.state.metrics_queue
            health_results["checks"]["metrics_queue"] = {
                "status": "healthy",
                "message": f"Metrics queue is running (queue size: {queue.queue_size})",
                "response_time_ms": round((time.time() - queue_start) * 1000, 2),
                "details": {
                    "queue_size": queue.queue_size,
                    "processed": queue.processed_count,
                    "failed": queue.failed_count,
                },
            }
        except Exception as e:
            health_results["checks"]["metrics_queue"] = {
                "status": "unhealthy",
                "message": f"Metrics queue check failed: {str(e)}",
                "response_time_ms": round((time.time() - queue_start) * 1000, 2),
            }
    else:
        health_results["checks"]["metrics_queue"] = {
            "status": "not_initialized",
            "message": "Metrics queue not initialized",
            "response_time_ms": 0,
        }

    # Circuit breaker registry
    cb_start = time.time()
    if hasattr(request.app.state, "circuit_breaker_registry"):
        try:
            health_results["checks"]["circuit_breaker"] = {
                "status": "healthy",
                "message": "Circuit breaker registry is initialized",
                "response_time_ms": round((time.time() - cb_start) * 1000, 2),
            }
        except Exception as e:
            health_results["checks"]["circuit_breaker"] = {
                "status": "unhealthy",
                "message": f"Circuit breaker check failed: {str(e)}",
                "response_time_ms": round((time.time() - cb_start) * 1000, 2),
            }
    else:
        health_results["checks"]["circuit_breaker"] = {
            "status": "not_initialized",
            "message": "Circuit breaker registry not initialized",
            "response_time_ms": 0,
        }

    health_results["status"] = "healthy" if overall_healthy else "degraded"
    health_results["healthy_checks"] = sum(
        1
        for check in health_results["checks"].values()
        if check["status"] in ["healthy", "disabled"]
    )
    health_results["total_checks"] = len(health_results["checks"])

    status_code = 200 if overall_healthy else 503
    return JSONResponse(status_code=status_code, content=health_results)


@router.get("/api/health/dashboard")
async def api_health_dashboard(refresh: bool = True):
    """Aggregated dashboard payload consumed by the FE HealthDashboard page.

    Returns the HealthDashboard model directly (total_services,
    healthy/degraded/unhealthy counts, overall_health_score, services list).
    """
    monitor = _get_health_monitor()
    if refresh:
        _ensure_registry_seeded(monitor)
    return monitor.get_health_dashboard()


@router.get("/api/health/timeline")
async def api_health_timeline(hours: int = 24):
    """Health-state timeline (events) over the last `hours` hours."""
    monitor = _get_health_monitor()
    end_time = datetime.now(timezone.utc)
    start_time = end_time.replace(microsecond=0)
    # Subtract `hours` worth of seconds. We keep this simple instead of
    # pulling in timedelta from a different import line.
    start_time = datetime.fromtimestamp(
        end_time.timestamp() - max(hours, 0) * 3600, tz=timezone.utc
    )
    return monitor.get_health_timeline(start_time=start_time, end_time=end_time)


@router.get("/api/health/heatmap")
async def api_health_heatmap(days: int = 30):
    """Problem-frequency heatmap over the last `days` days."""
    monitor = _get_health_monitor()
    return monitor.get_problem_heatmap(days=max(days, 1))
