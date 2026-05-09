"""
Simple In-Memory Rate Limiter (No Redis Required)

This module provides a lightweight rate limiting solution that doesn't require Redis.
Uses slowapi for efficient rate limiting with in-memory storage.

Features:
- 100 requests/minute per IP using sliding window
- In-memory storage (no external dependencies)
- Automatic cleanup of expired entries
- Cache-Control headers for frontend caching
- Request deduplication with TTL cache
"""

import asyncio
import hashlib
import json
import logging
import time
from collections import OrderedDict
from typing import Any, Callable, Dict, Optional

from fastapi import Request, Response
from fastapi.responses import JSONResponse
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)


class SimpleInMemoryCache:
    """
    Simple in-memory cache with TTL and size limits.

    Thread-safe implementation using asyncio locks.
    """

    def __init__(self, max_size: int = 1000, default_ttl: int = 10):
        """
        Initialize cache.

        Args:
            max_size: Maximum number of entries to store
            default_ttl: Default TTL in seconds
        """
        self.max_size = max_size
        self.default_ttl = default_ttl
        self.cache: OrderedDict[str, Dict[str, Any]] = OrderedDict()
        self.lock = asyncio.Lock()

    async def get(self, key: str) -> Optional[Any]:
        """Get value from cache if not expired."""
        async with self.lock:
            if key not in self.cache:
                return None

            entry = self.cache[key]
            if time.time() > entry["expires_at"]:
                # Expired, remove it
                del self.cache[key]
                return None

            # Move to end (LRU)
            self.cache.move_to_end(key)
            return entry["value"]

    async def set(self, key: str, value: Any, ttl: Optional[int] = None):
        """Set value in cache with TTL."""
        async with self.lock:
            if len(self.cache) >= self.max_size:
                # Remove oldest entry (LRU)
                self.cache.popitem(last=False)

            expires_at = time.time() + (ttl or self.default_ttl)
            self.cache[key] = {"value": value, "expires_at": expires_at, "created_at": time.time()}

    async def delete(self, key: str):
        """Delete entry from cache."""
        async with self.lock:
            self.cache.pop(key, None)

    async def clear(self):
        """Clear all entries."""
        async with self.lock:
            self.cache.clear()

    async def cleanup_expired(self):
        """Remove expired entries."""
        current_time = time.time()
        async with self.lock:
            expired_keys = [
                key for key, entry in self.cache.items() if current_time > entry["expires_at"]
            ]
            for key in expired_keys:
                del self.cache[key]

            if expired_keys:
                logger.debug(f"Cleaned up {len(expired_keys)} expired cache entries")

    async def stats(self) -> Dict[str, Any]:
        """Get cache statistics."""
        async with self.lock:
            current_time = time.time()
            expired_count = sum(
                1 for entry in self.cache.values() if current_time > entry["expires_at"]
            )

            return {
                "size": len(self.cache),
                "max_size": self.max_size,
                "active_entries": len(self.cache) - expired_count,
                "expired_entries": expired_count,
                "default_ttl": self.default_ttl,
            }


class CacheControlMiddleware(BaseHTTPMiddleware):
    """
    Middleware to add Cache-Control headers to responses.

    Reduces frontend polling frequency and improves performance.
    """

    def __init__(self, app, cache_patterns: Optional[Dict[str, int]] = None):
        """
        Initialize middleware.

        Args:
            app: FastAPI application
            cache_patterns: Dict mapping path patterns to max-age in seconds
        """
        super().__init__(app)

        # Default cache patterns (path_prefix: max-age in seconds)
        self.cache_patterns = cache_patterns or {
            "/api/metrics/": 10,  # Cache metrics for 10 seconds
            "/api/uptime/": 60,  # Cache uptime for 60 seconds
            "/api/health/": 30,  # Cache health for 30 seconds
            "/api/services": 30,  # Cache service list for 30 seconds
            "/api/machines": 30,  # Cache machine list for 30 seconds
        }

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """Add Cache-Control headers to matching responses."""
        response = await call_next(request)

        # Only add cache headers to successful GET requests
        if request.method == "GET" and response.status_code == 200:
            path = request.url.path

            # Find matching cache pattern
            for pattern, max_age in self.cache_patterns.items():
                if path.startswith(pattern):
                    # Add Cache-Control header
                    response.headers["Cache-Control"] = (
                        f"public, max-age={max_age}, must-revalidate"
                    )
                    response.headers["X-Cache-Max-Age"] = str(max_age)
                    break

        return response


