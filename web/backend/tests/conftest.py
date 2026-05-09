"""
Pytest configuration and shared fixtures for all tests
"""

# async_property is a transitive dep (via fastmcp) that does
# `is_coroutine = asyncio.iscoroutinefunction` at module load. Python 3.16
# soft-deprecated that name in favour of inspect.iscoroutinefunction; the
# wrapper emits a DeprecationWarning when async_property's `import` line
# is executed.
#
# The warning is captured by pytest before any test-level filterwarnings
# runs (it's an *import-time* event), and route-by-route filterwarnings in
# pyproject.toml don't catch it because the DeprecationWarning's location
# string is `<frozen importlib...>` rather than `async_property.*`.
#
# So we monkey-patch the alias BEFORE async_property gets imported. Doing
# it in conftest.py is enough because pytest loads the rootdir conftest
# before any test module is imported, and the test modules are what end
# up pulling in fastmcp → async_property.
import asyncio
import inspect

if asyncio.iscoroutinefunction is not inspect.iscoroutinefunction:
    asyncio.iscoroutinefunction = inspect.iscoroutinefunction  # type: ignore[assignment]

import warnings  # noqa: E402
from unittest.mock import AsyncMock, MagicMock  # noqa: E402

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
import redis.asyncio as redis  # noqa: E402

# Belt-and-braces: even with the monkey-patch above, suppress the message
# in case a future fastmcp pre-imports async_property before this conftest
# runs (e.g. via --import-mode=importlib quirks).
warnings.filterwarnings(
    "ignore",
    message=r".*asyncio\.iscoroutinefunction.*deprecated.*",
    category=DeprecationWarning,
)


@pytest_asyncio.fixture
async def mock_redis():
    """Mock Redis client for testing"""
    mock = AsyncMock(spec=redis.Redis)
    mock.ping = AsyncMock(return_value=True)
    mock.get = AsyncMock(return_value=None)
    mock.set = AsyncMock(return_value=True)
    mock.setex = AsyncMock(return_value=True)
    mock.delete = AsyncMock(return_value=1)
    mock.zadd = AsyncMock(return_value=1)
    mock.zrem = AsyncMock(return_value=1)
    mock.zcard = AsyncMock(return_value=0)
    mock.zrange = AsyncMock(return_value=[])
    mock.zrangebyscore = AsyncMock(return_value=[])
    mock.zremrangebyscore = AsyncMock(return_value=0)
    mock.pipeline = MagicMock()
    mock.expire = AsyncMock(return_value=True)
    mock.ttl = AsyncMock(return_value=300)
    mock.scan = AsyncMock(return_value=(0, []))
    mock.close = AsyncMock()

    # Mock pipeline
    pipeline_mock = AsyncMock()
    pipeline_mock.execute = AsyncMock(return_value=[0, 0, 1, True, []])
    pipeline_mock.zremrangebyscore = MagicMock(return_value=pipeline_mock)
    pipeline_mock.zcard = MagicMock(return_value=pipeline_mock)
    pipeline_mock.zadd = MagicMock(return_value=pipeline_mock)
    pipeline_mock.expire = MagicMock(return_value=pipeline_mock)
    pipeline_mock.zrange = MagicMock(return_value=pipeline_mock)

    mock.pipeline.return_value = pipeline_mock

    return mock


@pytest.fixture
def mock_subprocess():
    """Mock subprocess for testing timeout handler"""
    mock = AsyncMock()
    mock.returncode = 0
    mock.communicate = AsyncMock(return_value=(b"output", b""))
    mock.kill = AsyncMock()
    mock.wait = AsyncMock()
    return mock
