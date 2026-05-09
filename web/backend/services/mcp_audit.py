import asyncio
import logging
import os
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional

from fastapi import Request
from uuid_extensions import uuid7

from utils.datetime_utils import utcnow

from .mcp_postgres_db import MCPPostgresDB

logger = logging.getLogger(__name__)

# Default retention period (90 days) can be overridden via environment variable
DEFAULT_AUDIT_RETENTION_DAYS = 90
AUDIT_RETENTION_DAYS = int(os.getenv("AUDIT_RETENTION_DAYS", DEFAULT_AUDIT_RETENTION_DAYS))
# Default cleanup interval (once a day)
AUDIT_CLEANUP_INTERVAL_HOURS = int(os.getenv("AUDIT_CLEANUP_INTERVAL_HOURS", 24))


class AuditLogService:
    """
    Service for recording audit events, with configurable retention periods.

    Audit log entries are automatically pruned after the configured retention period.
    """

    def __init__(self, db_instance: MCPPostgresDB):
        """
        Initialize with database instance.

        Args:
            db_instance: MCPPostgresDB instance for database access
        """
        self.db = db_instance
        self.cleanup_task = None
        self.retention_days = AUDIT_RETENTION_DAYS
        self.cleanup_interval = AUDIT_CLEANUP_INTERVAL_HOURS

        # Start the cleanup background task
        if self.retention_days > 0:
            self.start_cleanup_task()
            logger.info(
                f"Audit log retention set to {self.retention_days} days, cleanup interval {self.cleanup_interval} hours"
            )
        else:
            logger.info("Audit log retention disabled (retention days <= 0)")

    def start_cleanup_task(self):
        """Start the background task for cleaning up old audit logs."""
        if self.cleanup_task is None or self.cleanup_task.done():
            self.cleanup_task = asyncio.create_task(self._cleanup_old_logs_task())
            logger.info("Started audit log cleanup background task")

    def stop_cleanup_task(self):
        """Stop the background cleanup task if it's running."""
        if self.cleanup_task and not self.cleanup_task.done():
            self.cleanup_task.cancel()
            logger.info("Canceled audit log cleanup background task")

    async def _cleanup_old_logs_task(self):
        """Background task that periodically cleans up old audit logs."""
        try:
            while True:
                try:
                    # Sleep first to avoid immediate cleanup on startup
                    await asyncio.sleep(self.cleanup_interval * 3600)  # Convert hours to seconds

                    # Perform cleanup
                    cutoff_date = utcnow() - timedelta(days=self.retention_days)
                    deleted_count = await self.delete_logs_before(cutoff_date)

                    if deleted_count > 0:
                        logger.info(
                            f"Audit log cleanup: Deleted {deleted_count} logs older than {cutoff_date.isoformat()}"
                        )
                except asyncio.CancelledError:
                    logger.info("Audit log cleanup task cancelled")
                    raise
                except Exception as e:
                    logger.error(f"Error in audit log cleanup task: {e}", exc_info=True)
                    # Sleep a shorter interval on error before retrying
                    await asyncio.sleep(900)  # 15 minutes
        except asyncio.CancelledError:
            logger.info("Audit log cleanup background task terminated")

    async def delete_logs_before(self, cutoff_date: datetime) -> int:
        """
        Delete audit logs older than the specified cutoff date.

        Args:
            cutoff_date: Datetime before which logs will be deleted

        Returns:
            Number of log entries deleted
        """
        try:
            async with self.db.pool.acquire() as conn:
                result = await conn.execute(
                    "DELETE FROM audit_logs WHERE timestamp < $1", cutoff_date
                )
                # Parse the DELETE n result to get the count
                deleted_count = 0
                if hasattr(result, "split"):
                    # Format is typically "DELETE n"
                    parts = result.split()
                    if len(parts) > 1 and parts[0] == "DELETE":
                        try:
                            deleted_count = int(parts[1])
                        except (ValueError, IndexError):
                            deleted_count = 0
                return deleted_count
        except Exception as e:
            logger.error(f"Error deleting audit logs before {cutoff_date}: {e}", exc_info=True)
            return 0

    @classmethod
    def __get_pydantic_json_schema__(cls, _core_schema, handler):
        """
        Custom JSON schema generator to prevent schema generation errors.
        This provides a simple schema for the AuditLogService type when used in FastAPI endpoints.
        """
        return {
            "type": "object",
            "title": "AuditLogService",
            "description": "Audit logging service instance",
        }

    async def log_event(
        self,
        actor_id: Optional[int],
        actor_type: str,
        action_type: str,
        resource_type: str,
        resource_id: Optional[str],
        status: str,
        details: Optional[Dict[str, Any]] = None,
        request: Optional[Request] = None,
    ) -> int:
        """
        Log an audit event.

        Args:
            actor_id: ID of the actor performing the action (user/agent ID)
            actor_type: Type of actor ('human', 'ai_agent', 'system')
            action_type: Type of action ('create', 'read', 'update', 'delete', 'execute')
            resource_type: Type of resource affected ('tool', 'user', 'role', etc.)
            resource_id: ID of the affected resource
            status: Status of the action ('success', 'failure')
            details: Additional details about the action
            request: FastAPI request object for extracting client info (optional)

        Returns:
            ID of the created audit log entry
        """
        # Generate a unique request ID if not already present
        request_id = getattr(request, "id", str(uuid7())) if request else str(uuid7())

        # Extract client IP if request is provided
        ip_address = None
        if request:
            ip_address = request.client.host if request.client else None

        # Log the event to the database
        log_id = await self.db.log_audit_event(
            actor_id=actor_id,
            actor_type=actor_type,
            action_type=action_type,
            resource_type=resource_type,
            resource_id=resource_id,
            status=status,
            details=details,
            request_id=request_id,
            ip_address=ip_address,
        )

        logger.info(
            f"Audit log: {action_type} {resource_type} by {actor_type} {actor_id} - {status}"
        )

        return log_id

    async def get_logs(
        self,
        start_time: Optional[datetime] = None,
        end_time: Optional[datetime] = None,
        actor_id: Optional[int] = None,
        actor_type: Optional[str] = None,
        action_type: Optional[str] = None,
        resource_type: Optional[str] = None,
        resource_id: Optional[str] = None,
        status: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Dict[str, Any]]:
        """
        Get audit logs with optional filtering.

        Args:
            start_time: Filter logs after this time
            end_time: Filter logs before this time
            actor_id: Filter logs by actor ID
            actor_type: Filter logs by actor type
            action_type: Filter logs by action type
            resource_type: Filter logs by resource type
            resource_id: Filter logs by resource ID
            status: Filter logs by status
            limit: Maximum number of logs to return
            offset: Offset for pagination

        Returns:
            List of audit log entries
        """
        return await self.db.get_audit_logs(
            start_time=start_time,
            end_time=end_time,
            actor_id=actor_id,
            actor_type=actor_type,
            action_type=action_type,
            resource_type=resource_type,
            resource_id=resource_id,
            status=status,
            limit=limit,
            offset=offset,
        )
