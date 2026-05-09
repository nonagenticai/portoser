"""
Device Registration and Management API Router
Implements auto-discovery and registration system for Portoser devices
"""

import fcntl
import ipaddress
import json
import logging
import os
import re
import shutil
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from fastapi import APIRouter, Depends, HTTPException, Query, status

from auth.dependencies import get_current_user
from auth.models import KeycloakUser
from models.device import (
    DeviceDeregistrationResponse,
    DeviceDiscoveryResponse,
    DeviceHeartbeatRequest,
    DeviceHeartbeatResponse,
    DeviceInfo,
    DeviceListResponse,
    DeviceOwnershipTransferRequest,
    DeviceOwnershipTransferResponse,
    DeviceRegistrationRequest,
    DeviceRegistrationResponse,
    DeviceUpdateRequest,
    ErrorResponse,
)
from routers.device_ownership import require_device_ownership
from services.cache_service import get_registry_cache, invalidate_registry_cache
from services.token_service import TokenService, TokenValidationError
from services.websocket_manager import WebSocketManager
from utils.datetime_utils import utcnow
from utils.validation import FilePathValidator

# Set during lifespan startup by main.py. Same pattern other routers use.
ws_manager: Optional[WebSocketManager] = None


async def _broadcast_device_event(event: Dict[str, Any]) -> None:
    """Best-effort broadcast: never fail the HTTP request because of a WS issue."""
    if ws_manager is None:
        return
    try:
        await ws_manager.broadcast_device_event(event)
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"Failed to broadcast device event: {exc}")


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/devices", tags=["devices"])

# Configuration
REGISTRY_CACHE_TTL = float(os.getenv("REGISTRY_CACHE_TTL", "30"))  # seconds

# Initialize cache
_cache = get_registry_cache(ttl=REGISTRY_CACHE_TTL)

# Default paths derived from this file's location so the package works without
# hard-coded user-specific paths. routers/devices.py -> parents[2] is repo root.
_REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = os.getenv("CADDY_REGISTRY_PATH", str(_REPO_ROOT / "registry.yml"))
REGISTRY_LOCK_PATH = f"{REGISTRY_PATH}.lock"
REGISTRY_BACKUP_DIR = Path(os.getenv("REGISTRY_BACKUP_DIR", str(_REPO_ROOT / "registry_backups")))
LOCK_TIMEOUT = 30  # seconds


# ============================================================================
# Registry Locking and Update Utilities
# ============================================================================


class RegistryLockTimeoutError(Exception):
    """Raised when registry lock cannot be acquired"""

    pass


class RegistryValidationError(Exception):
    """Raised when registry validation fails"""

    pass


def acquire_registry_lock(timeout: int = LOCK_TIMEOUT) -> Optional[object]:
    """
    Acquire exclusive lock on registry file
    Returns lock file object or raises RegistryLockTimeoutError
    """
    lock_path = Path(REGISTRY_LOCK_PATH)
    lock_file = None

    try:
        # Create lock file with process info
        lock_file = open(lock_path, "w")
        lock_data = {
            "pid": os.getpid(),
            "timestamp": utcnow().isoformat(),
            "hostname": os.uname().nodename,
        }
        lock_file.write(json.dumps(lock_data))
        lock_file.flush()

        # Acquire exclusive lock with timeout
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                logger.info("Registry lock acquired")
                return lock_file
            except BlockingIOError:
                time.sleep(0.1)

        raise RegistryLockTimeoutError(f"Could not acquire lock within {timeout}s")

    except Exception:
        if lock_file:
            lock_file.close()
        raise


def release_registry_lock(lock_file: object):
    """Release registry lock"""
    if lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()
            Path(REGISTRY_LOCK_PATH).unlink(missing_ok=True)
            logger.info("Registry lock released")
        except Exception as e:
            logger.error(f"Error releasing lock: {e}")


