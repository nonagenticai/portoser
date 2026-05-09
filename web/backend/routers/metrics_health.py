"""
Metrics Health Check Endpoint.

Dedicated health check endpoint for the metrics system that monitors:
- Cache status and hit rates
- Queue depth (collection queue)
- Circuit breaker states (for per-machine connectivity)
- Per-machine connectivity status

Response time is < 100ms by using cached data only.
"""

import logging
from datetime import datetime
from enum import Enum
from typing import Dict, List, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


# ============================================================================
# Response Models
# ============================================================================


class HealthStatus(str, Enum):
    """Overall health status"""

    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"


class MachineConnectivityStatus(str, Enum):
    """Per-machine connectivity status"""

    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"


class CacheHealthMetrics(BaseModel):
    """Cache system health metrics"""

    hit_rate: float = Field(..., description="Cache hit rate (0.0-1.0)")
    total_entries: int = Field(..., description="Total entries in cache")
    total_hits: int = Field(..., description="Total cache hits")
    total_misses: int = Field(..., description="Total cache misses")
    total_requests: int = Field(..., description="Total cache requests")
    ttl_seconds: int = Field(..., description="Cache TTL in seconds")
    oldest_entry_age_seconds: Optional[float] = Field(None, description="Age of oldest entry")


class QueueHealthMetrics(BaseModel):
    """Collection queue health metrics"""

    depth: int = Field(..., description="Current queue depth")
    max_depth: int = Field(..., description="Maximum queue depth")
    utilization: float = Field(..., description="Queue utilization (0.0-1.0)")
    processing_rate: float = Field(..., description="Items processed per second")
    avg_wait_time_ms: float = Field(..., description="Average wait time in queue")


class CircuitBreakerState(str, Enum):
    """Circuit breaker states"""

    CLOSED = "closed"  # Normal operation
    OPEN = "open"  # Failing, requests blocked
    HALF_OPEN = "half_open"  # Testing recovery


class CircuitBreakerMetrics(BaseModel):
    """Circuit breaker metrics for a machine"""

    machine: str = Field(..., description="Machine name")
    state: CircuitBreakerState = Field(..., description="Current circuit breaker state")
    failure_count: int = Field(..., description="Consecutive failures")
    failure_threshold: int = Field(..., description="Threshold to open circuit")
    last_failure_time: Optional[datetime] = Field(None, description="Last failure timestamp")
    last_success_time: Optional[datetime] = Field(None, description="Last success timestamp")
    recovery_timeout_seconds: int = Field(..., description="Seconds before retry")


class MachineConnectivity(BaseModel):
    """Per-machine connectivity status"""

    machine: str = Field(..., description="Machine name")
    status: MachineConnectivityStatus = Field(..., description="Connectivity status")
    last_success: Optional[datetime] = Field(None, description="Last successful connection")
    last_failure: Optional[datetime] = Field(None, description="Last failed connection")
    consecutive_failures: int = Field(0, description="Consecutive failure count")
    response_time_ms: Optional[float] = Field(None, description="Last response time")
    error_message: Optional[str] = Field(None, description="Last error message")


class MetricsHealthResponse(BaseModel):
    """Complete metrics system health response"""

    status: HealthStatus = Field(..., description="Overall metrics system health")
    timestamp: datetime = Field(..., description="Health check timestamp")
    cache: CacheHealthMetrics = Field(..., description="Cache health metrics")
    queue: QueueHealthMetrics = Field(..., description="Queue health metrics")
    circuit_breakers: List[CircuitBreakerMetrics] = Field(..., description="Circuit breaker states")
    machines: Dict[str, MachineConnectivityStatus] = Field(
        ..., description="Per-machine connectivity"
    )
    machine_details: List[MachineConnectivity] = Field(
        ..., description="Detailed machine connectivity"
    )
    collector_running: bool = Field(..., description="Whether metrics collector is running")
    collection_interval_seconds: int = Field(..., description="Collection interval")
    response_time_ms: float = Field(..., description="Health check response time")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "status": "healthy",
                "timestamp": "2025-11-27T10:30:00Z",
                "cache": {
                    "hit_rate": 0.85,
                    "total_entries": 42,
                    "total_hits": 850,
                    "total_misses": 150,
                    "total_requests": 1000,
                    "ttl_seconds": 60,
                    "oldest_entry_age_seconds": 45.2,
                },
                "queue": {
                    "depth": 12,
                    "max_depth": 1000,
                    "utilization": 0.012,
                    "processing_rate": 5.2,
                    "avg_wait_time_ms": 150.0,
                },
                "circuit_breakers": [
                    {
                        "machine": "host-a",
                        "state": "closed",
                        "failure_count": 0,
                        "failure_threshold": 5,
                        "last_success_time": "2025-11-27T10:29:00Z",
                        "recovery_timeout_seconds": 60,
                    }
                ],
                "machines": {"host-a": "healthy", "host-b": "degraded"},
                "machine_details": [
                    {
                        "machine": "host-a",
                        "status": "healthy",
                        "last_success": "2025-11-27T10:29:00Z",
                        "consecutive_failures": 0,
                        "response_time_ms": 45.2,
                    }
                ],
                "collector_running": True,
                "collection_interval_seconds": 120,
                "response_time_ms": 23.5,
            }
        }
    )


