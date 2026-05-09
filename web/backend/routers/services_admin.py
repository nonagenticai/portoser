"""Service registry CRUD + lifecycle controls.

Routes were extracted verbatim from main.py. The 10 endpoints split into
two natural groups:

- CRUD:    list / create / get / update / delete
- Control: start / stop / restart / rebuild / check_service_health

Same pattern as routers/machines.py: ``ws_manager`` is set during lifespan
startup and used to broadcast lifecycle events; ``run_portoser_command``
comes from ``services.cli_runner``.

The router is named ``services_admin`` rather than ``services`` so the
import doesn't collide with the existing ``services/`` package root.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Request

from models.registry_admin import ServiceCreate, ServiceUpdate
from services.cli_runner import run_portoser_command
from services.registry_helpers import load_registry, save_registry
from services.websocket_manager import WebSocketManager
from utils.validation import InputSanitizer

router = APIRouter(prefix="/api/services", tags=["services"])

# Set during lifespan startup by main.py.
ws_manager: Optional[WebSocketManager] = None


async def _broadcast(message: Dict[str, Any]) -> None:
    if ws_manager is not None:
        await ws_manager.broadcast(message)


@router.get("")
async def list_services() -> Dict[str, Any]:
    """Get all registered services."""
    registry = load_registry()
    services = []
    for name, svc_cfg in registry.get("services", {}).items():
        current_host = svc_cfg.get("current_host")
        services.append(
            {
                "name": name,
                "hostname": svc_cfg.get("hostname"),
                "current_host": current_host,
                "machine_name": current_host,  # Alias for frontend compatibility
                "deployment_type": svc_cfg.get("deployment_type"),
                "docker_compose": svc_cfg.get("docker_compose"),
                "service_file": svc_cfg.get("service_file"),
                "service_name": svc_cfg.get("service_name"),
                "port": svc_cfg.get("port"),
                "description": svc_cfg.get("description"),
                "dependencies": svc_cfg.get("dependencies", []),
                "tls_enabled": svc_cfg.get("tls", {}).get("enabled", False),
                "requires_auth": svc_cfg.get("auth", {}).get("enabled", False),
            }
        )
    return {"services": services}


@router.post("")
async def create_service(service: ServiceCreate) -> Dict[str, Any]:
    """Register a new service."""
    registry = load_registry()

    sanitized_service_name = InputSanitizer.sanitize_service_name(service.name)
    sanitized_hostname = (
        InputSanitizer.sanitize_hostname(service.hostname) if service.hostname else None
    )
    sanitized_host = InputSanitizer.sanitize_machine_name(service.current_host)

    if sanitized_service_name in registry.get("services", {}):
        raise HTTPException(status_code=400, detail="Service already exists")

    if "services" not in registry:
        registry["services"] = {}

    service_config = {
        "hostname": sanitized_hostname,
        "current_host": sanitized_host,
        "deployment_type": service.deployment_type,
    }

    if service.docker_compose:
        service_config["docker_compose"] = InputSanitizer.sanitize_path(service.docker_compose)
    if service.service_file:
        service_config["service_file"] = InputSanitizer.sanitize_path(service.service_file)
    if service.service_name:
        service_config["service_name"] = InputSanitizer.sanitize_service_name(service.service_name)

    registry["services"][sanitized_service_name] = service_config
    save_registry(registry)
    await _broadcast({"type": "service_created", "service": sanitized_service_name})
    return {"success": True, "service": sanitized_service_name}


@router.get("/{service_name}")
async def get_service(service_name: str) -> Dict[str, Any]:
    """Get details for a specific service.

    Skips the SSH-backed health check when the service's host is marked
    offline in the registry — otherwise every detail-page open blocks on
    the CLI's ConnectTimeout. "unknown" is the honest answer when we
    can't actually reach the host.
    """
    registry = load_registry()

    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    config = registry["services"][service_name]
    host_name = config.get("current_host") or config.get("machine_name")
    host_cfg = registry.get("hosts", {}).get(host_name) if host_name else None
    host_offline = bool(host_cfg) and host_cfg.get("status", "unknown") != "online"

    if host_offline:
        health = "unknown"
    else:
        health_result = await run_portoser_command(["health", "check", service_name], timeout=10)
        health = "healthy" if health_result["success"] else "unhealthy"

    return {
        "name": service_name,
        **config,
        "health": health,
    }


@router.put("/{service_name}")
async def update_service(service_name: str, update: ServiceUpdate) -> Dict[str, Any]:
    """Update service configuration."""
    registry = load_registry()
    sanitized_service_name = InputSanitizer.sanitize_service_name(service_name)

    if sanitized_service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    service = registry["services"][sanitized_service_name]
    if update.hostname is not None:
        service["hostname"] = InputSanitizer.sanitize_hostname(update.hostname)
    if update.current_host is not None:
        service["current_host"] = InputSanitizer.sanitize_machine_name(update.current_host)
    if update.deployment_type is not None:
        service["deployment_type"] = update.deployment_type
    if update.docker_compose is not None:
        service["docker_compose"] = InputSanitizer.sanitize_path(update.docker_compose)
    if update.service_file is not None:
        service["service_file"] = InputSanitizer.sanitize_path(update.service_file)
    if update.service_name is not None:
        service["service_name"] = InputSanitizer.sanitize_service_name(update.service_name)

    save_registry(registry)
    await _broadcast({"type": "service_updated", "service": sanitized_service_name})
    return {"success": True}


@router.delete("/{service_name}")
async def delete_service(service_name: str, force: bool = False) -> Dict[str, Any]:
    """Delete a service."""
    registry = load_registry()

    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    if not force:
        try:
            await run_portoser_command(["stop", service_name], timeout=30)
        except Exception:
            pass

    del registry["services"][service_name]
    save_registry(registry)
    await _broadcast({"type": "service_deleted", "service": service_name})
    return {"success": True}


@router.post("/{service_name}/start")
async def start_service(service_name: str) -> Dict[str, Any]:
    """Start a service."""
    registry = load_registry()

    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    result = await run_portoser_command(["start", service_name], timeout=30)
    await _broadcast(
        {"type": "service_started", "service": service_name, "success": result["success"]}
    )
    return {"success": result["success"], "output": result["output"], "error": result.get("error")}


@router.post("/{service_name}/stop")
async def stop_service(service_name: str, force: bool = False) -> Dict[str, Any]:
    """Stop a service."""
    registry = load_registry()

    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    args = ["stop", service_name]
    if force:
        args.append("--force")

    result = await run_portoser_command(args, timeout=30)
    await _broadcast(
        {"type": "service_stopped", "service": service_name, "success": result["success"]}
    )
    return {"success": result["success"], "output": result["output"], "error": result.get("error")}


@router.post("/{service_name}/restart")
async def restart_service(service_name: str) -> Dict[str, Any]:
    """Restart a service."""
    registry = load_registry()

    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    service = registry["services"][service_name]
    deployment_type = service.get("deployment_type")
    current_host = service.get("current_host")

    if deployment_type == "docker":
        result = await run_portoser_command(
            ["docker", "restart", service_name, current_host], timeout=60
        )
    else:
        result = await run_portoser_command(
            ["local", "restart", service_name, current_host], timeout=60
        )

    await _broadcast(
        {"type": "service_restarted", "service": service_name, "success": result["success"]}
    )
    return {"success": result["success"], "output": result["output"], "error": result.get("error")}


@router.post("/{service_name}/rebuild")
async def rebuild_service(service_name: str, request: Request) -> Dict[str, Any]:
    """Rebuild a Docker service (docker-compose down + build + up)."""
    if await request.is_disconnected():
        raise HTTPException(status_code=408, detail="Client disconnected")

    registry = load_registry()
    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    service = registry["services"][service_name]
    deployment_type = service.get("deployment_type")

    if deployment_type != "docker":
        raise HTTPException(status_code=400, detail="Rebuild only available for Docker services")

    current_host = service.get("current_host")
    await _broadcast({"type": "service_rebuilding", "service": service_name})

    stop_result = await run_portoser_command(
        ["docker", "stop", service_name, current_host], timeout=30
    )
    if not stop_result["success"]:
        return {"success": False, "error": "Failed to stop service before rebuild"}

    build_result = await run_portoser_command(
        ["docker", "build", service_name, current_host], stream=True, timeout=600
    )
    if not build_result["success"]:
        return {"success": False, "error": "Failed to build service"}

    deploy_result = await run_portoser_command(
        ["docker", "deploy", service_name, current_host], stream=True, timeout=120
    )

    await _broadcast(
        {"type": "service_rebuilt", "service": service_name, "success": deploy_result["success"]}
    )
    return {
        "success": deploy_result["success"],
        "output": deploy_result["output"],
        "error": deploy_result.get("error"),
    }


@router.get("/{service_name}/health")
async def check_service_health(service_name: str) -> Dict[str, Any]:
    """Check health status of a service.

    Returns ``status="unknown"`` rather than running the SSH-based health
    probe synchronously — that slows the UI to a crawl on large clusters.
    Real health data flows through the metrics collector in the background.
    """
    registry = load_registry()
    if service_name not in registry.get("services", {}):
        raise HTTPException(status_code=404, detail="Service not found")

    status = "unknown"
    return {
        "service": service_name,
        "status": status,
        "healthy": status == "healthy",
        "output": f"Health check disabled for performance. Status: {status}",
    }
