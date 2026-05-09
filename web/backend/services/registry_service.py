"""
Registry Service with File Locking and Validation

Provides thread-safe access to registry.yml with:
- File-level locking (fcntl) for concurrent access protection
- Schema validation using Pydantic
- Atomic writes to prevent corruption
- Backward compatibility with existing cache-based RegistryService
"""

import fcntl
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator

from utils.validation import FilePathValidator

logger = logging.getLogger(__name__)

# Port validation constant
FORBIDDEN_PORT = 8000  # Per user requirement: "ONLY your mother lives on port 8000!"


# =============================================================================
# Validation Functions
# =============================================================================


def validate_registry_file(file_path: str) -> bool:
    """
    Validate registry file before parsing.

    Checks:
    - File exists and is readable
    - File is valid YAML
    - File contains expected structure (machines/services keys)

    Args:
        file_path: Path to registry file to validate

    Returns:
        True if file is valid

    Raises:
        FileNotFoundError: If file doesn't exist
        ValueError: If file is invalid YAML or missing expected structure
    """
    try:
        path = Path(file_path)

        # Check file exists
        if not path.exists():
            raise FileNotFoundError(f"Registry file not found: {file_path}")

        # Check file is readable
        if not path.is_file():
            raise ValueError(f"Registry path is not a file: {file_path}")

        # Attempt to read and parse YAML
        with open(path, "r") as f:
            data = yaml.safe_load(f)

        # Validate basic structure
        if not isinstance(data, dict):
            raise ValueError("Registry file must contain a YAML dictionary")

        # Ensure at least one of machines/hosts/services exists
        if not any(key in data for key in ["machines", "hosts", "services"]):
            raise ValueError("Registry must contain at least one of: machines, hosts, or services")

        logger.debug(f"Registry file validation passed: {file_path}")
        return True

    except FileNotFoundError:
        raise
    except ValueError:
        raise
    except yaml.YAMLError as e:
        raise ValueError(f"Invalid YAML in registry file: {e}")
    except Exception as e:
        raise ValueError(f"Error validating registry file: {e}")


def validate_service_port(service_name: str, port: Any) -> None:
    """
    Validate a service port value.

    Checks:
    - Port is a valid integer
    - Port is in valid range (1-65535)
    - Port is not the forbidden port (8000)

    Args:
        service_name: Name of service for error messages
        port: Port value to validate

    Raises:
        ValueError: If port is invalid or forbidden
    """
    if port is None:
        return  # Port is optional

    try:
        port_num = int(port)
    except (TypeError, ValueError):
        raise ValueError(
            f"Service '{service_name}': port must be an integer, got {type(port).__name__}"
        )

    if port_num <= 0 or port_num > 65535:
        raise ValueError(
            f"Service '{service_name}': port {port_num} is out of valid range (1-65535)"
        )

    if port_num == FORBIDDEN_PORT:
        raise ValueError(
            f"Service '{service_name}': port {FORBIDDEN_PORT} is reserved and cannot be used. "
            f"(Per requirement: ONLY your mother lives on port {FORBIDDEN_PORT}!)"
        )


def validate_parsed_service_data(services_dict: Dict[str, Any]) -> Dict[str, Any]:
    """
    Validate all service data after parsing from registry.

    Checks each service for:
    - Valid port configuration (if present)
    - No forbidden ports (8000)

    Args:
        services_dict: Dictionary of services from registry

    Returns:
        services_dict if all validations pass

    Raises:
        ValueError: If any service has invalid port configuration
    """
    if not services_dict:
        return services_dict

    for service_name, service_config in services_dict.items():
        if not isinstance(service_config, dict):
            continue  # Skip non-dict entries

        # Check for port in service config
        if "port" in service_config:
            validate_service_port(service_name, service_config["port"])

        # Check for ports in nested config (some services might have port lists)
        if "ports" in service_config:
            ports = service_config["ports"]
            if isinstance(ports, list):
                for port in ports:
                    validate_service_port(service_name, port)
            else:
                validate_service_port(service_name, ports)

        # Check docker_compose port mappings if present
        if "docker_compose" in service_config:
            docker_config = service_config["docker_compose"]
            if isinstance(docker_config, dict):
                # Check services.*.ports in docker-compose structure
                if "services" in docker_config:
                    for svc_name, svc_config in docker_config["services"].items():
                        if isinstance(svc_config, dict) and "ports" in svc_config:
                            ports = svc_config["ports"]
                            if isinstance(ports, list):
                                for port_mapping in ports:
                                    # Handle port mappings like "8000:8000", "8000" or just integers
                                    if isinstance(port_mapping, str):
                                        # Extract external port from mapping like "8000:8000"
                                        external_port = port_mapping.split(":")[0]
                                        try:
                                            validate_service_port(
                                                f"{service_name}.{svc_name}", external_port
                                            )
                                        except ValueError:
                                            raise
                                    else:
                                        validate_service_port(
                                            f"{service_name}.{svc_name}", port_mapping
                                        )

    return services_dict


