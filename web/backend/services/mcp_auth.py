import hashlib
import hmac
import logging
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Dict, Optional, Set

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from uuid_extensions import uuid7

from utils.datetime_utils import utcnow

# Import JWT exceptions with fallbacks for different PyJWT versions
try:
    # Try the newer JWT exception names first
    from jwt.exceptions import PyJWTError as JWTError
except ImportError:
    try:
        # Try the alternative name
        from jwt.exceptions import JWTException as JWTError
    except ImportError:
        # Last resort - use a generic exception from the jwt library
        from jwt.exceptions import JWTError

        # If JWTError isn't directly available, create an alias to InvalidTokenError
        if "JWTError" not in locals():
            from jwt.exceptions import InvalidTokenError as JWTError

# Import the standard dependency function
from .mcp_dependencies import get_auth_service
from .mcp_postgres_db import MCPPostgresDB

# Configure logging
logger = logging.getLogger(__name__)

# JWT configuration from environment variables
# CRITICAL: In production, JWT_SECRET_KEY MUST be set in environment
_jwt_secret = os.getenv("JWT_SECRET_KEY", "")
_environment = os.getenv("ENVIRONMENT", "development")

if _environment == "production" and not _jwt_secret:
    raise ValueError(
        "JWT_SECRET_KEY must be set in production environment. "
        "Generate a strong secret with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
    )

# Use provided secret or fallback to dev default (never random!)
JWT_SECRET_KEY = _jwt_secret if _jwt_secret else "dev-secret-key-change-in-production"
JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
JWT_ACCESS_TOKEN_EXPIRE_MINUTES = int(
    os.getenv("JWT_ACCESS_TOKEN_EXPIRE_MINUTES", "120")
)  # 2 hours

# Log a warning if using default in non-production
if not _jwt_secret and _environment != "production":
    logger.warning(
        "⚠️  Using default JWT_SECRET_KEY for development. Set JWT_SECRET_KEY environment variable for production!"
    )

security = HTTPBearer()


# --- Helper for Scope Checking ---
def check_scope_permission(required_permission: str, granted_scopes_str: Optional[str]) -> bool:
    """
    Checks if a required permission is granted by a space-separated scope string.
    Handles basic wildcards like 'resource:*' or '*:action'.
    """
    if not required_permission:
        logger.warning("Empty required permission")
        return False

    if not granted_scopes_str:
        logger.warning(f"No scopes granted when checking for '{required_permission}'")
        return False

    granted_scopes = set(granted_scopes_str.split())
    logger.debug(f"Checking if '{required_permission}' is granted by scopes: {granted_scopes}")

    # Check for exact match
    if required_permission in granted_scopes:
        logger.debug(f"Permission '{required_permission}' granted - exact match found")
        return True

    # Check for admin-like scope (adjust if your system uses a different wildcard)
    if "*:*" in granted_scopes or "*" in granted_scopes:
        logger.debug(f"Permission '{required_permission}' granted - wildcard match (*:* or *)")
        return True

    # Split the required permission into resource and action
    parts = required_permission.split(":")
    if len(parts) != 2:
        logger.warning(
            f"Invalid permission format: '{required_permission}' - should be 'resource:action'"
        )
        return False  # Invalid permission format

    resource, action = parts

    # Check for resource wildcard (e.g., "tool:*" grants all tool permissions)
    resource_wildcard = f"{resource}:*"
    if resource_wildcard in granted_scopes:
        logger.debug(
            f"Permission '{required_permission}' granted - resource wildcard match ({resource_wildcard})"
        )
        return True

    # Check for action wildcard (e.g., "*:read" grants read permission on all resources)
    action_wildcard = f"*:{action}"
    if action_wildcard in granted_scopes:
        logger.debug(
            f"Permission '{required_permission}' granted - action wildcard match ({action_wildcard})"
        )
        return True

    logger.warning(
        f"Permission '{required_permission}' denied - no matching scope found in {granted_scopes}"
    )
    return False


