"""Security headers middleware for FastAPI"""

import logging
import os

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

logger = logging.getLogger(__name__)


def _csp_connect_src() -> str:
    """Build the connect-src directive for the Content-Security-Policy header.

    Operators can extend the allowed origins via the CSP_CONNECT_SRC env var
    (space-separated, e.g. "https://*.example.com wss://*.example.com").
    By default we allow same-origin plus any ws/wss scheme so local development
    works out of the box without baking specific domains into the source.
    """
    base_sources = ["'self'", "ws:", "wss:"]
    extra = os.getenv("CSP_CONNECT_SRC", "").strip()
    if extra:
        base_sources.extend(extra.split())
    return " ".join(base_sources)


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """
    Middleware to add security headers to all responses

    Headers added:
    - X-Content-Type-Options: Prevent MIME-type sniffing
    - X-Frame-Options: Prevent clickjacking
    - X-XSS-Protection: Enable XSS filtering
    - Strict-Transport-Security: Force HTTPS
    - Content-Security-Policy: Restrict resource loading
    - Referrer-Policy: Control referrer information
    - Permissions-Policy: Control browser features
    """

    def __init__(self, app, enable_hsts: bool = True, enable_csp: bool = True):
        super().__init__(app)
        self.enable_hsts = enable_hsts
        self.enable_csp = enable_csp

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)

        # Prevent MIME-type sniffing
        response.headers["X-Content-Type-Options"] = "nosniff"

        # Prevent clickjacking - Allow same origin for WebSocket frames
        response.headers["X-Frame-Options"] = "SAMEORIGIN"

        # Enable XSS filtering (legacy browsers)
        response.headers["X-XSS-Protection"] = "1; mode=block"

        # Force HTTPS (only in production)
        if self.enable_hsts:
            # max-age=31536000 (1 year), includeSubDomains
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

        # Content Security Policy
        if self.enable_csp:
            # connect-src defaults to same-origin + ws/wss; operators can add
            # their own hosts via the CSP_CONNECT_SRC env var.
            csp_directives = [
                "default-src 'self'",
                "script-src 'self' 'unsafe-inline' 'unsafe-eval'",  # React/Vite needs eval
                "style-src 'self' 'unsafe-inline'",  # Tailwind needs inline styles
                "img-src 'self' data: blob:",
                "font-src 'self' data:",
                f"connect-src {_csp_connect_src()}",
                "frame-ancestors 'self'",
                "base-uri 'self'",
                "form-action 'self'",
            ]
            response.headers["Content-Security-Policy"] = "; ".join(csp_directives)

        # Control referrer information
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

        # Permissions Policy (formerly Feature-Policy)
        permissions_policy = [
            "accelerometer=()",
            "camera=()",
            "geolocation=()",
            "gyroscope=()",
            "magnetometer=()",
            "microphone=()",
            "payment=()",
            "usb=()",
        ]
        response.headers["Permissions-Policy"] = ", ".join(permissions_policy)

        # Remove server identification header if present
        if "server" in response.headers:
            del response.headers["server"]

        return response