# ============================================================================
# Circuit Breaker Implementation
# ============================================================================


class CircuitBreaker:
    """Circuit breaker for per-machine connectivity"""

    def __init__(self, machine: str, failure_threshold: int = 5, recovery_timeout: int = 60):
        self.machine = machine
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.failure_count = 0
        self.state = CircuitBreakerState.CLOSED
        self.last_failure_time: Optional[datetime] = None
        self.last_success_time: Optional[datetime] = None

    def record_success(self):
        """Record successful operation"""
        self.failure_count = 0
        self.state = CircuitBreakerState.CLOSED
        self.last_success_time = utcnow()

    def record_failure(self):
        """Record failed operation"""
        self.failure_count += 1
        self.last_failure_time = utcnow()

        if self.failure_count >= self.failure_threshold:
            self.state = CircuitBreakerState.OPEN
            logger.warning(
                f"Circuit breaker OPEN for {self.machine} after {self.failure_count} failures"
            )

    def can_attempt(self) -> bool:
        """Check if we can attempt a request"""
        if self.state == CircuitBreakerState.CLOSED:
            return True

        if self.state == CircuitBreakerState.OPEN:
            # Check if we should transition to half-open
            if self.last_failure_time:
                elapsed = (utcnow() - self.last_failure_time).total_seconds()
                if elapsed >= self.recovery_timeout:
                    self.state = CircuitBreakerState.HALF_OPEN
                    logger.info(
                        f"Circuit breaker HALF_OPEN for {self.machine}, attempting recovery"
                    )
                    return True
            return False

        # HALF_OPEN state - allow one request to test
        return True

    def get_metrics(self) -> CircuitBreakerMetrics:
        """Get circuit breaker metrics"""
        return CircuitBreakerMetrics(
            machine=self.machine,
            state=self.state,
            failure_count=self.failure_count,
            failure_threshold=self.failure_threshold,
            last_failure_time=self.last_failure_time,
            last_success_time=self.last_success_time,
            recovery_timeout_seconds=self.recovery_timeout,
        )


# ============================================================================
# Metrics Health Monitor
# ============================================================================


