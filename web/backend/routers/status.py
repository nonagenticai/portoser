"""GET /api/status — overall cluster status via the portoser CLI.

Single-endpoint router. Extracted from main.py inline routes.
"""

from __future__ import annotations

from typing import Any, Dict

from fastapi import APIRouter, HTTPException

from services.cli_runner import run_portoser_command

router = APIRouter(prefix="/api", tags=["status"])

# The portoser status CLI iterates every service, then SSH-probes the host
# each one is deployed on (5s ConnectTimeout per attempt × ~38 services in
# the seed registry × multiple probes per service can run >100s when none
# of the hosts are reachable from the workstation). 30s is a deliberate
# cap: a healthy cluster-host execution returns in <5s, and a workstation
# hitting offline hosts quickly hits the cap and gets a degraded response
# rather than blocking the request indefinitely.
_STATUS_CLI_TIMEOUT_SECONDS = 30


@router.get("/status")
async def get_cluster_status() -> Dict[str, Any]:
    """Get overall cluster status.

    Returns 200 in both happy and degraded paths so the UI can render
    "cluster unreachable" without having to special-case 504. A 5xx is
    only raised for unexpected exec failures (covered by run_portoser_command).
    """
    # Short-circuit when the registry says no hosts are online. The CLI
    # would just SSH-probe every offline host serially and time out per-host;
    # we already know the answer from the registry.
    synthetic = _maybe_synthetic_offline_status()
    if synthetic is not None:
        return synthetic

    try:
        result = await run_portoser_command(["status"], timeout=_STATUS_CLI_TIMEOUT_SECONDS)
    except HTTPException as exc:
        # 504 is the expected timeout signal. Surface it as a degraded
        # success-shaped body — the UI just shows the output verbatim and
        # this message is more actionable than an opaque "timed out".
        if exc.status_code == 504:
            return {
                "success": False,
                "output": (
                    f"[status query exceeded {_STATUS_CLI_TIMEOUT_SECONDS}s — typical for "
                    "a workstation querying offline cluster hosts. Run `portoser status` "
                    "directly on a cluster-reachable host for full output.]"
                ),
            }
        raise
    return {"success": result["success"], "output": result["output"]}


def _maybe_synthetic_offline_status() -> Dict[str, Any] | None:
    """Build a status dump from registry.yml when no online hosts exist.

    Returns None when at least one host is online (so the real CLI runs)
    or when the registry can't be read (fail open).
    """
    try:
        import os
        from pathlib import Path

        from services.registry_service import RegistryService

        registry_path = os.getenv("CADDY_REGISTRY_PATH") or os.getenv("PORTOSER_REGISTRY")
        if not registry_path:
            # Fall back to <repo>/registry.yml. routers/status.py lives at
            # web/backend/routers/, so parents[3] is the repo root.
            registry_path = str(Path(__file__).resolve().parents[3] / "registry.yml")

        registry = RegistryService(registry_path=registry_path)
        data = registry.read()
        hosts = data.get("hosts", {}) or {}
        services = data.get("services", {}) or {}

        if not hosts:
            return None
        if any((cfg or {}).get("status") == "online" for cfg in hosts.values()):
            return None

        # Render a minimal text dump matching the CLI's "Service Status Overview"
        # format closely enough that the UI's pre-formatted output looks right.
        lines = [
            "Portoser - Service Status Overview",
            "======================================",
            "",
            f"{'SERVICE':<25} {'TYPE':<10} {'MACHINE':<15} {'STATUS':<10} HEALTH",
            "-" * 80,
        ]
        for name, cfg in services.items():
            cfg = cfg or {}
            stype = cfg.get("deployment_type") or "unknown"
            machine = cfg.get("current_host") or "unknown"
            lines.append(f"{name:<25} {stype:<10} {machine:<15} {'offline':<10} -")
        lines.append("")
        lines.append("[all hosts marked offline in registry — no SSH probe performed]")
        return {"success": True, "output": "\n".join(lines)}
    except Exception:
        return None
