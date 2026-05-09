"""FastAPI dependencies for authentication and authorization."""

from fastapi import Depends, HTTPException, Request, status

from .models import KeycloakUser


def get_current_user(request: Request) -> KeycloakUser:
    """Get current authenticated user from request state.

    Use this as a dependency in route handlers that require authentication.

    Args:
        request: FastAPI request object

    Returns:
        Authenticated user

    Raises:
        HTTPException: If user is not authenticated

    Example:
        @app.get("/protected")
        async def protected_route(user: KeycloakUser = Depends(get_current_user)):
            return {"user": user.preferred_username}
    """
    user = getattr(request.state, "user", None)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    return user


def require_role(required_role: str):
    """Dependency factory for role-based authorization.

    Args:
        required_role: Role name required to access endpoint

    Returns:
        Dependency function

    Example:
        @app.get("/admin-only")
        async def admin_route(user: KeycloakUser = Depends(require_role("admin"))):
            return {"message": "Admin access granted"}
    """

    def check_role(user: KeycloakUser = Depends(get_current_user)) -> KeycloakUser:
        if not user.has_realm_role(required_role):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Required role '{required_role}' not found",
            )
        return user

    return check_role


def require_any_role(*roles: str):
    """Require user to have ANY of the specified roles.

    Args:
        *roles: One or more role names

    Returns:
        Dependency function

    Example:
        @app.get("/editor")
        async def editor_route(
            user: KeycloakUser = Depends(require_any_role("editor", "admin"))
        ):
            return {"message": "Editor access granted"}
    """

    def check_roles(user: KeycloakUser = Depends(get_current_user)) -> KeycloakUser:
        user_roles = user.get_all_roles()
        if not any(role in user_roles for role in roles):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Required one of roles: {', '.join(roles)}",
            )
        return user

    return check_roles


def require_all_roles(*roles: str):
    """Require user to have ALL of the specified roles.

    Args:
        *roles: One or more role names

    Returns:
        Dependency function
    """

    def check_roles(user: KeycloakUser = Depends(get_current_user)) -> KeycloakUser:
        user_roles = user.get_all_roles()
        missing_roles = [role for role in roles if role not in user_roles]
        if missing_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Missing required roles: {', '.join(missing_roles)}",
            )
        return user

    return check_roles
