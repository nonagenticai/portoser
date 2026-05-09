"""
Advanced Metrics Caching Layer with Redis Backend

This module implements a sophisticated caching system for metrics with:
- Redis backend for distributed caching
- 5-minute TTL with background refresh at 4 minutes
- Cache invalidation strategies
- Cache hit/miss metrics tracking
- Automatic background refresh to prevent cache stampede
"""

import asyncio
import json
import logging
import os
from dataclasses import asdict, dataclass
from datetime import datetime
from enum import Enum
from functools import wraps
from typing import Any, Callable, Dict, List, Optional

import redis.asyncio as redis

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class CacheInvalidationStrategy(str, Enum):
    """Cache invalidation strategy types"""

    TTL_ONLY = "ttl_only"  # Expire based on TTL only
    ON_WRITE = "on_write"  # Invalidate on data updates
    PATTERN = "pattern"  # Invalidate by key pattern
    ALL = "all"  # Invalidate all cache entries


@dataclass
class CacheStats:
    """Statistics for cache performance tracking"""

    hits: int = 0
    misses: int = 0
    sets: int = 0
    deletes: int = 0
    refreshes: int = 0
    errors: int = 0
    total_requests: int = 0

    @property
    def hit_rate(self) -> float:
        """Calculate cache hit rate percentage"""
        if self.total_requests == 0:
            return 0.0
        return (self.hits / self.total_requests) * 100

    @property
    def miss_rate(self) -> float:
        """Calculate cache miss rate percentage"""
        if self.total_requests == 0:
            return 0.0
        return (self.misses / self.total_requests) * 100

    def to_dict(self) -> Dict[str, Any]:
        """Convert stats to dictionary"""
        return {**asdict(self), "hit_rate": self.hit_rate, "miss_rate": self.miss_rate}