def create_registry_backup() -> Path:
    """Create timestamped backup of current registry"""
    REGISTRY_BACKUP_DIR.mkdir(exist_ok=True, parents=True)
    timestamp = utcnow().strftime("%Y%m%d_%H%M%S")
    backup_path = REGISTRY_BACKUP_DIR / f"registry_{timestamp}.yml"

    if Path(REGISTRY_PATH).exists():
        shutil.copy2(REGISTRY_PATH, backup_path)
        logger.info(f"Registry backup created: {backup_path}")

        # Cleanup old backups (keep last 100)
        backups = sorted(REGISTRY_BACKUP_DIR.glob("registry_*.yml"))
        if len(backups) > 100:
            for old_backup in backups[:-100]:
                old_backup.unlink()

    return backup_path


def validate_registry(registry_data: Dict) -> tuple:
    """
    Validate registry structure and data integrity
    Returns: (is_valid, list_of_errors)
    """
    errors = []

    # Required top-level keys
    required_keys = ["domain", "hosts"]
    for key in required_keys:
        if key not in registry_data:
            errors.append(f"Missing required key: {key}")

    # Validate hosts section
    if "hosts" in registry_data:
        hosts = registry_data["hosts"]
        if not isinstance(hosts, dict):
            errors.append("'hosts' must be a dictionary")
        else:
            for hostname, host_config in hosts.items():
                # Validate hostname format
                if not re.match(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", hostname):
                    errors.append(f"Invalid hostname format: {hostname}")

                # Required host fields
                required_host_fields = ["ip", "ssh_user"]
                for field in required_host_fields:
                    if field not in host_config:
                        errors.append(f"Host {hostname} missing required field: {field}")

                # Validate IP address
                if "ip" in host_config:
                    try:
                        ipaddress.ip_address(host_config["ip"])
                    except ValueError:
                        errors.append(f"Invalid IP address for {hostname}: {host_config['ip']}")

    # Check for duplicate IPs
    if "hosts" in registry_data:
        ip_to_hosts = {}
        for hostname, config in registry_data["hosts"].items():
            ip = config.get("ip")
            if ip:
                if ip in ip_to_hosts:
                    errors.append(f"Duplicate IP {ip} assigned to {hostname} and {ip_to_hosts[ip]}")
                ip_to_hosts[ip] = hostname

    return (len(errors) == 0, errors)


def load_registry() -> Dict:
    """Load the registry.yml file with caching"""
    cache_key = f"registry:{REGISTRY_PATH}"

    # Try cache first
    cached_data = _cache.get(cache_key)
    if cached_data is not None:
        logger.debug("Registry loaded from cache")
        return cached_data

    # Load from disk on cache miss
    try:
        # Check if registry file exists and is readable
        FilePathValidator.check_file_exists(REGISTRY_PATH, "registry.yml")

        with open(REGISTRY_PATH, "r") as f:
            data = yaml.safe_load(f)
            result = data if data else {}

            # Cache the loaded data
            _cache.set(cache_key, result)
            logger.info("Registry loaded from disk and cached")
            return result
    except HTTPException:
        # Re-raise HTTP exceptions from validation
        raise
    except FileNotFoundError:
        logger.warning(f"Registry file not found at {REGISTRY_PATH}")
        default = {"domain": "internal", "hosts": {}, "services": {}}
        _cache.set(cache_key, default)
        return default
    except yaml.YAMLError as e:
        logger.error(f"Invalid YAML in registry: {e}")
        raise HTTPException(status_code=500, detail=f"Invalid YAML: {str(e)}")


def find_migration_target(
    registry: Dict, source_hostname: str, services: List[str]
) -> Optional[str]:
    """
    Find suitable target host for service migration
    Returns hostname of target or None if no suitable target found
    """
    hosts = registry.get("hosts", {})

    # Exclude source host
    candidate_hosts = {h: cfg for h, cfg in hosts.items() if h != source_hostname}

    if not candidate_hosts:
        logger.warning("No candidate hosts available for migration")
        return None

    # Count services per host for capacity check
    service_counts = {}
    for host in candidate_hosts:
        count = sum(
            1 for svc in registry.get("services", {}).values() if svc.get("current_host") == host
        )
        service_counts[host] = count

    # Select host with least services (round-robin style)
    target = min(service_counts.items(), key=lambda x: x[1])
    logger.info(f"Selected migration target: {target[0]} (current services: {target[1]})")

    return target[0]


def migrate_services_to_target(
    registry: Dict, services: List[str], source: str, target: str
) -> List[str]:
    """
    Migrate services from source to target host in registry
    Returns list of migrated service names
    """
    migrated = []

    for service_name in services:
        if service_name in registry.get("services", {}):
            registry["services"][service_name]["current_host"] = target
            migrated.append(service_name)
            logger.info(f"Migrated service '{service_name}' from {source} to {target}")

    return migrated


def save_registry(data: Dict, description: str = "Registry update") -> None:
    """
    Save registry with locking, backup, and validation
    """
    lock_file = None
    backup_path = None

    try:
        # Acquire lock
        lock_file = acquire_registry_lock()

        # Create backup
        backup_path = create_registry_backup()

        # Update metadata
        data["last_updated"] = utcnow().isoformat()
        current_version = float(data.get("version", "2.0"))
        data["version"] = f"{current_version + 0.1:.1f}"

        # Validate
        is_valid, errors = validate_registry(data)
        if not is_valid:
            logger.error(f"Registry validation failed: {errors}")
            raise RegistryValidationError(f"Validation errors: {', '.join(errors)}")

        # Write atomically
        temp_path = Path(f"{REGISTRY_PATH}.tmp")
        with open(temp_path, "w") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)

        # Atomic rename
        temp_path.replace(REGISTRY_PATH)

        # Log change
        log_registry_change(description, data)

        # Invalidate cache after successful save
        invalidate_registry_cache()

        logger.info(f"Registry updated successfully: {description}")

    except RegistryLockTimeoutError:
        raise HTTPException(
            status_code=503,
            detail="Registry is currently being updated. Please retry in a few seconds.",
            headers={"Retry-After": "5"},
        )
    except RegistryValidationError as e:
        # Rollback from backup
        if backup_path and backup_path.exists():
            logger.warning(f"Rolling back to backup: {backup_path}")
            shutil.copy2(backup_path, REGISTRY_PATH)
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        # Rollback from backup
        if backup_path and backup_path.exists():
            logger.warning(f"Rolling back to backup: {backup_path}")
            shutil.copy2(backup_path, REGISTRY_PATH)
        raise HTTPException(status_code=500, detail=f"Failed to save registry: {str(e)}")
    finally:
        if lock_file:
            release_registry_lock(lock_file)


