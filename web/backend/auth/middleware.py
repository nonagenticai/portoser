"""Authentication middleware."""

import logging
from typing import Callable, List, Optional

from fastapi import Request, Response
from fastapi.responses import JSONResponse
from jose import JWTError
from starlette.middleware.base import BaseHTTPMiddleware

from config import config  # Main app config for keycloak_enabled flag

from .config import get_settings
from .models import KeycloakUser
from .validator import get_validator

logger = logging.getLogger(__name__)

# Endpoints that don't require authentication
# SECURITY: Only safe read-only endpoints should be public
# All mutating APIs (POST/PUT/DELETE) and sensitive data endpoints require auth
PUBLIC_ENDPOINTS = [
    # Health checks
    "/ping",
    "/health",
    "/api/health",
    # API documentation (read-only)
    "/docs",
    "/redoc",
    "/openapi.json",
    # Device onboarding (needed for bootstrap)
    "/compose.sh",
    "/api/devices/register",
    "/api/register",  # Compatibility alias for device registration
    # Public auth-discovery endpoint: tells the SPA whether Keycloak is on
    # and which realm to redirect to. Returning 401 here would chicken-and-egg
    # the login flow.
    "/api/config",
    # Login / refresh: you can't require a token to get a token. Logout and
    # /me stay protected — they require a valid (or refreshable) session.
    "/api/auth/login",
    "/api/auth/refresh",
]


class KeycloakAuthMiddleware(BaseHTTPMiddleware):
    """Middleware to validate Keycloak JWT tokens on all requests."""

    def __init__(self, app, excluded_paths: Optional[List[str]] = None):
        """Initialize middleware.

        Args:
            app: FastAPI application
            excluded_paths: List of paths to exclude from authentication
        """
        super().__init__(app)
        self.settings = get_settings()
        self.validator = get_validator()
        self.excluded_paths = excluded_paths or PUBLIC_ENDPOINTS

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """Process each request through authentication.

        Args:
            request: Incoming request
            call_next: Next middleware/handler

        Returns:
            Response from handler or error response
        """
        # Skip authentication if Keycloak is disabled
        if not config.keycloak_enabled:
            return await call_next(request)

        # Skip authentication for public endpoints
        if self._is_excluded(request.url.path):
            return await call_next(request)

        # Extract token from Authorization header
        token = self._extract_token(request)
        if not token:
            return self._error_response(401, "Missing authentication token")

        # Validate token and attach user to request
        try:
            payload = await self.validator.validate_token(token)
            user = KeycloakUser(**payload)
            request.state.user = user
            logger.debug(f"Authenticated user: {user.preferred_username}")
        except JWTError as e:
            logger.warning(f"Invalid token: {e}")
            return self._error_response(401, f"Invalid token: {str(e)}")
        except Exception as e:
            logger.error(f"Authentication error: {e}", exc_info=True)
            return self._error_response(500, "Authentication service error")

        return await call_next(request)

    def _is_excluded(self, path: str) -> bool:
        """Check if path is excluded from authentication.

        Args:
            path: Request path

        Returns:
            True if path should skip authentication
        """
        clean_path = path.rstrip("/") or "/"

        # Exact match against PUBLIC_ENDPOINTS
        if clean_path in self.excluded_paths:
            return True

        # Prefix match only for docs and static files (read-only, safe)
        # SECURITY: Do NOT add API endpoints here - they should require auth
        excluded_prefixes = [
            "/docs",
            "/redoc",
            "/static",
            "/openapi.json",
        ]
        if any(clean_path.startswith(prefix) for prefix in excluded_prefixes):
            return True

        return False

    def _extract_token(self, request: Request) -> Optional[str]:
        """Extract Bearer token from Authorization header.

        Args:
            request: Incoming request

        Returns:
            JWT token string or None
        """
        auth_header = request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            return auth_header[7:]  # Remove "Bearer " prefix
        return None

    def _error_response(self, status_code: int, message: str) -> JSONResponse:
        """Return standardized error response.

        Args:
            status_code: HTTP status code
            message: Error message

        Returns:
            JSON error response
        """
        headers = {}
        if status_code == 401:
            headers["WWW-Authenticate"] = "Bearer"

        return JSONResponse(
            status_code=status_code,
            content={
                "error": {
                    "message": message,
                    "status": status_code,
                }
            },
            headers=headers,
        )
