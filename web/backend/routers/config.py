"""Configuration API Router

Provides endpoints for viewing application configuration.

GET /api/config         — public, returns the small set of fields the SPA
                          needs to bootstrap its OIDC login flow (keycloak
                          URL, realm, client_id) plus feature flags.
GET /api/config/admin   — admin-only, returns full config including worker
                          tunables and log level.
GET /api/config/validate — admin-only, runs startup validation checks.
"""

from typing import List, Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from auth.dependencies import require_role
from config import config

router = APIRouter(prefix="/api", tags=["configuration"])


class PublicConfigResponse(BaseModel):
    """Auth-discovery payload safe to expose without authentication."""

    auth_enabled: bool
    vault_enabled: bool
    keycloak_url: Optional[str] = None
    keycloak_realm: Optional[str] = None
    keycloak_client_id: Optional[str] = None


class ConfigResponse(BaseModel):
    """Detailed config response (admin)."""

    environment: str
    keycloak_enabled: bool
    background_workers_enabled: bool
    registry_path: str
    log_level: str
    vault_enabled: bool
    keycloak_url: Optional[str] = None
    keycloak_realm: Optional[str] = None
    worker_timeout: int
    worker_failure_threshold: int
    worker_circuit_timeout: int


class ConfigValidationResponse(BaseModel):
    """Response model for configuration validation"""

    valid: bool
    warnings: List[str]


@router.get("/config", response_model=PublicConfigResponse)
async def get_public_config():
    """Public auth-discovery payload.

    Listed in :pyattr:`auth.middleware.PUBLIC_ENDPOINTS` so the SPA can hit
    it pre-login to learn whether Keycloak is on, which realm, and which
    client_id to use for the OIDC redirect. Anything sensitive belongs in
    :func:`get_admin_config` instead.
    """
    return PublicConfigResponse(
        auth_enabled=config.keycloak_enabled,
        vault_enabled=config.vault_enabled,
        keycloak_url=config.keycloak_url if config.keycloak_enabled else None,
        keycloak_realm=config.keycloak_realm if config.keycloak_enabled else None,
        keycloak_client_id=config.keycloak_client_id if config.keycloak_enabled else None,
    )


@router.get("/config/admin", response_model=ConfigResponse)
async def get_admin_config(current_user: dict = Depends(require_role("admin"))):
    """
    Get full configuration (admin only)

    Returns detailed application configuration including:
    - Environment settings
    - Authentication configuration
    - Background worker settings
    - Registry paths
    - Logging configuration

    Requires: admin role
    """
    return ConfigResponse(
        environment=config.environment,
        keycloak_enabled=config.keycloak_enabled,
        background_workers_enabled=config.enable_background_workers,
        registry_path=config.registry_path,
        log_level=config.log_level,
        vault_enabled=config.vault_enabled,
        keycloak_url=config.keycloak_url if config.keycloak_enabled else None,
        keycloak_realm=config.keycloak_realm if config.keycloak_enabled else None,
        worker_timeout=config.worker_timeout,
        worker_failure_threshold=config.worker_failure_threshold,
        worker_circuit_timeout=config.worker_circuit_timeout,
    )


@router.get("/config/validate", response_model=ConfigValidationResponse)
async def validate_config(current_user: dict = Depends(require_role("admin"))):
    """
    Validate current configuration (admin only)

    Runs configuration validation checks and returns any warnings.

    Requires: admin role
    """
    warnings = config.validate_startup_config()

    return ConfigValidationResponse(valid=len(warnings) == 0, warnings=warnings)
