import asyncio
import json
import logging
import os
import re
import secrets
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Union
from urllib.parse import quote_plus
from uuid import UUID

import asyncpg
from asyncpg.exceptions import DuplicateDatabaseError, InvalidCatalogNameError
from uuid_extensions import uuid7

from utils.datetime_utils import utcnow

# Configure logging
logger = logging.getLogger(__name__)

# Default database configuration from environment variables
DB_HOST = os.getenv("POSTGRES_HOST", "localhost")
DB_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
DB_NAME = os.getenv("POSTGRES_DB", "enterprise_mcp_server")
DB_USER = os.getenv("POSTGRES_USER", "postgres")
DB_PASSWORD = os.getenv("POSTGRES_PASSWORD", "postgres")
DB_POOL_MIN_SIZE = int(os.getenv("POSTGRES_POOL_MIN_SIZE", "2"))
DB_POOL_MAX_SIZE = int(os.getenv("POSTGRES_POOL_MAX_SIZE", "10"))
DB_ADMIN_DB = os.getenv("POSTGRES_ADMIN_DB", "postgres")

# Warn if using default credentials in production
if DB_PASSWORD == "postgres" and os.getenv("ENVIRONMENT", "development") == "production":
    logger.warning(
        "⚠️  WARNING: Using default database password 'postgres' in production! Please set POSTGRES_PASSWORD environment variable."
    )


