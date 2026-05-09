"""Authentication module for Portoser backend."""

from .config import KeycloakSettings, get_settings
from .dependencies import get_current_user, require_all_roles, require_any_role, require_role
from .middleware import KeycloakAuthMiddleware
from .models import KeycloakUser
from .validator import TokenValidator, get_validator
from .websocket import (
    WS_CLOSE_FORBIDDEN,
    WS_CLOSE_UNAUTHENTICATED,
    authenticate_websocket,
    authenticate_websocket_with_role,
)

__all__ = [
    "KeycloakSettings",
    "get_settings",
    "KeycloakUser",
    "TokenValidator",
    "get_validator",
    "KeycloakAuthMiddleware",
    "get_current_user",
    "require_role",
    "require_any_role",
    "require_all_roles",
    "authenticate_websocket",
    "authenticate_websocket_with_role",
    "WS_CLOSE_UNAUTHENTICATED",
    "WS_CLOSE_FORBIDDEN",
]