def log_registry_change(description: str, registry_data: Dict):
    """Log registry changes to audit trail"""
    audit_log = Path(os.getenv("REGISTRY_AUDIT_LOG", str(_REPO_ROOT / "registry_changes.log")))
    audit_log.parent.mkdir(exist_ok=True, parents=True)

    change_record = {
        "timestamp": utcnow().isoformat(),
        "description": description,
        "version": registry_data.get("version"),
        "hosts_count": len(registry_data.get("hosts", {})),
        "services_count": len(registry_data.get("services", {})),
    }

    with open(audit_log, "a") as f:
        f.write(json.dumps(change_record) + "\n")


# ============================================================================
# Registration Token Validation
# ============================================================================

# Global token service instance (initialized in lifespan)
_token_service: Optional[TokenService] = None


def set_token_service(token_service: TokenService):
    """Set the global token service instance"""
    global _token_service
    _token_service = token_service


async def validate_registration_token(token: str) -> bool:
    """
    Validate registration token using database backend

    Args:
        token: Registration token string

    Returns:
        True if token is valid

    Raises:
        HTTPException: If token is invalid or service unavailable
    """
    if _token_service is None:
        logger.error("Token service not initialized")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Token validation service unavailable",
        )

    try:
        return await _token_service.validate_token(token)
    except TokenValidationError as e:
        logger.warning(f"Token validation failed: {e}")
        return False
    except Exception as e:
        logger.error(f"Token validation error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Token validation failed due to internal error",
        )


# ============================================================================
# Role Assignment Logic
# ============================================================================


