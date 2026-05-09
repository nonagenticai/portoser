"""MCP-related data models"""

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class ToolInfo(BaseModel):
    """Information about an MCP tool"""

    name: str
    description: Optional[str] = None
    version: Optional[str] = None
    type: Optional[str] = None


class ToolCreate(BaseModel):
    """Model for creating a single-file tool"""

    name: str = Field(..., description="Name of the tool", min_length=1, max_length=100)
    description: str = Field(..., description="Description of what the tool does", max_length=1000)
    code: str = Field(..., description="Python code for the tool", min_length=1)
    replace_existing: bool = Field(
        False, description="Whether to replace an existing tool with the same name"
    )


class MultiFileToolCreate(BaseModel):
    """Model for creating a multi-file tool"""

    name: str = Field(..., description="Name of the tool", min_length=1, max_length=100)
    description: str = Field(..., description="Description of what the tool does", max_length=1000)
    entrypoint: str = Field(..., description="Main file/function entry point (e.g., 'main.py')")
    files: Dict[str, str] = Field(..., description="Dictionary of filename -> file content")
    replace_existing: bool = Field(
        False, description="Whether to replace an existing tool with the same name"
    )
    tool_dir_uuid: Optional[str] = Field(
        None, description="Optional tool directory UUID for grouping"
    )


class ToolResponse(BaseModel):
    """Response model for tool creation"""

    success: bool
    message: str
    tool_id: Optional[str] = None
    tool_name: str
    created_at: Optional[str] = None
    version_number: Optional[int] = None


class ToolUpdate(BaseModel):
    """Model for updating a tool"""

    description: Optional[str] = Field(None, description="Updated description")
    code: Optional[str] = Field(None, description="Updated Python code")


class ToolListResponse(BaseModel):
    """Response model for listing tools"""

    tools: List[Dict[str, Any]]
    total: int


class ToolDetailResponse(BaseModel):
    """Detailed information about a tool"""

    id: str
    name: str
    description: Optional[str]
    code: Optional[str]
    type: str
    version: Optional[str]
    created_at: datetime
    updated_at: Optional[datetime]
    created_by: Optional[int]


class MCPServerConfig(BaseModel):
    """MCP Server configuration"""

    name: str = Field(default="Portoser MCP Server")
    host: str = Field(default="0.0.0.0")
    port: int = Field(default=8029)
    transport: str = Field(default="sse")  # sse or stdio


class MCPClientConfig(BaseModel):
    """MCP Client configuration for connecting to the server"""

    url: str
    post_url: str
    debug: bool = False
    retry_timeout_ms: int = 600
    connection_timeout_ms: int = 6000
    blocking_mode: bool = False
    stream_mode: bool = True
    message_format: str = "jsonrpc"
    jsonrpc_version: str = "2.0"
