"""Machine registry CRUD + lifecycle controls.

Routes were extracted verbatim from main.py. The only structural changes:
- ``@app.<verb>("/api/machines/...")`` → ``@router.<verb>("/...")`` (router
  carries the prefix).
- ``broadcast_message(...)`` → ``await _broadcast(...)``, which goes through
  the shared WebSocketManager set during lifespan startup.
- ``run_portoser_command`` is imported from services.cli_runner instead of
  reaching into main.

Behaviour at the API boundary is unchanged — verified by the 9 pinning
tests in tests/test_inline_machines.py.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException

from models.registry_admin import MachineCreate, MachineUpdate
from services.cli_runner import run_portoser_command
from services.registry_helpers import load_registry, save_registry
from services.websocket_manager import WebSocketManager
from utils.validation import InputSanitizer

router = APIRouter(prefix="/api/machines", tags=["machines"])

# Set during lifespan startup by main.py (same pattern as auth, devices,
# cluster routers). Stays None outside of a running app — which is fine
# because every handler that calls _broadcast is itself called from inside
# a request, and the lifespan must have finished before requests arrive.
ws_manager: Optional[WebSocketManager] = None


async def _broadcast(message: Dict[str, Any]) -> None:
    if ws_manager is not None:
        await ws_manager.broadcast(message)


@router.get("")
async def list_machines() -> Dict[str, Any]:
    """Get all registered machines."""
    registry = load_registry()
    machines = []
    for name, host_cfg in registry.get("hosts", {}).items():
        machines.append(
            {
                "name": name,
                "ip": host_cfg.get("ip"),
                "ssh_user": host_cfg.get("ssh_user"),
                "roles": host_cfg.get("roles", []),
                "services_count": sum(
                    1
                    for svc in registry.get("services", {}).values()
                    if svc.get("current_host") == name
                ),
            }
        )
    return {"machines": machines}


@router.post("")
async def create_machine(machine: MachineCreate) -> Dict[str, Any]:
    """Register a new machine."""
    registry = load_registry()

    sanitized_name = InputSanitizer.sanitize_machine_name(machine.name)
    sanitized_ip = InputSanitizer.sanitize_hostname(machine.ip)
    sanitized_user = InputSanitizer.sanitize_service_name(machine.ssh_user)

    if sanitized_name in registry.get("hosts", {}):
        raise HTTPException(status_code=400, detail="Machine already exists")

    if "hosts" not in registry:
        registry["hosts"] = {}

    # Both `host` and `ip` are written: the schema requires `host` (the SSH
    # target) and existing consumers also read `ip`. Without `host`, the
    # next save_registry validates and rejects the write.
    registry["hosts"][sanitized_name] = {
        "host": sanitized_ip,
        "ip": sanitized_ip,
        "ssh_user": sanitized_user,
        "roles": machine.roles,
    }

    save_registry(registry)
    await _broadcast({"type": "machine_created", "machine": sanitized_name})
    return {"success": True, "machine": sanitized_name}


@router.get("/{machine_name}")
async def get_machine(machine_name: str) -> Dict[str, Any]:
    """Get details for a specific machine."""
    registry = load_registry()

    if machine_name not in registry.get("hosts", {}):
        raise HTTPException(status_code=404, detail="Machine not found")

    config = registry["hosts"][machine_name]
    services = [
        {"name": svc_name, **svc_config}
        for svc_name, svc_config in registry.get("services", {}).items()
        if svc_config.get("current_host") == machine_name
    ]
    return {
        "name": machine_name,
        "ip": config.get("ip"),
        "ssh_user": config.get("ssh_user"),
        "roles": config.get("roles", []),
        "services": services,
    }


@router.put("/{machine_name}")
async def update_machine(machine_name: str, update: MachineUpdate) -> Dict[str, Any]:
    """Update machine configuration."""
    registry = load_registry()
    sanitized_machine_name = InputSanitizer.sanitize_machine_name(machine_name)

    if sanitized_machine_name not in registry.get("hosts", {}):
        raise HTTPException(status_code=404, detail="Machine not found")

    machine = registry["hosts"][sanitized_machine_name]
    if update.ip is not None:
        machine["ip"] = InputSanitizer.sanitize_hostname(update.ip)
    if update.ssh_user is not None:
        machine["ssh_user"] = InputSanitizer.sanitize_service_name(update.ssh_user)
    if update.roles is not None:
        machine["roles"] = update.roles

    save_registry(registry)
    await _broadcast({"type": "machine_updated", "machine": sanitized_machine_name})
    return {"success": True}


@router.delete("/{machine_name}")
async def delete_machine(machine_name: str) -> Dict[str, Any]:
    """Delete a machine (only if no services are deployed on it)."""
    registry = load_registry()

    if machine_name not in registry.get("hosts", {}):
        raise HTTPException(status_code=404, detail="Machine not found")

    services_on_machine = [
        svc_name
        for svc_name, svc_config in registry.get("services", {}).items()
        if svc_config.get("current_host") == machine_name
    ]

    if services_on_machine:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot delete machine with services: {', '.join(services_on_machine)}",
        )

    del registry["hosts"][machine_name]
    save_registry(registry)
    await _broadcast({"type": "machine_deleted", "machine": machine_name})
    return {"success": True}


async def _machine_action(machine_name: str, action: str, timeout: int = 60) -> Dict[str, Any]:
    """Run start/stop/restart against every service on a machine via the CLI."""
    registry = load_registry()
    if machine_name not in registry.get("hosts", {}):
        raise HTTPException(status_code=404, detail="Machine not found")

    result = await run_portoser_command([action, machine_name], timeout=timeout)
    await _broadcast(
        {"type": f"machine_{action}", "machine": machine_name, "success": result["success"]}
    )
    return {"success": result["success"], "output": result["output"], "error": result.get("error")}


@router.post("/{machine_name}/start")
async def start_machine(machine_name: str) -> Dict[str, Any]:
    """Start all services on a machine."""
    return await _machine_action(machine_name, "start")


@router.post("/{machine_name}/stop")
async def stop_machine(machine_name: str) -> Dict[str, Any]:
    """Stop all services on a machine."""
    return await _machine_action(machine_name, "stop")


@router.post("/{machine_name}/restart")
async def restart_machine(machine_name: str) -> Dict[str, Any]:
    """Restart all services on a machine."""
    return await _machine_action(machine_name, "restart", timeout=120)