# AuthService class definition moved back to auth.py (proper architectural location)
class AuthService:
    """Service for authentication and authorization."""

    def __init__(self, db_instance: MCPPostgresDB):
        """Initialize with database instance."""
        self.db = db_instance

    @classmethod
    def __get_pydantic_json_schema__(cls, _core_schema, handler):
        """
        Custom JSON schema generator to prevent schema generation errors.
        This provides a simple schema for the AuthService type when used in FastAPI endpoints.
        """
        return {
            "type": "object",
            "title": "AuthService",
            "description": "Authentication and authorization service instance",
        }

    async def create_access_token(self, data: Dict) -> str:
        """
        Create a JWT access token.

        Args:
            data: Dictionary containing data to encode in the token

        Returns:
            JWT token string
        """
        to_encode = data.copy()
        expire = utcnow() + timedelta(minutes=JWT_ACCESS_TOKEN_EXPIRE_MINUTES)
        to_encode.update({"exp": expire})
        encoded_jwt = jwt.encode(to_encode, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)
        return encoded_jwt

    def decode_token(self, token: str) -> Dict:
        """
        Decode and validate a JWT token.

        Args:
            token: JWT token to decode

        Returns:
            Dictionary of decoded token data

        Raises:
            HTTPException: If token is invalid or expired
        """
        try:
            # Check if token might be an OAuth token first by querying DB
            # This is a simplification; ideally, distinguish JWTs from opaque tokens
            # or have a dedicated introspection endpoint.
            # For now, assume if decode fails, it might be an OAuth token.
            payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=[JWT_ALGORITHM])
            return payload
        except jwt.exceptions.InvalidTokenError as e:
            # General catch-all for PyJWT errors
            # Don't raise immediately, it might be an OAuth token
            logger.debug(
                f"JWT decoding failed for token (might be OAuth token): {token[:10]}... Error: {e}"
            )
            # Return an indicator that JWT decoding failed
            return {"_jwt_decode_failed": True}
        except Exception as e:
            logger.error(f"Unexpected error decoding token: {e}")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token format",
                headers={"WWW-Authenticate": "Bearer"},
            )

    def hash_password(self, password: str) -> str:
        """
        Hash a password using a secure algorithm.

        Args:
            password: Plain text password

        Returns:
            Hashed password string
        """
        # Use a secure password hashing algorithm like bcrypt, Argon2, or PBKDF2
        # For simplicity, we'll use a simple SHA-256 hash with a random salt
        # In production, you should use a proper password hashing library like passlib
        salt = os.urandom(32)
        hashed = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100000)
        # Store salt and hash together
        return salt.hex() + "$" + hashed.hex()

    def verify_password(self, plain_password: str, hashed_password: str) -> bool:
        """
        Verify a password against a hash.

        Args:
            plain_password: Plain text password to verify
            hashed_password: Hashed password to check against

        Returns:
            True if password matches, False otherwise
        """
        if not hashed_password or "$" not in hashed_password:
            return False

        salt_hex, hash_hex = hashed_password.split("$")
        salt = bytes.fromhex(salt_hex)
        stored_hash = bytes.fromhex(hash_hex)

        check_hash = hashlib.pbkdf2_hmac("sha256", plain_password.encode("utf-8"), salt, 100000)

        # Use constant-time comparison to prevent timing attacks
        return hmac.compare_digest(check_hash, stored_hash)

    def hash_api_key(self, api_key: str) -> str:
        """
        Hash an API key using a secure algorithm.

        Args:
            api_key: Plain text API key

        Returns:
            Hashed API key string
        """
        # Similar to password hashing but can use a simpler scheme if needed
        salt = os.urandom(16)
        hashed = hashlib.pbkdf2_hmac("sha256", api_key.encode("utf-8"), salt, 50000)
        return salt.hex() + "$" + hashed.hex()

    def verify_api_key(self, plain_api_key: str, hashed_api_key: str) -> bool:
        """
        Verify an API key against a hash.

        Args:
            plain_api_key: Plain text API key to verify
            hashed_api_key: Hashed API key to check against

        Returns:
            True if API key matches, False otherwise
        """
        if not hashed_api_key or "$" not in hashed_api_key:
            return False

        salt_hex, hash_hex = hashed_api_key.split("$")
        salt = bytes.fromhex(salt_hex)
        stored_hash = bytes.fromhex(hash_hex)

        check_hash = hashlib.pbkdf2_hmac("sha256", plain_api_key.encode("utf-8"), salt, 50000)

        # Use constant-time comparison to prevent timing attacks
        return hmac.compare_digest(check_hash, stored_hash)

    def generate_api_key(self) -> str:
        """
        Generate a new API key.

        Returns:
            Randomly generated API key string
        """
        return f"mcp_{uuid7().hex}_{secrets.token_hex(16)}"

    async def authenticate_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """
        Authenticate a user with username and password.

        Args:
            username: User's username
            password: User's password

        Returns:
            User info dictionary if authentication succeeds, None otherwise
        """
        user = await self.db.get_user_by_username(username)
        if not user:
            return None

        if not user.get("password_hash") or not self.verify_password(
            password, user["password_hash"]
        ):
            return None

        return user

    async def authenticate_api_key(self, api_key: str) -> Optional[Dict[str, Any]]:
        """
        Authenticate a client with an API key.

        Args:
            api_key: Client's API key

        Returns:
            User info dictionary if authentication succeeds, None otherwise
        """
        # This would be more efficient with an API key index, but for now we'll iterate users
        async with self.db.pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM users WHERE api_key_hash IS NOT NULL")

            for row in rows:
                user = dict(row)
                if self.verify_api_key(api_key, user["api_key_hash"]):
                    return user

        return None

    async def get_user_permissions(self, user_id: int) -> Set[str]:
        """
        Get all permissions for a user based on their roles.

        Args:
            user_id: User ID to check permissions for

        Returns:
            Set of permission names the user has
        """
        roles = await self.db.get_user_roles(user_id)

        permissions = set()
        for role in roles:
            role_permissions = await self.db.get_role_permissions(role["id"])
            permissions.update(p["name"] for p in role_permissions)

        return permissions

    async def check_permission(self, user_id: int, required_permission: str) -> bool:
        """
        Check if a user has a specific permission.

        Supports:
        - Exact permission matches
        - Wildcard permissions (e.g., "tool:*" matches any tool permission)
        - Hierarchical permissions (e.g., "admin:*" grants all permissions under admin)

        Args:
            user_id: User ID to check
            required_permission: Permission name to check for

        Returns:
            True if user has the permission, False otherwise
        """
        permissions = await self.get_user_permissions(user_id)

        # Check for exact match
        if required_permission in permissions:
            return True

        # Check if user has 'admin' permission (grants all permissions)
        if "admin" in permissions:
            return True

        # Handle wildcard permissions
        if "*" in permissions:
            return True

        # Split the required permission into resource and action
        parts = required_permission.split(":")
        if len(parts) != 2:
            return False  # Invalid permission format

        resource, action = parts

        # Check for resource wildcard (e.g., "tool:*" grants all tool permissions)
        resource_wildcard = f"{resource}:*"
        if resource_wildcard in permissions:
            return True

        # Check for action wildcard (e.g., "*:read" grants read permission on all resources)
        action_wildcard = f"*:{action}"
        if action_wildcard in permissions:
            return True

        return False

    async def initialize_roles_and_permissions(self):
        """Initialize default roles and permissions if none exist."""
        # Role definitions
        roles_to_create = [
            {
                "name": "admin",
                "description": "Full administrative access with all permissions",
            },
            {"name": "tool_creator", "description": "Can create and manage tools"},
            {"name": "tool_user", "description": "Can execute tools"},
            {
                "name": "readonly",
                "description": "Read-only access to system information",
            },
            {"name": "auditor", "description": "Can view audit logs"},
            {
                "name": "api_gateway",
                "description": "Internal role for API Gateway communication",
            },
        ]

        # Permission definitions
        permissions_to_create = [
            {"name": "admin", "description": "Grants all permissions"},
            {"name": "tool:create", "description": "Create new tools"},
            {
                "name": "tool:read",
                "description": "Read tool definitions and list tools",
            },
            {"name": "tool:update", "description": "Update existing tools"},
            {"name": "tool:delete", "description": "Delete tools"},
            {"name": "tool:execute", "description": "Execute tools"},
            {"name": "tool:backup", "description": "Access and create tool backups"},
            {"name": "tool:restore", "description": "Restore tools from backups"},
            {"name": "user:create", "description": "Create new users"},
            {"name": "user:read", "description": "Read user information"},
            {"name": "user:update", "description": "Update user information"},
            {"name": "user:delete", "description": "Delete users"},
            {"name": "role:create", "description": "Create new roles"},
            {"name": "role:read", "description": "Read role information"},
            {
                "name": "role:update",
                "description": "Update roles and assign permissions",
            },
            {"name": "role:delete", "description": "Delete roles"},
            {"name": "role:assign", "description": "Assign roles to users"},
            {"name": "log:read", "description": "Read audit logs"},
            {
                "name": "gateway:configure",
                "description": "Configure gateway settings (e.g., allowed imports)",
            },
        ]

        # Get all permission names for assigning to admin
        all_permission_names = [perm["name"] for perm in permissions_to_create]

        # Role-Permission assignments - ensure admin has all permissions explicitly
        role_permissions = {
            "admin": all_permission_names,  # Give admin ALL permissions explicitly
            "tool_creator": [
                "tool:create",
                "tool:read",
                "tool:update",
                "tool:delete",
                "tool:backup",
                "tool:restore",
            ],
            "tool_user": ["tool:read", "tool:execute"],
            "readonly": ["tool:read", "user:read", "role:read"],
            "auditor": ["log:read"],
            "api_gateway": ["gateway:configure"],  # Permissions needed by gateway itself
        }

        # Transaction to ensure atomicity
        async with self.db.pool.acquire() as conn:
            async with conn.transaction():
                # First, check if we already have any roles
                existing_roles = await conn.fetch("SELECT COUNT(*) as count FROM roles")
                if existing_roles and existing_roles[0]["count"] > 0:
                    logger.info(
                        f"Found {existing_roles[0]['count']} existing roles. Checking for admin role consistency."
                    )

                    # Check if the admin role exists and has the right description
                    admin_role = await conn.fetchrow(
                        "SELECT id, description FROM roles WHERE name = 'admin'"
                    )
                    if admin_role:
                        await conn.execute(
                            "UPDATE roles SET description = $1 WHERE name = 'admin'",
                            "Full administrative access with all permissions",
                        )
                        logger.info("Updated admin role description for consistency.")

                # Create permissions
                perm_name_to_id = {}
                for perm in permissions_to_create:
                    perm_id = await conn.fetchval(
                        "INSERT INTO permissions (name, description) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET description = $2 RETURNING id",
                        perm["name"],
                        perm["description"],
                    )
                    if not perm_id:  # If failure in returning id, get existing ID
                        perm_id = await conn.fetchval(
                            "SELECT id FROM permissions WHERE name = $1", perm["name"]
                        )
                    perm_name_to_id[perm["name"]] = perm_id

                # Create roles
                role_name_to_id = {}
                for role in roles_to_create:
                    role_id = await conn.fetchval(
                        "INSERT INTO roles (name, description) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET description = $2 RETURNING id",
                        role["name"],
                        role["description"],
                    )
                    if not role_id:  # If failure in returning id, get existing ID
                        role_id = await conn.fetchval(
                            "SELECT id FROM roles WHERE name = $1", role["name"]
                        )
                    role_name_to_id[role["name"]] = role_id

                # Assign permissions to roles
                for role_name, perm_names in role_permissions.items():
                    role_id = role_name_to_id[role_name]
                    for perm_name in perm_names:
                        perm_id = perm_name_to_id[perm_name]
                        await conn.execute(
                            "INSERT INTO role_permissions (role_id, permission_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                            role_id,
                            perm_id,
                        )

        logger.info("Default roles and permissions initialized successfully.")


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials, Depends(security)],
    # Use the standard dependency function
    auth_service: Annotated[AuthService, Depends(get_auth_service)],
) -> Dict[str, Any]:
    """Dependency to get the current authenticated user from token."""
    token = credentials.credentials
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        # First, try decoding as JWT
        payload = auth_service.decode_token(token)

        if payload.get("_jwt_decode_failed"):  # Check if JWT decode failed
            # If JWT failed, try validating as OAuth token from DB
            logger.debug(f"JWT decode failed, checking DB for token: {token[:10]}...")
            token_data = await auth_service.db.get_access_token(token)
            if not token_data:
                logger.warning(f"Token not found in DB: {token[:10]}...")
                raise credentials_exception

            # Check token expiry
            expires_at = token_data.get("expires_at")
            now = datetime.now(timezone.utc) if expires_at and expires_at.tzinfo else datetime.now()
            if expires_at and expires_at < now:
                logger.warning(f"OAuth token expired: {token[:10]}...")
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Token has expired",
                    headers={"WWW-Authenticate": "Bearer"},
                )

            # If token is valid, prepare user data
            user_id = token_data.get("user_id")
            client_id = token_data.get("client_id")
            scope = token_data.get("scope", "")

            if user_id:
                # This is a user token (likely from password/refresh flow not shown)
                user = await auth_service.db.get_user_by_id(user_id)
                if user is None:
                    logger.error(f"User ID {user_id} from valid token not found in DB.")
                    raise credentials_exception
                # Return user info
                return {
                    "id": user_id,
                    "username": user["username"],
                    "type": "user",
                    "scope": scope,
                }
            elif client_id:
                # This is a client credentials token
                # Return client info (no specific user)
                return {
                    "id": None,
                    "client_id": client_id,
                    "type": "client",
                    "scope": scope,
                }
            else:
                logger.error(
                    f"Valid OAuth token {token[:10]}... has neither user_id nor client_id."
                )
                raise credentials_exception
        else:
            # JWT decoding was successful
            username: str = payload.get("username")
            user_id_str: str = payload.get("sub")
            if username is None or user_id_str is None:
                logger.warning("Invalid JWT payload: missing username or sub (user ID).")
                raise credentials_exception

            try:
                user_id = int(user_id_str)
            except ValueError:
                logger.warning(f"Invalid JWT payload: sub '{user_id_str}' is not an integer.")
                raise credentials_exception

            # Optionally verify user exists in DB based on ID from JWT
            user = await auth_service.db.get_user_by_id(user_id)
            if user is None:
                logger.warning(f"User ID {user_id} from JWT not found in database.")
                raise credentials_exception

            # Add scope info if available in JWT (non-standard)
            scope = payload.get("scope", "")  # Assume scope might be in JWT
            return {"id": user_id, "username": username, "type": "user", "scope": scope}

    except JWTError as e:
        logger.error(f"Token validation error (JWTError): {e}")
        raise credentials_exception
    except HTTPException as http_exc:  # Re-raise specific HTTP exceptions
        raise http_exc
    except Exception as e:
        logger.error(f"Unexpected error during token validation: {e}", exc_info=True)
        raise credentials_exception