def assign_roles(device: DeviceRegistrationRequest, cluster_state: Dict) -> List[str]:
    """
    Assign roles to device based on capabilities and resources
    Simplified version - would be more complex in production
    """
    assigned_roles = []

    # Check for Docker capability
    if "docker" in device.capabilities:
        assigned_roles.append("docker_services")

    # Check for MLX capability
    if "mlx" in device.capabilities or device.resources.mlx_capable:
        if device.resources.memory_gb >= 8:
            assigned_roles.append("ml_inference")
        if device.resources.memory_gb >= 16 and device.resources.gpu:
            assigned_roles.append("ml_training")

    # Check for database role
    if device.resources.memory_gb >= 8 and device.resources.disk_gb >= 100:
        # Check if we don't already have too many database hosts
        db_hosts = sum(
            1 for h in cluster_state.get("hosts", {}).values() if "database" in h.get("roles", [])
        )
        if db_hosts < 2:  # Max 2 database hosts
            assigned_roles.append("database")

    # Default to worker role if no specific roles
    if not assigned_roles:
        assigned_roles.append("worker")

    return assigned_roles


# ============================================================================
# Device Registration Endpoint
# ============================================================================


@router.post(
    "/register",
    response_model=DeviceRegistrationResponse,
    status_code=status.HTTP_201_CREATED,
    responses={
        201: {"description": "Device registered successfully"},
        202: {"description": "Registration pending approval"},
        400: {"model": ErrorResponse, "description": "Validation error"},
        401: {"model": ErrorResponse, "description": "Invalid token"},
        409: {"model": ErrorResponse, "description": "Hostname/IP conflict"},
        503: {"model": ErrorResponse, "description": "Registry locked"},
    },
)
async def register_device(
    request: DeviceRegistrationRequest, user: KeycloakUser = Depends(get_current_user)
):
    """
    Register a new device in the cluster

    Validates device information, checks for conflicts, assigns roles,
    and updates the registry file. Records the registering user as owner.
    """
    logger.info(f"Device registration request: {request.hostname} ({request.ip})")

    # Validate registration token
    if not await validate_registration_token(request.registration_token):
        logger.warning(f"Invalid registration token for {request.hostname}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error": "Invalid registration token",
                "message": "Token must be at least 8 characters and alphanumeric",
                "contact": "Administrator to obtain valid registration token",
            },
        )

    # Load current registry
    registry = load_registry()

    # Check for hostname conflict
    if request.hostname in registry.get("hosts", {}):
        existing = registry["hosts"][request.hostname]
        logger.warning(f"Hostname conflict: {request.hostname} already exists")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Hostname '{request.hostname}' already registered",
            headers={
                "X-Existing-Device": json.dumps(
                    {
                        "hostname": request.hostname,
                        "ip": existing.get("ip"),
                        "registered_at": existing.get("registered_at", "unknown"),
                    }
                )
            },
        )

    # Check for IP conflict
    for hostname, config in registry.get("hosts", {}).items():
        if config.get("ip") == request.ip:
            logger.warning(f"IP conflict: {request.ip} already registered to {hostname}")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"IP address '{request.ip}' already registered to '{hostname}'",
            )

    # Assign roles based on capabilities
    assigned_roles = assign_roles(request, registry)

    # Check if manual approval is required (for production env)
    approval_required = os.getenv("DEVICE_APPROVAL_REQUIRED", "false").lower() == "true"
    device_status = "pending" if approval_required else "active"

    # Create device entry
    device_entry = {
        "ip": request.ip,
        "ssh_user": request.ssh_user,
        "ssh_key_fingerprint": request.ssh_key_fingerprint,
        "arch": request.arch,
        "os": request.os,
        "os_version": request.os_version,
        "resources": {
            "cpu_cores": request.resources.cpu_cores,
            "cpu_threads": request.resources.cpu_threads,
            "memory_gb": request.resources.memory_gb,
            "disk_gb": request.resources.disk_gb,
            "gpu": request.resources.gpu,
            "mlx_capable": request.resources.mlx_capable,
        },
        "capabilities": request.capabilities,
        "labels": request.labels,
        "roles": assigned_roles,
        "status": device_status,
        "registered_at": utcnow().isoformat(),
        "owner_user_id": user.sub,
    }

    # Add to registry
    if "hosts" not in registry:
        registry["hosts"] = {}
    registry["hosts"][request.hostname] = device_entry

    # Save registry
    save_registry(registry, f"Register device: {request.hostname}")

    # Build response
    registered_at = utcnow().isoformat()

    next_steps = [
        "Verify SSH connectivity from cluster ingress host",
        "Ensure required capabilities are installed: " + ", ".join(request.capabilities),
    ]

    if approval_required:
        next_steps.append("Wait for administrator approval")

    response_data = {
        "status": "pending" if approval_required else "registered",
        "hostname": request.hostname,
        "assigned_roles": assigned_roles,
        "registry_version": registry.get("version", "2.0"),
        "next_steps": next_steps,
        "approval_required": approval_required,
        "registered_at": registered_at,
    }

    if approval_required:
        # Build approval URL from PORTOSER_PUBLIC_URL (e.g. "https://portoser.example.com").
        # Falls back to a relative path so the response is still useful when no public URL
        # is configured.
        public_base = os.getenv("PORTOSER_PUBLIC_URL", "").rstrip("/")
        approval_path = f"/devices/pending/{request.hostname}"
        response_data["approval_url"] = (
            f"{public_base}{approval_path}" if public_base else approval_path
        )
        response_data["message"] = "Registration requires manual approval"
        logger.info(f"Device {request.hostname} registered, pending approval")
        await _broadcast_device_event(
            {
                "type": "device_registered",
                "hostname": request.hostname,
                "ip": request.ip,
                "status": device_status,
                "approval_required": True,
            }
        )
        return DeviceRegistrationResponse(**response_data)
    else:
        logger.info(f"Device {request.hostname} registered successfully")
        await _broadcast_device_event(
            {
                "type": "device_registered",
                "hostname": request.hostname,
                "ip": request.ip,
                "status": device_status,
                "approval_required": False,
            }
        )
        return DeviceRegistrationResponse(**response_data)


