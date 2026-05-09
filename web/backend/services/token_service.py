"""
Token Service for Device Registration
Handles creation, validation, and management of registration tokens
"""

import logging
import secrets
from datetime import timedelta
from typing import Any, Dict, List, Optional

import asyncpg

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class TokenValidationError(Exception):
    """Raised when token validation fails"""

    pass


class TokenService:
    """Service for managing registration tokens"""

    def __init__(self, db_pool: asyncpg.Pool):
        """
        Initialize token service with database connection pool

        Args:
            db_pool: asyncpg connection pool
        """
        self.pool = db_pool

    async def create_token(
        self,
        description: str,
        expires_in_hours: Optional[int] = None,
        max_uses: Optional[int] = None,
        created_by: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Create a new registration token

        Args:
            description: Human-readable description of token purpose
            expires_in_hours: Hours until token expires (None for no expiration)
            max_uses: Maximum number of uses (None for unlimited)
            created_by: Username/ID of token creator

        Returns:
            Dict containing token details (id, token, description, expires_at, etc.)

        Raises:
            Exception: If database operation fails
        """
        # Generate secure random token
        token = secrets.token_urlsafe(32)

        # Calculate expiration time
        expires_at = None
        if expires_in_hours is not None:
            expires_at = utcnow() + timedelta(hours=expires_in_hours)

        async with self.pool.acquire() as conn:
            result = await conn.fetchrow(
                """
                INSERT INTO registration_tokens (
                    token, description, max_uses, expires_at, created_by
                ) VALUES ($1, $2, $3, $4, $5)
                RETURNING id, token, description, max_uses, current_uses,
                          expires_at, created_by, created_at
                """,
                token,
                description,
                max_uses,
                expires_at,
                created_by,
            )

        logger.info(
            f"Created registration token: {description} (expires: {expires_at}, max_uses: {max_uses})"
        )

        return {
            "id": str(result["id"]),
            "token": result["token"],
            "description": result["description"],
            "max_uses": result["max_uses"],
            "current_uses": result["current_uses"],
            "expires_at": result["expires_at"].isoformat() if result["expires_at"] else None,
            "created_by": result["created_by"],
            "created_at": result["created_at"].isoformat(),
        }

    async def validate_token(self, token: str) -> bool:
        """
        Validate registration token and increment usage count

        Args:
            token: Token string to validate

        Returns:
            True if token is valid and usage was recorded

        Raises:
            TokenValidationError: If token is invalid, expired, or exceeded max uses
        """
        if not token or len(token) < 8:
            raise TokenValidationError("Token is too short or empty")

        async with self.pool.acquire() as conn:
            # Fetch token with FOR UPDATE lock to prevent race conditions
            async with conn.transaction():
                result = await conn.fetchrow(
                    """
                    SELECT id, token, max_uses, current_uses, expires_at
                    FROM registration_tokens
                    WHERE token = $1
                    FOR UPDATE
                    """,
                    token,
                )

                if not result:
                    raise TokenValidationError("Token not found")

                # Check expiration
                if result["expires_at"] and result["expires_at"] < utcnow():
                    raise TokenValidationError("Token has expired")

                # Check usage limit
                if result["max_uses"] is not None:
                    if result["current_uses"] >= result["max_uses"]:
                        raise TokenValidationError("Token has reached maximum uses")

                # Increment usage counter
                await conn.execute(
                    """
                    UPDATE registration_tokens
                    SET current_uses = current_uses + 1,
                        last_used_at = $1
                    WHERE id = $2
                    """,
                    utcnow(),
                    result["id"],
                )

        logger.info(
            f"Token validated successfully: {token[:8]}... (uses: {result['current_uses'] + 1})"
        )
        return True

    async def revoke_token(self, token: str) -> bool:
        """
        Revoke a token by setting expiration to now

        Args:
            token: Token string to revoke

        Returns:
            True if token was revoked, False if not found
        """
        async with self.pool.acquire() as conn:
            result = await conn.execute(
                """
                UPDATE registration_tokens
                SET expires_at = $1
                WHERE token = $2 AND (expires_at IS NULL OR expires_at > $1)
                """,
                utcnow(),
                token,
            )

        # Parse result string "UPDATE N" to check if any rows were affected
        rows_affected = int(result.split()[-1]) if result else 0

        if rows_affected > 0:
            logger.info(f"Token revoked: {token[:8]}...")
            return True
        else:
            logger.warning(f"Token not found or already expired: {token[:8]}...")
            return False

    async def cleanup_expired_tokens(self) -> int:
        """
        Delete expired tokens from database

        Returns:
            Number of tokens deleted
        """
        async with self.pool.acquire() as conn:
            result = await conn.execute(
                """
                DELETE FROM registration_tokens
                WHERE expires_at < $1
                """,
                utcnow(),
            )

        # Parse result string "DELETE N"
        deleted_count = int(result.split()[-1]) if result else 0

        if deleted_count > 0:
            logger.info(f"Cleaned up {deleted_count} expired tokens")

        return deleted_count

    async def list_tokens(
        self, include_expired: bool = False, limit: int = 100, offset: int = 0
    ) -> List[Dict[str, Any]]:
        """
        List all registration tokens

        Args:
            include_expired: Whether to include expired tokens
            limit: Maximum number of tokens to return
            offset: Number of tokens to skip

        Returns:
            List of token dictionaries
        """
        query = """
            SELECT id, token, description, max_uses, current_uses,
                   expires_at, created_by, created_at, last_used_at
            FROM registration_tokens
        """

        if not include_expired:
            query += " WHERE expires_at IS NULL OR expires_at > $1"
            params = [utcnow(), limit, offset]
        else:
            params = [limit, offset]

        query += " ORDER BY created_at DESC LIMIT ${} OFFSET ${}".format(
            len(params) - 1, len(params)
        )

        async with self.pool.acquire() as conn:
            if not include_expired:
                results = await conn.fetch(query, *params)
            else:
                results = await conn.fetch(query, limit, offset)

        tokens = []
        for row in results:
            is_expired = row["expires_at"] and row["expires_at"].replace(
                tzinfo=None
            ) < utcnow().replace(tzinfo=None)
            is_exhausted = row["max_uses"] and row["current_uses"] >= row["max_uses"]
            tokens.append(
                {
                    "id": str(row["id"]),
                    "token": row["token"],
                    "description": row["description"],
                    "max_uses": row["max_uses"],
                    "current_uses": row["current_uses"],
                    "expires_at": row["expires_at"].isoformat() if row["expires_at"] else None,
                    "created_by": row["created_by"],
                    "created_at": row["created_at"].isoformat(),
                    "last_used_at": row["last_used_at"].isoformat()
                    if row["last_used_at"]
                    else None,
                    "is_expired": is_expired,
                    "is_exhausted": is_exhausted,
                    "is_valid": not is_expired and not is_exhausted,
                }
            )

        return tokens

    async def get_token_details(self, token: str) -> Optional[Dict[str, Any]]:
        """
        Get detailed information about a token

        Args:
            token: Token string to lookup

        Returns:
            Token details dict or None if not found
        """
        async with self.pool.acquire() as conn:
            result = await conn.fetchrow(
                """
                SELECT id, token, description, max_uses, current_uses,
                       expires_at, created_by, created_at, last_used_at
                FROM registration_tokens
                WHERE token = $1
                """,
                token,
            )

        if not result:
            return None

        return {
            "id": str(result["id"]),
            "token": result["token"],
            "description": result["description"],
            "max_uses": result["max_uses"],
            "current_uses": result["current_uses"],
            "expires_at": result["expires_at"].isoformat() if result["expires_at"] else None,
            "created_by": result["created_by"],
            "created_at": result["created_at"].isoformat(),
            "last_used_at": result["last_used_at"].isoformat() if result["last_used_at"] else None,
            "is_expired": result["expires_at"]
            and result["expires_at"].replace(tzinfo=None) < utcnow().replace(tzinfo=None),
            "is_exhausted": result["max_uses"] and result["current_uses"] >= result["max_uses"],
            "is_valid": (
                (
                    result["expires_at"] is None
                    or result["expires_at"].replace(tzinfo=None) > utcnow().replace(tzinfo=None)
                )
                and (result["max_uses"] is None or result["current_uses"] < result["max_uses"])
            ),
        }


# Singleton instance (initialized when database connection is available)
_token_service: Optional[TokenService] = None


def get_token_service(db_pool: asyncpg.Pool) -> TokenService:
    """
    Get or create TokenService instance

    Args:
        db_pool: asyncpg connection pool

    Returns:
        TokenService instance
    """
    global _token_service
    if _token_service is None:
        _token_service = TokenService(db_pool)
    return _token_service
