"""User models for Keycloak."""

from typing import List, Optional

from pydantic import BaseModel, Field


class KeycloakUser(BaseModel):
    """User model with Keycloak claims."""

    sub: str = Field(..., description="User ID (subject)")
    preferred_username: str = Field(..., description="Username")
    email: Optional[str] = None
    email_verified: bool = False
    name: Optional[str] = None

    # Keycloak roles
    realm_access: dict = Field(default_factory=dict)
    resource_access: dict = Field(default_factory=dict)

    # Token metadata
    exp: Optional[int] = None
    iat: Optional[int] = None
    iss: Optional[str] = None

    @property
    def username(self) -> str:
        """Convenience alias for `preferred_username` used by older log/audit code."""
        return self.preferred_username

    def has_realm_role(self, role: str) -> bool:
        """Check if user has realm role.

        Args:
            role: Role name to check (e.g., "admin", "portoser-user")

        Returns:
            True if user has the role
        """
        roles = self.realm_access.get("roles", [])
        return role in roles

    def has_client_role(self, client_id: str, role: str) -> bool:
        """Check if user has client-specific role.

        Args:
            client_id: Client ID
            role: Role name

        Returns:
            True if user has the client role
        """
        client_roles = self.resource_access.get(client_id, {}).get("roles", [])
        return role in client_roles

    def get_all_roles(self) -> List[str]:
        """Get all roles (realm + all clients).

        Returns:
            List of all role names
        """
        realm_roles = self.realm_access.get("roles", [])
        client_roles = []
        for client_data in self.resource_access.values():
            client_roles.extend(client_data.get("roles", []))
        return realm_roles + client_roles

    def require_role(self, role: str) -> None:
        """Require user to have specific realm role.

        Args:
            role: Required role name

        Raises:
            HTTPException: If user doesn't have the role
        """
        if not self.has_realm_role(role):
            from fastapi import HTTPException, status

            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN, detail=f"Required role '{role}' not found"
            )