class MetricsCache:
    """
    Advanced caching layer for metrics with Redis backend.

    Features:
    - 5-minute TTL with automatic expiration
    - Background refresh at 4 minutes to prevent cache misses
    - Multiple invalidation strategies
    - Comprehensive cache statistics
    - Automatic reconnection handling
    - Key namespacing for different metric types
    """

    # Cache configuration
    DEFAULT_TTL = 300  # 5 minutes in seconds
    REFRESH_THRESHOLD = 240  # 4 minutes in seconds

    # Key format: "metrics:{service}:{machine}:{timestamp_bucket}"
    KEY_PREFIX = "metrics"

    def __init__(
        self,
        redis_url: Optional[str] = None,
        ttl_seconds: int = DEFAULT_TTL,
        refresh_threshold: int = REFRESH_THRESHOLD,
        enable_background_refresh: bool = True,
    ):
        """
        Initialize the metrics cache.

        Args:
            redis_url: Redis connection URL (defaults to REDIS_URL env var)
            ttl_seconds: Time-to-live for cache entries in seconds
            refresh_threshold: Seconds before expiry to trigger background refresh
            enable_background_refresh: Enable automatic background cache refresh
        """
        # Use REDIS_URL if provided, otherwise construct from individual components
        if redis_url:
            self.redis_url = redis_url
        else:
            redis_host = os.getenv("REDIS_HOST", "localhost")
            redis_port = os.getenv("REDIS_PORT", "8987")
            redis_db = os.getenv("REDIS_DB", "0")
            self.redis_url = os.getenv("REDIS_URL", f"redis://{redis_host}:{redis_port}/{redis_db}")
        self.ttl_seconds = ttl_seconds
        self.refresh_threshold = refresh_threshold
        self.enable_background_refresh = enable_background_refresh

        # Redis connection pool
        self.redis_pool: Optional[redis.ConnectionPool] = None
        self.redis_client: Optional[redis.Redis] = None

        # Cache statistics
        self.stats = CacheStats()

        # Background refresh tasks
        self.refresh_tasks: Dict[str, asyncio.Task] = {}
        self.refresh_callbacks: Dict[str, Callable] = {}

        # Lock for thread-safe operations
        self._lock = asyncio.Lock()

        logger.info(
            f"MetricsCache initialized - TTL: {ttl_seconds}s, "
            f"Refresh: {refresh_threshold}s, URL: {self.redis_url}"
        )

    async def connect(self):
        """Establish connection to Redis"""
        try:
            self.redis_pool = redis.ConnectionPool.from_url(
                self.redis_url, decode_responses=True, max_connections=10
            )
            self.redis_client = redis.Redis(connection_pool=self.redis_pool)

            # Test connection
            await self.redis_client.ping()
            logger.info("Successfully connected to Redis")

        except Exception as e:
            logger.error(f"Failed to connect to Redis: {e}")
            raise

    async def disconnect(self):
        """Close Redis connection and cleanup"""
        try:
            # Cancel all background refresh tasks
            for task in self.refresh_tasks.values():
                if not task.done():
                    task.cancel()

            if self.refresh_tasks:
                await asyncio.gather(*self.refresh_tasks.values(), return_exceptions=True)

            # Close Redis connection
            if self.redis_client:
                await self.redis_client.close()

            if self.redis_pool:
                await self.redis_pool.disconnect()

            logger.info("Disconnected from Redis")

        except Exception as e:
            logger.error(f"Error during disconnect: {e}")

    def _make_cache_key(
        self, service: str, machine: str, timestamp_bucket: Optional[str] = None
    ) -> str:
        """
        Generate cache key in the format: metrics:{service}:{machine}:{timestamp_bucket}

        Args:
            service: Service name
            machine: Machine hostname
            timestamp_bucket: Time bucket (optional, defaults to current 5-min bucket)

        Returns:
            Formatted cache key
        """
        if timestamp_bucket is None:
            # Calculate 5-minute timestamp bucket
            now = utcnow()
            bucket_minutes = (now.minute // 5) * 5
            timestamp_bucket = now.replace(
                minute=bucket_minutes, second=0, microsecond=0
            ).isoformat()

        return f"{self.KEY_PREFIX}:{service}:{machine}:{timestamp_bucket}"

    def _extract_timestamp_from_key(self, key: str) -> Optional[datetime]:
        """
        Extract timestamp from cache key

        Args:
            key: Cache key

        Returns:
            Datetime object or None
        """
        try:
            parts = key.split(":")
            if len(parts) >= 4:
                timestamp_str = parts[3]
                return datetime.fromisoformat(timestamp_str)
        except Exception as e:
            logger.warning(f"Failed to extract timestamp from key {key}: {e}")

        return None

    async def get(
        self, service: str, machine: str, timestamp_bucket: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Get cached metrics data

        Args:
            service: Service name
            machine: Machine hostname
            timestamp_bucket: Time bucket (optional)

        Returns:
            Cached data or None if not found/expired
        """
        if not self.redis_client:
            logger.warning("Redis client not initialized")
            return None

        key = self._make_cache_key(service, machine, timestamp_bucket)

        try:
            # Get value and TTL
            async with self._lock:
                self.stats.total_requests += 1

                value = await self.redis_client.get(key)

                if value is None:
                    self.stats.misses += 1
                    logger.debug(f"Cache MISS: {key}")
                    return None

                # Check TTL and trigger background refresh if needed
                ttl = await self.redis_client.ttl(key)

                if ttl > 0 and ttl < self.refresh_threshold and self.enable_background_refresh:
                    # Schedule background refresh
                    await self._schedule_refresh(key, service, machine, timestamp_bucket)

                self.stats.hits += 1
                logger.debug(f"Cache HIT: {key} (TTL: {ttl}s)")

                # Parse and return JSON data
                return json.loads(value)

        except json.JSONDecodeError as e:
            logger.error(f"Failed to decode cached value for {key}: {e}")
            self.stats.errors += 1
            return None

        except Exception as e:
            logger.error(f"Error getting cache value for {key}: {e}")
            self.stats.errors += 1
            return None

    async def set(
        self,
        service: str,
        machine: str,
        data: Dict[str, Any],
        timestamp_bucket: Optional[str] = None,
        ttl: Optional[int] = None,
    ) -> bool:
        """
        Set cached metrics data

        Args:
            service: Service name
            machine: Machine hostname
            data: Metrics data to cache
            timestamp_bucket: Time bucket (optional)
            ttl: Custom TTL in seconds (optional, defaults to configured TTL)

        Returns:
            True if successful
        """
        if not self.redis_client:
            logger.warning("Redis client not initialized")
            return False

        key = self._make_cache_key(service, machine, timestamp_bucket)
        ttl = ttl or self.ttl_seconds

        try:
            # Add metadata
            cache_data = {
                "data": data,
                "cached_at": utcnow().isoformat(),
                "service": service,
                "machine": machine,
                "timestamp_bucket": timestamp_bucket or "current",
            }

            # Serialize to JSON
            value = json.dumps(cache_data, default=str)

            # Set with TTL
            async with self._lock:
                await self.redis_client.setex(key, ttl, value)
                self.stats.sets += 1

            logger.debug(f"Cache SET: {key} (TTL: {ttl}s)")
            return True

        except Exception as e:
            logger.error(f"Error setting cache value for {key}: {e}")
            self.stats.errors += 1
            return False

    async def invalidate(
        self,
        service: Optional[str] = None,
        machine: Optional[str] = None,
        strategy: CacheInvalidationStrategy = CacheInvalidationStrategy.PATTERN,
    ) -> int:
        """
        Invalidate cache entries based on strategy

        Args:
            service: Service name (optional, required for PATTERN strategy)
            machine: Machine hostname (optional, required for PATTERN strategy)
            strategy: Invalidation strategy

        Returns:
            Number of keys invalidated
        """
        if not self.redis_client:
            logger.warning("Redis client not initialized")
            return 0

        try:
            deleted_count = 0

            if strategy == CacheInvalidationStrategy.ALL:
                # Delete all metrics cache keys
                pattern = f"{self.KEY_PREFIX}:*"
                keys = await self._scan_keys(pattern)

                if keys:
                    deleted_count = await self.redis_client.delete(*keys)

            elif strategy == CacheInvalidationStrategy.PATTERN:
                # Delete keys matching service/machine pattern
                if service and machine:
                    pattern = f"{self.KEY_PREFIX}:{service}:{machine}:*"
                elif service:
                    pattern = f"{self.KEY_PREFIX}:{service}:*"
                elif machine:
                    pattern = f"{self.KEY_PREFIX}:*:{machine}:*"
                else:
                    pattern = f"{self.KEY_PREFIX}:*"

                keys = await self._scan_keys(pattern)

                if keys:
                    deleted_count = await self.redis_client.delete(*keys)

            async with self._lock:
                self.stats.deletes += deleted_count

            logger.info(
                f"Cache INVALIDATE: strategy={strategy.value}, "
                f"service={service}, machine={machine}, deleted={deleted_count}"
            )

            return deleted_count

        except Exception as e:
            logger.error(f"Error invalidating cache: {e}")
            self.stats.errors += 1
            return 0

    async def _scan_keys(self, pattern: str) -> List[str]:
        """
        Scan for keys matching pattern (cursor-based for large datasets)

        Args:
            pattern: Redis key pattern

        Returns:
            List of matching keys
        """
        keys = []
        cursor = 0

        try:
            while True:
                cursor, batch = await self.redis_client.scan(
                    cursor=cursor, match=pattern, count=100
                )
                keys.extend(batch)

                if cursor == 0:
                    break

            return keys

        except Exception as e:
            logger.error(f"Error scanning keys with pattern {pattern}: {e}")
            return []

    async def _schedule_refresh(
        self, key: str, service: str, machine: str, timestamp_bucket: Optional[str]
    ):
        """
        Schedule background refresh for a cache entry

        Args:
            key: Cache key
            service: Service name
            machine: Machine hostname
            timestamp_bucket: Time bucket
        """
        # Don't schedule if already refreshing
        if key in self.refresh_tasks and not self.refresh_tasks[key].done():
            return

        # Check if we have a refresh callback registered
        refresh_key = f"{service}:{machine}"

        if refresh_key not in self.refresh_callbacks:
            logger.debug(f"No refresh callback registered for {refresh_key}")
            return

        # Create refresh task
        task = asyncio.create_task(
            self._refresh_cache_entry(key, service, machine, timestamp_bucket)
        )

        self.refresh_tasks[key] = task
        logger.debug(f"Scheduled background refresh for {key}")

    async def _refresh_cache_entry(
        self, key: str, service: str, machine: str, timestamp_bucket: Optional[str]
    ):
        """
        Background task to refresh a cache entry

        Args:
            key: Cache key
            service: Service name
            machine: Machine hostname
            timestamp_bucket: Time bucket
        """
        try:
            refresh_key = f"{service}:{machine}"
            callback = self.refresh_callbacks.get(refresh_key)

            if not callback:
                logger.warning(f"No callback found for refresh key {refresh_key}")
                return

            # Call the refresh callback to get fresh data
            logger.debug(f"Refreshing cache entry: {key}")
            fresh_data = await callback(service, machine)

            if fresh_data:
                # Update cache with fresh data
                await self.set(service, machine, fresh_data, timestamp_bucket)

                async with self._lock:
                    self.stats.refreshes += 1

                logger.info(f"Successfully refreshed cache entry: {key}")
            else:
                logger.warning(f"Refresh callback returned no data for {key}")

        except Exception as e:
            logger.error(f"Error refreshing cache entry {key}: {e}")
            self.stats.errors += 1

        finally:
            # Cleanup task reference
            if key in self.refresh_tasks:
                del self.refresh_tasks[key]

    def register_refresh_callback(
        self, service: str, machine: str, callback: Callable[[str, str], Any]
    ):
        """
        Register a callback function for background cache refresh

        Args:
            service: Service name
            machine: Machine hostname
            callback: Async function to fetch fresh data (service, machine) -> data
        """
        refresh_key = f"{service}:{machine}"
        self.refresh_callbacks[refresh_key] = callback
        logger.debug(f"Registered refresh callback for {refresh_key}")

    def unregister_refresh_callback(self, service: str, machine: str):
        """
        Unregister a refresh callback

        Args:
            service: Service name
            machine: Machine hostname
        """
        refresh_key = f"{service}:{machine}"

        if refresh_key in self.refresh_callbacks:
            del self.refresh_callbacks[refresh_key]
            logger.debug(f"Unregistered refresh callback for {refresh_key}")

    async def get_stats(self) -> Dict[str, Any]:
        """
        Get cache statistics

        Returns:
            Dictionary with cache stats
        """
        stats_dict = self.stats.to_dict()

        # Add Redis info if available
        if self.redis_client:
            try:
                redis_info = await self.redis_client.info("stats")
                stats_dict["redis"] = {
                    "total_commands_processed": redis_info.get("total_commands_processed", 0),
                    "total_connections_received": redis_info.get("total_connections_received", 0),
                    "keyspace_hits": redis_info.get("keyspace_hits", 0),
                    "keyspace_misses": redis_info.get("keyspace_misses", 0),
                }
            except Exception as e:
                logger.warning(f"Failed to get Redis stats: {e}")

        # Add configuration
        stats_dict["config"] = {
            "ttl_seconds": self.ttl_seconds,
            "refresh_threshold": self.refresh_threshold,
            "background_refresh_enabled": self.enable_background_refresh,
            "active_refresh_tasks": len(self.refresh_tasks),
            "registered_callbacks": len(self.refresh_callbacks),
        }

        return stats_dict

    async def reset_stats(self):
        """Reset cache statistics"""
        async with self._lock:
            self.stats = CacheStats()
        logger.info("Cache statistics reset")

    async def health_check(self) -> Dict[str, Any]:
        """
        Perform health check on cache system

        Returns:
            Dictionary with health status
        """
        health = {"status": "healthy", "redis_connected": False, "errors": []}

        try:
            # Check Redis connection
            if self.redis_client:
                await self.redis_client.ping()
                health["redis_connected"] = True
            else:
                health["status"] = "unhealthy"
                health["errors"].append("Redis client not initialized")

        except Exception as e:
            health["status"] = "unhealthy"
            health["redis_connected"] = False
            health["errors"].append(f"Redis connection error: {str(e)}")

        # Check for high error rate
        if self.stats.total_requests > 0:
            error_rate = (self.stats.errors / self.stats.total_requests) * 100

            if error_rate > 10:  # More than 10% errors
                health["status"] = "degraded"
                health["errors"].append(f"High error rate: {error_rate:.2f}%")

        return health

    async def get_cache_size(self) -> Dict[str, Any]:
        """
        Get cache size information

        Returns:
            Dictionary with cache size stats
        """
        try:
            pattern = f"{self.KEY_PREFIX}:*"
            keys = await self._scan_keys(pattern)

            total_keys = len(keys)
            total_memory = 0

            # Sample keys to estimate memory (checking all could be expensive)
            sample_size = min(100, total_keys)

            if sample_size > 0:
                sample_keys = keys[:sample_size]

                for key in sample_keys:
                    try:
                        memory = await self.redis_client.memory_usage(key)
                        if memory:
                            total_memory += memory
                    except Exception:
                        pass

                # Extrapolate to all keys
                if sample_size > 0:
                    avg_memory = total_memory / sample_size
                    estimated_total = avg_memory * total_keys
                else:
                    estimated_total = 0
            else:
                estimated_total = 0

            return {
                "total_keys": total_keys,
                "estimated_memory_bytes": int(estimated_total),
                "estimated_memory_mb": round(estimated_total / (1024 * 1024), 2),
            }

        except Exception as e:
            logger.error(f"Error getting cache size: {e}")
            return {
                "total_keys": 0,
                "estimated_memory_bytes": 0,
                "estimated_memory_mb": 0,
                "error": str(e),
            }


# Decorator for easy cache integration
def cached(cache: MetricsCache, ttl: Optional[int] = None):
    """
    Decorator to cache function results

    Args:
        cache: MetricsCache instance
        ttl: Custom TTL (optional)

    Usage:
        @cached(cache_instance)
        async def get_metrics(service: str, machine: str):
            # ... fetch metrics ...
            return data
    """

    def decorator(func: Callable):
        @wraps(func)
        async def wrapper(service: str, machine: str, *args, **kwargs):
            # Try to get from cache
            cached_data = await cache.get(service, machine)

            if cached_data and "data" in cached_data:
                logger.debug(f"Returning cached result for {func.__name__}")
                return cached_data["data"]

            # Cache miss - execute function
            result = await func(service, machine, *args, **kwargs)

            # Store in cache
            if result:
                await cache.set(service, machine, result, ttl=ttl)

            return result

        return wrapper

    return decorator


# Example usage and integration
async def example_usage():
    """Example of how to use the MetricsCache"""

    # Initialize cache
    # redis_url can be set explicitly or will be constructed from environment variables
    cache = MetricsCache(
        redis_url=None,  # Will use REDIS_URL from env or construct from REDIS_HOST/PORT/DB
        ttl_seconds=300,  # 5 minutes
        refresh_threshold=240,  # Refresh at 4 minutes
        enable_background_refresh=True,
    )

    try:
        # Connect to Redis
        await cache.connect()

        # Define a data fetcher function
        async def fetch_metrics(service: str, machine: str) -> Dict[str, Any]:
            """Simulated metrics fetcher"""
            # In real usage, this would call the actual metrics service
            return {
                "cpu_percent": 45.2,
                "memory_mb": 1024.5,
                "timestamp": utcnow().isoformat(),
            }

        # Register refresh callback
        cache.register_refresh_callback("nginx", "web01", fetch_metrics)

        # Store metrics
        metrics_data = {
            "cpu_percent": 45.2,
            "memory_mb": 1024.5,
            "timestamp": utcnow().isoformat(),
        }

        await cache.set("nginx", "web01", metrics_data)

        # Retrieve metrics (cache hit)
        cached = await cache.get("nginx", "web01")
        print(f"Cached data: {cached}")

        # Get statistics
        stats = await cache.get_stats()
        print(f"Cache stats: {stats}")

        # Check health
        health = await cache.health_check()
        print(f"Health: {health}")

        # Invalidate cache
        await cache.invalidate("nginx", "web01", CacheInvalidationStrategy.PATTERN)

        # Get cache size
        size_info = await cache.get_cache_size()
        print(f"Cache size: {size_info}")

    finally:
        # Cleanup
        await cache.disconnect()


if __name__ == "__main__":
    # Run example
    asyncio.run(example_usage())
