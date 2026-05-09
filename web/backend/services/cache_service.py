"""Cache service with TTL support for reducing file I/O operations"""

import logging
import time
from dataclasses import dataclass
from functools import wraps
from threading import Lock
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger(__name__)


@dataclass
class CacheEntry:
    """Cache entry with value, timestamp, and TTL"""

    value: Any
    timestamp: float
    ttl: float

    def is_expired(self) -> bool:
        """Check if cache entry has expired"""
        return time.time() - self.timestamp > self.ttl


class CacheMetrics:
    """Metrics tracking for cache performance"""

    def __init__(self):
        self.hits = 0
        self.misses = 0
        self.invalidations = 0
        self.lock = Lock()

    def record_hit(self):
        """Record a cache hit"""
        with self.lock:
            self.hits += 1

    def record_miss(self):
        """Record a cache miss"""
        with self.lock:
            self.misses += 1

    def record_invalidation(self):
        """Record a cache invalidation"""
        with self.lock:
            self.invalidations += 1

    def get_hit_rate(self) -> float:
        """Calculate cache hit rate as percentage"""
        with self.lock:
            total = self.hits + self.misses
            if total == 0:
                return 0.0
            return (self.hits / total) * 100

    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics"""
        with self.lock:
            total = self.hits + self.misses
            return {
                "hits": self.hits,
                "misses": self.misses,
                "invalidations": self.invalidations,
                "total_requests": total,
                "hit_rate": self.get_hit_rate(),
            }

    def reset(self):
        """Reset all metrics"""
        with self.lock:
            self.hits = 0
            self.misses = 0
            self.invalidations = 0


class TTLCache:
    """Time-To-Live cache for storing temporary data"""

    def __init__(self, default_ttl: float = 30.0):
        """
        Initialize TTL cache

        Args:
            default_ttl: Default time-to-live in seconds
        """
        self.default_ttl = default_ttl
        self._cache: Dict[str, CacheEntry] = {}
        self._lock = Lock()
        self.metrics = CacheMetrics()
        logger.info(f"TTL cache initialized with {default_ttl}s TTL")

    def get(self, key: str) -> Optional[Any]:
        """
        Get value from cache if not expired

        Args:
            key: Cache key

        Returns:
            Cached value or None if expired/missing
        """
        with self._lock:
            if key not in self._cache:
                self.metrics.record_miss()
                logger.debug(f"Cache miss: {key}")
                return None

            entry = self._cache[key]
            if entry.is_expired():
                del self._cache[key]
                self.metrics.record_miss()
                logger.debug(f"Cache expired: {key}")
                return None

            self.metrics.record_hit()
            logger.debug(f"Cache hit: {key}")
            return entry.value

    def set(self, key: str, value: Any, ttl: Optional[float] = None):
        """
        Set value in cache with TTL

        Args:
            key: Cache key
            value: Value to cache
            ttl: Time-to-live in seconds (uses default if None)
        """
        with self._lock:
            entry = CacheEntry(
                value=value, timestamp=time.time(), ttl=ttl if ttl is not None else self.default_ttl
            )
            self._cache[key] = entry
            logger.debug(f"Cache set: {key} (TTL: {entry.ttl}s)")

    def invalidate(self, key: str) -> bool:
        """
        Invalidate (remove) a cache entry

        Args:
            key: Cache key to invalidate

        Returns:
            True if entry was removed, False if not found
        """
        with self._lock:
            if key in self._cache:
                del self._cache[key]
                self.metrics.record_invalidation()
                logger.info(f"Cache invalidated: {key}")
                return True
            return False

    def invalidate_pattern(self, pattern: str) -> int:
        """
        Invalidate all cache entries matching pattern

        Args:
            pattern: String pattern to match (simple substring match)

        Returns:
            Number of entries invalidated
        """
        with self._lock:
            keys_to_remove = [k for k in self._cache.keys() if pattern in k]
            for key in keys_to_remove:
                del self._cache[key]
                self.metrics.record_invalidation()

            if keys_to_remove:
                logger.info(f"Cache pattern invalidated: {pattern} ({len(keys_to_remove)} entries)")
            return len(keys_to_remove)

    def clear(self):
        """Clear all cache entries"""
        with self._lock:
            count = len(self._cache)
            self._cache.clear()
            logger.info(f"Cache cleared: {count} entries removed")

    def cleanup_expired(self) -> int:
        """
        Remove all expired entries

        Returns:
            Number of entries removed
        """
        with self._lock:
            expired_keys = [k for k, v in self._cache.items() if v.is_expired()]
            for key in expired_keys:
                del self._cache[key]

            if expired_keys:
                logger.debug(f"Cleaned up {len(expired_keys)} expired cache entries")
            return len(expired_keys)

    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics including metrics"""
        with self._lock:
            active_entries = len(self._cache)
            expired_count = sum(1 for v in self._cache.values() if v.is_expired())

            return {
                "active_entries": active_entries,
                "expired_entries": expired_count,
                **self.metrics.get_stats(),
            }


def cached(
    cache_instance: TTLCache, key_func: Optional[Callable] = None, ttl: Optional[float] = None
):
    """
    Decorator for caching function results

    Args:
        cache_instance: TTLCache instance to use
        key_func: Function to generate cache key from args/kwargs
        ttl: Time-to-live override

    Example:
        @cached(my_cache, lambda: "my_key", ttl=60)
        def expensive_operation():
            return perform_calculation()
    """

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            # Generate cache key
            if key_func:
                cache_key = key_func(*args, **kwargs)
            else:
                cache_key = f"{func.__name__}:{args}:{kwargs}"

            # Try to get from cache
            cached_value = cache_instance.get(cache_key)
            if cached_value is not None:
                return cached_value

            # Execute function and cache result
            result = func(*args, **kwargs)
            cache_instance.set(cache_key, result, ttl=ttl)
            return result

        return wrapper

    return decorator


# Global cache instances
_registry_cache: Optional[TTLCache] = None


def get_registry_cache(ttl: float = 30.0) -> TTLCache:
    """
    Get or create global registry cache instance

    Args:
        ttl: Time-to-live for cache entries in seconds

    Returns:
        TTLCache instance for registry data
    """
    global _registry_cache
    if _registry_cache is None:
        _registry_cache = TTLCache(default_ttl=ttl)
        logger.info("Global registry cache initialized")
    return _registry_cache


def invalidate_registry_cache():
    """Invalidate all registry-related cache entries"""
    if _registry_cache:
        _registry_cache.invalidate_pattern("registry")
        logger.info("Registry cache invalidated")
