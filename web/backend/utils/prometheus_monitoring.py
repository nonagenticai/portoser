"""
Comprehensive Monitoring & Alerting System for Metrics Platform

This module provides:
- Prometheus metrics export endpoint
- Real-time tracking of key performance indicators
- Alert definitions and thresholds
- Structured logging with metrics context
- Grafana dashboard configuration
"""

import json
import logging
import time
from collections import deque
from dataclasses import dataclass
from enum import Enum
from threading import Lock
from typing import Dict, List

# Prometheus client library
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    Info,
    generate_latest,
)

from utils.datetime_utils import utcnow

# ============================================================================
# PROMETHEUS METRICS DEFINITIONS
# ============================================================================


class MetricsRegistry:
    """Central registry for all Prometheus metrics"""

    def __init__(self):
        self.registry = CollectorRegistry()

        # Request metrics
        self.http_requests_total = Counter(
            "http_requests_total",
            "Total HTTP requests",
            ["method", "endpoint", "status"],
            registry=self.registry,
        )

        self.http_request_duration_seconds = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency in seconds",
            ["method", "endpoint"],
            buckets=(0.01, 0.05, 0.1, 0.5, 1.0, 2.5, 5.0, 10.0),
            registry=self.registry,
        )

        # Cache metrics
        self.cache_operations_total = Counter(
            "cache_operations_total",
            "Total cache operations",
            ["operation", "result"],
            registry=self.registry,
        )

        self.cache_hit_rate = Gauge(
            "cache_hit_rate", "Cache hit rate percentage", registry=self.registry
        )

        self.cache_size_bytes = Gauge(
            "cache_size_bytes", "Current cache size in bytes", registry=self.registry
        )

        # Error metrics
        self.errors_total = Counter(
            "errors_total", "Total errors", ["type", "severity"], registry=self.registry
        )

        self.error_rate = Gauge("error_rate", "Error rate percentage", registry=self.registry)

        # Queue metrics
        self.queue_depth = Gauge(
            "queue_depth", "Current queue depth", ["queue_name"], registry=self.registry
        )

        self.queue_operations_total = Counter(
            "queue_operations_total",
            "Total queue operations",
            ["queue_name", "operation"],
            registry=self.registry,
        )

        self.queue_processing_duration_seconds = Histogram(
            "queue_processing_duration_seconds",
            "Queue item processing duration",
            ["queue_name"],
            buckets=(0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0),
            registry=self.registry,
        )

        # Database metrics
        self.db_query_duration_seconds = Histogram(
            "db_query_duration_seconds",
            "Database query duration",
            ["query_type"],
            buckets=(0.01, 0.05, 0.1, 0.5, 1.0, 2.5, 5.0),
            registry=self.registry,
        )

        self.db_connections = Gauge(
            "db_connections", "Database connection pool status", ["state"], registry=self.registry
        )

        # Business metrics
        self.metrics_ingested_total = Counter(
            "metrics_ingested_total",
            "Total metrics ingested",
            ["source", "type"],
            registry=self.registry,
        )

        self.active_users = Gauge("active_users", "Currently active users", registry=self.registry)

        # System metrics
        self.system_info = Info("system", "System information", registry=self.registry)

        self.uptime_seconds = Gauge(
            "uptime_seconds", "System uptime in seconds", registry=self.registry
        )


# Global metrics registry
metrics_registry = MetricsRegistry()


# ============================================================================
# ALERT DEFINITIONS
# ============================================================================


class AlertSeverity(Enum):
    """Alert severity levels"""

    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


@dataclass
class AlertThreshold:
    """Alert threshold configuration"""

    name: str
    metric_name: str
    threshold: float
    comparison: str  # gt, lt, gte, lte, eq
    severity: AlertSeverity
    duration_seconds: int = 60
    description: str = ""


