"""
Unit tests for metrics cache module
Tests Redis caching, invalidation, and background refresh
"""

import json
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from utils.datetime_utils import utcnow

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services.metrics_cache import CacheInvalidationStrategy, CacheStats, MetricsCache, cached


class TestCacheStats:
    """Test cache statistics dataclass"""

    def test_cache_stats_creation(self):
        """Test creating cache stats"""
        stats = CacheStats()

        assert stats.hits == 0
        assert stats.misses == 0
        assert stats.sets == 0

    def test_hit_rate_calculation(self):
        """Test hit rate calculation"""
        stats = CacheStats(hits=80, misses=20, total_requests=100)

        assert stats.hit_rate == 80.0
        assert stats.miss_rate == 20.0

    def test_zero_requests_hit_rate(self):
        """Test hit rate with zero requests"""
        stats = CacheStats()

        assert stats.hit_rate == 0.0
        assert stats.miss_rate == 0.0

    def test_to_dict(self):
        """Test converting stats to dict"""
        stats = CacheStats(hits=10, misses=5, total_requests=15)
        stats_dict = stats.to_dict()

        assert "hits" in stats_dict
        assert "misses" in stats_dict
        assert "hit_rate" in stats_dict
        assert "miss_rate" in stats_dict


class TestMetricsCache:
    """Test metrics cache functionality"""

    @pytest.fixture
    async def cache(self, mock_redis):
        """Create metrics cache with mock Redis"""
        import os

        # Use environment variable or default (8987 matches docker-compose default)
        redis_url = os.getenv("REDIS_URL", "redis://localhost:8987/0")

        cache = MetricsCache(
            redis_url=redis_url,
            ttl_seconds=300,
            refresh_threshold=240,
            enable_background_refresh=False,  # Disable for unit tests
        )

        # Set mock Redis client
        cache.redis_client = mock_redis

        return cache

    def test_cache_initialization(self):
        """Test cache initialization"""
        cache = MetricsCache(ttl_seconds=300, refresh_threshold=240)

        assert cache.ttl_seconds == 300
        assert cache.refresh_threshold == 240

    def test_make_cache_key(self):
        """Test cache key generation"""
        cache = MetricsCache()
        key = cache._make_cache_key("nginx", "web01", "2025-01-15T10:30:00")

        assert key.startswith("metrics:")
        assert "nginx" in key
        assert "web01" in key

    def test_make_cache_key_with_default_bucket(self):
        """Test cache key with auto-generated timestamp bucket"""
        cache = MetricsCache()
        key = cache._make_cache_key("nginx", "web01")

        assert "metrics:nginx:web01:" in key

    @pytest.mark.asyncio
    async def test_cache_get_miss(self, cache, mock_redis):
        """Test cache miss"""
        mock_redis.get.return_value = None

        result = await cache.get("nginx", "web01")

        assert result is None
        assert cache.stats.misses == 1
        assert cache.stats.total_requests == 1

    @pytest.mark.asyncio
    async def test_cache_get_hit(self, cache, mock_redis):
        """Test cache hit"""
        cached_data = {
            "data": {"cpu": 50, "memory": 1024},
            "cached_at": utcnow().isoformat(),
            "service": "nginx",
            "machine": "web01",
        }

        mock_redis.get.return_value = json.dumps(cached_data)
        mock_redis.ttl.return_value = 250

        result = await cache.get("nginx", "web01")

        assert result is not None
        assert "data" in result
        assert result["data"]["cpu"] == 50
        assert cache.stats.hits == 1

    @pytest.mark.asyncio
    async def test_cache_set(self, cache, mock_redis):
        """Test setting cache value"""
        data = {"cpu": 50, "memory": 1024}

        success = await cache.set("nginx", "web01", data)

        assert success is True
        assert mock_redis.setex.called
        assert cache.stats.sets == 1

    @pytest.mark.asyncio
    async def test_cache_set_with_custom_ttl(self, cache, mock_redis):
        """Test setting cache with custom TTL"""
        data = {"cpu": 50}

        success = await cache.set("nginx", "web01", data, ttl=600)

        assert success is True
        call_args = mock_redis.setex.call_args
        assert call_args[0][1] == 600  # TTL argument

    @pytest.mark.asyncio
    async def test_cache_invalidate_all(self, cache, mock_redis):
        """Test invalidating all cache entries"""
        mock_redis.scan.return_value = (
            0,
            ["metrics:nginx:web01:bucket1", "metrics:nginx:web02:bucket2"],
        )
        mock_redis.delete.return_value = 2

        deleted = await cache.invalidate(strategy=CacheInvalidationStrategy.ALL)

        assert deleted == 2
        assert cache.stats.deletes == 2

    @pytest.mark.asyncio
    async def test_cache_invalidate_by_service(self, cache, mock_redis):
        """Test invalidating by service"""
        mock_redis.scan.return_value = (
            0,
            ["metrics:nginx:web01:bucket1", "metrics:nginx:web02:bucket2"],
        )
        mock_redis.delete.return_value = 2

        deleted = await cache.invalidate(
            service="nginx", strategy=CacheInvalidationStrategy.PATTERN
        )

        assert deleted == 2

    @pytest.mark.asyncio
    async def test_cache_invalidate_by_machine(self, cache, mock_redis):
        """Test invalidating by machine"""
        mock_redis.scan.return_value = (
            0,
            ["metrics:nginx:web01:bucket1", "metrics:apache:web01:bucket2"],
        )
        mock_redis.delete.return_value = 2

        deleted = await cache.invalidate(
            machine="web01", strategy=CacheInvalidationStrategy.PATTERN
        )

        assert deleted == 2

    @pytest.mark.asyncio
    async def test_scan_keys(self, cache, mock_redis):
        """Test scanning for keys"""
        mock_redis.scan.return_value = (
            0,
            ["metrics:nginx:web01:bucket1", "metrics:nginx:web02:bucket2"],
        )

        keys = await cache._scan_keys("metrics:nginx:*")

        assert len(keys) == 2
        assert "metrics:nginx:web01:bucket1" in keys

    @pytest.mark.asyncio
    async def test_register_refresh_callback(self, cache):
        """Test registering refresh callback"""

        async def refresh_func(service, machine):
            return {"cpu": 50}

        cache.register_refresh_callback("nginx", "web01", refresh_func)

        assert "nginx:web01" in cache.refresh_callbacks

    @pytest.mark.asyncio
    async def test_unregister_refresh_callback(self, cache):
        """Test unregistering refresh callback"""

        async def refresh_func(service, machine):
            return {"cpu": 50}

        cache.register_refresh_callback("nginx", "web01", refresh_func)
        cache.unregister_refresh_callback("nginx", "web01")

        assert "nginx:web01" not in cache.refresh_callbacks

    @pytest.mark.asyncio
    async def test_get_stats(self, cache, mock_redis):
        """Test getting cache statistics"""
        mock_redis.info.return_value = {
            "total_commands_processed": 100,
            "keyspace_hits": 80,
            "keyspace_misses": 20,
        }

        stats = await cache.get_stats()

        assert "hits" in stats
        assert "misses" in stats
        assert "config" in stats
        assert stats["config"]["ttl_seconds"] == 300

    @pytest.mark.asyncio
    async def test_reset_stats(self, cache):
        """Test resetting statistics"""
        cache.stats.hits = 10
        cache.stats.misses = 5

        await cache.reset_stats()

        assert cache.stats.hits == 0
        assert cache.stats.misses == 0

    @pytest.mark.asyncio
    async def test_health_check_healthy(self, cache, mock_redis):
        """Test health check when healthy"""
        mock_redis.ping.return_value = True

        health = await cache.health_check()

        assert health["status"] == "healthy"
        assert health["redis_connected"] is True
        assert len(health["errors"]) == 0

    @pytest.mark.asyncio
    async def test_health_check_redis_down(self, cache, mock_redis):
        """Test health check when Redis is down"""
        mock_redis.ping.side_effect = Exception("Connection refused")

        health = await cache.health_check()

        assert health["status"] == "unhealthy"
        assert health["redis_connected"] is False
        assert len(health["errors"]) > 0

    @pytest.mark.asyncio
    async def test_health_check_high_error_rate(self, cache):
        """Test health check with high error rate"""
        cache.stats.total_requests = 100
        cache.stats.errors = 15  # 15% error rate

        health = await cache.health_check()

        assert health["status"] == "degraded"
        assert "High error rate" in str(health["errors"])

    @pytest.mark.asyncio
    async def test_get_cache_size(self, cache, mock_redis):
        """Test getting cache size"""
        mock_redis.scan.return_value = (
            0,
            ["metrics:nginx:web01:bucket1", "metrics:nginx:web02:bucket2"],
        )
        mock_redis.memory_usage.return_value = 1024

        size_info = await cache.get_cache_size()

        assert size_info["total_keys"] == 2
        assert "estimated_memory_bytes" in size_info
        assert "estimated_memory_mb" in size_info

    @pytest.mark.asyncio
    async def test_cached_decorator_miss(self, cache, mock_redis):
        """Test cached decorator on cache miss"""
        mock_redis.get.return_value = None

        call_count = 0

        @cached(cache)
        async def get_metrics(service: str, machine: str):
            nonlocal call_count
            call_count += 1
            return {"cpu": 50}

        result = await get_metrics("nginx", "web01")

        assert result == {"cpu": 50}
        assert call_count == 1
        assert mock_redis.setex.called  # Should cache the result

    @pytest.mark.asyncio
    async def test_cached_decorator_hit(self, cache, mock_redis):
        """Test cached decorator on cache hit"""
        cached_data = {
            "data": {"cpu": 50},
            "cached_at": utcnow().isoformat(),
            "service": "nginx",
            "machine": "web01",
        }
        mock_redis.get.return_value = json.dumps(cached_data)
        mock_redis.ttl.return_value = 250

        call_count = 0

        @cached(cache)
        async def get_metrics(service: str, machine: str):
            nonlocal call_count
            call_count += 1
            return {"cpu": 75}

        result = await get_metrics("nginx", "web01")

        assert result == {"cpu": 50}  # Returns cached value
        assert call_count == 0  # Function not called

    @pytest.mark.asyncio
    async def test_connect(self):
        """Test connecting to Redis"""
        cache = MetricsCache()

        with patch("services.metrics_cache.redis") as mock_redis_module:
            mock_pool = MagicMock()
            mock_client = AsyncMock()
            mock_client.ping = AsyncMock(return_value=True)

            mock_redis_module.ConnectionPool.from_url.return_value = mock_pool
            mock_redis_module.Redis.return_value = mock_client

            await cache.connect()

            assert cache.redis_client is not None

    @pytest.mark.asyncio
    async def test_disconnect(self, cache):
        """Test disconnecting from Redis"""
        await cache.disconnect()

        # Verify cleanup was attempted
        assert True  # Just verify no exceptions
