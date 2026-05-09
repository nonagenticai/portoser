"""WebSocket authentication helpers.

Starlette's `BaseHTTPMiddleware` does not intercept WebSocket connections,
so the Keycloak auth middleware never sees `ws://` upgrades. WS endpoints
that need authentication call `authenticate_websocket()` immediately after
the handshake to validate a token and attach the resulting user to the
socket's scope.

Browser WebSocket clients can't set custom headers, so the helper accepts
the token in any of these places (checked in order):

  1. Authorization: Bearer <token> header
  2. Sec-WebSocket-Protocol subprotocol of the form "bearer.<token>"
  3. ?token=<token> query parameter

Failures close the socket with WebSocket close code 4401 (application-level
"unauthenticated"); 4403 is reserved for "authenticated but missing role".
"""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import WebSocket
from jose import JWTError

from config import config

from .models import KeycloakUser
from .validator import get_validator

logger = logging.getLogger(__name__)


# Application-level WebSocket close codes. RFC 6455 reserves 4000-4999 for
# private use; we mirror HTTP semantics so logs/tests are easy to grep.
WS_CLOSE_UNAUTHENTICATED = 4401
WS_CLOSE_FORBIDDEN = 4403


async def authenticate_websocket(websocket: WebSocket) -> Optional[KeycloakUser]:
    """Validate the bearer token attached to a WebSocket handshake.

    Returns the authenticated user, or `None` after closing the socket if
    the token is missing/invalid. Callers should bail out immediately on
    `None` (do not call `accept()` afterwards).

    When `KEYCLOAK_ENABLED=false` (the local-dev default), this returns a
    sentinel `KeycloakUser` so callers don't need to special-case the dev
    path — the result is the same as `request.state.user` would have been
    on an HTTP route.
    """
    # Dev mode: middleware would have skipped auth for HTTP requests, so
    # mirror that behaviour for WebSocket upgrades.
    if not config.keycloak_enabled:
        return _anonymous_dev_user()

    token = _extract_token(websocket)
    if not token:
        logger.info(
            "ws auth: missing token (path=%s, client=%s)",
            websocket.url.path,
            websocket.client.host if websocket.client else "?",
        )
        await _reject(websocket, WS_CLOSE_UNAUTHENTICATED, "Missing authentication token")
        return None

    try:
        payload = await get_validator().validate_token(token)
    except JWTError as exc:
        logger.warning("ws auth: invalid token on %s: %s", websocket.url.path, exc)
        await _reject(websocket, WS_CLOSE_UNAUTHENTICATED, f"Invalid token: {exc}")
        return None
    except Exception as exc:  # network failure to Keycloak, etc.
        logger.error("ws auth: validator error on %s: %s", websocket.url.path, exc, exc_info=True)
        await _reject(websocket, WS_CLOSE_UNAUTHENTICATED, "Authentication service error")
        return None

    user = KeycloakUser(**payload)
    websocket.state.user = user
    logger.debug("ws auth: %s connected to %s", user.preferred_username, websocket.url.path)
    return user


async def authenticate_websocket_with_role(
    websocket: WebSocket, required_role: str
) -> Optional[KeycloakUser]:
    """Like `authenticate_websocket` but also requires a Keycloak realm role.

    Returns `None` (after closing) if the user lacks the role. In dev mode
    (`KEYCLOAK_ENABLED=false`) the role check is skipped — same trust model
    as the HTTP `require_role` dependency.
    """
    user = await authenticate_websocket(websocket)
    if user is None:
        return None

    # Dev-mode sentinel users have no realm roles; do not gate them.
    if not config.keycloak_enabled:
        return user

    if not user.has_realm_role(required_role):
        logger.info(
            "ws auth: %s lacks role %s for %s",
            user.preferred_username,
            required_role,
            websocket.url.path,
        )
        await _reject(
            websocket,
            WS_CLOSE_FORBIDDEN,
            f"Required role '{required_role}' not found",
        )
        return None
    return user


def _extract_token(websocket: WebSocket) -> Optional[str]:
    """Pull the bearer token from header, subprotocol, or query string."""
    # 1. Authorization header — works for non-browser clients (CLI, tests).
    auth_header = websocket.headers.get("authorization")
    if auth_header and auth_header.lower().startswith("bearer "):
        return auth_header[7:].strip() or None

    # 2. Sec-WebSocket-Protocol subprotocol. Browsers can pass an array of
    #    subprotocols; clients use this trick to smuggle a bearer token
    #    alongside their real subprotocol. Accept "bearer.<token>" or just
    #    "bearer,<token>".
    proto_header = websocket.headers.get("sec-websocket-protocol")
    if proto_header:
        for proto in (p.strip() for p in proto_header.split(",")):
            if proto.startswith("bearer."):
                candidate = proto[len("bearer.") :].strip()
                if candidate:
                    return candidate
            if proto.lower() == "bearer":
                # Caller used "bearer" as a marker and the token is the
                # next protocol value.
                continue

    # 3. Query string fallback for browsers — the only option the native
    #    WebSocket API offers when you can't set headers.
    token = websocket.query_params.get("token") or websocket.query_params.get("access_token")
    if token:
        return token.strip() or None
    return None


async def _reject(websocket: WebSocket, code: int, reason: str) -> None:
    """Close the handshake with an application-level close code.

    Starlette permits closing before `accept()` — the resulting handshake
    response is `HTTP 403`. Closing after a partial accept uses the WS
    close frame. We try to close politely either way.
    """
    try:
        await websocket.close(code=code, reason=reason)
    except RuntimeError:
        # Socket may already be closed (handshake never completed).
        pass


def _anonymous_dev_user() -> KeycloakUser:
    """Build a permissive sentinel user for `KEYCLOAK_ENABLED=false`.

    This mirrors the `request.state.user` an HTTP route would observe in
    dev mode (none, but routes proceed because middleware skips auth).
    Returning a real `KeycloakUser` keeps WS handler code uniform.
    """
    return KeycloakUser(
        sub="dev-mode",
        preferred_username="dev",
        email=None,
        realm_access={"roles": []},
        resource_access={},
    )
