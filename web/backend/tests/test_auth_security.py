"""
Authentication Security Tests

Tests that authentication is properly hardened:
1. Production requires auth enabled
2. Public endpoints contain only safe read-only endpoints
3. Mutating endpoints require valid JWT
4. Missing Keycloak URL fails in production
"""

import os
from unittest.mock import MagicMock, patch

import pytest
from fastapi import Request
from fastapi.responses import JSONResponse

from auth.middleware import PUBLIC_ENDPOINTS, KeycloakAuthMiddleware
from config import Config


class TestProductionAuthRequirements:
    """Test that production mode requires authentication"""

    def test_production_requires_auth_enabled(self):
        """Production mode must have auth enabled by default"""
        with patch.dict(os.environ, {"ENVIRONMENT": "production"}, clear=False):
            config = Config()
            # In production, KEYCLOAK_ENABLED should default to true
            assert config.keycloak_enabled is True

    def test_development_allows_auth_disabled(self):
        """Development mode can have auth disabled"""
        with patch.dict(os.environ, {"ENVIRONMENT": "development"}, clear=False):
            config = Config()
            # In development, KEYCLOAK_ENABLED defaults to false
            assert config.keycloak_enabled is False

    def test_staging_allows_auth_disabled(self):
        """Staging mode can have auth disabled"""
        with patch.dict(os.environ, {"ENVIRONMENT": "staging"}, clear=False):
            config = Config()
            # In staging, KEYCLOAK_ENABLED defaults to false
            assert config.keycloak_enabled is False

    def test_production_validates_auth_enabled(self):
        """Production validation fails if auth is disabled"""
        with patch.dict(
            os.environ, {"ENVIRONMENT": "production", "KEYCLOAK_ENABLED": "false"}, clear=False
        ):
            config = Config()
            with pytest.raises(
                ValueError,
                match="CRITICAL SECURITY ERROR.*Authentication is REQUIRED in production",
            ):
                config.validate()

    def test_production_requires_keycloak_url(self):
        """Production fails if KEYCLOAK_URL not explicitly set"""
        with patch.dict(
            os.environ,
            {
                "ENVIRONMENT": "production",
                "KEYCLOAK_ENABLED": "true",
                "KEYCLOAK_CLIENT_SECRET": "test-secret",
            },
            clear=False,
        ):
            # Remove KEYCLOAK_URL to test default
            if "KEYCLOAK_URL" in os.environ:
                del os.environ["KEYCLOAK_URL"]

            config = Config()
            with pytest.raises(
                ValueError, match="KEYCLOAK_URL must be explicitly set in production"
            ):
                config.validate()

    def test_production_rejects_localhost_keycloak_url(self):
        """Production fails if KEYCLOAK_URL is localhost"""
        with patch.dict(
            os.environ,
            {
                "ENVIRONMENT": "production",
                "KEYCLOAK_ENABLED": "true",
                "KEYCLOAK_URL": "http://localhost:8080",
                "KEYCLOAK_CLIENT_SECRET": "test-secret",
            },
            clear=False,
        ):
            config = Config()
            with pytest.raises(
                ValueError, match="Default localhost URL is not allowed in production"
            ):
                config.validate()

    def test_production_requires_client_secret(self):
        """Production fails if KEYCLOAK_CLIENT_SECRET not set"""
        with patch.dict(
            os.environ,
            {
                "ENVIRONMENT": "production",
                "KEYCLOAK_ENABLED": "true",
                "KEYCLOAK_URL": "https://keycloak.example.com",
            },
            clear=False,
        ):
            # Remove secret
            if "KEYCLOAK_CLIENT_SECRET" in os.environ:
                del os.environ["KEYCLOAK_CLIENT_SECRET"]

            config = Config()
            with pytest.raises(ValueError, match="KEYCLOAK_CLIENT_SECRET is required"):
                config.validate()

    def test_production_with_proper_config_passes(self):
        """Production with proper auth config should pass validation"""
        with patch.dict(
            os.environ,
            {
                "ENVIRONMENT": "production",
                "KEYCLOAK_ENABLED": "true",
                "KEYCLOAK_URL": "https://keycloak.example.com",
                "KEYCLOAK_CLIENT_SECRET": "secure-secret-value",
                "JWT_SECRET_KEY": "production-jwt-secret",
            },
            clear=False,
        ):
            config = Config()
            assert config.validate() is True


