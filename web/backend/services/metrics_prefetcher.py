"""
Background Prefetching System for Known Services

This module implements an intelligent background prefetching system that:
1. Loads registry.yml to discover all active services
2. Prefetches metrics every 2 minutes for active services
3. Uses predictive caching based on access patterns
4. Runs as a background task without blocking the main application
5. Adapts prefetching strategy based on usage patterns
"""

import asyncio
import json
import logging
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml

from utils.datetime_utils import utcnow
from utils.validation import FilePathValidator

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("MetricsPrefetcher")


@dataclass
class AccessPattern:
    """Tracks access patterns for a service"""

    service_name: str
    machine: str
    access_count: int = 0
    last_access: Optional[datetime] = None
    access_times: deque = field(default_factory=lambda: deque(maxlen=100))
    cache_hits: int = 0
    cache_misses: int = 0
    prefetch_success: int = 0
    prefetch_failures: int = 0

    def record_access(self):
        """Record an access to this service"""
        now = utcnow()
        self.access_count += 1
        self.last_access = now
        self.access_times.append(now)

    def record_cache_hit(self):
        """Record a cache hit"""
        self.cache_hits += 1

    def record_cache_miss(self):
        """Record a cache miss"""
        self.cache_misses += 1

    def get_access_frequency(self, window_minutes: int = 60) -> float:
        """
        Calculate access frequency (accesses per minute) within a time window

        Args:
            window_minutes: Time window to analyze

        Returns:
            Accesses per minute
        """
        if not self.access_times:
            return 0.0

        cutoff = utcnow() - timedelta(minutes=window_minutes)
        recent_accesses = [t for t in self.access_times if t > cutoff]

        if not recent_accesses:
            return 0.0

        return len(recent_accesses) / window_minutes

    def get_priority_score(self) -> float:
        """
        Calculate priority score for prefetching

        Higher scores = higher priority
        Factors:
        - Recent access frequency (most important)
        - Total access count
        - Cache hit ratio (higher = more valuable to prefetch)
        - Time since last access (recency)
        """
        # Base score from frequency (0-100 scale)
        frequency_score = min(self.get_access_frequency(60) * 10, 100)

        # Recency bonus (0-50 scale)
        recency_score = 0.0
        if self.last_access:
            minutes_since = (utcnow() - self.last_access).total_seconds() / 60
            # Exponential decay: recent accesses get higher scores
            recency_score = 50 * (0.95**minutes_since)

        # Cache effectiveness bonus (0-30 scale)
        total_cache_attempts = self.cache_hits + self.cache_misses
        cache_effectiveness = 0.0
        if total_cache_attempts > 0:
            hit_ratio = self.cache_hits / total_cache_attempts
            cache_effectiveness = 30 * hit_ratio

        # Total access weight (0-20 scale)
        access_weight = min(self.access_count / 10, 20)

        return frequency_score + recency_score + cache_effectiveness + access_weight

    def should_prefetch(self, threshold: float = 10.0) -> bool:
        """
        Determine if this service should be prefetched

        Args:
            threshold: Priority score threshold

        Returns:
            True if should prefetch
        """
        return self.get_priority_score() >= threshold


@dataclass
class PrefetchedData:
    """Container for prefetched metrics data"""

    service_name: str
    machine: str
    data: Any
    timestamp: datetime
    ttl_seconds: int = 120  # 2 minutes default TTL

    def is_expired(self) -> bool:
        """Check if the cached data has expired"""
        age_seconds = (utcnow() - self.timestamp).total_seconds()
        return age_seconds >= self.ttl_seconds

    def get_age_seconds(self) -> float:
        """Get age of cached data in seconds"""
        return (utcnow() - self.timestamp).total_seconds()


