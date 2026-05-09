"""
Unit tests for rate limiter middleware
Tests sliding window rate limiting and request deduplication
"""

import asyncio
import json
import os
import sys
import time
from unittest.mock import Mock

import pytest

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from middleware.rate_limiter import RateLimiter, RateLimitMiddleware, RequestDeduplicator


class TestRateLimiter:
    """Test rate limiter functionality"""

    @pytest.fixture
    async def limiter(self, mock_redis):
        """Create rate limiter with mock Redis"""
        return RateLimiter(
            redis_client=mock_redis,
            max_requests=10,
            window_seconds=60,
            key_prefix="test_rate_limit",
        )

    def test_rate_limiter_initialization(self, mock_redis):
        """Test rate limiter initialization"""
        limiter = RateLimiter(redis_client=mock_redis, max_requests=100, window_seconds=60)

        assert limiter.max_requests == 100
        assert limiter.window_seconds == 60

    def test_get_key(self, mock_redis):
        """Test Redis key generation"""
        limiter = RateLimiter(mock_redis, key_prefix="test")
        key = limiter._get_key("192.0.2.1")

        assert key == "test:192.0.2.1"

    @pytest.mark.asyncio
    async def test_check_rate_limit_allowed(self, limiter, mock_redis):
        """Test rate limit check when allowed"""
        # Mock pipeline execution
        mock_redis.pipeline.return_value.execute.return_value = [
            0,  # zremrangebyscore result
            5,  # zcard result (5 requests in window)
            1,  # zadd result
            True,  # expire result
            [(b"key", time.time())],  # zrange result
        ]

        result = await limiter.check_rate_limit("192.0.2.1")

        assert result["allowed"] is True
        assert result["remaining"] >= 0
        assert result["limit"] == 10

    @pytest.mark.asyncio
    async def test_check_rate_limit_exceeded(self, limiter, mock_redis):
        """Test rate limit exceeded"""
        # Mock pipeline execution - 10 requests already
        mock_redis.pipeline.return_value.execute.return_value = [
            0,  # zremrangebyscore
            10,  # zcard (at limit)
            1,  # zadd
            True,  # expire
            [(b"key", time.time() - 30)],  # oldest entry
        ]

        result = await limiter.check_rate_limit("192.0.2.1")

        assert result["allowed"] is False
        assert result["remaining"] == 0
        assert "retry_after" in result

    @pytest.mark.asyncio
    async def test_sliding_window_cleanup(self, limiter, mock_redis):
        """Test sliding window removes old entries"""
        await limiter.check_rate_limit("192.0.2.1")

        # Verify zremrangebyscore was called to remove old entries
        pipeline = mock_redis.pipeline.return_value
        assert pipeline.zremrangebyscore.called

    @pytest.mark.asyncio
    async def test_rate_limit_reset_time(self, limiter, mock_redis):
        """Test reset time calculation"""
        now = time.time()
        mock_redis.pipeline.return_value.execute.return_value = [
            0,
            5,
            1,
            True,
            [(b"key", now - 30)],  # Oldest request 30 seconds ago
        ]

        result = await limiter.check_rate_limit("192.0.2.1")

        assert "reset_at" in result
        assert result["reset_at"] > now


class TestRequestDeduplicator:
    """Test request deduplication"""

    @pytest.fixture
    async def deduplicator(self, mock_redis):
        """Create request deduplicator with mock Redis"""
        return RequestDeduplicator(redis_client=mock_redis, ttl_seconds=5, key_prefix="test_dedup")

    def test_deduplicator_initialization(self, mock_redis):
        """Test deduplicator initialization"""
        dedup = RequestDeduplicator(redis_client=mock_redis, ttl_seconds=10)

        assert dedup.ttl_seconds == 10

    def test_generate_request_hash(self, deduplicator):
        """Test request hash generation"""
        hash1 = deduplicator._generate_request_hash("GET", "/api/metrics", "filter=cpu", None)

        hash2 = deduplicator._generate_request_hash("GET", "/api/metrics", "filter=cpu", None)

        # Same request should have same hash
        assert hash1 == hash2
        assert len(hash1) == 64  # SHA256 hex digest length

    def test_different_requests_different_hash(self, deduplicator):
        """Test different requests have different hashes"""
        hash1 = deduplicator._generate_request_hash("GET", "/api/metrics", "filter=cpu", None)

        hash2 = deduplicator._generate_request_hash(
            "GET",
            "/api/metrics",
            "filter=memory",  # Different query
            None,
        )

        assert hash1 != hash2

    def test_get_key(self, deduplicator):
        """Test Redis key generation"""
        request_hash = "abc123"
        key = deduplicator._get_key(request_hash)

        assert key == "test_dedup:abc123"

    @pytest.mark.asyncio
    async def test_get_cached_response_miss(self, deduplicator, mock_redis):
        """Test cache miss returns None"""
        mock_redis.get.return_value = None

        result = await deduplicator.get_cached_response("GET", "/api/metrics", "", None)

        assert result is None

    @pytest.mark.asyncio
    async def test_get_cached_response_hit(self, deduplicator, mock_redis):
        """Test cache hit returns data"""
        cached_data = {"status": "success", "data": {"cpu": 50}}

        mock_redis.get.return_value = json.dumps(cached_data)

        result = await deduplicator.get_cached_response("GET", "/api/metrics", "", None)

        assert result is not None
        assert result["status"] == "success"
        assert result["data"]["cpu"] == 50

    @pytest.mark.asyncio
    async def test_cache_response(self, deduplicator, mock_redis):
        """Test caching a response"""
        response_data = {"status": "success", "data": {"cpu": 50}}

        await deduplicator.cache_response("GET", "/api/metrics", "", None, response_data)

        # Verify setex was called with TTL
        mock_redis.setex.assert_called_once()
        call_args = mock_redis.setex.call_args
        assert call_args[0][1] == 5  # TTL


