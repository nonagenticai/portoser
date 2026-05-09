"""Standard exception handlers with comprehensive error handling."""

import logging
import traceback
from datetime import datetime, timezone

from fastapi import Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger(__name__)


async def not_found_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """Handle 404 Not Found errors with meaningful messages.

    Args:
        request: FastAPI request
        exc: HTTP exception with 404 status

    Returns:
        Standardized JSON error response with endpoint information
    """
    logger.warning(
        f"404 Not Found: {request.method} {request.url.path}",
        extra={
            "method": request.method,
            "path": request.url.path,
            "query_params": str(request.query_params),
            "client": request.client.host if request.client else "unknown",
        },
    )

    return JSONResponse(
        status_code=status.HTTP_404_NOT_FOUND,
        content={
            "error": {
                "message": f"Endpoint {request.url.path} not found",
                "status": status.HTTP_404_NOT_FOUND,
                "method": request.method,
                "path": request.url.path,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "suggestion": "Check API documentation at /docs for available endpoints",
            }
        },
    )


async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Handle Pydantic validation errors with detailed field information.

    Args:
        request: FastAPI request
        exc: Validation exception

    Returns:
        Standardized JSON error response with validation details
    """
    # Extract field names from validation errors
    field_errors = {}
    for error in exc.errors():
        field = ".".join(str(loc) for loc in error["loc"])
        field_errors[field] = error["msg"]

    logger.warning(
        f"Validation error on {request.method} {request.url.path}",
        extra={
            "method": request.method,
            "path": request.url.path,
            "errors": exc.errors(),
            "field_errors": field_errors,
            "client": request.client.host if request.client else "unknown",
        },
    )

    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={
            "error": {
                "message": "Validation error - please check your request data",
                "status": status.HTTP_422_UNPROCESSABLE_ENTITY,
                "details": exc.errors(),
                "field_errors": field_errors,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        },
    )


async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """Handle HTTP exceptions with enhanced context.

    Args:
        request: FastAPI request
        exc: HTTP exception

    Returns:
        Standardized JSON error response
    """
    # Log different levels based on status code
    if exc.status_code >= 500:
        logger.error(
            f"HTTP {exc.status_code} on {request.method} {request.url.path}: {exc.detail}",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status_code": exc.status_code,
                "client": request.client.host if request.client else "unknown",
            },
        )
    else:
        logger.warning(
            f"HTTP {exc.status_code} on {request.method} {request.url.path}: {exc.detail}",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status_code": exc.status_code,
                "client": request.client.host if request.client else "unknown",
            },
        )

    # Build enhanced error response
    error_content = {
        "error": {
            "message": str(exc.detail),
            "status": exc.status_code,
            "path": request.url.path,
            "method": request.method,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    }

    # Add helpful suggestions for common errors
    if exc.status_code == 401:
        error_content["error"]["suggestion"] = (
            "Authentication required. Please provide valid credentials."
        )
    elif exc.status_code == 403:
        error_content["error"]["suggestion"] = (
            "Insufficient permissions. Contact administrator if you need access."
        )
    elif exc.status_code == 503:
        error_content["error"]["suggestion"] = (
            "Service temporarily unavailable. Please try again later."
        )

    return JSONResponse(
        status_code=exc.status_code,
        content=error_content,
        headers=getattr(exc, "headers", None),
    )


async def global_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Handle all unhandled exceptions with comprehensive logging.

    Args:
        request: FastAPI request
        exc: Unhandled exception

    Returns:
        Standardized JSON error response
    """
    if isinstance(exc, StarletteHTTPException):
        # Let dedicated HTTP exception handling preserve the original response
        raise exc

    # Get full traceback for logging
    tb = traceback.format_exc()

    logger.error(
        f"Unhandled {type(exc).__name__} on {request.method} {request.url.path}: {str(exc)}",
        exc_info=True,
        extra={
            "method": request.method,
            "path": request.url.path,
            "exception_type": type(exc).__name__,
            "exception_message": str(exc),
            "client": request.client.host if request.client else "unknown",
            "traceback": tb,
        },
    )

    # Don't expose internal error details in production
    import os

    is_dev = os.getenv("ENVIRONMENT", "production") != "production"

    error_content = {
        "error": {
            "message": "Internal server error - an unexpected error occurred",
            "status": status.HTTP_500_INTERNAL_SERVER_ERROR,
            "path": request.url.path,
            "method": request.method,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    }

    # Include exception details in development mode only
    if is_dev:
        error_content["error"]["debug"] = {
            "exception_type": type(exc).__name__,
            "exception_message": str(exc),
            "traceback": tb.split("\n"),
        }

    return JSONResponse(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, content=error_content)