# ============================================================================
# Device Discovery Endpoint
# ============================================================================


@router.get(
    "/discover",
    response_model=DeviceDiscoveryResponse,
    responses={
        200: {"description": "Cluster discovery information"},
        500: {"model": ErrorResponse, "description": "Registry error"},
    },
)
async def discover_cluster():
    """
    Get cluster information for auto-configuration

    Returns network details, required capabilities, and registration endpoint
    """
    logger.info("Device discovery request")

    registry = load_registry()

    # Find ingress host (typically the first host or one with caddy_ingress role)
    ingress_host = None
    ingress_ip = None

    for hostname, config in registry.get("hosts", {}).items():
        if "caddy_ingress" in config.get("roles", []):
            ingress_host = hostname
            ingress_ip = config.get("ip")
            break

    # Fallback to first host
    if not ingress_host and registry.get("hosts"):
        first_host = next(iter(registry["hosts"].items()))
        ingress_host = first_host[0]
        ingress_ip = first_host[1].get("ip")

    # Determine network CIDR from existing IPs. The placeholder uses RFC5737
    # TEST-NET-1 so a fresh checkout never advertises a real LAN range.
    network_cidr = os.getenv("PORTOSER_DEFAULT_NETWORK_CIDR", "192.0.2.0/24")
    if ingress_ip:
        # Extract network from IP
        ip_parts = ingress_ip.split(".")
        if len(ip_parts) >= 3:
            network_cidr = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.0/24"

    # Build the registration endpoint from PORTOSER_PUBLIC_URL when set.
    # Falls back to a relative path so this still works on a fresh deployment.
    public_base = os.getenv("PORTOSER_PUBLIC_URL", "").rstrip("/")
    registration_endpoint = (
        f"{public_base}/api/devices/register" if public_base else "/api/devices/register"
    )

    response = DeviceDiscoveryResponse(
        domain=registry.get("domain", "internal"),
        dns_server=ingress_ip,
        ingress_host=ingress_host or "unknown",
        ingress_ip=ingress_ip or "unknown",
        network_cidr=network_cidr,
        cluster_version=registry.get("version", "2.0"),
        required_capabilities=["ssh", "docker"],
        registration_endpoint=registration_endpoint,
    )

    logger.info(f"Discovery response: ingress={ingress_host}, network={network_cidr}")
    return response


# ============================================================================
# Device Update Endpoint
# ============================================================================


