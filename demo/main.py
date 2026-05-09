"""Path-1 demo backend.

Tiny FastAPI app that reads the demo registry, polls each service's health
endpoint, and serves a minimal dashboard. This is *not* the production web
backend (web/backend/) — it exists so a fresh clone can `docker compose up`
and see the registry -> health-check -> dashboard loop without standing up
Postgres, Redis, Keycloak, or mTLS.
"""
from __future__ import annotations

import asyncio
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
import yaml
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

REGISTRY_PATH = Path(os.getenv("REGISTRY_PATH", "/app/registry.demo.yml"))
POLL_INTERVAL = float(os.getenv("HEALTH_CHECK_INTERVAL", "5"))
POLL_TIMEOUT = float(os.getenv("HEALTH_CHECK_TIMEOUT", "3"))

_state: dict[str, Any] = {"registry": {}, "health": {}}


def load_registry() -> dict[str, Any]:
    if not REGISTRY_PATH.exists():
        return {"services": {}, "hosts": {}}
    with REGISTRY_PATH.open() as fh:
        return yaml.safe_load(fh) or {}


async def poll_health() -> None:
    async with httpx.AsyncClient(timeout=POLL_TIMEOUT) as client:
        while True:
            registry = _state["registry"]
            health: dict[str, dict[str, Any]] = {}
            for name, svc in (registry.get("services") or {}).items():
                url = (svc.get("health") or {}).get("url")
                if not url:
                    health[name] = {"status": "unknown", "reason": "no health.url"}
                    continue
                try:
                    resp = await client.get(url)
                    health[name] = {
                        "status": "healthy" if resp.status_code < 500 else "unhealthy",
                        "code": resp.status_code,
                    }
                except Exception as exc:
                    health[name] = {"status": "unhealthy", "reason": str(exc)[:120]}
            _state["health"] = health
            await asyncio.sleep(POLL_INTERVAL)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _state["registry"] = load_registry()
    task = asyncio.create_task(poll_health())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="Portoser Demo", lifespan=lifespan)


@app.get("/api/health")
def api_health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/services")
def api_services() -> JSONResponse:
    services = _state["registry"].get("services") or {}
    payload = []
    for name, svc in services.items():
        payload.append(
            {
                "name": name,
                "host": svc.get("host"),
                "image": svc.get("image"),
                "description": svc.get("description"),
                "health": _state["health"].get(name, {"status": "pending"}),
            }
        )
    return JSONResponse({"services": payload})


@app.get("/api/registry")
def api_registry() -> JSONResponse:
    return JSONResponse(_state["registry"])


DASHBOARD_DIR = Path(__file__).parent / "dashboard"
if DASHBOARD_DIR.is_dir():
    app.mount("/", StaticFiles(directory=str(DASHBOARD_DIR), html=True), name="dashboard")
else:
    @app.get("/")
    def index() -> HTMLResponse:
        return HTMLResponse("<h1>Portoser demo</h1><p>Dashboard files not found.</p>")