class TestRateLimitMiddleware:
    """Test rate limit middleware"""

    @pytest.fixture
    def app(self):
        """Create mock FastAPI app"""
        from fastapi import FastAPI

        return FastAPI()

    @pytest.fixture
    async def middleware(self, app, mock_redis):
        """Create rate limit middleware"""
        limiter = RateLimiter(mock_redis, max_requests=10, window_seconds=60)
        deduplicator = RequestDeduplicator(mock_redis, ttl_seconds=5)

        return RateLimitMiddleware(
            app=app,
            redis_client=mock_redis,
            rate_limiter=limiter,
            deduplicator=deduplicator,
            exempt_paths=["/health"],
        )

    def test_middleware_initialization(self, app, mock_redis):
        """Test middleware initialization"""
        middleware = RateLimitMiddleware(
            app=app, redis_client=mock_redis, exempt_paths=["/health", "/metrics"]
        )

        assert middleware.redis is not None
        assert "/health" in middleware.exempt_paths

    def test_get_client_identifier(self, middleware):
        """Test extracting client identifier"""
        from fastapi import Request

        # Mock request with X-Forwarded-For
        mock_request = Mock(spec=Request)
        mock_request.headers.get.return_value = "1.2.3.4, 5.6.7.8"

        identifier = middleware._get_client_identifier(mock_request)

        assert identifier == "1.2.3.4"

    def test_get_client_identifier_direct(self, middleware):
        """Test client identifier from direct connection"""
        from fastapi import Request

        mock_request = Mock(spec=Request)
        mock_request.headers.get.return_value = None
        mock_request.client = Mock()
        mock_request.client.host = "192.0.2.1"

        identifier = middleware._get_client_identifier(mock_request)

        assert identifier == "192.0.2.1"

    def test_is_exempt(self, middleware):
        """Test exempt path detection"""
        assert middleware._is_exempt("/health") is True
        assert middleware._is_exempt("/api/metrics") is False
        assert middleware._is_exempt("/health/check") is True  # Starts with /health

    @pytest.mark.asyncio
    async def test_dispatch_exempt_path(self, middleware, mock_redis):
        """Test middleware skips exempt paths"""
        from fastapi import Request, Response

        mock_request = Mock(spec=Request)
        mock_request.url.path = "/health"

        async def call_next(request):
            return Response(content="OK", status_code=200)

        response = await middleware.dispatch(mock_request, call_next)

        assert response.status_code == 200
        # Rate limiter should not be called for exempt paths
        assert not mock_redis.pipeline.called

    @pytest.mark.asyncio
    async def test_dispatch_rate_limit_allowed(self, middleware, mock_redis):
        """Test middleware allows request within rate limit"""
        from fastapi import Request, Response

        mock_request = Mock(spec=Request)
        mock_request.url.path = "/api/metrics"
        mock_request.method = "POST"  # Not GET, so no dedup
        mock_request.headers.get.return_value = None
        mock_request.client = Mock()
        mock_request.client.host = "192.0.2.1"

        # Mock rate limit check - allowed
        mock_redis.pipeline.return_value.execute.return_value = [
            0,
            5,
            1,
            True,
            [(b"key", time.time())],
        ]

        async def call_next(request):
            return Response(content="OK", status_code=200)

        response = await middleware.dispatch(mock_request, call_next)

        assert response.status_code == 200
        assert "X-RateLimit-Limit" in response.headers

    @pytest.mark.asyncio
    async def test_dispatch_rate_limit_exceeded(self, middleware, mock_redis):
        """Test middleware blocks request when rate limit exceeded"""
        from fastapi import Request

        mock_request = Mock(spec=Request)
        mock_request.url.path = "/api/metrics"
        mock_request.method = "GET"
        mock_request.headers.get.return_value = None
        mock_request.client = Mock()
        mock_request.client.host = "192.0.2.1"

        # Mock rate limit check - exceeded
        mock_redis.pipeline.return_value.execute.return_value = [
            0,
            10,
            1,
            True,
            [(b"key", time.time() - 30)],
        ]

        async def call_next(request):
            from fastapi import Response

            return Response(content="OK", status_code=200)

        response = await middleware.dispatch(mock_request, call_next)

        assert response.status_code == 429
        assert "Retry-After" in response.headers


class TestRateLimitingIntegration:
    """Integration tests for rate limiting"""

    @pytest.mark.asyncio
    async def test_concurrent_requests(self, mock_redis):
        """Test rate limiting with concurrent requests"""
        limiter = RateLimiter(redis_client=mock_redis, max_requests=5, window_seconds=60)

        # Simulate 10 concurrent requests
        results = []

        async def make_request():
            return await limiter.check_rate_limit("test-client")

        # Mock pipeline to simulate gradual rate limit increase
        call_count = [0]

        async def mock_execute():
            call_count[0] += 1
            count = min(call_count[0], 5)
            return [0, count, 1, True, [(b"key", time.time())]]

        mock_redis.pipeline.return_value.execute = mock_execute

        tasks = [make_request() for _ in range(10)]
        results = await asyncio.gather(*tasks)

        # Some should be allowed, some blocked
        allowed = sum(1 for r in results if r["allowed"])
        blocked = sum(1 for r in results if not r["allowed"])

        assert allowed + blocked == 10