class TestPublicEndpointsSafety:
    """Test that PUBLIC_ENDPOINTS contains only safe read-only endpoints"""

    def test_public_endpoints_are_minimal(self):
        """PUBLIC_ENDPOINTS should be minimal and safe"""
        # Count should be small - only essential endpoints. The cap was 10
        # before; we added /api/health, /api/config, /api/auth/login, and
        # /api/auth/refresh — all required for the SPA login flow.
        assert len(PUBLIC_ENDPOINTS) <= 14, (
            f"PUBLIC_ENDPOINTS too large ({len(PUBLIC_ENDPOINTS)}), should be <= 14"
        )

    def test_public_endpoints_no_mutating_apis(self):
        """PUBLIC_ENDPOINTS should not contain mutating API endpoints"""
        # These are dangerous endpoints that should NOT be public
        dangerous_endpoints = [
            "/api/machines",
            "/api/services",
            "/api/diagnostics/run",
            "/api/metrics",
            "/api/uptime",
            "/api/diagnostics/health/all",
        ]

        for endpoint in dangerous_endpoints:
            assert endpoint not in PUBLIC_ENDPOINTS, (
                f"Dangerous endpoint '{endpoint}' found in PUBLIC_ENDPOINTS"
            )

    def test_public_endpoints_only_safe_endpoints(self):
        """PUBLIC_ENDPOINTS should only contain safe read-only endpoints"""
        # Define what we consider safe
        safe_endpoints = {
            "/ping",
            "/health",
            "/api/health",  # Same readiness payload, /api-prefixed for SPA
            "/docs",
            "/redoc",
            "/openapi.json",
            "/compose.sh",  # Bootstrap script
            "/api/devices/register",  # Device registration
            "/api/register",  # Compatibility alias
            "/api/config",  # OIDC bootstrap discovery; only public flags
            "/api/auth/login",  # Public by definition (you can't auth to auth)
            "/api/auth/refresh",  # Public by definition (refresh token IS auth)
        }

        for endpoint in PUBLIC_ENDPOINTS:
            assert endpoint in safe_endpoints, (
                f"Unexpected endpoint '{endpoint}' in PUBLIC_ENDPOINTS. "
                f"Only these are allowed: {safe_endpoints}"
            )

    def test_middleware_excludes_only_public_endpoints(self):
        """Middleware should only exclude truly public endpoints"""
        # Create a mock app
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        # Test that dangerous endpoints are NOT excluded
        dangerous_paths = [
            "/api/machines",
            "/api/services",
            "/api/diagnostics/run",
            "/api/metrics",
            "/api/uptime",
        ]

        for path in dangerous_paths:
            assert not middleware._is_excluded(path), (
                f"Dangerous path '{path}' is incorrectly excluded from auth"
            )

    def test_middleware_allows_only_safe_prefixes(self):
        """Middleware should only allow safe prefix matches"""
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        # Safe prefixes that should be allowed
        safe_paths = [
            "/docs",
            "/docs/index.html",
            "/redoc",
            "/static/favicon.ico",
            "/openapi.json",
        ]

        for path in safe_paths:
            assert middleware._is_excluded(path), f"Safe path '{path}' should be excluded from auth"

        # Unsafe API paths that should require auth
        unsafe_paths = [
            "/api/health/comprehensive",  # Should require auth now
            "/api/metrics/dashboard",
            "/api/diagnostics/health/all",
        ]

        for path in unsafe_paths:
            assert not middleware._is_excluded(path), (
                f"API path '{path}' should require authentication"
            )