@router.patch(
    "/{hostname}",
    response_model=Dict[str, Any],
    responses={
        200: {"description": "Device updated successfully"},
        403: {"model": ErrorResponse, "description": "Forbidden - not owner or admin"},
        404: {"model": ErrorResponse, "description": "Device not found"},
        400: {"model": ErrorResponse, "description": "Validation error"},
        503: {"model": ErrorResponse, "description": "Registry locked"},
    },
)
async def update_device(
    hostname: str, update: DeviceUpdateRequest, user: KeycloakUser = Depends(get_current_user)
):
    """
    Update device metadata and capabilities

    Allows updating resources, capabilities, labels, and SSH credentials.
    Only device owner or admin can update.
    """
    logger.info(f"Device update request: {hostname} by user {user.preferred_username}")

    registry = load_registry()

    # Check ownership
    require_device_ownership(hostname, user, registry)

    # Check if device exists
    if hostname not in registry.get("hosts", {}):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"Device '{hostname}' not found"
        )

    device = registry["hosts"][hostname]

    # Update resources if provided
    if update.resources:
        device["resources"] = {
            "cpu_cores": update.resources.cpu_cores,
            "cpu_threads": update.resources.cpu_threads,
            "memory_gb": update.resources.memory_gb,
            "disk_gb": update.resources.disk_gb,
            "gpu": update.resources.gpu,
            "mlx_capable": update.resources.mlx_capable,
        }

    # Update capabilities if provided
    if update.capabilities is not None:
        device["capabilities"] = update.capabilities

    # Update labels if provided
    if update.labels is not None:
        device["labels"] = update.labels

    # Update SSH credentials if provided
    if update.ssh_user:
        device["ssh_user"] = update.ssh_user
    if update.ssh_key_fingerprint:
        device["ssh_key_fingerprint"] = update.ssh_key_fingerprint

    # Update timestamp
    device["updated_at"] = utcnow().isoformat()

    # Re-assign roles if resources or capabilities changed
    if update.resources or update.capabilities:
        # Create a temporary request object for role assignment
        from models.device import DeviceResources

        temp_resources = DeviceResources(**device["resources"])

        class TempDevice:
            def __init__(self):
                self.capabilities = device.get("capabilities", [])
                self.resources = temp_resources

        new_roles = assign_roles(TempDevice(), registry)
        device["roles"] = new_roles

    # Save registry
    save_registry(registry, f"Update device: {hostname}")

    logger.info(f"Device {hostname} updated successfully")

    return {
        "success": True,
        "hostname": hostname,
        "updated_fields": {
            "resources": update.resources is not None,
            "capabilities": update.capabilities is not None,
            "labels": update.labels is not None,
            "ssh_user": update.ssh_user is not None,
            "ssh_key_fingerprint": update.ssh_key_fingerprint is not None,
        },
        "current_roles": device.get("roles", []),
        "updated_at": device["updated_at"],
    }


# ============================================================================
# Device Deregistration Endpoint
# ============================================================================


@router.delete(
    "/{hostname}",
    response_model=DeviceDeregistrationResponse,
    responses={
        200: {"description": "Device deregistered successfully"},
        400: {"model": ErrorResponse, "description": "Cannot deregister with active services"},
        403: {"model": ErrorResponse, "description": "Forbidden - not owner or admin"},
        404: {"model": ErrorResponse, "description": "Device not found"},
        501: {"model": ErrorResponse, "description": "Service migration not implemented"},
        503: {"model": ErrorResponse, "description": "Registry locked"},
    },
)
async def deregister_device(
    hostname: str,
    force: bool = Query(default=False, description="Force removal even if services are running"),
    migrate_services: bool = Query(
        default=False, description="Automatically migrate services to other hosts"
    ),
    user: KeycloakUser = Depends(get_current_user),
):
    """
    Remove a device from the cluster

    Optionally migrates services to other hosts or forces removal.
    Only device owner or admin can delete.
    """
    logger.info(
        f"Device deregistration request: {hostname} (force={force}, migrate={migrate_services}) by user {user.preferred_username}"
    )

    registry = load_registry()

    # Check ownership
    require_device_ownership(hostname, user, registry)

    # Check if device exists
    if hostname not in registry.get("hosts", {}):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"Device '{hostname}' not found"
        )

    # Check for services on this device
    services_on_device = [
        svc_name
        for svc_name, svc_config in registry.get("services", {}).items()
        if svc_config.get("current_host") == hostname
    ]

    services_migrated = []

    if services_on_device and not force:
        if migrate_services:
            # Find target host for migration
            target_host = find_migration_target(registry, hostname, services_on_device)

            if not target_host:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail={
                        "error": "No suitable migration target found",
                        "services": services_on_device,
                        "reason": "No other hosts available in cluster",
                        "suggestion": "Use force=true to remove device without migration",
                    },
                )

            # Migrate services to target
            logger.info(
                f"Migrating {len(services_on_device)} services from {hostname} to {target_host}"
            )
            services_migrated = migrate_services_to_target(
                registry, services_on_device, hostname, target_host
            )

            logger.info(f"Successfully migrated {len(services_migrated)} services to {target_host}")

        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Cannot deregister device with active services: {', '.join(services_on_device)}. Use force=true or migrate_services=true.",
            )

    # Remove device from registry
    del registry["hosts"][hostname]

    # Save registry
    save_registry(registry, f"Deregister device: {hostname}")

    deregistered_at = utcnow().isoformat()

    logger.info(f"Device {hostname} deregistered successfully")

    return DeviceDeregistrationResponse(
        status="deregistered",
        hostname=hostname,
        services_migrated=services_migrated,
        deregistered_at=deregistered_at,
    )


