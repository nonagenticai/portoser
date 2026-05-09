# Import AuthService after its complete definition in auth.py
# This import will happen at the end to avoid circular dependency
# We want to keep the type hint but import it for runtime at a later point
from typing import TYPE_CHECKING

from fastapi import HTTPException, Request, status

# Import the actual service classes and DB type
from .mcp_audit import AuditLogService
from .mcp_postgres_db import MCPPostgresDB

if TYPE_CHECKING:
    from .mcp_auth import AuthService

# Import FastMCP type for hinting
from fastmcp import FastMCP

# Dependency Functions - Retrieve services from app.state


def get_db(request: Request) -> MCPPostgresDB:
    """Dependency to get the database instance from app state."""
    # Check if MCP is enabled
    if not getattr(request.app.state, "mcp_enabled", False):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP services are currently disabled",
        )

    db = getattr(request.app.state, "mcp_db", None)
    if db is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP database connection failed. Please contact administrator.",
        )
    return db


def get_auth_service(request: Request) -> "AuthService":
    """Dependency to get the auth service instance from app state."""
    # Check if MCP is enabled
    if not getattr(request.app.state, "mcp_enabled", False):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP services are currently disabled",
        )

    auth_service = getattr(request.app.state, "auth_service", None)
    if auth_service is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP authentication service failed. Please contact administrator.",
        )
    return auth_service


def get_audit_service(request: Request) -> AuditLogService:
    """Dependency to get the audit service instance from app state."""
    # Check if MCP is enabled
    if not getattr(request.app.state, "mcp_enabled", False):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP services are currently disabled",
        )

    audit_service = getattr(request.app.state, "audit_service", None)
    if audit_service is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP audit service failed. Please contact administrator.",
        )
    return audit_service


def get_tool_registry(request: Request) -> FastMCP:
    """Dependency to get the FastMCP instance from app state."""
    # Check if MCP is enabled
    if not getattr(request.app.state, "mcp_enabled", False):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP services are currently disabled",
        )

    mcp_instance = getattr(request.app.state, "mcp_instance", None)
    if mcp_instance is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="MCP tool registry failed. Please contact administrator.",
        )
    return mcp_instance


# Import AuthService for runtime - REMOVED - This caused the circular import
# from .auth import AuthService