class MetricsPrefetcher:
    """
    Intelligent background prefetching system for service metrics

    Features:
    - Loads services from registry.yml
    - Prefetches metrics every 2 minutes for active services
    - Tracks access patterns to optimize prefetching
    - Adaptive prefetching based on usage
    - Non-blocking background operation
    """

    def __init__(
        self,
        registry_path: Optional[str] = None,
        prefetch_interval: int = 120,  # 2 minutes
        cache_ttl: int = 120,  # 2 minutes
        max_cache_size: int = 1000,
        pattern_analysis_interval: int = 300,  # 5 minutes
        min_priority_threshold: float = 5.0,
    ):
        """
        Initialize the metrics prefetcher

        Args:
            registry_path: Path to registry.yml
            prefetch_interval: Interval between prefetch cycles (seconds)
            cache_ttl: Time-to-live for cached data (seconds)
            max_cache_size: Maximum number of cached entries
            pattern_analysis_interval: How often to analyze patterns (seconds)
            min_priority_threshold: Minimum priority score to prefetch
        """
        # Default registry path: <repo-root>/registry.yml. services/metrics_prefetcher.py
        # -> parents[2] is the repo root.
        if registry_path is None:
            import os

            registry_path = os.getenv(
                "CADDY_REGISTRY_PATH",
                str(Path(__file__).resolve().parents[2] / "registry.yml"),
            )
        self.registry_path = Path(registry_path)
        self.prefetch_interval = prefetch_interval
        self.cache_ttl = cache_ttl
        self.max_cache_size = max_cache_size
        self.pattern_analysis_interval = pattern_analysis_interval
        self.min_priority_threshold = min_priority_threshold

        # State
        self.running = False
        self.prefetch_task: Optional[asyncio.Task] = None
        self.analysis_task: Optional[asyncio.Task] = None

        # Cache storage
        self.cache: Dict[str, PrefetchedData] = {}
        self.cache_lock = asyncio.Lock()

        # Access pattern tracking
        self.access_patterns: Dict[str, AccessPattern] = {}
        self.patterns_lock = asyncio.Lock()

        # Service discovery
        self.known_services: Set[Tuple[str, str]] = set()  # (service, machine) tuples
        self.registry_data: Dict[str, Any] = {}

        # Statistics
        self.stats = {
            "prefetch_cycles": 0,
            "total_prefetches": 0,
            "successful_prefetches": 0,
            "failed_prefetches": 0,
            "cache_hits": 0,
            "cache_misses": 0,
            "cache_evictions": 0,
            "pattern_analyses": 0,
            "services_discovered": 0,
        }

        logger.info("MetricsPrefetcher initialized:")
        logger.info(f"  Registry: {registry_path}")
        logger.info(f"  Prefetch interval: {prefetch_interval}s")
        logger.info(f"  Cache TTL: {cache_ttl}s")
        logger.info(f"  Max cache size: {max_cache_size}")

    async def start(self):
        """Start the background prefetching system"""
        if self.running:
            logger.warning("Prefetcher is already running")
            return

        logger.info("Starting MetricsPrefetcher...")
        self.running = True

        # Load initial service list
        await self.discover_services()

        # Start background tasks
        self.prefetch_task = asyncio.create_task(self._prefetch_loop())
        self.analysis_task = asyncio.create_task(self._pattern_analysis_loop())

        logger.info("MetricsPrefetcher started successfully")

    async def stop(self):
        """Stop the background prefetching system"""
        if not self.running:
            return

        logger.info("Stopping MetricsPrefetcher...")
        self.running = False

        # Cancel background tasks
        if self.prefetch_task:
            self.prefetch_task.cancel()
            try:
                await self.prefetch_task
            except asyncio.CancelledError:
                pass

        if self.analysis_task:
            self.analysis_task.cancel()
            try:
                await self.analysis_task
            except asyncio.CancelledError:
                pass

        logger.info("MetricsPrefetcher stopped")
        logger.info(f"Final statistics: {json.dumps(self.stats, indent=2)}")

    async def discover_services(self) -> List[Tuple[str, str]]:
        """
        Discover services from registry.yml

        Returns:
            List of (service_name, machine) tuples
        """
        try:
            # Check if registry file exists and is readable
            registry_path = FilePathValidator.check_file_exists(
                str(self.registry_path), "registry.yml"
            )

            with open(registry_path, "r") as f:
                self.registry_data = yaml.safe_load(f) or {}

            services_config = self.registry_data.get("services", {})
            discovered = []

            for service_name, config in services_config.items():
                machine = config.get("current_host")
                if machine:
                    service_tuple = (service_name, machine)
                    discovered.append(service_tuple)
                    self.known_services.add(service_tuple)

                    # Initialize access pattern if not exists
                    key = self._make_key(service_name, machine)
                    if key not in self.access_patterns:
                        self.access_patterns[key] = AccessPattern(
                            service_name=service_name, machine=machine
                        )

            self.stats["services_discovered"] = len(discovered)
            logger.info(f"Discovered {len(discovered)} services from registry")

            return discovered

        except Exception as e:
            logger.error(f"Failed to discover services: {e}")
            return []

    def _make_key(self, service: str, machine: str) -> str:
        """Create cache key from service and machine"""
        return f"{service}@{machine}"

    async def get_cached_data(self, service: str, machine: str) -> Optional[PrefetchedData]:
        """
        Get cached data for a service

        Args:
            service: Service name
            machine: Machine hostname

        Returns:
            PrefetchedData if cached and not expired, None otherwise
        """
        key = self._make_key(service, machine)

        # Track access pattern
        async with self.patterns_lock:
            if key not in self.access_patterns:
                self.access_patterns[key] = AccessPattern(service_name=service, machine=machine)
            self.access_patterns[key].record_access()

        async with self.cache_lock:
            cached = self.cache.get(key)

            if cached:
                if not cached.is_expired():
                    # Cache hit
                    self.stats["cache_hits"] += 1
                    async with self.patterns_lock:
                        self.access_patterns[key].record_cache_hit()

                    logger.debug(f"Cache HIT for {key} (age: {cached.get_age_seconds():.1f}s)")
                    return cached
                else:
                    # Expired, remove from cache
                    del self.cache[key]
                    logger.debug(f"Cache entry expired for {key}")

            # Cache miss
            self.stats["cache_misses"] += 1
            async with self.patterns_lock:
                self.access_patterns[key].record_cache_miss()

            logger.debug(f"Cache MISS for {key}")
            return None

    async def store_cached_data(self, service: str, machine: str, data: Any):
        """
        Store data in cache

        Args:
            service: Service name
            machine: Machine hostname
            data: Data to cache
        """
        key = self._make_key(service, machine)

        async with self.cache_lock:
            # Check cache size and evict if necessary
            if len(self.cache) >= self.max_cache_size:
                await self._evict_old_entries()

            cached_data = PrefetchedData(
                service_name=service,
                machine=machine,
                data=data,
                timestamp=utcnow(),
                ttl_seconds=self.cache_ttl,
            )

            self.cache[key] = cached_data
            logger.debug(f"Stored data in cache for {key}")

    async def _evict_old_entries(self):
        """Evict oldest cache entries to maintain max size"""
        if not self.cache:
            return

        # Sort by timestamp (oldest first)
        sorted_entries = sorted(self.cache.items(), key=lambda x: x[1].timestamp)

        # Remove oldest 20% of entries
        num_to_evict = max(1, len(sorted_entries) // 5)

        for i in range(num_to_evict):
            key, _ = sorted_entries[i]
            del self.cache[key]
            self.stats["cache_evictions"] += 1

        logger.debug(f"Evicted {num_to_evict} old cache entries")

    async def _prefetch_loop(self):
        """Main prefetch loop - runs every prefetch_interval seconds"""
        logger.info("Prefetch loop started")

        while self.running:
            try:
                await self._prefetch_cycle()
                await asyncio.sleep(self.prefetch_interval)
            except asyncio.CancelledError:
                logger.info("Prefetch loop cancelled")
                break
            except Exception as e:
                logger.error(f"Error in prefetch loop: {e}")
                await asyncio.sleep(self.prefetch_interval)

    async def _prefetch_cycle(self):
        """Execute one prefetch cycle"""
        start_time = time.time()
        self.stats["prefetch_cycles"] += 1

        logger.info(f"Starting prefetch cycle #{self.stats['prefetch_cycles']}")

        # Refresh service discovery
        await self.discover_services()

        # Get prioritized list of services to prefetch
        services_to_prefetch = await self._get_prefetch_targets()

        if not services_to_prefetch:
            logger.info("No services to prefetch this cycle")
            return

        logger.info(f"Prefetching {len(services_to_prefetch)} services")

        # Prefetch in parallel (with concurrency limit)
        semaphore = asyncio.Semaphore(5)  # Max 5 concurrent prefetches

        tasks = [
            self._prefetch_service(service, machine, semaphore)
            for service, machine in services_to_prefetch
        ]

        await asyncio.gather(*tasks, return_exceptions=True)

        elapsed = time.time() - start_time
        logger.info(f"Prefetch cycle completed in {elapsed:.2f}s. Cache size: {len(self.cache)}")

    async def _get_prefetch_targets(self) -> List[Tuple[str, str]]:
        """
        Determine which services should be prefetched based on access patterns

        Returns:
            List of (service, machine) tuples sorted by priority
        """
        async with self.patterns_lock:
            # Calculate priority for each service
            priorities = []

            for key, pattern in self.access_patterns.items():
                if pattern.should_prefetch(self.min_priority_threshold):
                    priorities.append(
                        (pattern.get_priority_score(), pattern.service_name, pattern.machine)
                    )

            # Sort by priority (highest first)
            priorities.sort(reverse=True)

            # Return top services (limit to reasonable number)
            max_prefetch = min(len(priorities), 50)
            targets = [(s, m) for _, s, m in priorities[:max_prefetch]]

            logger.debug(
                f"Selected {len(targets)} services for prefetching "
                f"(from {len(priorities)} eligible)"
            )

            return targets

    async def _prefetch_service(self, service: str, machine: str, semaphore: asyncio.Semaphore):
        """
        Prefetch metrics for a single service

        Args:
            service: Service name
            machine: Machine hostname
            semaphore: Concurrency control
        """
        async with semaphore:
            key = self._make_key(service, machine)

            try:
                # Simulate fetching metrics
                # In production, this would call the actual metrics service
                data = await self._fetch_metrics_data(service, machine)

                if data:
                    await self.store_cached_data(service, machine, data)
                    self.stats["successful_prefetches"] += 1
                    self.stats["total_prefetches"] += 1

                    async with self.patterns_lock:
                        if key in self.access_patterns:
                            self.access_patterns[key].prefetch_success += 1

                    logger.debug(f"Successfully prefetched {key}")
                else:
                    raise Exception("No data returned")

            except Exception as e:
                self.stats["failed_prefetches"] += 1
                self.stats["total_prefetches"] += 1

                async with self.patterns_lock:
                    if key in self.access_patterns:
                        self.access_patterns[key].prefetch_failures += 1

                logger.warning(f"Failed to prefetch {key}: {e}")

    async def _fetch_metrics_data(self, service: str, machine: str) -> Optional[Dict]:
        """
        Fetch metrics data for a service

        In production, this would interface with the actual MetricsService
        For this implementation, we simulate the data fetching

        Args:
            service: Service name
            machine: Machine hostname

        Returns:
            Metrics data dictionary or None on error
        """
        # Simulate network delay
        await asyncio.sleep(0.1)

        # Simulate 95% success rate
        import random

        if random.random() < 0.95:
            # Return mock metrics data
            return {
                "service": service,
                "machine": machine,
                "timestamp": utcnow().isoformat(),
                "cpu_percent": random.uniform(0, 100),
                "memory_mb": random.uniform(100, 8000),
                "status": "ok",
            }
        else:
            return None

    async def _pattern_analysis_loop(self):
        """Background loop for analyzing access patterns"""
        logger.info("Pattern analysis loop started")

        while self.running:
            try:
                await asyncio.sleep(self.pattern_analysis_interval)
                await self._analyze_patterns()
            except asyncio.CancelledError:
                logger.info("Pattern analysis loop cancelled")
                break
            except Exception as e:
                logger.error(f"Error in pattern analysis loop: {e}")

    async def _analyze_patterns(self):
        """Analyze access patterns and adjust prefetching strategy"""
        self.stats["pattern_analyses"] += 1

        logger.info("Analyzing access patterns...")

        async with self.patterns_lock:
            total_patterns = len(self.access_patterns)
            active_patterns = 0
            high_priority = 0

            for pattern in self.access_patterns.values():
                freq = pattern.get_access_frequency(60)
                if freq > 0:
                    active_patterns += 1

                if pattern.get_priority_score() >= self.min_priority_threshold:
                    high_priority += 1

            # Calculate cache effectiveness
            total_cache_ops = self.stats["cache_hits"] + self.stats["cache_misses"]
            hit_rate = 0.0
            if total_cache_ops > 0:
                hit_rate = (self.stats["cache_hits"] / total_cache_ops) * 100

            logger.info(
                f"Pattern analysis results:\n"
                f"  Total patterns tracked: {total_patterns}\n"
                f"  Active patterns (accessed in last hour): {active_patterns}\n"
                f"  High-priority services: {high_priority}\n"
                f"  Cache hit rate: {hit_rate:.1f}%\n"
                f"  Cache size: {len(self.cache)}/{self.max_cache_size}\n"
                f"  Prefetch success rate: "
                f"{self._calculate_prefetch_success_rate():.1f}%"
            )

    def _calculate_prefetch_success_rate(self) -> float:
        """Calculate prefetch success rate as percentage"""
        total = self.stats["total_prefetches"]
        if total == 0:
            return 0.0
        return (self.stats["successful_prefetches"] / total) * 100

    def get_statistics(self) -> Dict[str, Any]:
        """
        Get current prefetcher statistics

        Returns:
            Dictionary with statistics
        """
        total_cache_ops = self.stats["cache_hits"] + self.stats["cache_misses"]
        hit_rate = 0.0
        if total_cache_ops > 0:
            hit_rate = (self.stats["cache_hits"] / total_cache_ops) * 100

        return {
            "running": self.running,
            "configuration": {
                "prefetch_interval": self.prefetch_interval,
                "cache_ttl": self.cache_ttl,
                "max_cache_size": self.max_cache_size,
                "pattern_analysis_interval": self.pattern_analysis_interval,
                "min_priority_threshold": self.min_priority_threshold,
            },
            "statistics": {
                **self.stats,
                "cache_hit_rate": hit_rate,
                "prefetch_success_rate": self._calculate_prefetch_success_rate(),
                "current_cache_size": len(self.cache),
                "tracked_patterns": len(self.access_patterns),
            },
        }

    def get_service_pattern(self, service: str, machine: str) -> Optional[Dict]:
        """
        Get access pattern information for a service

        Args:
            service: Service name
            machine: Machine hostname

        Returns:
            Pattern information dictionary or None
        """
        key = self._make_key(service, machine)
        pattern = self.access_patterns.get(key)

        if not pattern:
            return None

        return {
            "service": service,
            "machine": machine,
            "access_count": pattern.access_count,
            "last_access": pattern.last_access.isoformat() if pattern.last_access else None,
            "cache_hits": pattern.cache_hits,
            "cache_misses": pattern.cache_misses,
            "cache_hit_rate": (
                (pattern.cache_hits / (pattern.cache_hits + pattern.cache_misses) * 100)
                if (pattern.cache_hits + pattern.cache_misses) > 0
                else 0.0
            ),
            "access_frequency_per_minute": pattern.get_access_frequency(60),
            "priority_score": pattern.get_priority_score(),
            "should_prefetch": pattern.should_prefetch(self.min_priority_threshold),
            "prefetch_success": pattern.prefetch_success,
            "prefetch_failures": pattern.prefetch_failures,
        }


async def main():
    """Main entry point for standalone testing"""
    print("=" * 70)
    print("MetricsPrefetcher - Background Prefetching System")
    print("=" * 70)
    print()

    # Initialize prefetcher (registry_path defaults to <repo-root>/registry.yml,
    # overridable via CADDY_REGISTRY_PATH env var).
    prefetcher = MetricsPrefetcher(
        prefetch_interval=120,  # 2 minutes
        cache_ttl=120,
        max_cache_size=1000,
        pattern_analysis_interval=300,  # 5 minutes
        min_priority_threshold=5.0,
    )

    # Start prefetching
    await prefetcher.start()

    print("\nPrefetcher started. Simulating access patterns...")
    print("Press Ctrl+C to stop\n")

    try:
        # Simulate some access patterns
        services = list(prefetcher.known_services)[:10]  # Take first 10 services

        for i in range(30):  # Simulate 30 accesses over time
            if services:
                import random

                service, machine = random.choice(services)

                # Simulate accessing the service
                cached_data = await prefetcher.get_cached_data(service, machine)

                if cached_data:
                    print(f"[{i + 1}] Retrieved cached data for {service}@{machine}")
                else:
                    print(f"[{i + 1}] Cache miss for {service}@{machine}")

                # Simulate some services being accessed more frequently
                if random.random() < 0.3 and len(services) > 0:
                    service, machine = services[0]  # First service gets accessed more
                    await prefetcher.get_cached_data(service, machine)

            await asyncio.sleep(2)

        # Display final statistics
        print("\n" + "=" * 70)
        print("Final Statistics:")
        print("=" * 70)
        stats = prefetcher.get_statistics()
        print(json.dumps(stats, indent=2, default=str))

        # Show some service patterns
        print("\n" + "=" * 70)
        print("Top Service Access Patterns:")
        print("=" * 70)
        for service, machine in services[:5]:
            pattern = prefetcher.get_service_pattern(service, machine)
            if pattern:
                print(f"\n{service}@{machine}:")
                print(f"  Access count: {pattern['access_count']}")
                print(f"  Priority score: {pattern['priority_score']:.2f}")
                print(f"  Should prefetch: {pattern['should_prefetch']}")
                print(f"  Cache hit rate: {pattern['cache_hit_rate']:.1f}%")

    except KeyboardInterrupt:
        print("\n\nReceived interrupt signal, stopping prefetcher...")

    finally:
        # Stop prefetcher
        await prefetcher.stop()
        print("\nPrefetcher stopped cleanly")


if __name__ == "__main__":
    asyncio.run(main())
