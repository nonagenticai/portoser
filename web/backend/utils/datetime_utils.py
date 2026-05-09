"""
Datetime utilities for Pydantic v2 compatibility.

Provides timezone-aware datetime functions to replace deprecated datetime.utcnow().
"""

from datetime import datetime, timezone


def utcnow() -> datetime:
    """
    Get current UTC time as a naive datetime object.

    This replaces the deprecated datetime.utcnow() with a timezone-aware
    equivalent that removes timezone info for backwards compatibility.

    Returns:
        datetime: Current UTC time without timezone info (naive datetime)
    """
    return datetime.now(timezone.utc).replace(tzinfo=None)


def utcnow_aware() -> datetime:
    """
    Get current UTC time as a timezone-aware datetime object.

    Use this for new code that should be timezone-aware.

    Returns:
        datetime: Current UTC time with timezone info
    """
    return datetime.now(timezone.utc)
