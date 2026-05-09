"""
Device ownership verification utilities for Portoser
"""

from typing import Dict

from fastapi import HTTPException, status

from auth.models import KeycloakUser


def check_device_ownership(hostname: str, user: KeycloakUser, registry: Dict) -> bool:
    """
    Check if user owns device or is admin

    Args:
        hostname: Device hostname
        user: Current user
        registry: Registry data

    Returns:
        True if user owns device or is admin
    """
    # Admins can manage all devices
    if user.has_realm_role("admin"):
        return True

    # Check device ownership
    device = registry.get("hosts", {}).get(hostname)
    if not device:
        return False

    owner_user_id = device.get("owner_user_id")
    if owner_user_id == user.sub:
        return True

    return False


def require_device_ownership(hostname: str, user: KeycloakUser, registry: Dict):
    """
    Raise exception if user doesn't own device and isn't admin

    Args:
        hostname: Device hostname
        user: Current user
        registry: Registry data

    Raises:
        HTTPException: If user lacks permission
    """
    if not check_device_ownership(hostname, user, registry):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"You do not have permission to manage device '{hostname}'. Only the device owner or admins can perform this action.",
        )
