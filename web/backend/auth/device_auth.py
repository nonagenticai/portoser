"""
Device API Authentication Dependencies
Provides role-based access control for device management endpoints
"""

from fastapi import Depends

from auth.dependencies import get_current_user, require_role
from auth.models import KeycloakUser


def require_admin() -> KeycloakUser:
    """
    Require admin role for sensitive device operations

    Use for PATCH and DELETE device endpoints that modify device state
    """
    return Depends(require_role("admin"))


def require_authenticated() -> KeycloakUser:
    """
    Require authenticated user for device listing

    Use for GET endpoints that expose device information
    """
    return Depends(get_current_user)