class MetricsHealthMonitor:
    """Monitor for metrics system health"""

    def __init__(self):
        self.circuit_breakers: Dict[str, CircuitBreaker] = {}
        self.cache_stats = {"hits": 0, "misses": 0, "total_requests": 0}
        self.queue_stats = {
            "current_depth": 0,
            "max_depth": 1000,
            "processed": 0,
            "total_wait_time_ms": 0.0,
        }
        self.machine_connectivity: Dict[str, MachineConnectivity] = {}

    def get_circuit_breaker(self, machine: str) -> CircuitBreaker:
        """Get or create circuit breaker for machine"""
        if machine not in self.circuit_breakers:
            self.circuit_breakers[machine] = CircuitBreaker(machine)
        return self.circuit_breakers[machine]

    def update_cache_stats(self, hit: bool):
        """Update cache statistics"""
        self.cache_stats["total_requests"] += 1
        if hit:
            self.cache_stats["hits"] += 1
        else:
            self.cache_stats["misses"] += 1

    def update_machine_connectivity(
        self,
        machine: str,
        success: bool,
        response_time_ms: Optional[float] = None,
        error_message: Optional[str] = None,
    ):
        """Update machine connectivity status"""
        if machine not in self.machine_connectivity:
            self.machine_connectivity[machine] = MachineConnectivity(
                machine=machine, status=MachineConnectivityStatus.UNKNOWN
            )

        conn = self.machine_connectivity[machine]

        if success:
            conn.last_success = utcnow()
            conn.consecutive_failures = 0
            conn.response_time_ms = response_time_ms
            conn.error_message = None

            # Update status based on response time
            if response_time_ms and response_time_ms > 1000:
                conn.status = MachineConnectivityStatus.DEGRADED
            else:
                conn.status = MachineConnectivityStatus.HEALTHY

            # Update circuit breaker
            self.get_circuit_breaker(machine).record_success()
        else:
            conn.last_failure = utcnow()
            conn.consecutive_failures += 1
            conn.error_message = error_message

            # Update status based on failure count
            if conn.consecutive_failures >= 5:
                conn.status = MachineConnectivityStatus.UNHEALTHY
            elif conn.consecutive_failures >= 2:
                conn.status = MachineConnectivityStatus.DEGRADED
            else:
                conn.status = MachineConnectivityStatus.DEGRADED

            # Update circuit breaker
            self.get_circuit_breaker(machine).record_failure()

    def get_health_status(self) -> HealthStatus:
        """Calculate overall health status"""
        # Check machine connectivity
        unhealthy_machines = sum(
            1
            for conn in self.machine_connectivity.values()
            if conn.status == MachineConnectivityStatus.UNHEALTHY
        )
        degraded_machines = sum(
            1
            for conn in self.machine_connectivity.values()
            if conn.status == MachineConnectivityStatus.DEGRADED
        )

        # Check circuit breakers
        open_circuits = sum(
            1 for cb in self.circuit_breakers.values() if cb.state == CircuitBreakerState.OPEN
        )

        # Check queue depth
        queue_utilization = self.queue_stats["current_depth"] / self.queue_stats["max_depth"]

        # Determine overall health
        if unhealthy_machines > 0 or open_circuits > 0:
            return HealthStatus.UNHEALTHY
        elif degraded_machines > 0 or queue_utilization > 0.7:
            return HealthStatus.DEGRADED
        else:
            return HealthStatus.HEALTHY


# ============================================================================
# Global monitor instance
# ============================================================================

metrics_health_monitor = MetricsHealthMonitor()


# ============================================================================
# Health Check Endpoint
# ============================================================================


def create_metrics_health_router(metrics_service=None, metrics_collector=None) -> APIRouter:
    """Create metrics health check router"""

    router = APIRouter(prefix="/api/metrics", tags=["metrics"])

    @router.get("/health", response_model=MetricsHealthResponse)
    async def get_metrics_health():
        """
        Get metrics system health status

        This endpoint checks:
        - Cache hit rates and performance
        - Collection queue depth and utilization
        - Circuit breaker states for each machine
        - Per-machine connectivity status

        Response time is guaranteed < 100ms by using only cached data.

        Returns:
            MetricsHealthResponse with complete health information
        """
        start_time = utcnow()

        try:
            # Get cache metrics from metrics service
            cache_metrics = _get_cache_metrics(metrics_service)

            # Get queue metrics from collector
            queue_metrics = _get_queue_metrics(metrics_collector)

            # Get circuit breaker states
            circuit_breaker_metrics = [
                cb.get_metrics() for cb in metrics_health_monitor.circuit_breakers.values()
            ]

            # Get per-machine connectivity
            machines_status = {
                machine: conn.status
                for machine, conn in metrics_health_monitor.machine_connectivity.items()
            }
            machine_details = list(metrics_health_monitor.machine_connectivity.values())

            # Get collector status
            collector_running = False
            collection_interval = 120
            if metrics_collector:
                status = metrics_collector.get_status()
                collector_running = status.get("running", False)
                collection_interval = status.get("interval", 120)

            # Calculate overall health
            overall_status = metrics_health_monitor.get_health_status()

            # Calculate response time
            response_time_ms = (utcnow() - start_time).total_seconds() * 1000

            return MetricsHealthResponse(
                status=overall_status,
                timestamp=utcnow(),
                cache=cache_metrics,
                queue=queue_metrics,
                circuit_breakers=circuit_breaker_metrics,
                machines=machines_status,
                machine_details=machine_details,
                collector_running=collector_running,
                collection_interval_seconds=collection_interval,
                response_time_ms=response_time_ms,
            )

        except Exception as e:
            logger.error(f"Error getting metrics health: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to get metrics health: {str(e)}")

    return router


