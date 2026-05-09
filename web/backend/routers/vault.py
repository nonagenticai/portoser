"""
Vault Router - Secure HashiCorp Vault Management API

Security Features:
- Keycloak authentication required
- No direct secret values exposed (masked in lists)
- Audit logging for all operations
- Rate limiting on sensitive operations
- Validation of all inputs
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/vault", tags=["vault"])

# Security: Import keycloak auth dependencies. We deliberately do NOT provide
# an in-process fallback — silently degrading to a fake user on import failure
# would mean a missing/broken auth module disables authentication in
# production. Let import errors crash startup so the operator notices.
from auth.dependencies import get_current_user, require_role  # noqa: E402

KEYCLOAK_ENABLED = True

# Portoser CLI path. Default falls back to <repo-root>/portoser computed from this file.
# routers/vault.py -> parents[2] is the repo root.
_DEFAULT_PORTOSER_CLI = str(Path(__file__).resolve().parents[2] / "portoser")
PORTOSER_CLI = os.getenv("PORTOSER_CLI", _DEFAULT_PORTOSER_CLI)


class VaultStatusResponse(BaseModel):
    """Vault status response"""

    initialized: bool
    sealed: bool
    address: str
    healthy: bool
    message: Optional[str] = None


class ServiceSecretsListItem(BaseModel):
    """Service in secrets list (no actual secret values)"""

    service: str
    secret_count: int
    last_updated: Optional[str] = None


class SecretKeyInfo(BaseModel):
    """Secret key info (value masked)"""

    key: str
    value_preview: str  # First 3 chars + "..."
    has_value: bool


class ServiceSecretsResponse(BaseModel):
    """Service secrets response (values masked for security)"""

    service: str
    secrets: List[SecretKeyInfo]
    total: int


class SecretUpdateRequest(BaseModel):
    """Request to update a secret"""

    service: str = Field(..., min_length=1, max_length=100, pattern="^[a-z0-9_-]+$")
    key: str = Field(..., min_length=1, max_length=200, pattern="^[A-Z0-9_]+$")
    value: str = Field(..., min_length=1, max_length=10000)

    @field_validator("service")
    @classmethod
    def validate_service(cls, v):
        """Prevent path traversal"""
        if ".." in v or "/" in v:
            raise ValueError("Invalid service name")
        return v

    @field_validator("key")
    @classmethod
    def validate_key(cls, v):
        """Ensure key follows conventions"""
        if not v.isupper() or not v.replace("_", "").isalnum():
            raise ValueError("Key must be uppercase with underscores only")
        return v


class MigrateServiceRequest(BaseModel):
    """Request to migrate service secrets"""

    service: str = Field(..., min_length=1, max_length=100, pattern="^[a-z0-9_-]+$")

    @field_validator("service")
    @classmethod
    def validate_service(cls, v):
        if ".." in v or "/" in v:
            raise ValueError("Invalid service name")
        return v


async def run_portoser_command(
    args: List[str], timeout: int = 30, return_partial_on_timeout: bool = True
) -> Dict[str, Any]:
    """
    Run portoser command securely with timeout and cleanup

    Args:
        args: Command arguments (will be validated)
        timeout: Command timeout in seconds
        return_partial_on_timeout: Return partial output on timeout

    Returns:
        Dict with stdout, stderr, returncode, success
    """
    # Security: Validate all arguments
    for arg in args:
        if ".." in arg or ";" in arg or "|" in arg or "&" in arg:
            raise ValueError(f"Invalid character in argument: {arg}")

    cmd = [PORTOSER_CLI] + args
    process = None

    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=os.path.dirname(PORTOSER_CLI),
        )

        # Wait with timeout
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)

        return {
            "stdout": stdout.decode(),
            "stderr": stderr.decode(),
            "returncode": process.returncode,
            "success": process.returncode == 0,
        }

    except asyncio.TimeoutError:
        logger.error(f"Vault CLI command timed out after {timeout}s: {args}")

        # Kill the process
        if process and process.returncode is None:
            try:
                process.kill()
                await asyncio.wait_for(process.wait(), timeout=2)
            except Exception:
                pass

        # Try to get partial output
        if return_partial_on_timeout:
            try:
                partial_stdout = await asyncio.wait_for(process.stdout.read(), timeout=1)
                partial_stderr = await asyncio.wait_for(process.stderr.read(), timeout=1)
                return {
                    "stdout": partial_stdout.decode() if partial_stdout else "",
                    "stderr": (partial_stderr.decode() if partial_stderr else "")
                    + f"\n[TIMEOUT after {timeout}s]",
                    "returncode": -1,
                    "success": False,
                }
            except Exception:
                pass

        raise HTTPException(
            status_code=status.HTTP_408_REQUEST_TIMEOUT,
            detail=f"Command timed out after {timeout}s",
        )

    except HTTPException:
        # Re-raise HTTP exceptions
        raise

    except Exception as e:
        logger.error(f"Failed to run portoser command: {e}")

        # Cleanup process on exception
        if process and process.returncode is None:
            try:
                process.kill()
                await asyncio.wait_for(process.wait(), timeout=2)
            except Exception:
                pass

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to execute command"
        )


def audit_log(user: Any, action: str, resource: str, details: Optional[Dict] = None):
    """
    Audit log for Vault operations.

    ``user`` is a ``KeycloakUser`` Pydantic model in the live auth path; the
    legacy dict signature is kept tolerant so older callers / mock fixtures
    don't crash this code path.
    """
    if hasattr(user, "email"):
        user_id = user.email or user.sub or "unknown"
    elif isinstance(user, dict):
        user_id = user.get("email") or user.get("sub") or "unknown"
    else:
        user_id = "unknown"
    log_entry = {
        "timestamp": utcnow().isoformat(),
        "user": user_id,
        "action": action,
        "resource": resource,
        "details": details or {},
    }
    logger.info(f"AUDIT: {json.dumps(log_entry)}")


@router.get("/status", response_model=VaultStatusResponse)
async def get_vault_status(user: Dict = Depends(get_current_user)):
    """
    Get Vault status

    Security: Requires authentication
    """
    audit_log(user, "read", "vault_status")

    result = await run_portoser_command(["vault", "status"], timeout=10)

    if not result["success"]:
        return VaultStatusResponse(
            initialized=False,
            sealed=True,
            address="unknown",
            healthy=False,
            message=result["stderr"],
        )

    # Parse output
    output = result["stdout"]
    return VaultStatusResponse(
        initialized=True,
        sealed="sealed: false" in output.lower() or "sealed: true" not in output.lower(),
        address=os.getenv("VAULT_ADDR", "http://localhost:8200"),
        healthy=True,
        message="Vault is operational",
    )


@router.get("/services", response_model=List[ServiceSecretsListItem])
async def list_services_with_secrets(user: Dict = Depends(get_current_user)):
    """
    List all services that have secrets in Vault

    Security:
    - Requires authentication
    - Does NOT return actual secret values
    - Only returns service names and metadata
    """
    audit_log(user, "list", "vault_services")

    result = await run_portoser_command(["vault", "list"], timeout=10)

    # Local dev runs with VAULT_ENABLED=false; the CLI exits non-zero with
    # an empty stderr in that case. Return [] rather than 500 so the
    # frontend can render an empty state instead of an error toast.
    if not result["success"]:
        logger.info("vault list failed (vault likely disabled): %s", result["stderr"])
        return []

    # Parse output (service names only)
    services = []
    for line in result["stdout"].split("\n"):
        line = line.strip()
        if line and line.startswith("-"):
            service_name = line.replace("-", "").strip()
            if service_name:
                services.append(
                    ServiceSecretsListItem(
                        service=service_name,
                        secret_count=0,  # We don't expose count for security
                        last_updated=None,
                    )
                )

    return services


@router.get("/services/{service}", response_model=ServiceSecretsResponse)
async def get_service_secrets(service: str, user: Dict = Depends(get_current_user)):
    """
    Get secrets for a service

    Security:
    - Requires authentication
    - Values are MASKED (only first 3 chars + "..." shown)
    - Full values never sent to frontend
    - Audit logged
    """
    # Validate service name
    if ".." in service or "/" in service:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid service name")

    audit_log(user, "read", f"vault_secrets:{service}")

    result = await run_portoser_command(["vault", "get", service], timeout=10)

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"No secrets found for service: {service}"
        )

    # Parse output and MASK values
    secrets = []
    for line in result["stdout"].split("\n"):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            parts = line.split("=", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                value = parts[1].strip()

                # SECURITY: Mask the value
                if len(value) > 3:
                    masked_value = value[:3] + "..." + " (" + str(len(value)) + " chars)"
                else:
                    masked_value = "***"

                secrets.append(
                    SecretKeyInfo(key=key, value_preview=masked_value, has_value=len(value) > 0)
                )

    return ServiceSecretsResponse(service=service, secrets=secrets, total=len(secrets))


@router.post("/services/{service}/secrets")
async def update_service_secret(
    service: str, request: SecretUpdateRequest, user: Dict = Depends(require_role("admin"))
):
    """
    Update a secret for a service

    Security:
    - Requires authentication
    - Input validation (prevents injection)
    - Audit logged with user info
    - No secret value in logs
    """
    # Double-check service name matches
    if service != request.service:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Service name mismatch")

    # Audit log (without the actual secret value)
    audit_log(
        user,
        "write",
        f"vault_secret:{service}/{request.key}",
        {"key": request.key, "value_length": len(request.value)},
    )

    # Run command
    result = await run_portoser_command(
        ["vault", "put", service, request.key, request.value], timeout=30
    )

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to update secret: {result['stderr']}",
        )

    return {
        "success": True,
        "message": f"Secret {request.key} updated for {service}",
        "service": service,
        "key": request.key,
    }


@router.post("/migrate")
async def migrate_service_to_vault(
    request: MigrateServiceRequest, user: Dict = Depends(require_role("admin"))
):
    """
    Migrate a service's .env file to Vault

    Security:
    - Requires authentication
    - Audit logged
    - Creates backup of original .env
    """
    audit_log(user, "migrate", f"service:{request.service}")

    result = await run_portoser_command(["vault", "migrate", request.service], timeout=60)

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Migration failed: {result['stderr']}",
        )

    return {
        "success": True,
        "message": f"Service {request.service} migrated to Vault",
        "service": request.service,
        "output": result["stdout"],
    }


@router.post("/migrate-all")
async def migrate_all_services(user: Dict = Depends(require_role("admin"))):
    """
    Migrate all services to Vault

    Security:
    - Requires authentication
    - Audit logged
    - High-privilege operation
    """
    audit_log(user, "migrate_all", "all_services", {"note": "Bulk migration operation"})

    result = await run_portoser_command(["vault", "migrate-all"], timeout=120)

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Migration failed: {result['stderr']}",
        )

    return {
        "success": True,
        "message": "All services migrated to Vault",
        "output": result["stdout"],
    }


@router.post("/init")
async def initialize_vault(user: Dict = Depends(require_role("admin"))):
    """
    Initialize Vault (first-time setup)

    Security:
    - Requires authentication
    - Should only be run once
    - Returns unseal keys (HIGHLY SENSITIVE)
    - User must save keys securely
    - Audit logged
    """
    audit_log(user, "init", "vault", {"warning": "SENSITIVE OPERATION - Vault initialization"})

    result = await run_portoser_command(["vault", "init"], timeout=60)

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Initialization failed: {result['stderr']}",
        )

    return {
        "success": True,
        "message": "Vault initialized - SAVE THE UNSEAL KEYS SECURELY!",
        "output": result["stdout"],
        "warning": "Unseal keys are shown ONCE. Save them securely!",
    }


@router.post("/setup-approles")
async def setup_approles(user: Dict = Depends(require_role("admin"))):
    """
    Setup AppRoles for all machines

    Security:
    - Requires authentication
    - Creates machine authentication
    - Audit logged
    """
    audit_log(user, "setup", "vault_approles")

    result = await run_portoser_command(["vault", "setup-approles"], timeout=60)

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"AppRole setup failed: {result['stderr']}",
        )

    return {
        "success": True,
        "message": "AppRoles created for all machines",
        "output": result["stdout"],
    }


# Include router in main.py
def get_router():
    return router
