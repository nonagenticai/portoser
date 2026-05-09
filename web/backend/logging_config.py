"""
Structured logging configuration with secret sanitization

This module provides:
- JSON structured logging with structlog
- Secret field sanitization (password, token, secret, key)
- Request ID correlation for distributed tracing
- Performance-optimized logging
"""

import logging
import re
import sys
from typing import Any, Dict

import structlog

# Secret field patterns to sanitize
SECRET_PATTERNS = [
    r"password",
    r"passwd",
    r"token",
    r"secret",
    r"key",
    r"apikey",
    r"api_key",
    r"auth",
    r"authorization",
    r"credential",
]

# Compile regex patterns for performance
SECRET_REGEX = re.compile("|".join(SECRET_PATTERNS), re.IGNORECASE)


def sanitize_secrets(logger: Any, method_name: str, event_dict: Dict[str, Any]) -> Dict[str, Any]:
    """
    Processor to sanitize secret fields in log entries

    Args:
        logger: Logger instance
        method_name: Logging method name
        event_dict: Event dictionary to sanitize

    Returns:
        Sanitized event dictionary
    """

    def _sanitize_value(key: str, value: Any) -> Any:
        """Recursively sanitize values"""
        if SECRET_REGEX.search(str(key)):
            return "***REDACTED***"

        if isinstance(value, dict):
            return {k: _sanitize_value(k, v) for k, v in value.items()}
        elif isinstance(value, list):
            return [_sanitize_value(key, item) for item in value]
        elif isinstance(value, str) and len(value) > 20:
            # Check if the value looks like a token/key (long alphanumeric string)
            if re.match(r"^[A-Za-z0-9\-_\.]{32,}$", value):
                return f"{value[:8]}...{value[-4:]}"

        return value

    # Sanitize all fields in the event dict
    sanitized = {}
    for key, value in event_dict.items():
        sanitized[key] = _sanitize_value(key, value)

    return sanitized


def add_request_id(logger: Any, method_name: str, event_dict: Dict[str, Any]) -> Dict[str, Any]:
    """
    Processor to add request ID to log entries

    Args:
        logger: Logger instance
        method_name: Logging method name
        event_dict: Event dictionary

    Returns:
        Event dictionary with request_id added
    """
    import contextvars

    # Try to get request ID from context
    request_id = contextvars.ContextVar("request_id", default=None).get()
    if request_id:
        event_dict["request_id"] = request_id

    return event_dict


def configure_logging(
    log_level: str = "INFO", json_logs: bool = True, development: bool = False
) -> None:
    """
    Configure structured logging for the application

    Args:
        log_level: Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL)
        json_logs: Whether to use JSON format (True for production, False for dev)
        development: Whether running in development mode
    """
    # Convert log level string to logging constant
    level = getattr(logging, log_level.upper(), logging.INFO)

    # Configure structlog processors
    processors = [
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        add_request_id,
        sanitize_secrets,
    ]

    if development:
        # Development mode: colorful console output
        processors.append(structlog.dev.ConsoleRenderer())
    else:
        # Production mode: JSON output
        processors.extend(
            [
                structlog.processors.format_exc_info,
                structlog.processors.UnicodeDecoder(),
                structlog.processors.JSONRenderer(),
            ]
        )

    structlog.configure(
        processors=processors,
        wrapper_class=structlog.stdlib.BoundLogger,
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )

    # Configure standard library logging
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=level,
    )

    # Set log level for common noisy libraries
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("asyncio").setLevel(logging.WARNING)


def get_logger(name: str) -> structlog.BoundLogger:
    """
    Get a structured logger instance

    Args:
        name: Logger name (usually __name__)

    Returns:
        Configured logger instance
    """
    return structlog.get_logger(name)
