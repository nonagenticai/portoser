"""
Datetime utilities for Pydantic v2 compatibility.

Provides timezone-aware datetime functions to replace deprecated datetime.utcnow().
"""

from datetime import datetime, timezone


def utcnow() -> datetime:
    """
    Get current UTC time as a NAIVE datetime object.

    Use this only for in-memory, naive-vs-naive comparisons (metrics, caches,
    rate limiters, websocket JSON payloads). For anything persisted to or
    compared against the database, use ``utcnow_aware()`` instead: every
    timestamp column is TIMESTAMPTZ and psycopg returns those as tz-aware
    datetimes, so mixing them with a naive value raises TypeError.

    Returns:
        datetime: Current UTC time without timezone info (naive datetime)
    """
    return datetime.now(timezone.utc).replace(tzinfo=None)


def utcnow_aware() -> datetime:
    """
    Get current UTC time as a timezone-aware datetime object.

    Use this for everything that touches the database (TIMESTAMPTZ columns) and
    for any new code that should be timezone-aware.

    Returns:
        datetime: Current UTC time with timezone info
    """
    return datetime.now(timezone.utc)