class TestMutatingEndpointsRequireAuth:
    """Test that POST/PUT/DELETE endpoints require valid JWT"""

    @pytest.mark.asyncio
    async def test_post_machines_requires_auth(self):
        """POST /api/machines should require authentication"""
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        # Create a mock request without auth header
        request = MagicMock(spec=Request)
        request.url.path = "/api/machines"
        request.method = "POST"
        request.headers.get.return_value = None  # No Authorization header

        # Mock call_next
        async def mock_call_next(req):
            return JSONResponse({"status": "ok"})

        # Mock config to enable auth
        with patch("auth.middleware.config") as mock_config:
            mock_config.keycloak_enabled = True

            # Dispatch should return 401
            response = await middleware.dispatch(request, mock_call_next)
            assert response.status_code == 401

    @pytest.mark.asyncio
    async def test_put_services_requires_auth(self):
        """PUT /api/services/{id} should require authentication"""
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        request = MagicMock(spec=Request)
        request.url.path = "/api/services/test-service"
        request.method = "PUT"
        request.headers.get.return_value = None

        async def mock_call_next(req):
            return JSONResponse({"status": "ok"})

        with patch("auth.middleware.config") as mock_config:
            mock_config.keycloak_enabled = True
            response = await middleware.dispatch(request, mock_call_next)
            assert response.status_code == 401

    @pytest.mark.asyncio
    async def test_delete_machines_requires_auth(self):
        """DELETE /api/machines/{id} should require authentication"""
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        request = MagicMock(spec=Request)
        request.url.path = "/api/machines/test-machine"
        request.method = "DELETE"
        request.headers.get.return_value = None

        async def mock_call_next(req):
            return JSONResponse({"status": "ok"})

        with patch("auth.middleware.config") as mock_config:
            mock_config.keycloak_enabled = True
            response = await middleware.dispatch(request, mock_call_next)
            assert response.status_code == 401

    @pytest.mark.asyncio
    async def test_get_machines_requires_auth(self):
        """GET /api/machines should now require authentication"""
        mock_app = MagicMock()
        middleware = KeycloakAuthMiddleware(mock_app)

        request = MagicMock(spec=Request)
        request.url.path = "/api/machines"
        request.method = "GET"
        request.headers.get.return_value = None

        async def mock_call_next(req):
            return JSONResponse({"status": "ok"})

        with patch("auth.middleware.config") as mock_config:
            mock_config.keycloak_enabled = True
            response = await middleware.dispatch(request, mock_call_next)
            assert response.status_code == 401


class TestConfigValidation:
    """Test configuration validation at startup"""

    def test_development_config_validates(self):
        """Development config should validate without strict requirements"""
        with patch.dict(os.environ, {"ENVIRONMENT": "development"}, clear=False):
            config = Config()
            assert config.validate() is True

    def test_vault_enabled_requires_token(self):
        """Vault enabled requires VAULT_TOKEN"""
        with patch.dict(
            os.environ, {"ENVIRONMENT": "development", "VAULT_ENABLED": "true"}, clear=False
        ):
            # Remove vault token
            if "VAULT_TOKEN" in os.environ:
                del os.environ["VAULT_TOKEN"]

            config = Config()
            with pytest.raises(ValueError, match="VAULT_TOKEN is required"):
                config.validate()


class TestPublicEndpointsCount:
    """Test and document the PUBLIC_ENDPOINTS count"""

    def test_public_endpoints_count_before_after(self):
        """
        Document PUBLIC_ENDPOINTS reduction.

        BEFORE: 18 endpoints (including dangerous ones).
        AFTER:  Should be <= 14 (the original 8 + auth-bootstrap additions:
                /api/health, /api/config, /api/auth/login, /api/auth/refresh).
        """
        # This test documents the change
        before_count = 18  # Original count with dangerous endpoints
        after_count = len(PUBLIC_ENDPOINTS)

        assert after_count < before_count, (
            f"PUBLIC_ENDPOINTS should be reduced from {before_count} to {after_count}"
        )
        assert after_count <= 14, f"PUBLIC_ENDPOINTS should be <= 14, got {after_count}"

        # Print for status report
        print(f"\nPUBLIC_ENDPOINTS reduced: {before_count} -> {after_count}")
