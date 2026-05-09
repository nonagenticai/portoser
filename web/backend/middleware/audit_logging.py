"""Comprehensive audit logging middleware for security and compliance"""

import json
import logging
import time
import uuid
from typing import Optional

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from utils.datetime_utils import utcnow

logger = logging.getLogger("audit")


class AuditLoggingMiddleware(BaseHTTPMiddleware):
    """
    Middleware for comprehensive audit logging of all API requests

    Logs for security and compliance:
    - Who performed the action (user ID, username)
    - What action was performed (method, endpoint, body)
    - When it occurred (timestamp with timezone)
    - Where it came from (IP address, user agent)
    - Result (status code, errors)
    - Request ID for correlation

    Sensitive data (passwords, tokens, secrets) is automatically redacted.
    """

    # Sensitive field names to redact
    SENSITIVE_FIELDS = {
        "password",
        "token",
        "secret",
        "api_key",
        "apikey",
        "authorization",
        "auth",
        "key",
        "credential",
        "credentials",
        "passwd",
        "pwd",
        "access_token",
        "refresh_token",
        "private_key",
    }

    # Methods that trigger audit logging
    AUDIT_METHODS = {"POST", "PUT", "PATCH", "DELETE"}

    def __init__(self, app, log_all_requests: bool = False):
        """
        Initialize audit logging middleware

        Args:
            app: FastAPI application
            log_all_requests: If True, log ALL requests (including GET). If False, only log state-changing operations.
        """
        super().__init__(app)
        self.log_all_requests = log_all_requests

    def redact_sensitive_data(self, data: dict) -> dict:
        """
        Recursively redact sensitive fields from data

        Args:
            data: Dictionary that may contain sensitive data

        Returns:
            Dictionary with sensitive fields redacted
        """
        if not isinstance(data, dict):
            return data

        redacted = {}
        for key, value in data.items():
            key_lower = key.lower()

            # Check if this field is sensitive
            if any(sensitive in key_lower for sensitive in self.SENSITIVE_FIELDS):
                redacted[key] = "***REDACTED***"
            elif isinstance(value, dict):
                redacted[key] = self.redact_sensitive_data(value)
            elif isinstance(value, list):
                redacted[key] = [
                    self.redact_sensitive_data(item) if isinstance(item, dict) else item
                    for item in value
                ]
            else:
                redacted[key] = value

        return redacted

    async def get_request_body(self, request: Request) -> Optional[dict]:
        """
        Safely extract and parse request body

        Args:
            request: Starlette request object

        Returns:
            Parsed request body as dict, or None if not available/parseable
        """
        try:
            # Check content type
            content_type = request.headers.get("content-type", "")

            if "application/json" in content_type:
                # Store body for later (request body can only be read once)
                body = await request.body()
                if body:
                    # Parse JSON
                    body_dict = json.loads(body.decode("utf-8"))
                    return self.redact_sensitive_data(body_dict)

            return None
        except Exception as e:
            logger.debug(f"Failed to parse request body: {e}")
            return None

    def get_user_info(self, request: Request) -> dict:
        """
        Extract user information from request

        Args:
            request: Starlette request object

        Returns:
            Dictionary with user information
        """
        user = getattr(request.state, "user", None)

        if user:
            return {
                "user_id": getattr(user, "sub", None),
                "username": getattr(user, "preferred_username", None),
                "email": getattr(user, "email", None),
                "roles": getattr(user, "realm_access", {}).get("roles", []),
            }

        return {"user_id": None, "username": "anonymous", "email": None, "roles": []}

    def get_client_info(self, request: Request) -> dict:
        """
        Extract client information from request

        Args:
            request: Starlette request object

        Returns:
            Dictionary with client information
        """
        # Get real IP (considering proxy headers)
        x_forwarded_for = request.headers.get("x-forwarded-for")
        if x_forwarded_for:
            client_ip = x_forwarded_for.split(",")[0].strip()
        else:
            client_ip = request.client.host if request.client else None

        return {
            "ip_address": client_ip,
            "user_agent": request.headers.get("user-agent"),
            "referer": request.headers.get("referer"),
        }

    def should_audit(self, request: Request) -> bool:
        """
        Determine if this request should be audited

        Args:
            request: Starlette request object

        Returns:
            True if request should be audited
        """
        # Always audit state-changing operations
        if request.method in self.AUDIT_METHODS:
            return True

        # Audit all requests if configured
        if self.log_all_requests:
            return True

        # Don't audit health checks and metrics endpoints
        path = request.url.path
        if path in ["/health", "/metrics", "/api/health"]:
            return False

        return False

    async def dispatch(self, request: Request, call_next):
        # Generate request ID for correlation
        request_id = str(uuid.uuid4())
        request.state.request_id = request_id

        # Add request ID to response headers
        start_time = time.time()

        # Check if we should audit this request
        should_audit = self.should_audit(request)

        # Pre-process request data if auditing
        request_body = None
        if should_audit:
            request_body = await self.get_request_body(request)

        # Process request
        response = await call_next(request)

        # Calculate duration
        duration_ms = round((time.time() - start_time) * 1000, 2)

        # Add request ID to response
        response.headers["X-Request-ID"] = request_id

        # Log audit entry if needed
        if should_audit:
            user_info = self.get_user_info(request)
            client_info = self.get_client_info(request)

            # Build audit log entry
            audit_entry = {
                "timestamp": utcnow().isoformat(),
                "request_id": request_id,
                "method": request.method,
                "path": request.url.path,
                "query_params": dict(request.query_params),
                "status_code": response.status_code,
                "duration_ms": duration_ms,
                "user": user_info,
                "client": client_info,
            }

            # Add request body if available (already redacted)
            if request_body:
                audit_entry["request_body"] = request_body

            # Determine log level based on status code
            if response.status_code >= 500:
                log_level = logging.ERROR
                audit_entry["severity"] = "ERROR"
            elif response.status_code >= 400:
                log_level = logging.WARNING
                audit_entry["severity"] = "WARNING"
            elif request.method in self.AUDIT_METHODS:
                log_level = logging.INFO
                audit_entry["severity"] = "INFO"
            else:
                log_level = logging.DEBUG
                audit_entry["severity"] = "DEBUG"

            # Log as structured JSON
            logger.log(
                log_level,
                f"AUDIT: {request.method} {request.url.path} {response.status_code}",
                extra={"audit": audit_entry},
            )

        return response