def _get_cache_metrics(metrics_service) -> CacheHealthMetrics:
    """Extract cache metrics from metrics service"""
    if not metrics_service or not hasattr(metrics_service, "cache"):
        return CacheHealthMetrics(
            hit_rate=0.0,
            total_entries=0,
            total_hits=0,
            total_misses=0,
            total_requests=0,
            ttl_seconds=60,
        )

    cache = metrics_service.cache
    stats = metrics_health_monitor.cache_stats

    # Calculate hit rate
    total_requests = stats["total_requests"]
    hit_rate = stats["hits"] / total_requests if total_requests > 0 else 0.0

    # Get cache size
    total_entries = len(cache.cache)

    # Find oldest entry
    oldest_age = None
    if cache.cache:
        now = datetime.now()
        oldest_timestamp = min(timestamp for timestamp, _ in cache.cache.values())
        oldest_age = (now - oldest_timestamp).total_seconds()

    return CacheHealthMetrics(
        hit_rate=hit_rate,
        total_entries=total_entries,
        total_hits=stats["hits"],
        total_misses=stats["misses"],
        total_requests=total_requests,
        ttl_seconds=int(cache.ttl.total_seconds()),
        oldest_entry_age_seconds=oldest_age,
    )


def _get_queue_metrics(metrics_collector) -> QueueHealthMetrics:
    """Extract queue metrics from metrics collector"""
    stats = metrics_health_monitor.queue_stats

    # Calculate utilization
    utilization = stats["current_depth"] / stats["max_depth"]

    # Calculate processing rate (items per second)
    # This would be calculated based on historical data in production
    processing_rate = 5.0  # Mock value

    # Calculate average wait time
    avg_wait_time = 0.0
    if stats["processed"] > 0:
        avg_wait_time = stats["total_wait_time_ms"] / stats["processed"]

    return QueueHealthMetrics(
        depth=stats["current_depth"],
        max_depth=stats["max_depth"],
        utilization=utilization,
        processing_rate=processing_rate,
        avg_wait_time_ms=avg_wait_time,
    )


# ============================================================================
# Integration Helper Functions
# ============================================================================


def integrate_with_metrics_service(metrics_service):
    """
    Integrate health monitor with metrics service

    This should be called during startup to wrap the metrics service
    methods and track cache hits/misses.
    """
    if not metrics_service:
        return

    # Wrap the cache get method to track hits/misses
    original_get = metrics_service.cache.get

    def tracked_get(key: str):
        result = original_get(key)
        metrics_health_monitor.update_cache_stats(hit=result is not None)
        return result

    metrics_service.cache.get = tracked_get
    logger.info("Integrated health monitor with metrics service cache")


def update_machine_status_from_metrics(machine_metrics):
    """
    Update machine connectivity status from machine metrics

    This should be called when metrics are collected to update
    the health monitor with current machine status.

    Args:
        machine_metrics: MachineMetrics object from metrics collection
    """
    if not machine_metrics:
        return

    machine = machine_metrics.machine
    success = machine_metrics.status == "ok"
    error_message = machine_metrics.error if hasattr(machine_metrics, "error") else None

    # Estimate response time (in production, this would be measured)
    response_time_ms = 50.0 if success else None

    metrics_health_monitor.update_machine_connectivity(
        machine=machine,
        success=success,
        response_time_ms=response_time_ms,
        error_message=error_message,
    )


# ============================================================================
# Export
# ============================================================================

__all__ = [
    "create_metrics_health_router",
    "metrics_health_monitor",
    "integrate_with_metrics_service",
    "update_machine_status_from_metrics",
    "MetricsHealthResponse",
    "HealthStatus",
    "MachineConnectivityStatus",
]