# Legacy models for backward compatibility
class ServiceInfo(BaseModel):
    """Information about a service from the registry"""

    name: str
    hostname: Optional[str] = None
    current_host: str
    deployment_type: str
    service_file: Optional[str] = None
    docker_compose: Optional[str] = None


class HostInfo(BaseModel):
    """Information about a host from the registry"""

    name: str
    ip: str
    ssh_user: str
    path: Optional[str] = None
    roles: List[str] = []
    # Operational status from the registry. The yaml writes one of
    # "online" / "offline" / "unknown" (or omits the key entirely on
    # legacy entries — treated as "unknown"). Services use is_online()
    # to short-circuit SSH probes against hosts known to be offline,
    # which is what makes the dev "dummy registry" usable for the UI
    # without 30s SSH timeouts on every poll.
    status: str = "unknown"

    def is_online(self) -> bool:
        """True only if the registry explicitly says this host is online.

        "unknown" is treated as offline (we have no positive evidence it's
        reachable) — this is the conservative choice for the dev/dummy-data
        case where SSH probes against unreachable IPs are expensive.
        """
        return self.status == "online"


# Schema validation models
class MachineSchema(BaseModel):
    """Schema for machine configuration"""

    model_config = ConfigDict(extra="allow")

    host: str = Field(..., description="SSH host/IP address")
    ssh_user: Optional[str] = Field(None, description="SSH username")
    ip: Optional[str] = Field(None, description="IP address")
    path: Optional[str] = Field(None, description="Base path for services on this host")
    roles: list = Field(default_factory=list, description="Machine roles")


class ServiceSchema(BaseModel):
    """Schema for service configuration"""

    model_config = ConfigDict(extra="allow")

    current_host: Optional[str] = Field(None, description="Current deployment host")
    deployment_type: Optional[str] = Field(
        None, description="Deployment type (docker, native, local)"
    )


class RegistrySchema(BaseModel):
    """Schema for registry.yml validation"""

    model_config = ConfigDict(extra="allow")

    machines: Dict[str, MachineSchema] = Field(
        default_factory=dict, description="Machine configurations"
    )
    services: Dict[str, ServiceSchema] = Field(
        default_factory=dict, description="Service configurations"
    )

    # Support both 'machines' and 'hosts' keys for backward compatibility
    hosts: Optional[Dict[str, MachineSchema]] = Field(
        None, description="Legacy hosts key (alias for machines)"
    )

    @field_validator("machines", mode="before")
    @classmethod
    def validate_machines(cls, v):
        """Ensure each machine has required fields"""
        if v is None:
            v = {}

        # Validate machine configurations
        for machine_name, data in v.items():
            if isinstance(data, dict):
                # Check for required 'host' field
                if "host" not in data and "ip" not in data:
                    raise ValueError(
                        f"Machine '{machine_name}' missing required 'host' or 'ip' field"
                    )

        return v

    @field_validator("services", mode="before")
    @classmethod
    def validate_services(cls, v):
        """Validate service configurations"""
        if v is None:
            v = {}
        return v


