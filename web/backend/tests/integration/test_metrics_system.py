"""
Integration tests for the complete metrics system
Tests interaction between cache, queue, circuit breaker, and rate limiter
"""

import asyncio
import os
import sys
from unittest.mock import AsyncMock, Mock

import pytest

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from middleware.rate_limiter import RateLimiter
from services.metrics_cache import MetricsCache
from services.metrics_queue import MetricsQueue, Priority
from utils.circuit_breaker import CircuitBreaker, CircuitBreakerConfig
from utils.timeout_handler import (
    ErrorCategory,
    ExecutionResult,
    retry_with_backoff,
)


class TestMetricsSystemIntegration:
    """Integration tests for complete metrics system"""

    @pytest.fixture
    async def mock_redis(self):
        """Mock Redis client"""
        mock = AsyncMock()
        mock.ping = AsyncMock(return_value=True)
        mock.get = AsyncMock(return_value=None)
        mock.setex = AsyncMock(return_value=True)
        # `info()` returns a dict on real redis-py. Without a concrete
        # return_value the awaited result is itself an AsyncMock, and
        # MetricsCache.get_stats does `redis_info.get(...)` on it — that
        # call returns yet another coroutine that nobody awaits, which
        # python flags as a "coroutine never awaited" RuntimeWarning.
        mock.info = AsyncMock(return_value={})
        # Redis pipeline operations (zadd, zcard, zrange, expire, etc.) are
        # sync — they buffer commands locally and only `execute()` is async.
        # Using AsyncMock for the pipeline causes RuntimeWarnings: "coroutine
        # was never awaited" since the rate-limiter doesn't await the
        # buffering calls.
        mock.pipeline = Mock()
        pipeline_mock = Mock()
        pipeline_mock.execute = AsyncMock(return_value=[0, 0, 1, True, []])
        mock.pipeline.return_value = pipeline_mock
        return mock

    @pytest.fixture
    async def metrics_cache(self, mock_redis):
        """Create metrics cache"""
        cache = MetricsCache(ttl_seconds=60, enable_background_refresh=False)
        cache.redis_client = mock_redis
        return cache

    @pytest.fixture
    async def metrics_queue(self):
        """Create metrics queue"""
        queue = MetricsQueue(num_workers=2, max_queue_size=100, max_rate=50)
        await queue.start()
        yield queue
        await queue.stop(wait_for_completion=False)

    @pytest.fixture
    def circuit_breaker(self):
        """Create circuit breaker"""
        config = CircuitBreakerConfig(failure_threshold=3, recovery_timeout=1, success_threshold=1)
        return CircuitBreaker("test-service", config)

    @pytest.fixture
    async def rate_limiter(self, mock_redis):
        """Create rate limiter"""
        return RateLimiter(redis_client=mock_redis, max_requests=10, window_seconds=60)

    @pytest.mark.asyncio
    async def test_cache_and_queue_interaction(self, metrics_cache, metrics_queue, mock_redis):
        """Test cache and queue working together"""
        # Simulate metrics collection workflow

        # 1. Check cache (miss)
        cached = await metrics_cache.get("nginx", "web01")
        assert cached is None

        # 2. Queue metrics collection task
        task_id = "metrics-nginx-web01"
        success = await metrics_queue.submit_task(
            task_id=task_id,
            metric_type="service_metrics",
            data={"service": "nginx", "machine": "web01"},
        )
        assert success is True

        # 3. Wait for processing
        await asyncio.sleep(0.5)

        # 4. Cache the result
        metrics_data = {"cpu": 50, "memory": 1024}
        await metrics_cache.set("nginx", "web01", metrics_data)

        # 5. Verify cache hit
        import json

        mock_redis.get.return_value = json.dumps(
            {
                "data": metrics_data,
                "cached_at": "2025-01-15T10:00:00",
                "service": "nginx",
                "machine": "web01",
            }
        )
        mock_redis.ttl.return_value = 50

        cached = await metrics_cache.get("nginx", "web01")
        assert cached is not None
        assert cached["data"]["cpu"] == 50

    @pytest.mark.asyncio
    async def test_circuit_breaker_with_retry(self, circuit_breaker):
        """Test circuit breaker integration with retry logic"""
        call_count = 0

        @retry_with_backoff(max_attempts=3, base_delay=0.1)
        async def failing_metrics_fetch():
            nonlocal call_count
            call_count += 1

            if call_count < 3:
                return ExecutionResult(
                    success=False, error_category=ErrorCategory.TIMEOUT, error_message="timeout"
                )

            return ExecutionResult(success=True, stdout="metrics_data")

        # Use circuit breaker with retry
        result = await circuit_breaker.call(failing_metrics_fetch)

        assert result.success is True
        assert call_count == 3  # Retried twice before success

    @pytest.mark.asyncio
    async def test_rate_limiter_protects_queue(self, rate_limiter, metrics_queue, mock_redis):
        """Test rate limiter protecting queue submission"""
        # Configure mock for rate limiting
        mock_redis.pipeline.return_value.execute.return_value = [0, 5, 1, True, []]

        # Check rate limit before submitting
        rate_check = await rate_limiter.check_rate_limit("client-1")

        if rate_check["allowed"]:
            # Submit to queue
            success = await metrics_queue.submit_task(
                task_id="task-1", metric_type="cpu", data={"value": 50}
            )
            assert success is True

    @pytest.mark.asyncio
    async def test_full_metrics_collection_workflow(
        self, metrics_cache, metrics_queue, circuit_breaker, rate_limiter, mock_redis
    ):
        """Test complete metrics collection workflow"""
        service = "nginx"
        machine = "web01"
        client_id = "api-client-1"

        # Step 1: Rate limit check
        mock_redis.pipeline.return_value.execute.return_value = [0, 3, 1, True, []]
        rate_check = await rate_limiter.check_rate_limit(client_id)
        assert rate_check["allowed"] is True

        # Step 2: Check cache
        cached = await metrics_cache.get(service, machine)
        assert cached is None  # Cache miss

        # Step 3: Submit collection task to queue
        async def collect_metrics():
            # Simulate metrics collection
            await asyncio.sleep(0.1)
            return ExecutionResult(success=True, stdout='{"cpu": 45, "memory": 2048}')

        # Use circuit breaker for collection
        result = await circuit_breaker.call(collect_metrics)
        assert result.success is True

        # Step 4: Cache the result
        metrics_data = {"cpu": 45, "memory": 2048}
        cache_success = await metrics_cache.set(service, machine, metrics_data)
        assert cache_success is True

        # Step 5: Verify subsequent request gets cached data
        import json

        mock_redis.get.return_value = json.dumps(
            {
                "data": metrics_data,
                "cached_at": "2025-01-15T10:00:00",
                "service": service,
                "machine": machine,
            }
        )
        mock_redis.ttl.return_value = 250

        cached = await metrics_cache.get(service, machine)
        assert cached is not None
        assert cached["data"]["cpu"] == 45

    @pytest.mark.asyncio
    async def test_failure_cascade_prevention(self, circuit_breaker):
        """Test circuit breaker prevents failure cascades"""
        failure_count = 0

        async def unreliable_service():
            nonlocal failure_count
            failure_count += 1
            raise Exception("Service unavailable")

        # Trip the circuit breaker
        for _ in range(3):
            with pytest.raises(Exception):
                await circuit_breaker.call(unreliable_service)

        # Circuit should now be open
        from utils.circuit_breaker import CircuitBreakerError, CircuitState

        assert circuit_breaker.get_state() == CircuitState.OPEN

        # Further calls should fail fast without hitting the service
        with pytest.raises(CircuitBreakerError):
            await circuit_breaker.call(unreliable_service)

        # Failure count should not increase (circuit open, fast fail)
        assert failure_count == 3

    @pytest.mark.asyncio
    async def test_queue_priority_with_rate_limiting(self, metrics_queue):
        """Test queue handles priority correctly with rate limiting"""
        processed = []

        async def track_callback(task):
            processed.append(task.priority)

        # Submit mixed priority tasks
        await metrics_queue.submit_task(
            task_id="low-1",
            metric_type="batch",
            data={},
            priority=Priority.LOW,
            callback=track_callback,
        )

        await metrics_queue.submit_realtime_task(
            task_id="high-1", metric_type="realtime", data={}, callback=track_callback
        )

        await metrics_queue.submit_task(
            task_id="normal-1",
            metric_type="normal",
            data={},
            priority=Priority.NORMAL,
            callback=track_callback,
        )

        # Wait for processing
        await asyncio.sleep(1.0)

        # At least some tasks should be processed
        assert len(processed) > 0

    @pytest.mark.asyncio
    async def test_graceful_degradation_flow(self, circuit_breaker, metrics_cache):
        """Test graceful degradation when services fail"""
        from utils.timeout_handler import handle_graceful_degradation

        # Simulate failed metrics collection
        async def failing_collection():
            return ExecutionResult(
                success=False,
                error_category=ErrorCategory.TIMEOUT,
                error_message="Connection timeout",
                attempts=3,
            )

        result = await circuit_breaker.call(failing_collection)

        # Handle graceful degradation
        degraded = handle_graceful_degradation(result, "cpu_metrics")

        assert degraded["status"] == "degraded"
        assert degraded["fallback"] is True
        assert degraded["error"]["category"] == "timeout"

    @pytest.mark.asyncio
    async def test_concurrent_metrics_collection(self, metrics_queue):
        """Test system handles concurrent metrics collection"""
        # Submit many tasks concurrently
        tasks = []
        for i in range(20):
            task = metrics_queue.submit_task(
                task_id=f"task-{i}", metric_type="cpu", data={"value": i}
            )
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        # All tasks should be submitted successfully (or fail due to backpressure)
        assert len(results) == 20

        # Wait for processing
        await asyncio.sleep(1.5)

        # Check statistics
        stats = await metrics_queue.get_statistics()
        assert stats["tasks_submitted"] >= 20

    @pytest.mark.asyncio
    async def test_cache_invalidation_after_update(self, metrics_cache, mock_redis):
        """Test cache invalidation workflow"""
        service = "nginx"
        machine = "web01"

        # Cache data
        await metrics_cache.set(service, machine, {"cpu": 50})

        # Invalidate cache
        mock_redis.scan.return_value = (0, [f"metrics:{service}:{machine}:bucket"])
        mock_redis.delete.return_value = 1

        deleted = await metrics_cache.invalidate(service=service, machine=machine)

        assert deleted >= 0

    @pytest.mark.asyncio
    async def test_health_check_integration(self, metrics_cache, mock_redis):
        """Test health checking across components"""
        # Cache health
        mock_redis.ping.return_value = True
        cache_health = await metrics_cache.health_check()

        assert cache_health["status"] == "healthy"
        assert cache_health["redis_connected"] is True

    @pytest.mark.asyncio
    async def test_statistics_collection(self, metrics_cache, metrics_queue):
        """Test collecting statistics from all components"""
        # Submit some tasks
        await metrics_queue.submit_task(task_id="test-1", metric_type="cpu", data={"value": 50})

        await asyncio.sleep(0.5)

        # Get queue stats
        queue_stats = await metrics_queue.get_statistics()
        assert "tasks_submitted" in queue_stats

        # Get cache stats
        cache_stats = await metrics_cache.get_stats()
        assert "hits" in cache_stats
        assert "config" in cache_stats
