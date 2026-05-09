from fastapi import HTTPException, Header
import os

async def verify_build_token(x_build_token: str = Header(None)):
    """Verify build API token

    Args:
        x_build_token: Token from X-Build-Token header

    Returns:
        True if token is valid

    Raises:
        HTTPException: If token is missing or invalid
    """
    expected = os.getenv("BUILD_API_TOKEN")
    if not expected:
        raise HTTPException(
            status_code=500,
            detail="BUILD_API_TOKEN not configured on server"
        )
    if not x_build_token:
        raise HTTPException(
            status_code=401,
            detail="X-Build-Token header required"
        )
    if x_build_token != expected:
        raise HTTPException(
            status_code=401,
            detail="Invalid build token"
        )
    return True