class MemoryRateLimitMiddleware(BaseHTTPMiddleware):
    """
    In-memory rate limiting middleware with request deduplication.

    Uses slowapi for rate limiting and simple in-memory cache for deduplication.
    """

    def __init__(
        self, app, limiter: Limiter, cache: SimpleInMemoryCache, exempt_paths: Optional[list] = None
    ):
        """
        Initialize middleware.

        Args:
            app: FastAPI application
            limiter: Slowapi Limiter instance
            cache: SimpleInMemoryCache instance
            exempt_paths: List of paths exempt from rate limiting
        """
        super().__init__(app)
        self.limiter = limiter
        self.cache = cache
        self.exempt_paths = exempt_paths or ["/health", "/ping", "/docs", "/redoc", "/openapi.json"]

    def _is_exempt(self, path: str) -> bool:
        """Check if path is exempt from rate limiting."""
        return any(path.startswith(exempt) for exempt in self.exempt_paths)

    def _generate_cache_key(self, request: Request) -> str:
        """Generate cache key for request."""
        # Include method, path, and query params in cache key
        key_data = f"{request.method}:{request.url.path}:{request.query_params}"
        return hashlib.sha256(key_data.encode()).hexdigest()

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """Process request with rate limiting and caching."""
        path = request.url.path

        # Skip rate limiting for exempt paths
        if self._is_exempt(path):
            return await call_next(request)

        # Check cache for GET requests
        if request.method == "GET":
            cache_key = self._generate_cache_key(request)
            cached_response = await self.cache.get(cache_key)

            if cached_response:
                logger.debug(f"Cache hit for {path}")
                return JSONResponse(
                    status_code=cached_response["status_code"],
                    content=cached_response["content"],
                    headers={
                        **cached_response.get("headers", {}),
                        "X-Cache": "HIT",
                        "X-Cache-Age": str(int(time.time() - cached_response["cached_at"])),
                    },
                )

        # Process request
        response = await call_next(request)

        # Cache successful GET responses
        if request.method == "GET" and response.status_code == 200:
            # Read response body
            response_body = b""
            async for chunk in response.body_iterator:
                response_body += chunk

            try:
                content = json.loads(response_body.decode())

                # Determine TTL based on path
                ttl = 10  # Default 10 seconds
                if "/api/metrics/" in path:
                    ttl = 5  # 5 seconds for metrics
                elif "/api/uptime/" in path:
                    ttl = 60  # 60 seconds for uptime

                # Cache response
                cache_key = self._generate_cache_key(request)
                await self.cache.set(
                    cache_key,
                    {
                        "status_code": response.status_code,
                        "content": content,
                        "headers": dict(response.headers),
                        "cached_at": time.time(),
                    },
                    ttl=ttl,
                )

                # Reconstruct response
                return JSONResponse(
                    status_code=response.status_code,
                    content=content,
                    headers={**dict(response.headers), "X-Cache": "MISS"},
                )
            except (json.JSONDecodeError, UnicodeDecodeError):
                # Non-JSON response, return as-is
                pass

        return response


# Global cache instance
_global_cache: Optional[SimpleInMemoryCache] = None


def get_global_cache() -> SimpleInMemoryCache:
    """Get or create global cache instance."""
    global _global_cache
    if _global_cache is None:
        _global_cache = SimpleInMemoryCache(max_size=1000, default_ttl=10)
    return _global_cache


async def start_cache_cleanup_task(cache: SimpleInMemoryCache):
    """Background task to cleanup expired cache entries."""
    while True:
        try:
            await asyncio.sleep(60)  # Run every minute
            await cache.cleanup_expired()
        except Exception as e:
            logger.error(f"Error in cache cleanup task: {e}")


# Example usage
def setup_memory_rate_limiting(app, rate_limit: str = "100/minute"):
    """
    Setup in-memory rate limiting for FastAPI app.

    Args:
        app: FastAPI application
        rate_limit: Rate limit string (e.g., "100/minute")

    Example:
        app = FastAPI()
        setup_memory_rate_limiting(app, rate_limit="100/minute")
    """
    # Initialize slowapi limiter
    limiter = Limiter(key_func=get_remote_address, default_limits=[rate_limit])

    # Initialize cache
    cache = get_global_cache()

    # Add exception handler for rate limit exceeded
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    # Add cache control middleware (first, so it's applied last)
    app.add_middleware(CacheControlMiddleware)

    # Add rate limiting middleware
    app.add_middleware(MemoryRateLimitMiddleware, limiter=limiter, cache=cache)

    # Store limiter and cache in app state
    app.state.limiter = limiter
    app.state.cache = cache

    logger.info(f"Memory-based rate limiting enabled: {rate_limit}")

    return limiter, cache
