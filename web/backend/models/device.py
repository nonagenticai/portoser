"""
Device registration and management models for Portoser
"""

import ipaddress
import re
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, field_validator

# ============================================================================
# Device Resource Models
# ============================================================================


class DeviceResources(BaseModel):
    """Hardware resources for a device"""

    # ge=0 (not 1): registry entries for unprobed/unknown hosts default to 0,
    # and the /api/devices endpoint must still return a valid DeviceResources
    # row for them rather than 500-ing the whole device list.
    cpu_cores: int = Field(..., ge=0, description="Number of CPU cores")
    cpu_threads: int = Field(..., ge=0, description="Number of CPU threads")
    memory_gb: int = Field(..., ge=0, description="RAM in gigabytes")
    disk_gb: int = Field(..., ge=0, description="Disk space in gigabytes")
    gpu: bool = Field(default=False, description="GPU available")
    mlx_capable: bool = Field(default=False, description="MLX framework capable")


# ============================================================================
# Device Registration Models
# ============================================================================


class DeviceRegistrationRequest(BaseModel):
    """Request model for device registration"""

    hostname: str = Field(..., min_length=1, max_length=255, description="Device hostname")
    ip: str = Field(..., description="IP address")
    arch: str = Field(..., description="CPU architecture (arm64, x86_64, etc)")
    os: str = Field(..., description="Operating system (darwin, linux, etc)")
    os_version: str = Field(..., description="OS version")
    resources: DeviceResources = Field(..., description="Hardware resources")
    ssh_user: str = Field(..., min_length=1, description="SSH username")
    ssh_key_fingerprint: str = Field(..., description="SSH key fingerprint")
    capabilities: List[str] = Field(
        default_factory=list, description="Device capabilities (docker, native, mlx, etc)"
    )
    labels: Dict[str, str] = Field(default_factory=dict, description="Custom labels for filtering")
    registration_token: str = Field(..., description="Registration token from admin")

    @field_validator("hostname")
    @classmethod
    def validate_hostname(cls, v):
        """Validate hostname format (DNS-compatible)"""
        if not re.match(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", v):
            raise ValueError(
                "Hostname must be a valid DNS name (lowercase alphanumeric and hyphens)"
            )
        return v

    @field_validator("ip")
    @classmethod
    def validate_ip(cls, v):
        """Validate IP address format"""
        try:
            ipaddress.ip_address(v)
        except ValueError:
            raise ValueError("Invalid IP address format")
        return v

    @field_validator("arch")
    @classmethod
    def validate_arch(cls, v):
        """Validate architecture"""
        valid_archs = ["arm64", "x86_64", "amd64", "aarch64"]
        if v not in valid_archs:
            raise ValueError(f"Architecture must be one of: {', '.join(valid_archs)}")
        return v

    @field_validator("os")
    @classmethod
    def validate_os(cls, v):
        """Validate operating system"""
        valid_os = ["darwin", "linux", "windows"]
        if v not in valid_os:
            raise ValueError(f"OS must be one of: {', '.join(valid_os)}")
        return v


class DeviceRegistrationResponse(BaseModel):
    """Response model for successful device registration"""

    status: str = Field(..., description="Registration status (registered, pending)")
    hostname: str = Field(..., description="Device hostname")
    assigned_roles: List[str] = Field(default_factory=list, description="Roles assigned to device")
    registry_version: str = Field(..., description="Current registry version")
    next_steps: List[str] = Field(default_factory=list, description="Next steps for device setup")
    approval_required: bool = Field(
        default=False, description="Whether manual approval is required"
    )
    registered_at: str = Field(..., description="Registration timestamp")
    approval_url: Optional[str] = Field(None, description="URL for approval (if pending)")
    message: Optional[str] = Field(None, description="Additional message")


# ============================================================================
# Device Update Models
# ============================================================================


class DeviceUpdateRequest(BaseModel):
    """Request model for updating device metadata"""

    resources: Optional[DeviceResources] = Field(None, description="Updated hardware resources")
    capabilities: Optional[List[str]] = Field(None, description="Updated capabilities")
    labels: Optional[Dict[str, str]] = Field(None, description="Updated labels")
    ssh_user: Optional[str] = Field(None, description="Updated SSH user")
    ssh_key_fingerprint: Optional[str] = Field(None, description="Updated SSH key fingerprint")


# ============================================================================
# Device Discovery Models
# ============================================================================


class DeviceDiscoveryResponse(BaseModel):
    """Response model for cluster discovery"""

    domain: str = Field(..., description="Cluster domain")
    dns_server: Optional[str] = Field(None, description="DNS server IP")
    ingress_host: str = Field(..., description="Ingress hostname")
    ingress_ip: str = Field(..., description="Ingress IP address")
    network_cidr: str = Field(..., description="Network CIDR")
    cluster_version: str = Field(..., description="Cluster version")
    required_capabilities: List[str] = Field(
        default_factory=list, description="Required capabilities"
    )
    registration_endpoint: str = Field(..., description="Registration API endpoint")


# ============================================================================
# Device Deregistration Models
# ============================================================================


class DeviceDeregistrationResponse(BaseModel):
    """Response model for device deregistration"""

    status: str = Field(..., description="Deregistration status")
    hostname: str = Field(..., description="Device hostname")
    services_migrated: List[str] = Field(
        default_factory=list, description="Services migrated to other hosts"
    )
    deregistered_at: str = Field(..., description="Deregistration timestamp")


# ============================================================================
# Error Response Models
# ============================================================================


class ValidationErrorDetail(BaseModel):
    """Validation error details"""

    field: str = Field(..., description="Field name with error")
    message: str = Field(..., description="Error message")


class ErrorResponse(BaseModel):
    """Generic error response"""

    error: str = Field(..., description="Error type")
    message: str = Field(..., description="Error message")
    details: Optional[Dict[str, Any]] = Field(None, description="Additional error details")
    existing_device: Optional[Dict[str, Any]] = Field(
        None, description="Existing device info (for conflicts)"
    )
    retry_after: Optional[int] = Field(None, description="Retry after N seconds (for 503 errors)")


# ============================================================================
# Device List/Query Models
# ============================================================================


class DeviceInfo(BaseModel):
    """Device information for listing"""

    hostname: str
    ip: str
    arch: str
    os: str
    os_version: str
    resources: DeviceResources
    ssh_user: str
    capabilities: List[str]
    labels: Dict[str, str]
    status: str = Field(
        default="pending", description="Device status (pending, active, disabled, maintenance)"
    )
    approval_status: str = Field(
        default="pending", description="Approval status (pending, approved, rejected)"
    )
    registered_at: str
    approved_at: Optional[str] = None
    last_seen_at: Optional[str] = None
    assigned_roles: List[str] = Field(default_factory=list)
    owner_user_id: Optional[str] = Field(None, description="User ID of device owner")


class DeviceListResponse(BaseModel):
    """Response model for device list"""

    devices: List[DeviceInfo]
    total: int
    total_pages: int = Field(..., description="Total number of pages")
    page: int = Field(..., description="Current page number (1-indexed)")
    page_size: int = Field(..., description="Number of devices per page")


# ============================================================================
# Device Ownership Models
# ============================================================================


class DeviceOwnershipTransferRequest(BaseModel):
    """Request model for transferring device ownership"""

    new_owner_user_id: str = Field(..., description="User ID of new owner")


class DeviceOwnershipTransferResponse(BaseModel):
    """Response model for ownership transfer"""

    status: str = Field(..., description="Transfer status")
    hostname: str = Field(..., description="Device hostname")
    previous_owner_user_id: Optional[str] = Field(None, description="Previous owner user ID")
    new_owner_user_id: str = Field(..., description="New owner user ID")
    transferred_at: str = Field(..., description="Transfer timestamp")


# ============================================================================
# Heartbeat Models
# ============================================================================


class DeviceHeartbeatRequest(BaseModel):
    """Request model for device heartbeat"""

    status: Optional[str] = Field(None, description="Device health status")
    metrics: Optional[Dict[str, Any]] = Field(None, description="Optional device metrics")


class DeviceHeartbeatResponse(BaseModel):
    """Response model for heartbeat acknowledgment"""

    success: bool
    hostname: str
    last_seen_at: str
    status: str = Field(..., description="Device status (online, offline, maintenance)")