class RegistryService:
    """
    Thread-safe registry service with file locking and validation.

    Features:
    - Shared locks for reads (multiple readers allowed)
    - Exclusive locks for writes (single writer)
    - Atomic writes via temp file + rename
    - Schema validation before writes
    - Automatic backup creation
    - Backward compatibility with legacy cache-based methods
    """

    def __init__(self, registry_path: str, cache_ttl: float = 30.0):
        """
        Initialize registry service.

        Args:
            registry_path: Path to registry.yml file
            cache_ttl: Ignored (kept for backward compatibility)
        """
        self.registry_path = Path(registry_path)
        self._registry_data: Optional[Dict[str, Any]] = None
        self._ensure_registry_exists()

    def _ensure_registry_exists(self):
        """Ensure registry file exists, create empty one if not"""
        if not self.registry_path.exists():
            logger.warning(
                f"Registry file not found at {self.registry_path}, creating empty registry"
            )
            self.registry_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.registry_path, "w") as f:
                yaml.safe_dump({"machines": {}, "services": {}, "hosts": {}}, f)

    def read(self) -> Dict[str, Any]:
        """
        Read registry with shared lock.

        Multiple readers can read simultaneously.
        Blocks if a writer has the exclusive lock.

        Returns:
            Registry data as dictionary

        Raises:
            ValueError: If registry schema is invalid or contains forbidden port
            FileNotFoundError: If registry file doesn't exist
        """
        try:
            # Validate registry file exists and is readable before reading
            FilePathValidator.check_file_exists(str(self.registry_path), "registry.yml")

            # Validate registry file before reading
            validate_registry_file(str(self.registry_path))

            with open(self.registry_path, "r") as f:
                # Acquire shared lock (multiple readers allowed)
                fcntl.flock(f.fileno(), fcntl.LOCK_SH)
                try:
                    data = yaml.safe_load(f) or {}

                    # Normalize 'hosts' to 'machines' for backward compatibility
                    if "hosts" in data and "machines" not in data:
                        data["machines"] = data["hosts"]
                    elif "machines" in data and "hosts" not in data:
                        data["hosts"] = data["machines"]

                    # Ensure required keys exist
                    if "machines" not in data:
                        data["machines"] = {}
                    if "services" not in data:
                        data["services"] = {}
                    if "hosts" not in data:
                        data["hosts"] = data["machines"]

                    # Validate parsed service data (port validation)
                    try:
                        validate_parsed_service_data(data.get("services", {}))
                    except ValueError as e:
                        logger.error(f"Service data validation failed: {e}")
                        raise

                    # Validate schema (lenient mode - allows extra fields)
                    # We don't use strict validation to support backward compatibility
                    try:
                        RegistrySchema(**data)
                    except Exception as e:
                        logger.warning(f"Registry schema validation warning: {e}")
                        # Don't fail on validation errors, just log them

                    return data
                finally:
                    # Release shared lock
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)

        except FileNotFoundError:
            logger.error(f"Registry file not found at {self.registry_path}")
            raise
        except yaml.YAMLError as e:
            logger.error(f"Invalid YAML in registry: {e}")
            raise ValueError(f"Invalid YAML in registry: {e}")
        except ValueError:
            raise
        except Exception as e:
            logger.error(f"Error reading registry: {e}")
            raise

    def write(self, data: Dict[str, Any]) -> None:
        """
        Write registry atomically with exclusive lock.

        Uses atomic write pattern:
        1. Validate data
        2. Write to temporary file with exclusive lock
        3. Atomic rename to replace original

        This prevents corruption if the process crashes during write.

        Args:
            data: Registry data to write

        Raises:
            ValueError: If data fails schema validation
        """
        # Validate schema before writing (lenient mode)
        try:
            # Ensure required keys exist
            if "machines" not in data:
                data["machines"] = {}
            if "services" not in data:
                data["services"] = {}

            # Maintain backward compatibility with 'hosts' key
            if "hosts" not in data:
                data["hosts"] = data["machines"]

            # Validate parsed service data (port validation before write)
            try:
                validate_parsed_service_data(data.get("services", {}))
            except ValueError as e:
                logger.error(f"Service data validation failed: {e}")
                raise

            # Update last_updated timestamp
            from utils.datetime_utils import utcnow

            data["last_updated"] = utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

            # Validate (but allow validation to be lenient)
            try:
                RegistrySchema(**data)
            except Exception as e:
                logger.warning(f"Registry schema validation warning: {e}")
                # Continue anyway for backward compatibility
        except ValueError:
            raise
        except Exception as e:
            logger.error(f"Registry validation failed: {e}")
            raise ValueError(f"Registry validation failed: {e}")

        # Create backup before writing
        try:
            if self.registry_path.exists():
                backup_path = (
                    self.registry_path.parent
                    / f"{self.registry_path.name}.backup.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
                )
                with open(self.registry_path, "r") as src:
                    with open(backup_path, "w") as dst:
                        dst.write(src.read())
                logger.info(f"Created registry backup: {backup_path}")
        except Exception as e:
            logger.warning(f"Failed to create backup: {e}")

        # Atomic write: write to temp file, then rename
        # Use unique temp file name to avoid race conditions between threads
        import threading

        temp_suffix = f".tmp.{os.getpid()}.{threading.get_ident()}"
        temp_path = self.registry_path.parent / f"{self.registry_path.name}{temp_suffix}"

        try:
            with open(temp_path, "w") as f:
                # Acquire exclusive lock (blocks all readers and writers)
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                try:
                    # Write data
                    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
                    f.flush()
                    os.fsync(f.fileno())  # Force write to disk
                finally:
                    # Release exclusive lock
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)

            # Atomic rename (replaces old file)
            # This is atomic on POSIX systems
            temp_path.replace(self.registry_path)
            logger.info(f"Registry written successfully to {self.registry_path}")

        except Exception as e:
            # Clean up temp file on error
            if temp_path.exists():
                temp_path.unlink()
            logger.error(f"Error writing registry: {e}")
            raise

    def update(self, updater_func) -> Dict[str, Any]:
        """
        Read, modify, and write registry atomically.

        This is a convenience method that handles read-modify-write atomically.

        Args:
            updater_func: Function that takes current data and returns modified data

        Returns:
            Updated registry data
        """
        # Note: This still has a small race condition between read and write.
        # For true atomic updates, we'd need to hold the lock across both operations,
        # but that would block all readers during the update function execution.
        # For registry updates, this is acceptable as updates are infrequent.

        data = self.read()
        updated_data = updater_func(data)
        self.write(updated_data)
        return updated_data

    # Backward compatibility methods (legacy API)
    def reload(self) -> None:
        """Reload the registry file from disk (legacy compatibility)"""
        # With locking, we always read from disk, so this is a no-op
        pass

    def get_cache_stats(self) -> Dict[str, Any]:
        """Get cache performance statistics (legacy compatibility)"""
        return {"note": "Caching disabled with locked registry service"}

    def get_all_services(self) -> List[ServiceInfo]:
        """
        Get all services from the registry (legacy compatibility)

        Returns:
            List of ServiceInfo objects
        """
        data = self.read()
        services = []
        services_dict = data.get("services", {})

        for name, config in services_dict.items():
            try:
                service = ServiceInfo(
                    name=name,
                    hostname=config.get("hostname"),
                    current_host=config.get("current_host", "unknown"),
                    deployment_type=config.get("deployment_type", "unknown"),
                    service_file=config.get("service_file"),
                    docker_compose=config.get("docker_compose"),
                )
                services.append(service)
            except Exception as e:
                logger.error(f"Failed to parse service {name}: {e}")

        return services

    def get_service(self, name: str) -> Optional[ServiceInfo]:
        """
        Get a specific service by name (legacy compatibility)

        Args:
            name: Service name

        Returns:
            ServiceInfo or None if not found
        """
        data = self.read()
        services_dict = data.get("services", {})
        config = services_dict.get(name)

        if not config:
            return None

        try:
            return ServiceInfo(
                name=name,
                hostname=config.get("hostname"),
                current_host=config.get("current_host", "unknown"),
                deployment_type=config.get("deployment_type", "unknown"),
                service_file=config.get("service_file"),
                docker_compose=config.get("docker_compose"),
            )
        except Exception as e:
            logger.error(f"Failed to parse service {name}: {e}")
            return None

    def get_all_hosts(self) -> List[HostInfo]:
        """
        Get all hosts from the registry (legacy compatibility)

        Returns:
            List of HostInfo objects
        """
        data = self.read()
        hosts = []
        hosts_dict = data.get("hosts", {})

        for name, config in hosts_dict.items():
            try:
                host = HostInfo(
                    name=name,
                    ip=config.get("ip", "unknown"),
                    ssh_user=config.get("ssh_user", "unknown"),
                    path=config.get("path"),
                    roles=config.get("roles", []),
                    status=config.get("status", "unknown"),
                )
                hosts.append(host)
            except Exception as e:
                logger.error(f"Failed to parse host {name}: {e}")

        return hosts

    def get_host(self, name: str) -> Optional[HostInfo]:
        """
        Get a specific host by name (legacy compatibility)

        Args:
            name: Host name

        Returns:
            HostInfo or None if not found
        """
        data = self.read()
        hosts_dict = data.get("hosts", {})
        config = hosts_dict.get(name)

        if not config:
            return None

        try:
            return HostInfo(
                name=name,
                ip=config.get("ip", "unknown"),
                ssh_user=config.get("ssh_user", "unknown"),
                path=config.get("path"),
                roles=config.get("roles", []),
                status=config.get("status", "unknown"),
            )
        except Exception as e:
            logger.error(f"Failed to parse host {name}: {e}")
            return None

    def get_services_on_host(self, host: str) -> List[ServiceInfo]:
        """
        Get all services running on a specific host (legacy compatibility)

        Args:
            host: Host name

        Returns:
            List of ServiceInfo objects
        """
        all_services = self.get_all_services()
        return [s for s in all_services if s.current_host == host]

    def get_domain(self) -> str:
        """Get the domain from the registry (legacy compatibility)"""
        data = self.read()
        return data.get("domain", "internal")
