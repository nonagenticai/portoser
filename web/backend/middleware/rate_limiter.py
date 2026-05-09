"""
API Rate Limiting and Request Deduplication for Metrics Endpoints

This module implements:
1. Rate limiting: 100 requests/minute per IP using sliding window algorithm
2. Request deduplication: cache identical requests for 5 seconds
3. Redis-backed counter storage
4. FastAPI middleware and dependencies
5. Rate limit headers (X-RateLimit-*)
"""

import hashlib
import json
import time
from typing import Any, Callable, Dict, Optional

import redis.asyncio as redis
from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from utils.datetime_utils import utcnow


class RateLimiter:
    """
    Sliding window rate limiter using Redis.

    Implements a sliding window algorithm that provides smooth rate limiting
    without the burst issues of fixed window approaches.
    """

    def __init__(
        self,
        redis_client: redis.Redis,
        max_requests: int = 100,
        window_seconds: int = 60,
        key_prefix: str = "rate_limit",
    ):
        """
        Initialize rate limiter.

        Args:
            redis_client: Redis async client instance
            max_requests: Maximum requests allowed in window (default: 100)
            window_seconds: Time window in seconds (default: 60)
            key_prefix: Redis key prefix for rate limit data
        """
        self.redis = redis_client
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.key_prefix = key_prefix

    def _get_key(self, identifier: str) -> str:
        """Generate Redis key for rate limit tracking."""
        return f"{self.key_prefix}:{identifier}"

    async def check_rate_limit(self, identifier: str) -> Dict[str, Any]:
        """
        Check if request is within rate limit using sliding window.

        Args:
            identifier: Unique identifier (e.g., IP address)

        Returns:
            Dict with rate limit status:
                - allowed: bool, whether request is allowed
                - remaining: int, requests remaining in window
                - reset_at: timestamp when window resets
                - retry_after: seconds until request can be retried (if blocked)
        """
        key = self._get_key(identifier)
        now = time.time()
        window_start = now - self.window_seconds

        # Use Redis sorted set with timestamps as scores
        pipe = self.redis.pipeline()

        # Remove old entries outside the sliding window
        pipe.zremrangebyscore(key, 0, window_start)

        # Count requests in current window
        pipe.zcard(key)

        # Add current request timestamp
        pipe.zadd(key, {str(now): now})

        # Set expiry on the key
        pipe.expire(key, self.window_seconds + 1)

        # Get oldest request in window for reset calculation
        pipe.zrange(key, 0, 0, withscores=True)

        results = await pipe.execute()

        # results[1] is the count before adding current request
        current_count = results[1]
        oldest_entries = results[4]

        # Calculate reset time (when oldest request expires)
        if oldest_entries:
            oldest_timestamp = oldest_entries[0][1]
            reset_at = oldest_timestamp + self.window_seconds
        else:
            reset_at = now + self.window_seconds

        # Check if limit exceeded
        allowed = current_count < self.max_requests
        remaining = max(0, self.max_requests - current_count - 1)

        # If not allowed, remove the request we just added
        if not allowed:
            await self.redis.zrem(key, str(now))
            remaining = 0

        retry_after = max(0, int(reset_at - now)) if not allowed else 0

        return {
            "allowed": allowed,
            "remaining": remaining,
            "reset_at": int(reset_at),
            "retry_after": retry_after,
            "limit": self.max_requests,
            "window": self.window_seconds,
        }