class MCPPostgresDB:
    """Database API for storing and retrieving MCP tool definitions using PostgreSQL."""

    def __init__(
        self,
        pool: asyncpg.Pool,
        loop: asyncio.AbstractEventLoop,
        executor: ThreadPoolExecutor,
    ):
        self.pool = pool
        self._loop = loop
        self._executor = executor
        self._closed = False

    @classmethod
    async def connect(cls, max_retries: int = 5, retry_delay: float = 2.0) -> "MCPPostgresDB":
        """Create a new database connection pool and instance with retry logic.

        Args:
            max_retries: Maximum number of connection attempts (default: 5)
            retry_delay: Initial delay between retries in seconds, doubles on each retry (default: 2.0)

        Returns:
            MCPPostgresDB: Connected database instance

        Raises:
            ConnectionError: If unable to establish connection after all retries
        """
        loop = asyncio.get_event_loop()
        executor = ThreadPoolExecutor(max_workers=DB_POOL_MAX_SIZE)
        dsn = f"postgresql://{quote_plus(DB_USER)}:{quote_plus(DB_PASSWORD)}@{DB_HOST}:{DB_PORT}/{DB_NAME}"

        logger.info(f"Attempting to connect to PostgreSQL at {DB_HOST}:{DB_PORT}/{DB_NAME}")
        logger.info(
            f"Connection parameters: user={DB_USER}, pool_size={DB_POOL_MIN_SIZE}-{DB_POOL_MAX_SIZE}"
        )

        pool = None
        last_error = None
        current_delay = retry_delay

        for attempt in range(1, max_retries + 1):
            try:
                logger.info(f"Connection attempt {attempt}/{max_retries}")

                # Try to create the pool
                pool = await asyncpg.create_pool(
                    dsn=dsn,
                    min_size=DB_POOL_MIN_SIZE,
                    max_size=DB_POOL_MAX_SIZE,
                    command_timeout=60,
                    statement_cache_size=100,
                    timeout=30,  # Connection timeout
                )

                logger.info(f"Successfully created connection pool on attempt {attempt}")
                break  # Success! Exit retry loop

            except InvalidCatalogNameError:
                logger.warning(
                    f"Database '{DB_NAME}' does not exist (attempt {attempt}/{max_retries}). "
                    f"Attempting to create it automatically..."
                )

                try:
                    await cls._ensure_database_exists()
                    logger.info("Database creation completed, retrying connection...")

                    # Retry immediately after creating database
                    pool = await asyncpg.create_pool(
                        dsn=dsn,
                        min_size=DB_POOL_MIN_SIZE,
                        max_size=DB_POOL_MAX_SIZE,
                        command_timeout=60,
                        statement_cache_size=100,
                        timeout=30,
                    )
                    logger.info("Successfully connected after database creation")
                    break  # Success! Exit retry loop

                except Exception as create_err:
                    logger.error(
                        f"Failed to create database or reconnect (attempt {attempt}/{max_retries}): {create_err}",
                        exc_info=True,
                    )
                    last_error = create_err

                    if attempt < max_retries:
                        logger.info(f"Waiting {current_delay}s before retry...")
                        await asyncio.sleep(current_delay)
                        current_delay *= 2  # Exponential backoff

            except (OSError, ConnectionRefusedError, asyncio.TimeoutError) as e:
                # Network/connection errors - retry with backoff
                logger.warning(
                    f"Connection failed (attempt {attempt}/{max_retries}): {type(e).__name__}: {e}"
                )
                last_error = e

                if attempt < max_retries:
                    logger.info(f"Waiting {current_delay}s before retry...")
                    await asyncio.sleep(current_delay)
                    current_delay *= 2  # Exponential backoff

            except Exception as e:
                # Unexpected error
                logger.error(
                    f"Unexpected error during connection (attempt {attempt}/{max_retries}): {e}",
                    exc_info=True,
                )
                last_error = e

                if attempt < max_retries:
                    logger.info(f"Waiting {current_delay}s before retry...")
                    await asyncio.sleep(current_delay)
                    current_delay *= 2

        # Check if we successfully created a pool
        if not pool:
            executor.shutdown(wait=False)
            error_msg = (
                f"Failed to connect to PostgreSQL at {DB_HOST}:{DB_PORT}/{DB_NAME} "
                f"after {max_retries} attempts. Last error: {last_error}"
            )
            logger.error(error_msg)
            raise ConnectionError(error_msg) from last_error

        # Check connection and create tables if they don't exist
        try:
            logger.info("Verifying connection and creating tables...")
            async with pool.acquire() as conn:
                await cls._create_tables(conn)
            logger.info("Database initialization completed successfully")
        except Exception as e:
            logger.error(f"Failed during initial table creation: {e}", exc_info=True)
            try:
                await pool.close()
            except Exception:
                pass
            executor.shutdown(wait=False)
            raise ConnectionError(f"Failed initial table creation: {e}") from e

        slf = cls(pool, loop, executor)
        return slf

    async def close(self) -> None:
        """Close the connection pool and shutdown the executor safely."""
        if self._closed:
            return
        self._closed = True
        try:
            if self.pool:
                await self.pool.close()
        finally:
            try:
                if self._executor:
                    self._executor.shutdown(wait=False)
            except Exception:
                pass

    @staticmethod
    async def _create_tables(conn: asyncpg.Connection):
        """Create necessary tables if they don't exist."""

        # STEP 1: Create independent tables first (no foreign key dependencies)

        # Create users table first (referenced by other tables)
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT,
                api_key_hash TEXT,
                is_active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                email TEXT
            );
        """
        )

        # Create roles table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS roles (
                id SERIAL PRIMARY KEY,
                name TEXT UNIQUE NOT NULL,
                description TEXT
            );
        """
        )

        # Create permissions table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS permissions (
                id SERIAL PRIMARY KEY,
                name TEXT UNIQUE NOT NULL,
                description TEXT
            );
        """
        )

        # Create tools table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_tools (
                id SERIAL PRIMARY KEY,
                tool_id UUID NOT NULL UNIQUE,
                name TEXT NOT NULL UNIQUE,
                description TEXT NOT NULL,
                code TEXT NOT NULL,
                is_multi_file BOOLEAN NOT NULL DEFAULT FALSE,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                updated_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
        )

        # STEP 2: Create tables with foreign key dependencies

        # Create tool versions table (depends on mcp_tools and users)
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_tool_versions (
                id SERIAL PRIMARY KEY,
                tool_id UUID NOT NULL REFERENCES mcp_tools(tool_id) ON DELETE CASCADE,
                version_number INTEGER NOT NULL,
                code TEXT NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                created_by INTEGER REFERENCES users(id),
                description TEXT,
                UNIQUE(tool_id, version_number)
            );
        """
        )

        # Create multi-file tools auxiliary table (depends on mcp_tools)
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_tool_files (
                id SERIAL PRIMARY KEY,
                tool_id UUID NOT NULL REFERENCES mcp_tools(tool_id) ON DELETE CASCADE,
                filename TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                updated_at TIMESTAMP WITH TIME ZONE NOT NULL,
                UNIQUE(tool_id, filename)
            );
        """
        )

        # Ensure email column exists on users for older DB versions
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT;")

        # Create role_permissions junction table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS role_permissions (
                role_id INTEGER REFERENCES roles(id) ON DELETE CASCADE,
                permission_id INTEGER REFERENCES permissions(id) ON DELETE CASCADE,
                PRIMARY KEY (role_id, permission_id)
            );
        """
        )

        # Create user_roles junction table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_roles (
                user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
                role_id INTEGER REFERENCES roles(id) ON DELETE CASCADE,
                PRIMARY KEY (user_id, role_id)
            );
        """
        )

        # Create audit_logs table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS audit_logs (
                id SERIAL PRIMARY KEY,
                timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
                actor_id INTEGER REFERENCES users(id),
                actor_type TEXT NOT NULL, -- 'human', 'ai_agent', 'system'
                action_type TEXT NOT NULL, -- 'create', 'read', 'update', 'delete', 'execute'
                resource_type TEXT NOT NULL, -- 'tool', 'user', 'role', etc.
                resource_id TEXT, -- The ID of the affected resource
                status TEXT NOT NULL, -- 'success', 'failure'
                details JSONB, -- Additional context for the action
                request_id TEXT, -- For tracing requests across components
                ip_address TEXT
            );
        """
        )

        # Create OAuth tables
        # OAuth clients table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS oauth_clients (
                id SERIAL PRIMARY KEY,
                client_id TEXT UNIQUE NOT NULL,
                client_secret TEXT NOT NULL,
                client_name TEXT NOT NULL,
                redirect_uris JSONB NOT NULL,
                client_uri TEXT,
                logo_uri TEXT,
                scope TEXT,
                contacts JSONB,
                client_id_issued_at BIGINT NOT NULL,
                client_secret_expires_at BIGINT NOT NULL
            );
        """
        )

        # OAuth authorization codes table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS oauth_auth_codes (
                id SERIAL PRIMARY KEY,
                code TEXT UNIQUE NOT NULL,
                client_id TEXT NOT NULL,
                user_id INTEGER REFERENCES users(id),
                scope TEXT,
                code_challenge TEXT NOT NULL,
                code_challenge_method TEXT NOT NULL,
                redirect_uri TEXT NOT NULL,
                expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
        )

        # OAuth access tokens table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS oauth_access_tokens (
                id SERIAL PRIMARY KEY,
                token TEXT UNIQUE NOT NULL,
                client_id TEXT NOT NULL,
                user_id INTEGER REFERENCES users(id),
                scope TEXT,
                expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
        )

        # OAuth refresh tokens table
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS oauth_refresh_tokens (
                id SERIAL PRIMARY KEY,
                token TEXT UNIQUE NOT NULL,
                client_id TEXT NOT NULL,
                user_id INTEGER REFERENCES users(id),
                scope TEXT,
                access_token_id INTEGER REFERENCES oauth_access_tokens(id) ON DELETE CASCADE,
                expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
        )

        # Create indexes for efficient querying
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS audit_logs_timestamp_idx ON audit_logs(timestamp);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS audit_logs_actor_id_idx ON audit_logs(actor_id);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS audit_logs_resource_type_resource_id_idx ON audit_logs(resource_type, resource_id);"
        )

        # Create indexes for OAuth tables
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_clients_client_id_idx ON oauth_clients(client_id);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_auth_codes_code_idx ON oauth_auth_codes(code);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_auth_codes_expires_at_idx ON oauth_auth_codes(expires_at);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_access_tokens_token_idx ON oauth_access_tokens(token);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_access_tokens_expires_at_idx ON oauth_access_tokens(expires_at);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_refresh_tokens_token_idx ON oauth_refresh_tokens(token);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS oauth_refresh_tokens_expires_at_idx ON oauth_refresh_tokens(expires_at);"
        )

        # Add email index if not already present from previous runs
        await conn.execute("CREATE INDEX IF NOT EXISTS users_email_idx ON users(email);")

        # Registration tokens (used by routers/devices.py for device onboarding).
        # Folded in from migrate_registration_tokens.py so a fresh install
        # gets a working device-register endpoint without a manual migration.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS registration_tokens (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                token VARCHAR(255) UNIQUE NOT NULL,
                description TEXT,
                max_uses INTEGER,
                current_uses INTEGER DEFAULT 0,
                expires_at TIMESTAMPTZ,
                created_by VARCHAR(255),
                created_at TIMESTAMPTZ DEFAULT NOW(),
                last_used_at TIMESTAMPTZ,
                CONSTRAINT check_token_uses CHECK (
                    current_uses >= 0
                    AND (current_uses <= max_uses OR max_uses IS NULL)
                ),
                CONSTRAINT check_max_uses CHECK (max_uses IS NULL OR max_uses > 0)
            );
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_registration_tokens_token ON registration_tokens(token);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_registration_tokens_expires_at ON registration_tokens(expires_at);"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_registration_tokens_created_by ON registration_tokens(created_by);"
        )

        logger.info("Database tables created successfully")

    @classmethod
    async def _ensure_database_exists(cls, max_retries: int = 3) -> None:
        """
        Ensure the target database exists by connecting to an admin database (defaults to 'postgres')
        and creating the desired database if it is missing. This allows the application to self-heal
        when run against a fresh PostgreSQL instance.

        Args:
            max_retries: Maximum number of connection attempts to admin database (default: 3)

        Raises:
            ValueError: If database name contains invalid characters
            ConnectionError: If unable to connect to admin database after retries
        """
        # Validate database name to prevent SQL injection
        if not re.fullmatch(r"[A-Za-z0-9_]+", DB_NAME):
            raise ValueError(
                f"Database name '{DB_NAME}' contains invalid characters; only alphanumeric and underscore are supported."
            )

        admin_dsn = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_ADMIN_DB}"
        logger.info(
            f"Ensuring PostgreSQL database '{DB_NAME}' exists using admin database '{DB_ADMIN_DB}' "
            f"at {DB_HOST}:{DB_PORT}"
        )

        conn: Optional[asyncpg.Connection] = None
        last_error = None

        for attempt in range(1, max_retries + 1):
            try:
                logger.info(f"Connecting to admin database (attempt {attempt}/{max_retries})...")
                conn = await asyncpg.connect(dsn=admin_dsn, timeout=30)
                logger.info(f"Successfully connected to admin database '{DB_ADMIN_DB}'")

                # Check if target database exists
                exists = await conn.fetchval(
                    "SELECT 1 FROM pg_database WHERE datname = $1",
                    DB_NAME,
                )

                if exists:
                    logger.info(f"Database '{DB_NAME}' already exists")
                    return

                # Database doesn't exist, create it
                logger.info(f"Database '{DB_NAME}' not found; creating it now...")
                try:
                    # Cannot use parameterized query for CREATE DATABASE
                    await conn.execute(f"CREATE DATABASE {DB_NAME}")
                    logger.info(f"Database '{DB_NAME}' created successfully")
                    return

                except DuplicateDatabaseError:
                    logger.info(f"Database '{DB_NAME}' was created concurrently by another process")
                    return

                except Exception as create_err:
                    logger.error(
                        f"Error creating database '{DB_NAME}': {create_err}",
                        exc_info=True,
                    )
                    raise

            except (OSError, ConnectionRefusedError, asyncio.TimeoutError) as e:
                logger.warning(
                    f"Failed to connect to admin database (attempt {attempt}/{max_retries}): {type(e).__name__}: {e}"
                )
                last_error = e

                if attempt < max_retries:
                    retry_delay = attempt * 2  # Progressive backoff
                    logger.info(f"Waiting {retry_delay}s before retry...")
                    await asyncio.sleep(retry_delay)

            except Exception as e:
                logger.error(f"Unexpected error ensuring database exists: {e}", exc_info=True)
                raise

            finally:
                if conn:
                    try:
                        await conn.close()
                        conn = None
                    except Exception:
                        pass

        # If we got here, all retries failed
        error_msg = (
            f"Failed to connect to admin database '{DB_ADMIN_DB}' at {DB_HOST}:{DB_PORT} "
            f"after {max_retries} attempts. Cannot ensure database '{DB_NAME}' exists. "
            f"Last error: {last_error}"
        )
        logger.error(error_msg)
        raise ConnectionError(error_msg) from last_error

    async def add_tool(
        self,
        name: str,
        description: str,
        code: str,
        created_by: Optional[int] = None,
        replace_existing: bool = False,
    ) -> str:
        """Add a new single-file tool definition to the database or replace if specified."""
        now = self._get_timestamp()
        tool_uuid = uuid7()
        tool_uuid_str = str(tool_uuid)

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Check if exists
                existing = await conn.fetchrow(
                    """
                    SELECT tool_id FROM mcp_tools WHERE name = $1
                """,
                    name,
                )

                if existing and not replace_existing:
                    raise ValueError(f"Tool with name '{name}' already exists.")

                if existing and replace_existing:
                    # Delete existing versions and files associated with the old UUID before replacing
                    old_tool_uuid = existing["tool_id"]
                    logger.warning(
                        f"Replacing existing tool '{name}' (UUID: {old_tool_uuid}). Associated versions and files will be deleted."
                    )
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_versions WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_files WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )
                    # Delete the main tool entry
                    await conn.execute(
                        """
                        DELETE FROM mcp_tools WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )

                # Insert new tool
                await conn.execute(
                    """
                    INSERT INTO mcp_tools (tool_id, name, description, code, is_multi_file, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, FALSE, $5, $6)
                """,
                    tool_uuid,
                    name,
                    description,
                    code,
                    now,
                    now,
                )

                # Add the first version automatically
                await conn.execute(
                    """
                    INSERT INTO mcp_tool_versions (tool_id, version_number, code, created_at, created_by, description)
                    VALUES ($1, 1, $2, $3, $4, $5)
                """,
                    tool_uuid,
                    code,
                    now,
                    created_by,
                    description,
                )

        logger.info(f"Created tool {tool_uuid_str} with name: {name}")
        return tool_uuid_str

    async def add_multi_file_tool(
        self,
        name: str,
        description: str,
        entrypoint: str,
        files: Dict[str, str],
        created_by: Optional[int] = None,
        tool_dir_uuid: Optional[str] = None,
        replace_existing: bool = False,
    ) -> str:
        """Add a new multi-file tool definition to the database or replace if specified."""
        now = self._get_timestamp()
        tool_uuid = UUID(tool_dir_uuid) if tool_dir_uuid else uuid7()
        tool_uuid_str = str(tool_uuid)

        if not entrypoint or entrypoint not in files:
            raise ValueError("Entrypoint file must be present in the files dictionary")

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Check if exists
                existing = await conn.fetchrow(
                    """
                    SELECT tool_id FROM mcp_tools WHERE name = $1
                """,
                    name,
                )

                if existing and not replace_existing:
                    raise ValueError(f"Tool with name '{name}' already exists.")

                if existing and replace_existing:
                    old_tool_uuid = existing["tool_id"]
                    logger.warning(
                        f"Replacing existing multi-file tool '{name}' (UUID: {old_tool_uuid}). Associated versions and files will be deleted."
                    )
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_versions WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_files WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )
                    await conn.execute(
                        """
                        DELETE FROM mcp_tools WHERE tool_id = $1
                    """,
                        old_tool_uuid,
                    )

                # Insert main tool entry (code field stores entrypoint filename)
                await conn.execute(
                    """
                    INSERT INTO mcp_tools (tool_id, name, description, code, is_multi_file, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, TRUE, $5, $6)
                """,
                    tool_uuid,
                    name,
                    description,
                    entrypoint,
                    now,
                    now,
                )

                # Insert files
                for filename, content in files.items():
                    await conn.execute(
                        """
                        INSERT INTO mcp_tool_files (tool_id, filename, content, created_at, updated_at)
                        VALUES ($1, $2, $3, $4, $5)
                    """,
                        tool_uuid,
                        filename,
                        content,
                        now,
                        now,
                    )

                # Add the first version automatically (points to the initial set of files)
                await conn.execute(
                    """
                    INSERT INTO mcp_tool_versions (tool_id, version_number, code, created_at, created_by, description)
                    VALUES ($1, 1, $2, $3, $4, $5)
                """,
                    tool_uuid,
                    entrypoint,
                    now,
                    created_by,
                    description,
                )

        logger.info(f"Created multi-file tool {tool_uuid_str} with name: {name}")
        return tool_uuid_str

    async def update_tool(self, name: str, description: str, code: str) -> bool:
        """Update an existing single-file tool in the database."""
        now = self._get_timestamp()

        async with self.pool.acquire() as conn:
            # First get the current tool details
            tool = await conn.fetchrow(
                """
                SELECT * FROM mcp_tools
                WHERE name = $1 AND is_multi_file = FALSE
            """,
                name,
            )

            if not tool:
                logger.warning(f"Tool {name} not found or is multi-file, cannot update")
                return False

            tool_id = tool["tool_id"]

            # Get current version count
            version_count = await conn.fetchval(
                """
                SELECT COUNT(*) FROM mcp_tool_versions
                WHERE tool_id = $1
            """,
                tool_id,
            )

            next_version = version_count + 1

            async with conn.transaction():
                # Update the main tool record
                await conn.execute(
                    """
                    UPDATE mcp_tools
                    SET description = $1, code = $2, updated_at = $3
                    WHERE tool_id = $4
                """,
                    description,
                    code,
                    now,
                    tool_id,
                )

                # Insert new version
                await conn.execute(
                    """
                    INSERT INTO mcp_tool_versions
                    (tool_id, version_number, code, created_at)
                    VALUES ($1, $2, $3, $4)
                """,
                    tool_id,
                    next_version,
                    code,
                    now,
                )

                # If we have more than 3 versions, delete the oldest
                if next_version > 3:
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_versions
                        WHERE tool_id = $1 AND version_number = $2
                    """,
                        tool_id,
                        next_version - 3,
                    )

        logger.info(f"Updated tool: {name}")
        return True

    async def update_multi_file_tool(
        self, name: str, description: str, entrypoint: str, files: Dict[str, str]
    ) -> bool:
        """Update an existing multi-file tool in the database."""
        now = self._get_timestamp()

        async with self.pool.acquire() as conn:
            # First get the current tool details
            tool = await conn.fetchrow(
                """
                SELECT * FROM mcp_tools
                WHERE name = $1 AND is_multi_file = TRUE
            """,
                name,
            )

            if not tool:
                logger.warning(f"Multi-file tool {name} not found")
                return False

            tool_id = tool["tool_id"]

            # Get current version count
            version_count = await conn.fetchval(
                """
                SELECT COUNT(*) FROM mcp_tool_versions
                WHERE tool_id = $1
            """,
                tool_id,
            )

            next_version = version_count + 1

            async with conn.transaction():
                # Update the main tool record
                await conn.execute(
                    """
                    UPDATE mcp_tools
                    SET description = $1, code = $2, updated_at = $3
                    WHERE tool_id = $4
                """,
                    description,
                    entrypoint,
                    now,
                    tool_id,
                )

                # Insert new version
                await conn.execute(
                    """
                    INSERT INTO mcp_tool_versions
                    (tool_id, version_number, code, created_at)
                    VALUES ($1, $2, $3, $4)
                """,
                    tool_id,
                    next_version,
                    entrypoint,
                    now,
                )

                # If we have more than 3 versions, delete the oldest
                if next_version > 3:
                    await conn.execute(
                        """
                        DELETE FROM mcp_tool_versions
                        WHERE tool_id = $1 AND version_number = $2
                    """,
                        tool_id,
                        next_version - 3,
                    )

                # Delete existing files
                await conn.execute(
                    """
                    DELETE FROM mcp_tool_files
                    WHERE tool_id = $1
                """,
                    tool_id,
                )

                # Insert each new file
                for filename, content in files.items():
                    await conn.execute(
                        """
                        INSERT INTO mcp_tool_files
                        (tool_id, filename, content, created_at, updated_at)
                        VALUES ($1, $2, $3, $4, $5)
                    """,
                        tool_id,
                        filename,
                        content,
                        now,
                        now,
                    )

        logger.info(f"Updated multi-file tool {name}")
        return True

    async def delete_tool(self, name: str) -> bool:
        """Delete a tool from the database."""
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # First get the tool_id
                tool_id = await conn.fetchval(
                    """
                    SELECT tool_id FROM mcp_tools
                    WHERE name = $1
                """,
                    name,
                )

                if not tool_id:
                    logger.warning(f"Tool {name} not found, cannot delete")
                    return False

                # The ON DELETE CASCADE will handle deleting related records in mcp_tool_files and mcp_tool_versions
                await conn.execute(
                    """
                    DELETE FROM mcp_tools
                    WHERE tool_id = $1
                """,
                    tool_id,
                )

        logger.info(f"Deleted tool: {name}")
        return True

    async def get_tool_by_name(self, name: str) -> Optional[Dict[str, Any]]:
        """Get a tool by its name."""
        async with self.pool.acquire() as conn:
            # Get tool record
            record = await conn.fetchrow(
                """
                SELECT * FROM mcp_tools
                WHERE name = $1
            """,
                name,
            )

            if not record:
                return None

            # Convert to dict
            tool_dict = dict(record)

            # If it's a multi-file tool, get its files
            if tool_dict.get("is_multi_file"):
                tool_dict["files"] = await self.get_tool_files(tool_dict["tool_id"])

            return tool_dict

    async def get_tool_files(self, tool_id: str) -> Dict[str, str]:
        """Get all files for a multi-file tool."""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT filename, content FROM mcp_tool_files
                WHERE tool_id = $1
            """,
                tool_id,
            )

            return {row["filename"]: row["content"] for row in rows}

    async def get_all_tools(self) -> List[Dict[str, Any]]:
        """Get all tools from the database."""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT * FROM mcp_tools
                ORDER BY name
            """
            )

            # Convert to list of dicts
            tools = [dict(row) for row in rows]

            # For each multi-file tool, get its files
            for tool in tools:
                if tool.get("is_multi_file"):
                    tool["files"] = await self.get_tool_files(tool["tool_id"])

            return tools

    async def get_tool_versions(self, tool_id: Union[str, UUID]) -> List[Dict[str, Any]]:
        """Get all versions for a specific tool."""
        tool_uuid_obj = UUID(tool_id) if isinstance(tool_id, str) else tool_id
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT * FROM mcp_tool_versions WHERE tool_id = $1 ORDER BY version_number DESC
            """,
                tool_uuid_obj,
            )
        return [dict(row) for row in rows]

    async def add_tool_version(
        self,
        tool_id: Union[int, UUID],  # Accept SERIAL ID or UUID
        code: str,
        created_by: Optional[int] = None,  # Add creator ID
        description: Optional[str] = None,  # Allow storing description with version
    ) -> Dict[str, Any]:
        """Add a new version for a single-file tool."""
        now = self._get_timestamp()
        tool_uuid = None

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Find the tool UUID if given the SERIAL ID
                if isinstance(tool_id, int):
                    tool_record = await conn.fetchrow(
                        """
                        SELECT tool_id FROM mcp_tools WHERE id = $1
                    """,
                        tool_id,
                    )
                    if not tool_record:
                        raise ValueError(f"Tool with internal ID {tool_id} not found.")
                    tool_uuid = tool_record["tool_id"]
                elif isinstance(tool_id, UUID):
                    tool_uuid = tool_id
                    # Verify UUID exists
                    tool_record = await conn.fetchrow(
                        """
                        SELECT id FROM mcp_tools WHERE tool_id = $1
                    """,
                        tool_uuid,
                    )
                    if not tool_record:
                        raise ValueError(f"Tool with UUID {tool_id} not found.")
                else:
                    raise TypeError("tool_id must be an int (serial ID) or UUID")

                # Check if it's a multi-file tool (versioning handled differently)
                is_multi = await conn.fetchval(
                    """
                    SELECT is_multi_file FROM mcp_tools WHERE tool_id = $1
                """,
                    tool_uuid,
                )
                if is_multi:
                    raise ValueError(
                        "Versioning via add_tool_version is only supported for single-file tools."
                    )

                # Get the next version number
                max_version = await conn.fetchval(
                    """
                    SELECT MAX(version_number) FROM mcp_tool_versions WHERE tool_id = $1
                """,
                    tool_uuid,
                )
                next_version = (max_version or 0) + 1

                # Insert the new version
                await conn.execute(
                    """
                    INSERT INTO mcp_tool_versions (tool_id, version_number, code, created_at, created_by, description)
                    VALUES ($1, $2, $3, $4, $5, $6)
                """,
                    tool_uuid,
                    next_version,
                    code,
                    now,
                    created_by,
                    description,
                )

                # Update the main tool record's code and updated_at timestamp
                await conn.execute(
                    """
                    UPDATE mcp_tools SET code = $1, updated_at = $2 WHERE tool_id = $3
                """,
                    code,
                    now,
                    tool_uuid,
                )

        return {
            "tool_id": str(tool_uuid),
            "version_number": next_version,
            "created_at": now,
            "created_by": created_by,
            "description": description,
        }

    async def restore_tool_version(self, tool_id: Union[str, UUID], version_number: int) -> bool:
        """Restore a specific version of a single-file tool."""
        now = self._get_timestamp()
        tool_uuid_obj = UUID(tool_id) if isinstance(tool_id, str) else tool_id

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Check if it's a multi-file tool
                is_multi = await conn.fetchval(
                    """
                    SELECT is_multi_file FROM mcp_tools WHERE tool_id = $1
                """,
                    tool_uuid_obj,
                )
                if is_multi:
                    raise ValueError("Restoring versions is only supported for single-file tools.")

                # Get the code from the specified version
                version_data = await conn.fetchrow(
                    """
                    SELECT code FROM mcp_tool_versions WHERE tool_id = $1 AND version_number = $2
                """,
                    tool_uuid_obj,
                    version_number,
                )

                if not version_data:
                    raise ValueError(f"Version {version_number} not found for tool {tool_id}")

                restored_code = version_data["code"]

                # Update the main tool record
                result = await conn.execute(
                    """
                    UPDATE mcp_tools SET code = $1, updated_at = $2 WHERE tool_id = $3
                """,
                    restored_code,
                    now,
                    tool_uuid_obj,
                )

                return result == "UPDATE 1"

    async def log_audit_event(
        self,
        actor_id: Optional[int],
        actor_type: str,
        action_type: str,
        resource_type: str,
        resource_id: Optional[str],
        status: str,
        details: Dict[str, Any] = None,
        request_id: Optional[str] = None,
        ip_address: Optional[str] = None,
    ) -> int:
        """Log an audit event to the database."""
        now = self._get_timestamp()

        async with self.pool.acquire() as conn:
            log_id = await conn.fetchval(
                """
                INSERT INTO audit_logs
                (timestamp, actor_id, actor_type, action_type, resource_type, resource_id, status, details, request_id, ip_address)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                RETURNING id
            """,
                now,
                actor_id,
                actor_type,
                action_type,
                resource_type,
                resource_id,
                status,
                json.dumps(details) if details else None,
                request_id,
                ip_address,
            )

        logger.info(f"Logged audit event: {action_type} {resource_type} by {actor_type} {actor_id}")
        return log_id

    async def get_audit_logs(
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
        """Get audit logs with optional filtering."""
        query_parts = ["SELECT * FROM audit_logs WHERE 1=1"]
        params = []
        param_index = 1

        if start_time:
            query_parts.append(f"AND timestamp >= ${param_index}")
            params.append(start_time)
            param_index += 1

        if end_time:
            query_parts.append(f"AND timestamp <= ${param_index}")
            params.append(end_time)
            param_index += 1

        if actor_id:
            query_parts.append(f"AND actor_id = ${param_index}")
            params.append(actor_id)
            param_index += 1

        if actor_type:
            query_parts.append(f"AND actor_type = ${param_index}")
            params.append(actor_type)
            param_index += 1

        if action_type:
            query_parts.append(f"AND action_type = ${param_index}")
            params.append(action_type)
            param_index += 1

        if resource_type:
            query_parts.append(f"AND resource_type = ${param_index}")
            params.append(resource_type)
            param_index += 1

        if resource_id:
            query_parts.append(f"AND resource_id = ${param_index}")
            params.append(resource_id)
            param_index += 1

        if status:
            query_parts.append(f"AND status = ${param_index}")
            params.append(status)
            param_index += 1

        query_parts.append("ORDER BY timestamp DESC")
        query_parts.append(f"LIMIT ${param_index}")
        params.append(limit)
        param_index += 1

        query_parts.append(f"OFFSET ${param_index}")
        params.append(offset)

        query = " ".join(query_parts)

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, *params)

            # Convert to list of dicts and parse JSONB details
            result = []
            for row in rows:
                log_entry = dict(row)
                if log_entry.get("details"):
                    log_entry["details"] = json.loads(log_entry["details"])
                result.append(log_entry)

            return result

    # --- Authentication and Authorization Methods ---

    async def create_user(
        self,
        username: str,
        password_hash: Optional[str] = None,
        api_key_hash: Optional[str] = None,
        email: Optional[str] = None,
    ) -> int:
        """Create a new user."""
        now = self._get_timestamp()
        try:
            async with self.pool.acquire() as conn:
                user_id = await conn.fetchval(
                    """
                    INSERT INTO users (username, password_hash, api_key_hash, created_at, email)
                    VALUES ($1, $2, $3, $4, $5)
                    RETURNING id
                """,
                    username,
                    password_hash,
                    api_key_hash,
                    now,
                    email,
                )
            return user_id
        except asyncpg.exceptions.UniqueViolationError:
            raise ValueError(f"Username '{username}' already exists.")

    async def get_user_by_username(self, username: str) -> Optional[Dict[str, Any]]:
        """Get user details by username."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM users WHERE username = $1
            """,
                username,
            )
        return dict(row) if row else None

    async def get_user_by_id(self, user_id: int) -> Optional[Dict[str, Any]]:
        """Get user details by ID."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM users WHERE id = $1
            """,
                user_id,
            )
        return dict(row) if row else None

    async def get_user_by_api_key_hash(self, api_key_hash: str) -> Optional[Dict[str, Any]]:
        """Get user details by API key hash."""
        if not api_key_hash:
            return None
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM users WHERE api_key_hash = $1 AND is_active = TRUE
            """,
                api_key_hash,
            )
        return dict(row) if row else None

    async def get_user_roles(self, user_id: int) -> List[Dict[str, Any]]:
        """Get all roles assigned to a user."""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT r.* FROM roles r
                JOIN user_roles ur ON r.id = ur.role_id
                WHERE ur.user_id = $1
            """,
                user_id,
            )

            return [dict(row) for row in rows]

    async def get_role_permissions(self, role_id: int) -> List[Dict[str, Any]]:
        """Get all permissions assigned to a role."""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT p.* FROM permissions p
                JOIN role_permissions rp ON p.id = rp.permission_id
                WHERE rp.role_id = $1
            """,
                role_id,
            )

            return [dict(row) for row in rows]

    async def assign_role_to_user(self, user_id: int, role_id: int) -> bool:
        """Assign a role to a user."""
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    """
                    INSERT INTO user_roles (user_id, role_id)
                    VALUES ($1, $2)
                    ON CONFLICT (user_id, role_id) DO NOTHING
                """,
                    user_id,
                    role_id,
                )

            logger.info(f"Assigned role {role_id} to user {user_id}")
            return True
        except Exception as e:
            logger.error(f"Failed to assign role {role_id} to user {user_id}: {e}")
            return False

    async def create_role(self, name: str, description: Optional[str] = None) -> int:
        """Create a new role."""
        async with self.pool.acquire() as conn:
            role_id = await conn.fetchval(
                """
                INSERT INTO roles (name, description)
                VALUES ($1, $2)
                RETURNING id
            """,
                name,
                description,
            )

        logger.info(f"Created role: {name}")
        return role_id

    async def create_permission(self, name: str, description: Optional[str] = None) -> int:
        """Create a new permission."""
        async with self.pool.acquire() as conn:
            permission_id = await conn.fetchval(
                """
                INSERT INTO permissions (name, description)
                VALUES ($1, $2)
                RETURNING id
            """,
                name,
                description,
            )

        logger.info(f"Created permission: {name}")
        return permission_id

    async def assign_permission_to_role(self, role_id: int, permission_id: int) -> bool:
        """Assign a permission to a role."""
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    """
                    INSERT INTO role_permissions (role_id, permission_id)
                    VALUES ($1, $2)
                    ON CONFLICT (role_id, permission_id) DO NOTHING
                """,
                    role_id,
                    permission_id,
                )

            logger.info(f"Assigned permission {permission_id} to role {role_id}")
            return True
        except Exception as e:
            logger.error(f"Failed to assign permission {permission_id} to role {role_id}: {e}")
            return False

    async def update_user_roles(self, user_id: int, role_names: List[str]) -> bool:
        """Update the roles assigned to a user."""
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # 1. Get role IDs for the given names
                placeholders = ", ".join([f"${i + 1}" for i in range(len(role_names))])
                roles = await conn.fetch(
                    f"""
                    SELECT id, name FROM roles WHERE name IN ({placeholders})
                """,
                    *role_names,
                )
                role_map = {r["name"]: r["id"] for r in roles}

                # Check if all requested roles exist
                if len(role_map) != len(role_names):
                    missing = set(role_names) - set(role_map.keys())
                    raise ValueError(f"The following roles do not exist: {', '.join(missing)}")

                role_ids = list(role_map.values())

                # 2. Delete existing roles for the user
                await conn.execute(
                    """
                    DELETE FROM user_roles WHERE user_id = $1
                """,
                    user_id,
                )

                # 3. Insert new roles for the user
                if role_ids:
                    values_to_insert = [(user_id, role_id) for role_id in role_ids]
                    await conn.copy_records_to_table(
                        "user_roles",
                        records=values_to_insert,
                        columns=["user_id", "role_id"],
                    )
                logger.info(f"Updated roles for user {user_id} to: {role_names}")
                return True

    async def set_user_active_status(self, user_id: int, is_active: bool) -> bool:
        """Set the active status for a user."""
        async with self.pool.acquire() as conn:
            result = await conn.execute(
                """
                UPDATE users SET is_active = $1 WHERE id = $2
            """,
                is_active,
                user_id,
            )
        updated = result == "UPDATE 1"
        if updated:
            logger.info(f"Set active status for user {user_id} to: {is_active}")
        else:
            logger.warning(f"User {user_id} not found when trying to set active status.")
        return updated

    def _get_timestamp(self) -> datetime:
        """Return the current timestamp in UTC."""
        return utcnow()

    async def get_all_tools_for_backup(self, include_versions: bool = True) -> List[Dict[str, Any]]:
        """
        Get all tools with their details, optionally including all versions.

        Args:
            include_versions: If True, include all versions for each tool

        Returns:
            List of dictionaries containing tool details
        """
        try:
            async with self.pool.acquire() as conn:
                # First get all tools
                tools_query = """
                SELECT t.id, t.tool_id, t.name, t.description, t.is_multi_file,
                       t.created_at, t.created_by, t.code,
                       u.username as creator_username
                FROM mcp_tools t
                LEFT JOIN users u ON t.created_by = u.id
                ORDER BY t.name
                """

                tools_rows = await conn.fetch(tools_query)

                # Prepare the result list
                result = []

                # Process each tool
                for tool in tools_rows:
                    tool_dict = dict(tool)

                    # Convert tool_id (UUID) to string for JSON serialization
                    if "tool_id" in tool_dict:
                        tool_dict["tool_id"] = str(tool_dict["tool_id"])

                    # Convert datetimes to ISO format for JSON serialization
                    if "created_at" in tool_dict and tool_dict["created_at"]:
                        tool_dict["created_at"] = tool_dict["created_at"].isoformat()

                    # Handle multi-file tools
                    if tool_dict.get("is_multi_file"):
                        # For multi-file tools, get all the files
                        files_query = """
                        SELECT filename, content
                        FROM mcp_tool_files
                        WHERE tool_id = $1
                        """
                        files_rows = await conn.fetch(files_query, tool_dict["id"])

                        files_dict = {}
                        for file_row in files_rows:
                            files_dict[file_row["filename"]] = file_row["content"]

                        tool_dict["files"] = files_dict
                        # For multi-file tools, 'code' is actually the entrypoint file name

                    # Add versions if requested
                    if include_versions and not tool_dict.get("is_multi_file"):
                        versions_query = """
                        SELECT v.id, v.version_number, v.description, v.code, v.created_at, v.created_by,
                               v.is_current, u.username as creator_username
                        FROM mcp_tool_versions v
                        LEFT JOIN users u ON v.created_by = u.id
                        WHERE v.tool_id = $1 AND v.is_current = false
                        ORDER BY v.version_number DESC
                        """

                        versions_rows = await conn.fetch(versions_query, tool_dict["id"])

                        versions_list = []
                        for version in versions_rows:
                            version_dict = dict(version)

                            # Convert datetimes for JSON serialization
                            if "created_at" in version_dict and version_dict["created_at"]:
                                version_dict["created_at"] = version_dict["created_at"].isoformat()

                            versions_list.append(version_dict)

                        tool_dict["versions"] = versions_list

                    # Add the processed tool to the result
                    result.append(tool_dict)

                return result

        except Exception as e:
            self.logger.error(f"Error getting all tools for backup: {e}", exc_info=True)
            raise

    @classmethod
    def __get_pydantic_json_schema__(cls, _core_schema, handler):
        """
        Custom JSON schema generator to prevent schema generation errors.
        This provides a simple schema for the MCPPostgresDB type when used in FastAPI endpoints.
        """
        return {
            "type": "object",
            "title": "MCPPostgresDB",
            "description": "PostgreSQL database connection",
        }

    # --- OAuth Methods ---

    async def get_oauth_client(self, client_id: str) -> Optional[Dict[str, Any]]:
        """Get an OAuth client by client_id."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM oauth_clients WHERE client_id = $1
            """,
                client_id,
            )

            if row:
                client = dict(row)
                # Convert JSONB to Python objects
                client["redirect_uris"] = client.get("redirect_uris", [])
                client["contacts"] = client.get("contacts", [])
                return client
            return None

    async def save_oauth_client(self, client: Dict[str, Any]) -> bool:
        """Save a new OAuth client."""
        async with self.pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO oauth_clients (
                    client_id, client_secret, client_name, redirect_uris,
                    client_uri, logo_uri, scope, contacts,
                    client_id_issued_at, client_secret_expires_at
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            """,
                client["client_id"],
                client["client_secret"],
                client["client_name"],
                json.dumps(client["redirect_uris"]),
                client.get("client_uri"),
                client.get("logo_uri"),
                client.get("scope"),
                json.dumps(client.get("contacts", [])),
                client["client_id_issued_at"],
                client["client_secret_expires_at"],
            )
            return True

    async def create_auth_code(
        self,
        client_id: str,
        user_id: int,
        scope: Optional[str],
        code_challenge: str,
        code_challenge_method: str,
        redirect_uri: str,
    ) -> str:
        """Create an authorization code."""
        # Generate a unique code
        code = secrets.token_urlsafe(32)
        now = self._get_timestamp()
        expires_at = now + timedelta(minutes=10)  # Auth codes expire after 10 minutes

        async with self.pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO oauth_auth_codes (
                    code, client_id, user_id, scope, code_challenge,
                    code_challenge_method, redirect_uri, expires_at, created_at
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """,
                code,
                client_id,
                user_id,
                scope,
                code_challenge,
                code_challenge_method,
                redirect_uri,
                expires_at,
                now,
            )

        return code

    async def get_auth_code(self, code: str) -> Optional[Dict[str, Any]]:
        """Get an authorization code."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM oauth_auth_codes WHERE code = $1
            """,
                code,
            )

            if row:
                return dict(row)
            return None

    async def delete_auth_code(self, code: str) -> bool:
        """Delete an authorization code."""
        async with self.pool.acquire() as conn:
            await conn.execute(
                """
                DELETE FROM oauth_auth_codes WHERE code = $1
            """,
                code,
            )
            return True

    async def create_tokens(
        self, client_id: str, user_id: int, scope: Optional[str]
    ) -> Dict[str, str]:
        """Create access and refresh tokens."""
        access_token = secrets.token_urlsafe(32)
        refresh_token = secrets.token_urlsafe(32)
        now = self._get_timestamp()
        access_expires = now + timedelta(hours=1)  # Access tokens expire after 1 hour
        refresh_expires = now + timedelta(days=30)  # Refresh tokens expire after 30 days

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Create access token
                access_token_id = await conn.fetchval(
                    """
                    INSERT INTO oauth_access_tokens (
                        token, client_id, user_id, scope, expires_at, created_at
                    ) VALUES ($1, $2, $3, $4, $5, $6)
                    RETURNING id
                """,
                    access_token,
                    client_id,
                    user_id,
                    scope,
                    access_expires,
                    now,
                )

                # Create refresh token
                await conn.execute(
                    """
                    INSERT INTO oauth_refresh_tokens (
                        token, client_id, user_id, scope, access_token_id, expires_at, created_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7)
                """,
                    refresh_token,
                    client_id,
                    user_id,
                    scope,
                    access_token_id,
                    refresh_expires,
                    now,
                )

        return {"access_token": access_token, "refresh_token": refresh_token}

    async def validate_refresh_token(
        self, refresh_token: str, client_id: str
    ) -> Optional[Dict[str, Any]]:
        """Validate a refresh token and return token data if valid."""
        now = self._get_timestamp()

        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM oauth_refresh_tokens
                WHERE token = $1 AND client_id = $2 AND expires_at > $3
            """,
                refresh_token,
                client_id,
                now,
            )

            if row:
                return dict(row)
            return None

    async def refresh_tokens(self, refresh_token: str, client_id: str) -> Dict[str, str]:
        """Create new tokens from a refresh token."""
        # Get refresh token data
        token_data = await self.validate_refresh_token(refresh_token, client_id)
        if not token_data:
            raise ValueError("Invalid refresh token")

        # Revoke the old tokens
        await self.revoke_refresh_token(refresh_token, client_id)

        # Create new tokens
        return await self.create_tokens(
            client_id=client_id,
            user_id=token_data["user_id"],
            scope=token_data["scope"],
        )

    async def validate_client_credentials(
        self, client_id: str, client_secret: str
    ) -> Optional[Dict[str, Any]]:
        """Validate client credentials."""
        logger.info(f"Validating credentials for client_id: {client_id}")

        async with self.pool.acquire() as conn:
            # First, check if the client exists
            client_exists = await conn.fetchval(
                """
                SELECT COUNT(*) FROM oauth_clients
                WHERE client_id = $1
            """,
                client_id,
            )

            if client_exists == 0:
                logger.warning(f"Client with ID '{client_id}' not found")
                return None

            # Then check credentials
            row = await conn.fetchrow(
                """
                SELECT * FROM oauth_clients
                WHERE client_id = $1 AND client_secret = $2
            """,
                client_id,
                client_secret,
            )

            if row:
                client = dict(row)
                # Convert JSONB to Python objects
                client["redirect_uris"] = client.get("redirect_uris", [])
                client["contacts"] = client.get("contacts", [])
                logger.info(f"Client credentials validated successfully for '{client_id}'")
                return client
            else:
                logger.warning(f"Invalid secret for client '{client_id}'")
                return None

    async def create_client_credentials_token(
        self, client_id: str, scope: Optional[str]
    ) -> Dict[str, str]:
        """Create an access token for client credentials flow (no refresh token)."""
        logger.info(
            f"Creating client credentials token for client '{client_id}' with scope '{scope}'"
        )

        access_token = secrets.token_urlsafe(32)
        now = self._get_timestamp()
        access_expires = now + timedelta(hours=1)  # Access tokens expire after 1 hour

        # If scope is None, get client's registered scope from the database
        if scope is None:
            try:
                client = await self.get_oauth_client(client_id)
                if client and client.get("scope"):
                    scope = client.get("scope")
                    logger.info(f"Using client's registered scope from database: '{scope}'")
            except Exception as e:
                logger.error(f"Error retrieving client scope: {e}")

        async with self.pool.acquire() as conn:
            try:
                await conn.execute(
                    """
                    INSERT INTO oauth_access_tokens (
                        token, client_id, user_id, scope, expires_at, created_at
                    ) VALUES ($1, $2, $3, $4, $5, $6)
                """,
                    access_token,
                    client_id,
                    None,
                    scope,
                    access_expires,
                    now,
                )
                logger.debug(
                    f"Created token {access_token[:15]}... for client '{client_id}' with scope: '{scope}'"
                )
            except Exception as e:
                logger.error(f"Error creating token: {e}")
                raise

        return {"access_token": access_token}

    async def revoke_access_token(self, token: str, client_id: Optional[str] = None) -> bool:
        """Revoke an access token."""
        async with self.pool.acquire() as conn:
            if client_id:
                await conn.execute(
                    """
                    DELETE FROM oauth_access_tokens
                    WHERE token = $1 AND client_id = $2
                """,
                    token,
                    client_id,
                )
            else:
                await conn.execute(
                    """
                    DELETE FROM oauth_access_tokens
                    WHERE token = $1
                """,
                    token,
                )

            # Return True if any row was deleted
            return True

    async def revoke_refresh_token(self, token: str, client_id: Optional[str] = None) -> bool:
        """Revoke a refresh token."""
        async with self.pool.acquire() as conn:
            if client_id:
                await conn.execute(
                    """
                    DELETE FROM oauth_refresh_tokens
                    WHERE token = $1 AND client_id = $2
                """,
                    token,
                    client_id,
                )
            else:
                await conn.execute(
                    """
                    DELETE FROM oauth_refresh_tokens
                    WHERE token = $1
                """,
                    token,
                )

            # Return True if any row was deleted
            return True

    async def get_access_token(self, token: str) -> Optional[Dict[str, Any]]:
        """Get access token information."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT * FROM oauth_access_tokens
                WHERE token = $1
            """,
                token,
            )

            if row:
                return dict(row)
            return None

    async def get_token_data(self, token: str) -> Optional[Dict[str, Any]]:
        """Get token data and check if it's valid (not expired).

        This method adds additional validation checks beyond get_access_token.
        """
        token_data = await self.get_access_token(token)

        if not token_data:
            return None

        # Check if token is expired
        now = self._get_timestamp()
        expires_at = token_data.get("expires_at")

        if expires_at:
            # Handle timezone-aware comparison
            try:
                # If expires_at is timezone-aware, convert now to match
                if hasattr(expires_at, "tzinfo") and expires_at.tzinfo is not None:
                    # Use UTC for consistency if comparing with timezone-aware datetimes
                    from datetime import timezone

                    now = datetime.now(timezone.utc)

                if expires_at < now:
                    logger.warning(f"Token expired: {token[:15]}...")
                    return None
            except TypeError as e:
                # Log the error but don't fail - allow the token through if we can't compare properly
                logger.warning(f"Couldn't compare expiry times: {e}")

        return token_data

    async def mark_token_as_used(self, token: str) -> bool:
        """Mark a token as used to prevent reuse."""
        async with self.pool.acquire() as conn:
            # Add a 'used' column if it doesn't exist
            try:
                await conn.execute(
                    """
                    ALTER TABLE oauth_access_tokens
                    ADD COLUMN IF NOT EXISTS used BOOLEAN DEFAULT FALSE
                """
                )

                # Mark the token as used
                await conn.execute(
                    """
                    UPDATE oauth_access_tokens
                    SET used = TRUE
                    WHERE token = $1
                """,
                    token,
                )
                return True
            except Exception as e:
                logger.error(f"Error marking token as used: {e}")
                return False

    async def list_users(self) -> List[Dict[str, Any]]:
        """Fetch all users from the database."""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT id, username, is_active, created_at FROM users ORDER BY username"
            )
            return [dict(row) for row in rows]
