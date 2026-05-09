"""Tests for the centralized WebSocket auth helper.

We test `_extract_token` and `authenticate_websocket` directly via mock
WebSockets — exercising the actual FastAPI WS handshake would require a
running event loop and the full app, which is out of scope for a unit
test. The integration is covered by the existing API tests.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from jose import JWTError

from auth.websocket import (
    WS_CLOSE_FORBIDDEN,
    WS_CLOSE_UNAUTHENTICATED,
    _extract_token,
    authenticate_websocket,
    authenticate_websocket_with_role,
)


def _ws(*, headers=None, query=None):
    """Build a mock WebSocket that quacks like FastAPI's."""
    ws = MagicMock()
    ws.headers = headers or {}
    ws.query_params = query or {}
    ws.url.path = "/ws/test"
    ws.client = None
    ws.state = MagicMock()
    ws.close = AsyncMock()
    return ws


class TestExtractToken:
    def test_authorization_bearer_header(self):
        ws = _ws(headers={"authorization": "Bearer abc.def.ghi"})
        assert _extract_token(ws) == "abc.def.ghi"

    def test_authorization_header_case_insensitive(self):
        ws = _ws(headers={"authorization": "bearer abc"})
        assert _extract_token(ws) == "abc"

    def test_authorization_header_other_scheme_ignored(self):
        ws = _ws(headers={"authorization": "Basic dXNlcjpwYXNz"})
        assert _extract_token(ws) is None

    def test_subprotocol_bearer_dot_token(self):
        ws = _ws(headers={"sec-websocket-protocol": "bearer.xyz.token, json"})
        assert _extract_token(ws) == "xyz.token"

    def test_query_string_token(self):
        ws = _ws(query={"token": "querytoken"})
        assert _extract_token(ws) == "querytoken"

    def test_query_string_access_token_alias(self):
        ws = _ws(query={"access_token": "alt"})
        assert _extract_token(ws) == "alt"

    def test_header_takes_precedence_over_query(self):
        ws = _ws(
            headers={"authorization": "Bearer headertok"},
            query={"token": "querytok"},
        )
        assert _extract_token(ws) == "headertok"

    def test_missing_everywhere(self):
        assert _extract_token(_ws()) is None


@pytest.mark.asyncio
class TestAuthenticateWebsocketDevMode:
    """When KEYCLOAK_ENABLED=false the helper returns a sentinel user."""

    async def test_dev_mode_returns_sentinel_without_token(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "false")
        ws = _ws()
        user = await authenticate_websocket(ws)
        assert user is not None
        assert user.preferred_username == "dev"
        ws.close.assert_not_called()


@pytest.mark.asyncio
class TestAuthenticateWebsocketProductionMode:
    """When KEYCLOAK_ENABLED=true, real token validation happens."""

    async def test_missing_token_closes_with_4401(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        ws = _ws()
        user = await authenticate_websocket(ws)
        assert user is None
        ws.close.assert_awaited_once()
        kwargs = ws.close.await_args.kwargs
        assert kwargs.get("code") == WS_CLOSE_UNAUTHENTICATED

    async def test_invalid_token_closes_with_4401(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        validator = MagicMock()
        validator.validate_token = AsyncMock(side_effect=JWTError("bad sig"))
        with patch("auth.websocket.get_validator", return_value=validator):
            ws = _ws(headers={"authorization": "Bearer bad"})
            user = await authenticate_websocket(ws)
        assert user is None
        ws.close.assert_awaited_once()
        assert ws.close.await_args.kwargs.get("code") == WS_CLOSE_UNAUTHENTICATED

    async def test_validator_unexpected_error_closes_with_4401(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        validator = MagicMock()
        validator.validate_token = AsyncMock(side_effect=RuntimeError("kc down"))
        with patch("auth.websocket.get_validator", return_value=validator):
            ws = _ws(headers={"authorization": "Bearer t"})
            user = await authenticate_websocket(ws)
        assert user is None
        ws.close.assert_awaited_once()

    async def test_valid_token_attaches_user(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        payload = {
            "sub": "u-1",
            "preferred_username": "alice",
            "realm_access": {"roles": ["operator"]},
        }
        validator = MagicMock()
        validator.validate_token = AsyncMock(return_value=payload)
        with patch("auth.websocket.get_validator", return_value=validator):
            ws = _ws(headers={"authorization": "Bearer t"})
            user = await authenticate_websocket(ws)
        assert user is not None
        assert user.preferred_username == "alice"
        assert ws.state.user is user
        ws.close.assert_not_called()

    async def test_role_required_passes_when_user_has_role(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        payload = {
            "sub": "u-1",
            "preferred_username": "alice",
            "realm_access": {"roles": ["admin"]},
        }
        validator = MagicMock()
        validator.validate_token = AsyncMock(return_value=payload)
        with patch("auth.websocket.get_validator", return_value=validator):
            ws = _ws(headers={"authorization": "Bearer t"})
            user = await authenticate_websocket_with_role(ws, "admin")
        assert user is not None
        ws.close.assert_not_called()

    async def test_role_required_closes_with_4403_when_missing(self, monkeypatch):
        monkeypatch.setenv("KEYCLOAK_ENABLED", "true")
        payload = {
            "sub": "u-1",
            "preferred_username": "alice",
            "realm_access": {"roles": ["operator"]},
        }
        validator = MagicMock()
        validator.validate_token = AsyncMock(return_value=payload)
        with patch("auth.websocket.get_validator", return_value=validator):
            ws = _ws(headers={"authorization": "Bearer t"})
            user = await authenticate_websocket_with_role(ws, "admin")
        assert user is None
        ws.close.assert_awaited_once()
        assert ws.close.await_args.kwargs.get("code") == WS_CLOSE_FORBIDDEN