class RequestDeduplicator:
    """
    Request deduplication using Redis cache.

    Caches identical requests for a specified TTL to avoid redundant processing.
    """

    def __init__(self, redis_client: redis.Redis, ttl_seconds: int = 5, key_prefix: str = "dedup"):
        """
        Initialize request deduplicator.

        Args:
            redis_client: Redis async client instance
            ttl_seconds: Time to cache responses in seconds (default: 5)
            key_prefix: Redis key prefix for deduplication data
        """
        self.redis = redis_client
        self.ttl_seconds = ttl_seconds
        self.key_prefix = key_prefix

    def _generate_request_hash(
        self,
        method: str,
        path: str,
        query_params: str,
        body: Optional[bytes],
        headers: Optional[Dict[str, str]] = None,
    ) -> str:
        """
        Generate unique hash for request.

        Args:
            method: HTTP method
            path: Request path
            query_params: Query parameters string
            body: Request body bytes
            headers: Optional headers to include in hash

        Returns:
            SHA256 hash of request components
        """
        hash_components = [method.upper(), path, query_params or "", body or b""]

        # Include specific headers if needed (e.g., Accept, Content-Type)
        if headers:
            for key in sorted(headers.keys()):
                hash_components.append(f"{key}:{headers[key]}")

        hash_input = "|".join(
            comp.decode() if isinstance(comp, bytes) else str(comp) for comp in hash_components
        )

        return hashlib.sha256(hash_input.encode()).hexdigest()

    def _get_key(self, request_hash: str) -> str:
        """Generate Redis key for cached response."""
        return f"{self.key_prefix}:{request_hash}"

    async def get_cached_response(
        self, method: str, path: str, query_params: str, body: Optional[bytes] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Get cached response for identical request.

        Args:
            method: HTTP method
            path: Request path
            query_params: Query parameters string
            body: Request body bytes

        Returns:
            Cached response dict or None if not found
        """
        request_hash = self._generate_request_hash(method, path, query_params, body)
        key = self._get_key(request_hash)

        cached = await self.redis.get(key)
        if cached:
            return json.loads(cached)

        return None

    async def cache_response(
        self,
        method: str,
        path: str,
        query_params: str,
        body: Optional[bytes],
        response_data: Dict[str, Any],
    ) -> None:
        """
        Cache response for request.

        Args:
            method: HTTP method
            path: Request path
            query_params: Query parameters string
            body: Request body bytes
            response_data: Response data to cache
        """
        request_hash = self._generate_request_hash(method, path, query_params, body)
        key = self._get_key(request_hash)

        await self.redis.setex(key, self.ttl_seconds, json.dumps(response_data))


class RateLimitMiddleware(BaseHTTPMiddleware):
    """
    FastAPI middleware for rate limiting and request deduplication.

    Applies rate limiting to all requests and deduplication to GET requests.
    """

    def __init__(
        self,
        app: FastAPI,
        redis_client: redis.Redis,
        rate_limiter: Optional[RateLimiter] = None,
        deduplicator: Optional[RequestDeduplicator] = None,
        exempt_paths: Optional[list[str]] = None,
    ):
        """
        Initialize middleware.

        Args:
            app: FastAPI application
            redis_client: Redis async client
            rate_limiter: RateLimiter instance (created if not provided)
            deduplicator: RequestDeduplicator instance (created if not provided)
            exempt_paths: List of paths exempt from rate limiting
        """
        super().__init__(app)
        self.redis = redis_client
        self.rate_limiter = rate_limiter or RateLimiter(redis_client)
        self.deduplicator = deduplicator or RequestDeduplicator(redis_client)
        self.exempt_paths = exempt_paths or ["/health", "/metrics/health"]

    def _get_client_identifier(self, request: Request) -> str:
        """
        Extract client identifier from request.

        Checks X-Forwarded-For header first, then falls back to client IP.

        Args:
            request: FastAPI request object

        Returns:
            Client IP address
        """
        # Check X-Forwarded-For header (for proxied requests)
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            # Take the first IP in the chain
            return forwarded.split(",")[0].strip()

        # Fall back to direct client IP
        if request.client:
            return request.client.host

        return "unknown"

    def _is_exempt(self, path: str) -> bool:
        """Check if path is exempt from rate limiting."""
        return any(path.startswith(exempt) for exempt in self.exempt_paths)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """
        Process request through rate limiting and deduplication.

        Args:
            request: FastAPI request object
            call_next: Next middleware/handler in chain

        Returns:
            Response object
        """
        path = request.url.path

        # Skip rate limiting for exempt paths
        if self._is_exempt(path):
            return await call_next(request)

        # Get client identifier
        client_id = self._get_client_identifier(request)

        # Check rate limit
        rate_limit_status = await self.rate_limiter.check_rate_limit(client_id)

        # Add rate limit headers to response
        headers = {
            "X-RateLimit-Limit": str(rate_limit_status["limit"]),
            "X-RateLimit-Remaining": str(rate_limit_status["remaining"]),
            "X-RateLimit-Reset": str(rate_limit_status["reset_at"]),
            "X-RateLimit-Window": str(rate_limit_status["window"]),
        }

        # If rate limit exceeded, return 429
        if not rate_limit_status["allowed"]:
            headers["Retry-After"] = str(rate_limit_status["retry_after"])

            return JSONResponse(
                status_code=429,
                content={
                    "error": "Rate limit exceeded",
                    "message": f"Maximum {rate_limit_status['limit']} requests per {rate_limit_status['window']} seconds",
                    "retry_after": rate_limit_status["retry_after"],
                },
                headers=headers,
            )

        # Check for cached response (only for GET requests)
        if request.method == "GET":
            query_params = str(request.query_params)
            cached_response = await self.deduplicator.get_cached_response(
                request.method, path, query_params
            )

            if cached_response:
                headers["X-Cache"] = "HIT"
                headers["X-Cache-Age"] = str(int(time.time() - cached_response.get("cached_at", 0)))

                return JSONResponse(
                    status_code=cached_response.get("status_code", 200),
                    content=cached_response.get("content"),
                    headers={**headers, **cached_response.get("headers", {})},
                )

        # Process request
        response = await call_next(request)

        # Add rate limit headers to response
        for key, value in headers.items():
            response.headers[key] = value

        # Cache GET responses with 200 status
        if request.method == "GET" and response.status_code == 200:
            # Read response body
            response_body = b""
            async for chunk in response.body_iterator:
                response_body += chunk

            try:
                content = json.loads(response_body.decode())

                # Cache response
                query_params = str(request.query_params)
                await self.deduplicator.cache_response(
                    request.method,
                    path,
                    query_params,
                    None,
                    {
                        "status_code": response.status_code,
                        "content": content,
                        "headers": dict(response.headers),
                        "cached_at": int(time.time()),
                    },
                )

                response.headers["X-Cache"] = "MISS"

                # Reconstruct response with body
                return JSONResponse(
                    status_code=response.status_code,
                    content=content,
                    headers=dict(response.headers),
                )
            except (json.JSONDecodeError, UnicodeDecodeError):
                # If response is not JSON, return as-is
                pass

        return response


# FastAPI Dependency Functions


async def get_redis_client() -> redis.Redis:
    """
    FastAPI dependency to get Redis client.

    Returns:
        Redis async client instance
    """
    import os

    redis_host = os.getenv("REDIS_HOST", "localhost")
    redis_port = int(os.getenv("REDIS_PORT", "8987"))
    redis_db = int(os.getenv("REDIS_DB", "0"))

    client = redis.Redis(
        host=redis_host,
        port=redis_port,
        db=redis_db,
        decode_responses=False,
        socket_connect_timeout=5,
        socket_timeout=5,
    )
    try:
        yield client
    finally:
        await client.close()


async def get_rate_limiter(redis_client: redis.Redis = Depends(get_redis_client)) -> RateLimiter:
    """
    FastAPI dependency to get RateLimiter instance.

    Args:
        redis_client: Redis client from dependency

    Returns:
        RateLimiter instance
    """
    return RateLimiter(redis_client, max_requests=100, window_seconds=60)


async def get_deduplicator(
    redis_client: redis.Redis = Depends(get_redis_client),
) -> RequestDeduplicator:
    """
    FastAPI dependency to get RequestDeduplicator instance.

    Args:
        redis_client: Redis client from dependency

    Returns:
        RequestDeduplicator instance
    """
    return RequestDeduplicator(redis_client, ttl_seconds=5)


def require_rate_limit(request: Request, rate_limiter: RateLimiter = Depends(get_rate_limiter)):
    """
    FastAPI dependency for explicit rate limit checking.

    Can be used on individual endpoints for custom rate limiting.

    Args:
        request: FastAPI request object
        rate_limiter: RateLimiter instance from dependency

    Raises:
        HTTPException: 429 if rate limit exceeded
    """

    async def check():
        # Get client identifier
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            client_id = forwarded.split(",")[0].strip()
        elif request.client:
            client_id = request.client.host
        else:
            client_id = "unknown"

        # Check rate limit
        status = await rate_limiter.check_rate_limit(client_id)

        if not status["allowed"]:
            raise HTTPException(
                status_code=429,
                detail={"error": "Rate limit exceeded", "retry_after": status["retry_after"]},
                headers={
                    "Retry-After": str(status["retry_after"]),
                    "X-RateLimit-Limit": str(status["limit"]),
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": str(status["reset_at"]),
                },
            )

    return check


# Example FastAPI Application Setup


def create_app() -> FastAPI:
    """
    Create FastAPI application with rate limiting middleware.

    Returns:
        Configured FastAPI application
    """
    import os

    app = FastAPI(title="Metrics API with Rate Limiting")

    # Initialize Redis client (singleton for app lifecycle)
    redis_host = os.getenv("REDIS_HOST", "localhost")
    redis_port = int(os.getenv("REDIS_PORT", "8987"))
    redis_db = int(os.getenv("REDIS_DB", "0"))

    redis_client = redis.Redis(
        host=redis_host, port=redis_port, db=redis_db, decode_responses=False
    )

    # Add rate limiting middleware
    app.add_middleware(
        RateLimitMiddleware,
        redis_client=redis_client,
        exempt_paths=["/health", "/docs", "/openapi.json"],
    )

    @app.on_event("startup")
    async def startup():
        """Test Redis connection on startup."""
        try:
            await redis_client.ping()
            print("Successfully connected to Redis")
        except Exception as e:
            print(f"Failed to connect to Redis: {e}")

    @app.on_event("shutdown")
    async def shutdown():
        """Close Redis connection on shutdown."""
        await redis_client.close()

    # Example endpoints

    @app.get("/health")
    async def health_check():
        """Health check endpoint (exempt from rate limiting)."""
        return {"status": "healthy"}

    @app.get("/metrics/system")
    async def get_system_metrics(request: Request):
        """Get system metrics (rate limited and deduplicated)."""
        return {
            "timestamp": utcnow().isoformat(),
            "cpu_usage": 45.2,
            "memory_usage": 62.8,
            "disk_usage": 71.5,
        }

    @app.get("/metrics/application")
    async def get_application_metrics(request: Request):
        """Get application metrics (rate limited and deduplicated)."""
        return {
            "timestamp": utcnow().isoformat(),
            "requests_per_second": 123.4,
            "active_connections": 45,
            "error_rate": 0.02,
        }

    @app.post("/metrics/events")
    async def post_event(request: Request, event_data: dict):
        """Post event (rate limited, not deduplicated due to POST)."""
        return {
            "status": "received",
            "event_id": hashlib.sha256(str(time.time()).encode()).hexdigest()[:16],
        }

    return app


# Utility functions for testing and monitoring


async def get_rate_limit_stats(
    redis_client: redis.Redis, identifier: str, key_prefix: str = "rate_limit"
) -> Dict[str, Any]:
    """
    Get current rate limit statistics for an identifier.

    Args:
        redis_client: Redis async client
        identifier: Client identifier (IP address)
        key_prefix: Redis key prefix

    Returns:
        Dict with current stats
    """
    key = f"{key_prefix}:{identifier}"
    now = time.time()
    window_start = now - 60

    # Get all requests in current window
    requests = await redis_client.zrangebyscore(key, window_start, now, withscores=True)

    return {
        "identifier": identifier,
        "current_count": len(requests),
        "requests": [{"timestamp": score, "age_seconds": now - score} for _, score in requests],
    }


async def clear_rate_limit(
    redis_client: redis.Redis, identifier: str, key_prefix: str = "rate_limit"
) -> bool:
    """
    Clear rate limit data for an identifier.

    Useful for testing or administrative purposes.

    Args:
        redis_client: Redis async client
        identifier: Client identifier to clear
        key_prefix: Redis key prefix

    Returns:
        True if data was cleared
    """
    key = f"{key_prefix}:{identifier}"
    result = await redis_client.delete(key)
    return result > 0


if __name__ == "__main__":
    import os

    import uvicorn

    # Create and run application
    app = create_app()

    backend_port = int(os.getenv("BACKEND_PORT", "8988"))
    bind_host = os.getenv("BIND_HOST", "127.0.0.1")

    print("Starting Metrics API with Rate Limiting...")
    print("Rate Limit: 100 requests per 60 seconds")
    print("Deduplication: 5 second cache for GET requests")
    print(f"Listening on {bind_host}:{backend_port}")

    uvicorn.run(app, host=bind_host, port=backend_port)
