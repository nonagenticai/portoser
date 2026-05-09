"""Auth router: login / refresh / logout / me.

The SPA hits these endpoints to bootstrap authentication so it can attach
``Authorization: Bearer ...`` to subsequent /api/* and WS requests.

Login and refresh MUST be exempt from the Keycloak auth middleware
(otherwise we'd be asking for a token in order to get a token); they are
listed in :pyattr:`auth.middleware.PUBLIC_ENDPOINTS`.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from auth.dependencies import get_current_user
from auth.models import KeycloakUser
from config import config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/auth", tags=["auth"])

# Set during lifespan startup by main.py to avoid the circular import that
# would otherwise come from importing main here.
keycloak_client: Optional[Any] = None


class LoginRequest(BaseModel):
    username: str = Field(..., min_length=1)
    password: str = Field(..., min_length=1)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(..., min_length=1)


class LogoutRequest(BaseModel):
    refresh_token: str = Field(..., min_length=1)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    expires_in: int = 3600
    token_type: str = "Bearer"


class LoginResponse(TokenResponse):
    user: Dict[str, Any]


def _require_keycloak() -> Any:
    """Reject auth flows when Keycloak isn't enabled or wasn't initialized."""
    if not config.keycloak_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication is disabled on this instance",
        )
    if keycloak_client is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Keycloak client not initialized",
        )
    return keycloak_client


@router.post("/login", response_model=LoginResponse)
async def login(request: LoginRequest) -> LoginResponse:
    """Exchange username/password for tokens via Keycloak.

    The SPA stores the resulting access_token + refresh_token (sessionStorage
    in the reference client) and attaches the access_token to every API call.
    """
    client = _require_keycloak()
    try:
        result = client.authenticate(request.username, request.password)
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"Login failed for {request.username!r}: {exc}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials"
        ) from None

    return LoginResponse(
        access_token=result["access_token"],
        refresh_token=result.get("refresh_token"),
        expires_in=result.get("expires_in", 3600),
        user=result.get("user", {}),
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(request: RefreshRequest) -> TokenResponse:
    """Trade a refresh_token for a fresh access_token + (rotated) refresh_token."""
    client = _require_keycloak()
    try:
        tokens = client.refresh_token(request.refresh_token)
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"Refresh failed: {exc}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token invalid or expired"
        ) from None

    access_token = tokens.get("access_token")
    if not access_token:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Keycloak did not return access_token on refresh",
        )

    return TokenResponse(
        access_token=access_token,
        refresh_token=tokens.get("refresh_token"),
        expires_in=tokens.get("expires_in", 3600),
    )


@router.post("/logout")
async def logout(request: LogoutRequest) -> Dict[str, bool]:
    """Revoke the refresh token at Keycloak. Idempotent — failure still 200s."""
    client = _require_keycloak()
    try:
        ok = client.logout(request.refresh_token)
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"Logout call to Keycloak failed: {exc}")
        ok = False
    return {"success": ok}


@router.get("/me")
async def me(current_user: KeycloakUser = Depends(get_current_user)) -> Dict[str, Any]:
    """Return the decoded user payload for whoever holds the current token."""
    return {
        "sub": current_user.sub,
        "username": current_user.preferred_username,
        "email": current_user.email,
        "roles": current_user.realm_access.get("roles", []) if current_user.realm_access else [],
    }
