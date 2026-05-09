"""
Portoser Web Interface - Backend API
FastAPI backend for managing cluster deployments with drag-and-drop interface

Integrated with:
- Keycloak for authentication
- HashiCorp Vault for secrets management
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

import _warnings_setup  # noqa: F401  # silences 3rd-party deprecation warnings before other imports
from auth.middleware import KeycloakAuthMiddleware
from auth.websocket import authenticate_websocket
from config import config
from keycloak_client import KeycloakClient
from routers import (
    auth_router,
    certificates_router,
    cluster_router,
    config_router,
    dependencies_router,
    deployment_router,
    devices_metrics_router,
    devices_router,
    diagnostics_router,
    health_router,
    history_router,
    knowledge_router,
    machines_router,
    mcp_router,
    prometheus_router,
    services_admin_router,
    status_router,
    vault_router,
)
from routers import metrics as metrics_router_module
from routers import uptime as uptime_router_module
from routers.metrics_health import create_metrics_health_router
from routers.websocket_metrics import create_metrics_websocket_router
from services import WebSocketManager
from services.startup import run_shutdown, run_startup
from utils.exception_handlers import (
    global_exception_handler,
    http_exception_handler,
    not_found_handler,
    validation_exception_handler,
)
from utils.request_logging import RequestLoggingMiddleware
from vault_client import VaultClient

# Configuration from environment
SERVICE_NAME = os.getenv("SERVICE_NAME", "portoser-web")
VERSION = os.getenv("VERSION", "1.0.0")

# Default paths derived from this file's location so the package works without
# hard-coded user-specific paths. On a source checkout, web/backend/main.py ->
# parents[2] is the repo root. In a Docker image, main.py lives at /app/main.py
# (no parents[2]); container deployments set CADDY_REGISTRY_PATH and
# PORTOSER_CLI explicitly via env, so an unreachable default is fine.
try:
    _REPO_ROOT: Path = Path(__file__).resolve().parents[2]
except IndexError:
    _REPO_ROOT = Path("/nonexistent")
DEFAULT_REGISTRY_PATH = str(_REPO_ROOT / "registry.yml")
DEFAULT_PORTOSER_CLI = str(_REPO_ROOT / "portoser")

# Setup structured logging
from utils.logging_setup import setup_logging  # noqa: E402

setup_logging()
logger = logging.getLogger(__name__)


# Module-level WebSocketManager: created in lifespan() and exposed at module
# scope so endpoints declared at module-level (e.g. /ws/devices) can refer to
# it. Stays None until startup; endpoints must guard against that.
ws_manager: Optional[WebSocketManager] = None


# Lifespan context manager for startup/shutdown events
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan event handler for startup and shutdown."""
    global ws_manager
    # Build core services + wire routers + start workers + start MCP.
    services = await run_startup(
        app,
        vault_client=vault_client,
        keycloak_client=keycloak_client,
        service_name=SERVICE_NAME,
        version=VERSION,
        default_registry_path=DEFAULT_REGISTRY_PATH,
        default_portoser_cli=DEFAULT_PORTOSER_CLI,
    )
    # The /ws and /ws/devices module-level endpoints reach for ws_manager
    # via the global; expose what startup built.
    ws_manager = services.ws_manager
    try:
        yield
    finally:
        await run_shutdown(app, services, SERVICE_NAME)


app = FastAPI(
    title=SERVICE_NAME,
    description="Portoser Web Interface for managing cluster deployments",
    version=VERSION,
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
)

# Register routers
app.include_router(auth_router)
app.include_router(deployment_router)
app.include_router(diagnostics_router)
app.include_router(health_router)
app.include_router(knowledge_router)
app.include_router(vault_router)
app.include_router(dependencies_router)
app.include_router(history_router)
app.include_router(mcp_router)
app.include_router(certificates_router)
app.include_router(devices_router)
app.include_router(devices_metrics_router)
app.include_router(config_router)
app.include_router(cluster_router)
app.include_router(machines_router)
app.include_router(services_admin_router)
app.include_router(status_router)
app.include_router(prometheus_router)
app.include_router(metrics_router_module.router)
app.include_router(uptime_router_module.router)

# Bootstrap script compatibility: alias /api/register to /api/devices/register
from models.device import DeviceRegistrationRequest, DeviceRegistrationResponse  # noqa: E402
from routers.devices import register_device as device_register_handler  # noqa: E402


@app.post(
    "/api/register",
    response_model=DeviceRegistrationResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["devices", "bootstrap-compatibility"],
)
async def register_device_compat(request: DeviceRegistrationRequest):
    """
    Backward compatibility endpoint for bootstrap script

    This endpoint aliases /api/devices/register to maintain compatibility
    with existing bootstrap.sh scripts that expect /api/register
    """
    logger.info(f"Bootstrap registration request forwarded: {request.hostname}")
    return await device_register_handler(request)