# ============================================================================
# Device Ownership Transfer Endpoint
# ============================================================================


@router.post(
    "/{hostname}/transfer-ownership",
    response_model=DeviceOwnershipTransferResponse,
    responses={
        200: {"description": "Ownership transferred successfully"},
        403: {"model": ErrorResponse, "description": "Forbidden - not owner or admin"},
        404: {"model": ErrorResponse, "description": "Device not found"},
        503: {"model": ErrorResponse, "description": "Registry locked"},
    },
)
async def transfer_device_ownership(
    hostname: str,
    request: DeviceOwnershipTransferRequest,
    user: KeycloakUser = Depends(get_current_user),
):
    """
    Transfer device ownership to another user

    Only current owner or admin can transfer ownership.
    """
    logger.info(
        f"Device ownership transfer request: {hostname} by user {user.preferred_username} to {request.new_owner_user_id}"
    )

    registry = load_registry()

    # Check current ownership
    require_device_ownership(hostname, user, registry)

    # Check if device exists
    if hostname not in registry.get("hosts", {}):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"Device '{hostname}' not found"
        )

    device = registry["hosts"][hostname]
    previous_owner_user_id = device.get("owner_user_id")

    # Update owner
    device["owner_user_id"] = request.new_owner_user_id
    device["ownership_transferred_at"] = utcnow().isoformat()
    device["ownership_transferred_by"] = user.sub

    # Save registry
    save_registry(
        registry, f"Transfer ownership of device {hostname} to {request.new_owner_user_id}"
    )

    transferred_at = utcnow().isoformat()

    logger.info(f"Device {hostname} ownership transferred to {request.new_owner_user_id}")

    return DeviceOwnershipTransferResponse(
        status="transferred",
        hostname=hostname,
        previous_owner_user_id=previous_owner_user_id,
        new_owner_user_id=request.new_owner_user_id,
        transferred_at=transferred_at,
    )


# ============================================================================
# Device List Endpoint
# ============================================================================


