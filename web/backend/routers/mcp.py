"""MCP tool management router"""

import logging
import os
from typing import Annotated, Any, Dict, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastmcp import FastMCP

from models.mcp import (
    MCPClientConfig,
    ToolCreate,
    ToolListResponse,
    ToolResponse,
    ToolUpdate,
)
from services.mcp_audit import AuditLogService
from services.mcp_auth import requires_permission
from services.mcp_dependencies import get_audit_service, get_db, get_tool_registry
from services.mcp_postgres_db import MCPPostgresDB
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/mcp", tags=["mcp"])


def _portoser_public_url() -> str:
    """Public base URL for Portoser, configured via PORTOSER_PUBLIC_URL.

    Returns a relative-empty string when unset so callers fall back to relative paths.
    """
    return os.getenv("PORTOSER_PUBLIC_URL", "").rstrip("/")


@router.get("/status")
async def mcp_status():
    """Get MCP server status

    This is Portoser's built-in MCP server, exposed under /api/mcp/*.
    The advertised URL comes from the PORTOSER_PUBLIC_URL environment variable.
    """
    base_url = _portoser_public_url()
    mcp_url = f"{base_url}/api/mcp" if base_url else "/api/mcp"
    return {
        "status": "running",
        "server": "Portoser Built-in MCP",
        "url": mcp_url,
        "version": "1.0.0",
        "protocol": "mcp",
        "transport": "sse",
        "note": "This is separate from any generic/enterprise MCP server you may run.",
    }


@router.get("/config", response_model=MCPClientConfig)
async def get_mcp_config():
    """Get MCP client configuration for connecting to this server

    Returns the configuration for Portoser's built-in MCP server, accessible
    under /api/mcp/*. The advertised base URL comes from PORTOSER_PUBLIC_URL.
    """
    # Public base URL of this Portoser instance (e.g. behind Caddy/ingress).
    base_url = _portoser_public_url()

    return MCPClientConfig(
        url=f"{base_url}/api/mcp/sse",
        post_url=f"{base_url}/api/mcp/messages/",
        debug=True,
        retry_timeout_ms=600,
        connection_timeout_ms=6000,
        blocking_mode=False,
        stream_mode=True,
        message_format="jsonrpc",
        jsonrpc_version="2.0",
    )


@router.get("/tools", response_model=ToolListResponse)
async def list_tools(
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=1000),
    mcp: FastMCP = Depends(get_tool_registry),
):
    """List all available MCP tools"""
    try:
        # Get tools from FastMCP
        tools = await mcp.get_tools()

        # Convert to dict format
        tool_list = []
        for tool in tools:
            tool_dict = {
                "name": tool.name,
                "description": tool.description or "",
            }
            if hasattr(tool, "inputSchema"):
                tool_dict["inputSchema"] = tool.inputSchema
            tool_list.append(tool_dict)

        # Apply pagination
        paginated_tools = tool_list[skip : skip + limit]

        return ToolListResponse(
            tools=paginated_tools,
            total=len(tool_list),
        )
    except Exception as e:
        logger.error(f"Error listing tools: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list tools: {str(e)}",
        )


@router.post("/tools", response_model=ToolResponse)
async def add_tool(
    tool_data: ToolCreate,
    current_user: Annotated[Dict[str, Any], Depends(requires_permission("tool:create"))],
    db: Annotated[MCPPostgresDB, Depends(get_db)],
    audit_service: Annotated[AuditLogService, Depends(get_audit_service)],
):
    """Add a new tool to the MCP server"""
    user_id = current_user.get("id")

    try:
        # Validate tool name
        if not tool_data.name.strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Tool name cannot be empty",
            )

        # Check for existing tool if not replacing
        if not tool_data.replace_existing:
            existing_tool = await db.get_tool_by_name(tool_data.name.strip())
            if existing_tool:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Tool '{tool_data.name}' already exists. Use replace_existing=true to overwrite.",
                )

        # Add the tool to database
        tool_id = await db.add_tool(
            name=tool_data.name.strip(),
            description=tool_data.description.strip(),
            code=tool_data.code,
            created_by=user_id,
            replace_existing=tool_data.replace_existing,
        )

        # Log audit event
        await audit_service.log_event(
            event_type="tool_created",
            user_id=user_id,
            details={
                "tool_id": str(tool_id),
                "tool_name": tool_data.name,
                "replaced": tool_data.replace_existing,
            },
        )

        logger.info(f"Tool '{tool_data.name}' created successfully by user {user_id}")

        return ToolResponse(
            success=True,
            message=f"Tool '{tool_data.name}' created successfully",
            tool_id=str(tool_id),
            tool_name=tool_data.name,
            created_at=utcnow().isoformat(),
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error creating tool: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create tool: {str(e)}",
        )