class AlertManager:
    """Manages alert rules and firing alerts"""

    def __init__(self):
        self.thresholds = self._define_thresholds()
        self.active_alerts: Dict[str, Dict] = {}
        self.alert_history: deque = deque(maxlen=1000)
        self.lock = Lock()

    def _define_thresholds(self) -> List[AlertThreshold]:
        """Define all alert thresholds"""
        return [
            # Error rate alerts
            AlertThreshold(
                name="HighErrorRate",
                metric_name="error_rate",
                threshold=10.0,
                comparison="gt",
                severity=AlertSeverity.CRITICAL,
                duration_seconds=60,
                description="Error rate exceeds 10%",
            ),
            AlertThreshold(
                name="ElevatedErrorRate",
                metric_name="error_rate",
                threshold=5.0,
                comparison="gt",
                severity=AlertSeverity.WARNING,
                duration_seconds=120,
                description="Error rate exceeds 5%",
            ),
            # Latency alerts
            AlertThreshold(
                name="HighLatency",
                metric_name="http_request_duration_p95",
                threshold=5.0,
                comparison="gt",
                severity=AlertSeverity.CRITICAL,
                duration_seconds=60,
                description="95th percentile latency exceeds 5 seconds",
            ),
            AlertThreshold(
                name="ElevatedLatency",
                metric_name="http_request_duration_p95",
                threshold=2.0,
                comparison="gt",
                severity=AlertSeverity.WARNING,
                duration_seconds=180,
                description="95th percentile latency exceeds 2 seconds",
            ),
            # Queue depth alerts
            AlertThreshold(
                name="QueueOverflow",
                metric_name="queue_depth",
                threshold=10000,
                comparison="gt",
                severity=AlertSeverity.CRITICAL,
                duration_seconds=30,
                description="Queue depth exceeds 10,000 items",
            ),
            AlertThreshold(
                name="QueueBacklog",
                metric_name="queue_depth",
                threshold=5000,
                comparison="gt",
                severity=AlertSeverity.WARNING,
                duration_seconds=120,
                description="Queue depth exceeds 5,000 items",
            ),
            # Cache hit rate alerts
            AlertThreshold(
                name="LowCacheHitRate",
                metric_name="cache_hit_rate",
                threshold=50.0,
                comparison="lt",
                severity=AlertSeverity.WARNING,
                duration_seconds=300,
                description="Cache hit rate below 50%",
            ),
            # Database connection alerts
            AlertThreshold(
                name="DatabaseConnectionExhaustion",
                metric_name="db_connections_available",
                threshold=5,
                comparison="lt",
                severity=AlertSeverity.CRITICAL,
                duration_seconds=30,
                description="Less than 5 database connections available",
            ),
        ]

    def evaluate_alerts(self, current_metrics: Dict[str, float]) -> List[Dict]:
        """Evaluate all alert rules against current metrics"""
        fired_alerts = []

        with self.lock:
            for threshold in self.thresholds:
                if threshold.metric_name not in current_metrics:
                    continue

                current_value = current_metrics[threshold.metric_name]
                is_breached = self._check_threshold(
                    current_value, threshold.threshold, threshold.comparison
                )

                if is_breached:
                    alert = self._fire_alert(threshold, current_value)
                    fired_alerts.append(alert)
                else:
                    self._resolve_alert(threshold.name)

        return fired_alerts

    def _check_threshold(self, value: float, threshold: float, comparison: str) -> bool:
        """Check if value breaches threshold"""
        comparisons = {
            "gt": lambda v, t: v > t,
            "lt": lambda v, t: v < t,
            "gte": lambda v, t: v >= t,
            "lte": lambda v, t: v <= t,
            "eq": lambda v, t: v == t,
        }
        return comparisons[comparison](value, threshold)

    def _fire_alert(self, threshold: AlertThreshold, current_value: float) -> Dict:
        """Fire an alert"""
        now = utcnow()

        if threshold.name in self.active_alerts:
            alert = self.active_alerts[threshold.name]
            alert["last_seen"] = now.isoformat()
            alert["current_value"] = current_value
        else:
            alert = {
                "name": threshold.name,
                "severity": threshold.severity.value,
                "metric": threshold.metric_name,
                "threshold": threshold.threshold,
                "current_value": current_value,
                "description": threshold.description,
                "fired_at": now.isoformat(),
                "last_seen": now.isoformat(),
            }
            self.active_alerts[threshold.name] = alert
            self.alert_history.append(alert.copy())

        return alert

    def _resolve_alert(self, alert_name: str):
        """Resolve an active alert"""
        if alert_name in self.active_alerts:
            alert = self.active_alerts.pop(alert_name)
            alert["resolved_at"] = utcnow().isoformat()
            self.alert_history.append(alert)

    def get_active_alerts(self) -> List[Dict]:
        """Get all currently active alerts"""
        with self.lock:
            return list(self.active_alerts.values())


# Global alert manager
alert_manager = AlertManager()


# ============================================================================
# STRUCTURED LOGGING
# ============================================================================