@router.get(
    "",
    response_model=DeviceListResponse,
    responses={
        200: {"description": "Device list retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Registry error"},
    },
)
async def list_devices(
    page: int = Query(1, ge=1, description="Page number (1-indexed)"),
    page_size: int = Query(10, ge=1, le=100, description="Number of devices per page (max 100)"),
    status: Optional[str] = Query(None, description="Filter by status"),
    role: Optional[str] = Query(None, description="Filter by role"),
    user: KeycloakUser = Depends(get_current_user),
):
    """
    List all registered devices with pagination

    Supports filtering by status or role, with configurable page and page_size
    """
    logger.info(
        f"Device list request (page={page}, page_size={page_size}, status={status}, role={role})"
    )

    registry = load_registry()
    devices = []

    for hostname, config in registry.get("hosts", {}).items():
        # Apply filters
        if status and config.get("status") != status:
            continue
        if role and role not in config.get("roles", []):
            continue

        from models.device import DeviceResources

        resources = DeviceResources(
            **config.get(
                "resources",
                {
                    "cpu_cores": 0,
                    "cpu_threads": 0,
                    "memory_gb": 0,
                    "disk_gb": 0,
                    "gpu": False,
                    "mlx_capable": False,
                },
            )
        )

        device_info = DeviceInfo(
            hostname=hostname,
            ip=config.get("ip", ""),
            arch=config.get("arch", "unknown"),
            os=config.get("os", "unknown"),
            os_version=config.get("os_version", "unknown"),
            resources=resources,
            ssh_user=config.get("ssh_user", ""),
            capabilities=config.get("capabilities", []),
            labels=config.get("labels", {}),
            status=config.get("status", "unknown"),
            approval_status=config.get("approval_status", "approved"),
            registered_at=config.get("registered_at", ""),
            approved_at=config.get("approved_at"),
            last_seen_at=config.get("last_seen_at"),
            owner_user_id=config.get("owner_user_id"),
            assigned_roles=config.get("roles", []),
        )
        devices.append(device_info)

    # Calculate pagination
    total = len(devices)
    total_pages = (total + page_size - 1) // page_size  # Ceiling division
    offset = (page - 1) * page_size
    paginated_devices = devices[offset : offset + page_size]

    logger.info(
        f"Returning page {page}/{total_pages} with {len(paginated_devices)} devices (total: {total})"
    )

    return DeviceListResponse(
        devices=paginated_devices,
        total=total,
        total_pages=total_pages,
        page=page,
        page_size=page_size,
    )


# ============================================================================
# Device Heartbeat Endpoint
# ============================================================================


@router.post(
    "/{hostname}/heartbeat",
    response_model=DeviceHeartbeatResponse,
    responses={
        200: {"description": "Heartbeat received"},
        404: {"model": ErrorResponse, "description": "Device not found"},
        503: {"model": ErrorResponse, "description": "Registry locked"},
    },
)
async def device_heartbeat(hostname: str, request: Optional[DeviceHeartbeatRequest] = None):
    """
    Record device heartbeat and update last_seen_at timestamp.

    This endpoint should be called by devices every 1-2 minutes to indicate they are online.
    Devices with no heartbeat for 5 minutes will be marked as offline by background task.
    """
    logger.info(f"Heartbeat received from device: {hostname}")

    registry = load_registry()

    # Check if device exists
    if hostname not in registry.get("hosts", {}):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"Device '{hostname}' not found"
        )

    device = registry["hosts"][hostname]

    # Update last_seen_at timestamp
    now = utcnow().isoformat()
    device["last_seen_at"] = now

    # Update status to online if not in maintenance mode
    current_status = device.get("status", "active")
    if current_status != "maintenance":
        device["status"] = "online"

    # Save optional metrics if provided
    if request and request.metrics:
        device["last_metrics"] = request.metrics

    # Save registry
    save_registry(registry, f"Heartbeat from {hostname}")

    logger.info(f"Heartbeat processed for {hostname}, status: {device.get('status')}")

    await _broadcast_device_event(
        {
            "type": "device_heartbeat",
            "hostname": hostname,
            "status": device.get("status", "online"),
            "last_seen_at": now,
        }
    )

    return DeviceHeartbeatResponse(
        success=True, hostname=hostname, last_seen_at=now, status=device.get("status", "online")
    )


@router.get(
    "/cache/stats",
    response_model=Dict[str, Any],
    responses={
        200: {"description": "Cache statistics"},
    },
)
async def get_cache_stats():
    """
    Get registry cache performance statistics

    Returns cache hit rate, misses, and other metrics
    """
    stats = _cache.get_stats()
    logger.info(f"Cache stats requested: {stats['hit_rate']:.2f}% hit rate")
    return {"cache_stats": stats, "ttl_seconds": REGISTRY_CACHE_TTL, "cache_enabled": True}


@router.post(
    "/cache/invalidate",
    response_model=Dict[str, Any],
    responses={
        200: {"description": "Cache invalidated"},
    },
)
async def invalidate_cache():
    """
    Manually invalidate registry cache

    Forces next registry read to load from disk
    """
    invalidate_registry_cache()
    logger.info("Registry cache manually invalidated")
    return {
        "success": True,
        "message": "Registry cache invalidated",
        "next_load": "Will load from disk",
    }