@router.get("/tools/{tool_name}")
async def get_tool(
    tool_name: str,
    db: Annotated[MCPPostgresDB, Depends(get_db)],
):
    """Get details about a specific tool"""
    try:
        tool = await db.get_tool_by_name(tool_name)
        if not tool:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Tool '{tool_name}' not found",
            )

        return tool

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting tool: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get tool: {str(e)}",
        )


@router.put("/tools/{tool_name}", response_model=ToolResponse)
async def update_tool(
    tool_name: str,
    tool_data: ToolUpdate,
    current_user: Annotated[Dict[str, Any], Depends(requires_permission("tool:update"))],
    db: Annotated[MCPPostgresDB, Depends(get_db)],
    audit_service: Annotated[AuditLogService, Depends(get_audit_service)],
):
    """Update an existing tool"""
    user_id = current_user.get("id")

    try:
        # Check if tool exists
        existing_tool = await db.get_tool_by_name(tool_name)
        if not existing_tool:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Tool '{tool_name}' not found",
            )

        # Update the tool
        update_data = {}
        if tool_data.description is not None:
            update_data["description"] = tool_data.description
        if tool_data.code is not None:
            update_data["code"] = tool_data.code

        if not update_data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="No update data provided",
            )

        await db.update_tool(tool_name, **update_data)

        # Log audit event
        await audit_service.log_event(
            event_type="tool_updated",
            user_id=user_id,
            details={
                "tool_name": tool_name,
                "updated_fields": list(update_data.keys()),
            },
        )

        logger.info(f"Tool '{tool_name}' updated successfully by user {user_id}")

        return ToolResponse(
            success=True,
            message=f"Tool '{tool_name}' updated successfully",
            tool_name=tool_name,
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error updating tool: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to update tool: {str(e)}",
        )


@router.delete("/tools/{tool_name}", response_model=ToolResponse)
async def delete_tool(
    tool_name: str,
    current_user: Annotated[Dict[str, Any], Depends(requires_permission("tool:delete"))],
    db: Annotated[MCPPostgresDB, Depends(get_db)],
    audit_service: Annotated[AuditLogService, Depends(get_audit_service)],
):
    """Delete a tool"""
    user_id = current_user.get("id")

    try:
        # Check if tool exists
        existing_tool = await db.get_tool_by_name(tool_name)
        if not existing_tool:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Tool '{tool_name}' not found",
            )

        # Delete the tool
        await db.delete_tool(tool_name)

        # Log audit event
        await audit_service.log_event(
            event_type="tool_deleted",
            user_id=user_id,
            details={
                "tool_name": tool_name,
            },
        )

        logger.info(f"Tool '{tool_name}' deleted successfully by user {user_id}")

        return ToolResponse(
            success=True,
            message=f"Tool '{tool_name}' deleted successfully",
            tool_name=tool_name,
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error deleting tool: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to delete tool: {str(e)}",
        )


@router.get("/audit/logs")
async def get_audit_logs(
    current_user: Annotated[Dict[str, Any], Depends(requires_permission("audit:read"))],
    audit_service: Annotated[AuditLogService, Depends(get_audit_service)],
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=1000),
    event_type: Optional[str] = Query(None),
):
    """Get audit logs for MCP operations"""
    try:
        logs = await audit_service.get_logs(
            skip=skip,
            limit=limit,
            event_type=event_type,
        )

        return {
            "logs": logs,
            "total": len(logs),
        }

    except Exception as e:
        logger.error(f"Error getting audit logs: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get audit logs: {str(e)}",
        )