class MetricsContextLogger:
    """Logger with automatic metrics context"""

    def __init__(self, name: str):
        self.logger = logging.getLogger(name)
        self._setup_logging()

    def _setup_logging(self):
        """Setup structured JSON logging"""
        handler = logging.StreamHandler()
        formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
        handler.setFormatter(formatter)
        self.logger.addHandler(handler)
        self.logger.setLevel(logging.INFO)

    def _format_log(self, level: str, message: str, context: Dict = None) -> Dict:
        """Format log entry with metrics context"""
        log_entry = {
            "timestamp": utcnow().isoformat(),
            "level": level,
            "message": message,
            "logger": self.logger.name,
        }

        if context:
            log_entry["context"] = context

        return log_entry

    def info(self, message: str, **kwargs):
        """Log info with metrics context"""
        log_data = self._format_log("INFO", message, kwargs)
        self.logger.info(json.dumps(log_data))

    def warning(self, message: str, **kwargs):
        """Log warning with metrics context"""
        log_data = self._format_log("WARNING", message, kwargs)
        self.logger.warning(json.dumps(log_data))
        metrics_registry.errors_total.labels(type="warning", severity="low").inc()

    def error(self, message: str, **kwargs):
        """Log error with metrics context"""
        log_data = self._format_log("ERROR", message, kwargs)
        self.logger.error(json.dumps(log_data))
        metrics_registry.errors_total.labels(type="error", severity="medium").inc()

    def critical(self, message: str, **kwargs):
        """Log critical error with metrics context"""
        log_data = self._format_log("CRITICAL", message, kwargs)
        self.logger.critical(json.dumps(log_data))
        metrics_registry.errors_total.labels(type="critical", severity="high").inc()


# ============================================================================
# METRICS COLLECTOR
# ============================================================================


class MetricsCollector:
    """Collects and aggregates metrics for monitoring"""

    def __init__(self):
        self.request_times = deque(maxlen=1000)
        self.cache_stats = {"hits": 0, "misses": 0}
        self.error_count = 0
        self.total_requests = 0
        self.start_time = time.time()
        self.lock = Lock()

    def record_request(self, duration: float, success: bool):
        """Record request metrics"""
        with self.lock:
            self.request_times.append(duration)
            self.total_requests += 1
            if not success:
                self.error_count += 1

    def record_cache_access(self, hit: bool):
        """Record cache access"""
        with self.lock:
            if hit:
                self.cache_stats["hits"] += 1
            else:
                self.cache_stats["misses"] += 1

    def get_current_metrics(self) -> Dict[str, float]:
        """Get current aggregated metrics"""
        with self.lock:
            total_cache = self.cache_stats["hits"] + self.cache_stats["misses"]
            cache_hit_rate = (
                (self.cache_stats["hits"] / total_cache * 100) if total_cache > 0 else 0
            )

            error_rate = (
                (self.error_count / self.total_requests * 100) if self.total_requests > 0 else 0
            )

            p95_latency = (
                sorted(self.request_times)[int(len(self.request_times) * 0.95)]
                if self.request_times
                else 0
            )

            return {
                "cache_hit_rate": cache_hit_rate,
                "error_rate": error_rate,
                "http_request_duration_p95": p95_latency,
                "total_requests": self.total_requests,
                "uptime_seconds": time.time() - self.start_time,
            }

    def update_gauges(self):
        """Update Prometheus gauge metrics"""
        metrics = self.get_current_metrics()

        metrics_registry.cache_hit_rate.set(metrics["cache_hit_rate"])
        metrics_registry.error_rate.set(metrics["error_rate"])
        metrics_registry.uptime_seconds.set(metrics["uptime_seconds"])


# Global metrics collector
prometheus_metrics_collector = MetricsCollector()


# ============================================================================
# METRICS ENDPOINT
# ============================================================================


def metrics_endpoint():
    """
    Prometheus metrics endpoint handler

    Returns:
        tuple: (content, content_type, status_code)
    """
    # Update current metrics
    prometheus_metrics_collector.update_gauges()

    # Generate Prometheus exposition format
    metrics_output = generate_latest(metrics_registry.registry)

    return metrics_output, CONTENT_TYPE_LATEST, 200


# ============================================================================
# HEALTH CHECK ENDPOINT
# ============================================================================


def health_check_endpoint() -> Dict:
    """
    Health check endpoint with detailed status

    Returns:
        dict: Health check response
    """
    current_metrics = prometheus_metrics_collector.get_current_metrics()
    active_alerts = alert_manager.get_active_alerts()

    # Determine overall health
    critical_alerts = [a for a in active_alerts if a["severity"] == "critical"]
    health_status = "unhealthy" if critical_alerts else "healthy"

    return {
        "status": health_status,
        "timestamp": utcnow().isoformat(),
        "uptime_seconds": current_metrics["uptime_seconds"],
        "metrics": current_metrics,
        "alerts": {
            "active_count": len(active_alerts),
            "critical_count": len(critical_alerts),
            "alerts": active_alerts,
        },
    }


# ============================================================================
# Export
# ============================================================================

__all__ = [
    "metrics_registry",
    "alert_manager",
    "prometheus_metrics_collector",
    "metrics_endpoint",
    "health_check_endpoint",
    "MetricsContextLogger",
]
