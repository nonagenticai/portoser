"""Request logging middleware."""

import logging
import time
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    """Log all HTTP requests with timing and status information."""

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """Process request and log details.

        Args:
            request: Incoming request
            call_next: Next handler in chain

        Returns:
            Response from handler
        """
        start_time = time.time()

        # Extract client info
        client_host = request.client.host if request.client else "unknown"

        # Log request start
        logger.info(
            "Request started",
            extra={
                "method": request.method,
                "path": request.url.path,
                "client": client_host,
            },
        )

        # Process request
        response = await call_next(request)

        # Calculate duration
        duration = time.time() - start_time
        duration_ms = round(duration * 1000, 2)

        # Log request completion
        logger.info(
            "Request completed",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": duration_ms,
            },
        )

        # Add timing header
        response.headers["X-Process-Time"] = str(duration_ms)

        return response