# Register device WebSocket endpoint
@app.websocket("/ws/devices")
async def device_websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time device events.

    Protocol (client → server):
        {"action": "subscribe"}                     subscribe to all devices
        {"action": "subscribe", "hostname": "..."}  subscribe to one device
        {"action": "unsubscribe"}                   unsubscribe from all
        {"action": "unsubscribe", "hostname": ...}  unsubscribe from one
        {"action": "ping"}                          heartbeat → pong reply

    Server → client events:
        {"type": "connected", "timestamp": ...}
        {"type": "device_registered", "hostname": ..., "ip": ..., ...}
        {"type": "device_heartbeat", "hostname": ..., "status": ..., ...}
        {"type": "device_offline", "hostname": ..., ...}
        {"type": "pong", "timestamp": ...}
        {"type": "error", "message": ...}
    """
    import json as _json

    if await authenticate_websocket(websocket) is None:
        return

    # Reuse the same WebSocketManager all other routers share so
    # device-router-emitted events reach this connection.
    if ws_manager is None:
        await websocket.close(code=1011, reason="WebSocket manager not initialized")
        return

    await ws_manager.connect(websocket)
    try:
        await websocket.send_json(
            {
                "type": "connected",
                "message": "Connected to device events stream",
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        )

        while True:
            try:
                data = await websocket.receive_json()
            except _json.JSONDecodeError:
                await websocket.send_json(
                    {
                        "type": "error",
                        "message": "Invalid JSON",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    }
                )
                continue

            action = data.get("action")
            hostname = data.get("hostname")

            if action == "subscribe":
                await ws_manager.subscribe_device(websocket, hostname)
                await websocket.send_json(
                    {
                        "type": "subscribed",
                        "hostname": hostname or "*",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    }
                )
            elif action == "unsubscribe":
                await ws_manager.unsubscribe_device(websocket, hostname)
                await websocket.send_json(
                    {
                        "type": "unsubscribed",
                        "hostname": hostname or "*",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    }
                )
            elif action == "ping":
                await websocket.send_json(
                    {"type": "pong", "timestamp": datetime.now(timezone.utc).isoformat()}
                )
            else:
                await websocket.send_json(
                    {
                        "type": "error",
                        "message": f"Unknown action: {action}",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    }
                )
    except WebSocketDisconnect:
        logger.info("Device WebSocket client disconnected")
    except Exception as e:
        logger.error(f"Error in device WebSocket: {e}")
    finally:
        await ws_manager.unsubscribe_device(websocket)
        await ws_manager.disconnect(websocket)


# Register metrics health router
# We create it with None for services since they're initialized in lifespan
# The endpoint will access them via the app.state or module globals
metrics_health_router = create_metrics_health_router(
    metrics_service=None,  # Will use module-level metrics_service from metrics_router_module
    metrics_collector=None,  # Will use module-level metrics_collector from metrics_router_module
)
app.include_router(metrics_health_router)

# Register WebSocket metrics router
# Note: This creates a new /api/ws/metrics endpoint separate from the existing /api/metrics/ws
# The new endpoint provides enhanced subscription management for real-time metrics updates
websocket_metrics_router = create_metrics_websocket_router(
    ws_manager=None,  # Will be set during lifespan startup
    metrics_service=None,  # Will use module-level metrics_service from metrics_router_module
)
app.include_router(websocket_metrics_router)

# Mount static files for bootstrap script
frontend_public = Path(__file__).parent.parent / "frontend" / "public"
if frontend_public.exists():
    app.mount("/static", StaticFiles(directory=str(frontend_public)), name="static")
    logger.info(f"Mounted static files from {frontend_public}")

# Serve compose.sh for bootstrap
from fastapi.responses import FileResponse  # noqa: E402


@app.get("/compose.sh")
async def get_compose_script():
    """Serve compose.sh for device bootstrap"""
    compose_path = Path(__file__).parent.parent.parent / "compose.sh"
    if not compose_path.exists():
        raise HTTPException(status_code=404, detail="compose.sh not found")
    return FileResponse(
        path=str(compose_path), media_type="text/x-shellscript", filename="compose.sh"
    )


# Add CORS middleware (before auth middleware)
# Build allowed origins from CORS_ALLOWED_ORIGINS env var (comma-separated).
# Operators must explicitly list any non-localhost origins they want allowed
# (e.g. "https://portoser.example.com,https://node-1.example.com:8008").
_cors_env = os.getenv("CORS_ALLOWED_ORIGINS", "").strip()
allowed_origins: List[str] = [o.strip() for o in _cors_env.split(",") if o.strip()]

# Only allow localhost in development
if config.environment != "production":
    allowed_origins.extend(
        [
            "http://localhost:8989",
            "http://localhost:5173",
            "https://localhost:8989",
        ]
    )
else:
    logger.info("Production mode: localhost origins disabled for CORS")

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Add rate limiting middleware (after CORS, before security headers)
# Only enable if Redis is available
redis_enabled = os.getenv("REDIS_ENABLED", "false").lower() == "true"
if redis_enabled:
    try:
        import redis.asyncio as redis

        from middleware.rate_limiter import RateLimitMiddleware

        redis_host = os.getenv("REDIS_HOST", "localhost")
        redis_port = int(os.getenv("REDIS_PORT", "8987"))
        redis_db = int(os.getenv("REDIS_DB", "0"))

        redis_client = redis.Redis(
            host=redis_host,
            port=redis_port,
            db=redis_db,
            decode_responses=False,
            socket_connect_timeout=5,
            socket_timeout=5,
        )

        app.add_middleware(
            RateLimitMiddleware,
            redis_client=redis_client,
            exempt_paths=["/health", "/ping", "/docs", "/redoc", "/openapi.json"],
        )
        logger.info(f"Rate limiting middleware enabled (Redis: {redis_host}:{redis_port})")
    except Exception as e:
        logger.warning(f"Failed to initialize rate limiting middleware: {e}")
        logger.warning("Rate limiting disabled")
else:
    logger.info("Rate limiting disabled (REDIS_ENABLED=false)")

# Add security headers middleware (after CORS, before auth)
from middleware.security_headers import SecurityHeadersMiddleware  # noqa: E402

app.add_middleware(
    SecurityHeadersMiddleware, enable_hsts=(config.environment == "production"), enable_csp=True
)

# Add audit logging middleware (after security headers, before auth)
from middleware.audit_logging import AuditLoggingMiddleware  # noqa: E402

app.add_middleware(
    AuditLoggingMiddleware,
    log_all_requests=(config.environment == "development"),  # Only log state-changing in production
)

# Add request logging middleware (before auth for complete logging)
app.add_middleware(RequestLoggingMiddleware)

# Add Keycloak authentication middleware
app.add_middleware(KeycloakAuthMiddleware)

# Register exception handlers
from fastapi.exceptions import RequestValidationError  # noqa: E402
from starlette.exceptions import HTTPException as StarletteHTTPException  # noqa: E402

# Register validation errors
app.add_exception_handler(RequestValidationError, validation_exception_handler)


# Register HTTP exception handlers (order matters - specific before general)
@app.exception_handler(404)
async def custom_404_handler(request, exc):
    """Custom 404 handler for not found errors"""
    return await not_found_handler(request, exc)


# Register general HTTP exception handler
app.add_exception_handler(StarletteHTTPException, http_exception_handler)

# Register global exception handler for all unhandled exceptions
app.add_exception_handler(Exception, global_exception_handler)

# Configuration
REGISTRY_PATH = os.getenv("CADDY_REGISTRY_PATH", DEFAULT_REGISTRY_PATH)
PORTOSER_CLI = os.getenv("PORTOSER_CLI", DEFAULT_PORTOSER_CLI)

# Initialize optional services
vault_client = None
keycloak_client = None

if config.vault_enabled:
    try:
        vault_client = VaultClient(url=config.vault_url, token=config.vault_token)
        logger.info("Vault client initialized")
    except Exception as e:
        logger.error(f"Failed to initialize Vault: {e}")
        vault_client = None

if config.keycloak_enabled:
    try:
        keycloak_client = KeycloakClient(
            server_url=config.keycloak_url,
            realm=config.keycloak_realm,
            client_id=config.keycloak_client_id,
            client_secret=config.keycloak_client_secret,
        )
        logger.info("Keycloak client initialized")
    except Exception as e:
        logger.error(f"Failed to initialize Keycloak: {e}")
        keycloak_client = None

# All extracted router modules access load_registry / save_registry /
# run_portoser_command directly via services.{registry_helpers,cli_runner};
# they no longer need to be re-exported here. broadcast_message is gone for
# the same reason — handlers go through ws_manager.broadcast() directly.

# ============================================================================
# WebSocket Management
# ============================================================================


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time updates."""
    if await authenticate_websocket(websocket) is None:
        return
    if ws_manager is None:
        await websocket.close(code=1011, reason="WebSocket manager not initialized")
        return

    await ws_manager.connect(websocket)
    try:
        while True:
            try:
                data = await websocket.receive_text()
                if data == "ping":
                    # Frontend JSON.parse's every WS message; the legacy
                    # plain-text "pong" tripped its parser. Match the JSON
                    # shape the other WS endpoints (cluster, metrics,
                    # diagnostics, deployment) already use.
                    await websocket.send_json({"type": "pong"})
                else:
                    logger.debug(f"Received WebSocket message: {data}")
            except asyncio.TimeoutError:
                continue
            except WebSocketDisconnect:
                raise
            except Exception as e:
                logger.error(f"Error receiving WebSocket message: {e}")
                break

    except WebSocketDisconnect:
        logger.info("WebSocket client disconnected normally")


@app.get("/ping")
async def ping():
    """Lightweight ping endpoint for healthchecks."""
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    backend_port = int(os.getenv("BACKEND_PORT", "8988"))
    # Default to loopback in dev to prevent unintended LAN exposure.
    # Container/production deployments set BIND_HOST=0.0.0.0 explicitly.
    bind_host = os.getenv("BIND_HOST", "127.0.0.1")
    uvicorn.run(app, host=bind_host, port=backend_port)