def requires_permission(required_permission: str):
    """
    Dependency factory that creates a dependency requiring a specific permission.
    """

    async def permission_dependency(
        request: Request,  # Inject Request to access headers/state
        # Use the standard dependency function
        auth_service: Annotated[AuthService, Depends(get_auth_service)],
        # Get current user info using the updated get_current_user
        current_user: Annotated[Dict[str, Any], Depends(get_current_user)],
    ) -> Dict[str, Any]:
        """Dependency function that checks for the required permission."""
        user_id = current_user.get("id")
        client_id = current_user.get("client_id")
        granted_scopes = current_user.get("scope", "")
        user_type = current_user.get("type", "unknown")

        has_permission = False

        if user_type == "user" and user_id is not None:
            # Check DB permissions for regular users
            has_permission = await auth_service.check_permission(user_id, required_permission)
        elif user_type == "client" and client_id is not None:
            # Check scopes for OAuth clients
            has_permission = check_scope_permission(required_permission, granted_scopes)
        else:
            logger.warning(f"Unknown user type or missing ID in token: {current_user}")
            has_permission = False

        if not has_permission:
            logger.warning(
                f"Permission denied for '{required_permission}'. User/Client: {current_user}"
            )
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Insufficient permissions: Requires '{required_permission}'",
            )

        logger.debug(f"Permission granted for '{required_permission}'. User/Client: {current_user}")
        return current_user  # Return user data if permission check passes

    # Add Pydantic schema generation logic if needed for docs
    def __get_pydantic_json_schema__(core_schema, handler):  # noqa: N807  # Pydantic library hook
        # Return a basic representation or customize as needed
        return {
            "type": "object",
            "title": f"RequiresPermission({required_permission})",
            "description": f"Ensures user has the '{required_permission}' permission.",
        }

    # Attach the schema function to the dependency function
    permission_dependency.__get_pydantic_json_schema__ = __get_pydantic_json_schema__

    return permission_dependency
