"""Application startup wiring extracted from main.py:lifespan().

Splits a ~360-line lifespan into focused phases so the layout of startup
matches what each phase actually does:

  validate_environment()  → env + auth config gates (raises on hard fails)
  build_core_services()   → circuit breakers, CLI, WS, metrics, etc.
  wire_routers()          → set the module-level globals each router reads
  start_workers()         → WorkerManager + per-worker enable flags
  start_mcp()             → optional FastMCP + Postgres pool + token service
  shutdown_workers()      → reverse of start_workers() (called from finally)

main.py's lifespan() becomes a thin coordinator that calls
``run_startup()`` and ``run_shutdown()``. Behaviour is identical to the
inline implementation that lived in main.py prior to commit 17ce19b plus
the post-extraction cleanup; the only structural change is that the wiring
is now testable in isolation.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Any, Optional

from fastapi import FastAPI

from config import config
from services import (
    ClusterManager,
    HealthMonitor,
    KnowledgeBase,
    MetricsCollector,
    MetricsService,
    PortoserCLI,
    UptimeService,
    WebSocketManager,
)
from services.history_manager import HistoryManager
from services.metrics_prefetcher import MetricsPrefetcher
from services.metrics_queue import MetricsQueue
from services.worker_manager import WorkerManager
from utils.circuit_breaker import CircuitBreakerConfig, CircuitBreakerRegistry

logger = logging.getLogger(__name__)


@dataclass
class StartupServices:
    """Container for everything built during startup, returned by
    ``run_startup`` and threaded through to ``run_shutdown``."""

    cli_service: PortoserCLI
    ws_manager: WebSocketManager
    health_monitor: HealthMonitor
    knowledge_base: KnowledgeBase
    history_manager: HistoryManager
    cluster_manager: ClusterManager
    metrics_service: MetricsService
    uptime_service: UptimeService
    metrics_collector: MetricsCollector
    metrics_queue: MetricsQueue
    metrics_prefetcher: MetricsPrefetcher
    circuit_breaker_registry: CircuitBreakerRegistry
    worker_manager: WorkerManager
    device_health_monitor: Any  # services.device_health_monitor.DeviceHealthMonitor
    workers_enabled: bool = False
    mcp_enabled: bool = False
    # Snapshot of the env-resolved paths the routers read out of
    # routers.health (set during wire_routers).
    registry_path: str = ""
    portoser_cli: str = ""


# ---------------------------------------------------------------------------
# Validation phase
# ---------------------------------------------------------------------------


def validate_environment(default_registry_path: str, default_portoser_cli: str) -> tuple[str, str]:
    """Run env + auth config gates. Returns (registry_path, portoser_cli)
    after env-var resolution."""
    from utils.env_validation import EnvironmentValidator

    EnvironmentValidator.validate_all()
    EnvironmentValidator.log_environment_info()

    logger.info("Validating authentication configuration...")
    try:
        config.validate()
        logger.info("Authentication configuration validated successfully")
    except ValueError as e:
        logger.error(f"Authentication configuration validation failed: {e}")
        raise

    config_warnings = config.validate_startup_config()
    if config_warnings:
        logger.warning("=== CONFIGURATION WARNINGS ===")
        for warning in config_warnings:
            logger.warning(warning)
        logger.warning("==============================")
    else:
        logger.info("Configuration validated successfully - no warnings")

    registry_path = os.getenv("CADDY_REGISTRY_PATH", default_registry_path)
    portoser_cli = os.getenv("PORTOSER_CLI", default_portoser_cli)

    logger.info(f"Registry: {registry_path}")
    logger.info(f"Vault: {'Enabled' if config.vault_enabled else 'Disabled'}")
    logger.info(f"Keycloak: {'Enabled' if config.keycloak_enabled else 'Disabled'}")
    logger.info(
        f"Background Workers: {'Enabled' if config.enable_background_workers else 'Disabled'}"
    )

    if not os.path.exists(registry_path):
        logger.warning(f"Registry file not found at {registry_path}")
    if not os.path.exists(portoser_cli):
        logger.warning(f"Portoser CLI not found at {portoser_cli}")

    return registry_path, portoser_cli


# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------


def build_core_services(registry_path: str, portoser_cli: str) -> StartupServices:
    """Construct every long-lived service the app uses.

    Returns a partly-populated StartupServices — workers + mcp_enabled
    flags get filled in by start_workers() / start_mcp() later.
    """
    logger.info("Initializing circuit breaker registry...")
    circuit_breaker_registry = CircuitBreakerRegistry(
        config=CircuitBreakerConfig(
            failure_threshold=5,
            recovery_timeout=60,
            success_threshold=1,
        )
    )
    logger.info("Circuit breaker registry initialized")

    logger.info("Initializing intelligent deployment services...")
    cli_service = PortoserCLI(cli_path=portoser_cli)
    ws_manager = WebSocketManager()
    health_monitor = HealthMonitor(cli_service=cli_service)
    # Web backend is a read-only viewer over the on-disk KB the CLI
    # writes (env: KNOWLEDGE_BASE_DIR). Falling back to the legacy
    # KNOWLEDGE_BASE_PATH lets compose files written before the rename
    # keep working.
    knowledge_dir = os.getenv("KNOWLEDGE_BASE_DIR") or os.getenv("KNOWLEDGE_BASE_PATH")
    knowledge_base = KnowledgeBase(knowledge_dir=knowledge_dir)
    history_manager = HistoryManager(cli_path=portoser_cli)

    logger.info("Initializing cluster manager...")
    cluster_manager = ClusterManager(registry_path=registry_path)
    logger.info("Cluster manager initialized")

    logger.info("Initializing metrics and uptime services...")
    metrics_service = MetricsService(cli_path=portoser_cli, cache_ttl=60)
    uptime_service = UptimeService(cli_path=portoser_cli, cache_ttl=300)
    metrics_collector = MetricsCollector(
        interval=120,
        metrics_service=metrics_service,
        ws_manager=ws_manager,
        registry_path=registry_path,
    )

    logger.info("Initializing metrics queue...")
    metrics_queue = MetricsQueue(
        num_workers=5,
        max_queue_size=1000,
        max_rate=10,
        max_retries=3,
    )
    logger.info("Metrics queue initialized")

    logger.info("Initializing metrics prefetcher...")
    metrics_prefetcher = MetricsPrefetcher(
        registry_path=registry_path,
        prefetch_interval=120,
        cache_ttl=120,
        max_cache_size=1000,
        pattern_analysis_interval=300,
        min_priority_threshold=5.0,
    )
    logger.info("Metrics prefetcher initialized")

    logger.info("Initializing device health monitor...")
    from services.device_health_monitor import DeviceHealthMonitor

    device_health_monitor = DeviceHealthMonitor(ws_manager=ws_manager)

    logger.info("Initializing worker manager...")
    worker_manager = WorkerManager()

    if cli_service.is_available():
        logger.info("Portoser CLI service initialized")
    else:
        logger.warning("Portoser CLI not available - intelligent deployment features may not work")

    return StartupServices(
        cli_service=cli_service,
        ws_manager=ws_manager,
        health_monitor=health_monitor,
        knowledge_base=knowledge_base,
        history_manager=history_manager,
        cluster_manager=cluster_manager,
        metrics_service=metrics_service,
        uptime_service=uptime_service,
        metrics_collector=metrics_collector,
        metrics_queue=metrics_queue,
        metrics_prefetcher=metrics_prefetcher,
        circuit_breaker_registry=circuit_breaker_registry,
        worker_manager=worker_manager,
        device_health_monitor=device_health_monitor,
        registry_path=registry_path,
        portoser_cli=portoser_cli,
    )


# ---------------------------------------------------------------------------
# Wire-routers phase
# ---------------------------------------------------------------------------


def wire_routers(
    services: StartupServices,
    *,
    vault_client: Optional[Any],
    keycloak_client: Optional[Any],
    service_name: str,
    version: str,
) -> None:
    """Set the module-level globals each router reads at request time.

    Routers were extracted from main.py one at a time; each picks up its
    collaborators here rather than via FastAPI dependency injection so the
    extraction pass stayed mechanical.
    """
    # Routers that came with the codebase already use module globals:
    import routers.deployment as deployment_module
    import routers.diagnostics as diagnostics_module
    import routers.health as health_module
    import routers.history as history_module
    import routers.knowledge as knowledge_module
    from routers import metrics as metrics_router_module
    from routers import uptime as uptime_router_module

    deployment_module.cli_service = services.cli_service
    deployment_module.ws_manager = services.ws_manager
    deployment_module.uptime_service = services.uptime_service
    diagnostics_module.cli_service = services.cli_service
    diagnostics_module.ws_manager = services.ws_manager
    diagnostics_module.health_monitor = services.health_monitor
    health_module.health_monitor = services.health_monitor
    health_module.ws_manager = services.ws_manager
    knowledge_module.knowledge_base = services.knowledge_base
    history_module.history_manager = services.history_manager
    metrics_router_module.metrics_service = services.metrics_service
    metrics_router_module.metrics_collector = services.metrics_collector
    metrics_router_module.ws_manager = services.ws_manager
    uptime_router_module.uptime_service = services.uptime_service
    uptime_router_module.ws_manager = services.ws_manager

    # Routers that were extracted out of main.py during the extraction pass:
    import routers.auth as auth_module
    import routers.cluster as cluster_module
    import routers.devices as devices_module
    import routers.machines as machines_module
    import routers.services_admin as services_admin_module

    cluster_module.cluster_manager = services.cluster_manager
    cluster_module.ws_manager = services.ws_manager
    devices_module.ws_manager = services.ws_manager
    auth_module.keycloak_client = keycloak_client
    machines_module.ws_manager = services.ws_manager
    services_admin_module.ws_manager = services.ws_manager

    # Health router needs the same paths/clients main.py used to compute
    # /api/health and /api/health/comprehensive responses.
    health_module.vault_client = vault_client
    health_module.keycloak_client = keycloak_client
    health_module.SERVICE_NAME = service_name
    health_module.VERSION = version
    health_module.REGISTRY_PATH = services.registry_path
    health_module.PORTOSER_CLI = services.portoser_cli


# ---------------------------------------------------------------------------
# Worker phase
# ---------------------------------------------------------------------------


async def start_workers(app: FastAPI, services: StartupServices) -> None:
    """Start the long-running background workers under WorkerManager.

    Stores the WorkerManager + circuit-breaker registry + metrics queue on
    ``app.state`` so request handlers can reach them.
    """
    app.state.metrics_queue = services.metrics_queue
    app.state.circuit_breaker_registry = services.circuit_breaker_registry
    app.state.worker_manager = services.worker_manager

    cli_ready = await _check_cli_available(services.cli_service)
    if not cli_ready:
        logger.warning("CLI not available, background workers will be limited")

    workers_enabled = config.enable_background_workers
    services.workers_enabled = workers_enabled

    if not workers_enabled:
        logger.warning(
            "Background workers DISABLED - metrics and device health monitoring will not "
            "update. Set ENABLE_BACKGROUND_WORKERS=true to enable live data."
        )
        return

    logger.info("Background workers ENABLED - starting metrics and device health monitoring")
    worker_manager = services.worker_manager

    # Device health monitor — always on when workers are enabled
    await worker_manager.start_worker(
        name="device_health_monitor",
        func=services.device_health_monitor._monitor_loop,
        timeout=config.worker_timeout,
        enabled=True,
        failure_threshold=config.worker_failure_threshold,
        circuit_timeout=config.worker_circuit_timeout,
        long_running=True,
    )
    services.device_health_monitor.running = True
    logger.info("Device health monitor worker started")

    # Metrics queue (per-worker enable flag)
    if os.getenv("METRICS_QUEUE_ENABLED", "true").lower() == "true":
        metrics_queue = services.metrics_queue

        async def _start_metrics_queue() -> None:
            await metrics_queue.start()

        await worker_manager.start_worker(
            name="metrics_queue",
            func=_start_metrics_queue,
            timeout=config.worker_timeout,
            enabled=True,
            failure_threshold=config.worker_failure_threshold,
            circuit_timeout=config.worker_circuit_timeout,
            long_running=True,
        )
        logger.info("Metrics queue worker started")
    else:
        logger.info("Metrics queue disabled (METRICS_QUEUE_ENABLED=false)")

    # Metrics collector (per-worker enable flag, OFF by default)
    if os.getenv("METRICS_COLLECTOR_ENABLED", "false").lower() == "true":
        metrics_collector = services.metrics_collector

        async def _start_metrics_collector() -> None:
            await metrics_collector.start()

        await worker_manager.start_worker(
            name="metrics_collector",
            func=_start_metrics_collector,
            timeout=config.worker_timeout,
            enabled=True,
            failure_threshold=config.worker_failure_threshold,
            circuit_timeout=config.worker_circuit_timeout,
            long_running=True,
        )
        logger.info("Metrics collector worker started")
    else:
        logger.info("Metrics collector disabled (METRICS_COLLECTOR_ENABLED=false)")

    # Metrics prefetcher (per-worker enable flag)
    if os.getenv("METRICS_PREFETCHER_ENABLED", "true").lower() == "true":
        metrics_prefetcher = services.metrics_prefetcher

        async def _start_metrics_prefetcher() -> None:
            await metrics_prefetcher.start()

        await worker_manager.start_worker(
            name="metrics_prefetcher",
            func=_start_metrics_prefetcher,
            timeout=config.worker_timeout,
            enabled=True,
            failure_threshold=config.worker_failure_threshold,
            circuit_timeout=config.worker_circuit_timeout,
            long_running=True,
        )
        logger.info("Metrics prefetcher worker started")
    else:
        logger.info("Metrics prefetcher disabled (METRICS_PREFETCHER_ENABLED=false)")

    logger.info("All background workers started successfully")


# ---------------------------------------------------------------------------
# MCP phase
# ---------------------------------------------------------------------------


async def start_mcp(app: FastAPI, services: StartupServices) -> None:
    """Optional FastMCP + Postgres pool + device-token service.

    Stores results on ``app.state``. On failure, ``app.state.mcp_enabled``
    is False and the MCP routers return 503.
    """
    mcp_enabled = os.getenv("MCP_ENABLED", "true").lower() == "true"

    if not mcp_enabled:
        logger.info("MCP disabled via MCP_ENABLED environment variable")
        app.state.mcp_enabled = False
        services.mcp_enabled = False
        return

    logger.info("Initializing MCP services...")
    try:
        from fastmcp import FastMCP

        from services.mcp_audit import AuditLogService
        from services.mcp_auth import AuthService
        from services.mcp_postgres_db import MCPPostgresDB

        mcp_instance = FastMCP(name="Portoser MCP Server")
        logger.info("FastMCP instance created")

        mcp_db = await MCPPostgresDB.connect()
        logger.info("MCP database connected")

        auth_service = AuthService(mcp_db)
        audit_service = AuditLogService(mcp_db)
        await auth_service.initialize_roles_and_permissions()
        logger.info("MCP auth and audit services initialized")

        app.state.mcp_db = mcp_db
        app.state.auth_service = auth_service
        app.state.audit_service = audit_service
        app.state.mcp_instance = mcp_instance

        # Wire device-registration token service. Without this, both
        # /api/devices/register and /api/register return 503.
        try:
            from routers import devices as devices_router
            from services.token_service import TokenService

            devices_router.set_token_service(TokenService(mcp_db.pool))
            logger.info("Device registration token service wired")
        except Exception as ts_error:
            logger.error(
                f"Failed to wire device token service: {ts_error}; "
                "device registration will return 503."
            )

        logger.info("MCP services initialized and stored in app.state")
        app.state.mcp_enabled = True
        services.mcp_enabled = True

    except Exception as mcp_error:
        logger.error(f"MCP initialization failed: {mcp_error}")
        logger.error("MCP features will be disabled - MCP endpoints will return 503")
        app.state.mcp_enabled = False
        services.mcp_enabled = False


# ---------------------------------------------------------------------------
# Top-level orchestration
# ---------------------------------------------------------------------------


async def run_startup(
    app: FastAPI,
    *,
    vault_client: Optional[Any],
    keycloak_client: Optional[Any],
    service_name: str,
    version: str,
    default_registry_path: str,
    default_portoser_cli: str,
) -> StartupServices:
    """Single entry point for everything that used to live in lifespan()
    before the yield."""
    logger.info(f"Starting {service_name} v{version} ({config.environment})")
    logger.info(
        f"Environment: {config.environment} | Authentication: "
        f"{'ENABLED' if config.keycloak_enabled else 'DISABLED'}"
    )

    registry_path, portoser_cli = validate_environment(default_registry_path, default_portoser_cli)
    services = build_core_services(registry_path, portoser_cli)
    wire_routers(
        services,
        vault_client=vault_client,
        keycloak_client=keycloak_client,
        service_name=service_name,
        version=version,
    )
    await start_workers(app, services)
    await start_mcp(app, services)
    return services


# ---------------------------------------------------------------------------
# Shutdown phase
# ---------------------------------------------------------------------------


async def run_shutdown(app: FastAPI, services: StartupServices, service_name: str) -> None:
    """Reverse of run_startup. Safe to call even if startup partially failed."""
    logger.info(f"Shutting down {service_name}")

    if hasattr(app.state, "worker_manager"):
        logger.info("Shutting down worker manager...")
        await app.state.worker_manager.shutdown()
        logger.info("Worker manager shut down")

    # If workers were disabled, nothing was started via WorkerManager. Some
    # services may still have started themselves outside the manager — clean
    # those up directly.
    if not services.workers_enabled:
        if (
            hasattr(services.device_health_monitor, "_task")
            and services.device_health_monitor._task
        ):
            logger.info("Stopping device health monitor...")
            await services.device_health_monitor.stop()
            logger.info("Device health monitor stopped")

        if os.getenv("METRICS_QUEUE_ENABLED", "true").lower() == "true":
            logger.info("Stopping metrics queue...")
            await services.metrics_queue.stop(wait_for_completion=True)
            logger.info("Metrics queue stopped")

        if os.getenv("METRICS_COLLECTOR_ENABLED", "false").lower() == "true":
            logger.info("Stopping metrics collector...")
            await services.metrics_collector.stop()
            logger.info("Metrics collector stopped")

        if os.getenv("METRICS_PREFETCHER_ENABLED", "true").lower() == "true":
            logger.info("Stopping metrics prefetcher...")
            await services.metrics_prefetcher.stop()
            logger.info("Metrics prefetcher stopped")

    if hasattr(app.state, "mcp_db"):
        try:
            await app.state.mcp_db.close()
            logger.info("MCP database connection closed")
        except Exception as e:
            logger.error(f"Error closing MCP database: {e}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _check_cli_available(cli_service: PortoserCLI, timeout: int = 5) -> bool:
    """Verify the CLI binary is on disk and `--version` doesn't hang."""
    import asyncio

    try:
        if not cli_service.is_available():
            logger.warning("CLI binary not found or not executable")
            return False

        result = await asyncio.wait_for(cli_service.execute_command(["--version"]), timeout=timeout)
        return result.get("success", False)
    except asyncio.TimeoutError:
        logger.warning(f"CLI readiness check timed out after {timeout}s")
        return False
    except Exception as e:
        logger.warning(f"CLI readiness check failed: {e}")
        return False
