"""
Device Onboarding Metrics for Prometheus

Tracks device registration, online status, and registry operations
"""

from typing import Tuple

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)


class DeviceMetricsRegistry:
    """Metrics registry for device onboarding system"""

    def __init__(self):
        self.registry = CollectorRegistry()

        # Device registration metrics
        self.devices_registered_total = Counter(
            "devices_registered_total",
            "Total number of devices registered",
            ["status", "arch", "os"],
            registry=self.registry,
        )

        # Device online status
        self.devices_online = Gauge(
            "devices_online",
            "Number of devices currently online",
            ["status", "role"],
            registry=self.registry,
        )

        # Registration duration
        self.registration_duration_seconds = Histogram(
            "registration_duration_seconds",
            "Time taken to register a device",
            ["status"],
            buckets=(0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0),
            registry=self.registry,
        )

        # Registry lock wait time
        self.registry_lock_wait_seconds = Histogram(
            "registry_lock_wait_seconds",
            "Time spent waiting for registry lock",
            buckets=(0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, 30.0),
            registry=self.registry,
        )

        # Additional device metrics
        self.device_deregistrations_total = Counter(
            "device_deregistrations_total",
            "Total number of devices deregistered",
            ["reason"],
            registry=self.registry,
        )

        self.device_updates_total = Counter(
            "device_updates_total",
            "Total number of device updates",
            ["update_type"],
            registry=self.registry,
        )

        self.registry_operations_total = Counter(
            "registry_operations_total",
            "Total registry operations",
            ["operation", "result"],
            registry=self.registry,
        )

        self.registry_validation_errors_total = Counter(
            "registry_validation_errors_total",
            "Total registry validation errors",
            ["error_type"],
            registry=self.registry,
        )

        self.registry_size_bytes = Gauge(
            "registry_size_bytes", "Current size of registry file in bytes", registry=self.registry
        )

        self.registry_backup_age_seconds = Gauge(
            "registry_backup_age_seconds",
            "Age of most recent registry backup",
            registry=self.registry,
        )

        self.device_heartbeats_total = Counter(
            "device_heartbeats_total",
            "Total device heartbeats received",
            ["hostname", "status"],
            registry=self.registry,
        )

        self.device_last_seen_seconds = Gauge(
            "device_last_seen_seconds",
            "Seconds since device was last seen",
            ["hostname"],
            registry=self.registry,
        )

        self.device_resources = Gauge(
            "device_resources",
            "Device resource metrics",
            ["hostname", "resource_type"],
            registry=self.registry,
        )


# Global device metrics registry
device_metrics = DeviceMetricsRegistry()


def track_registration(status: str, arch: str, os: str, duration: float):
    """Track device registration metrics"""
    device_metrics.devices_registered_total.labels(status=status, arch=arch, os=os).inc()

    device_metrics.registration_duration_seconds.labels(status=status).observe(duration)


def track_registry_lock(wait_time: float):
    """Track registry lock wait time"""
    device_metrics.registry_lock_wait_seconds.observe(wait_time)


def track_deregistration(reason: str):
    """Track device deregistration"""
    device_metrics.device_deregistrations_total.labels(reason=reason).inc()


def track_device_update(update_type: str):
    """Track device update"""
    device_metrics.device_updates_total.labels(update_type=update_type).inc()


def track_registry_operation(operation: str, result: str):
    """Track registry operation"""
    device_metrics.registry_operations_total.labels(operation=operation, result=result).inc()


def track_validation_error(error_type: str):
    """Track registry validation error"""
    device_metrics.registry_validation_errors_total.labels(error_type=error_type).inc()


def update_device_online_count(status: str, role: str, count: int):
    """Update count of online devices"""
    device_metrics.devices_online.labels(status=status, role=role).set(count)


def update_registry_size(size_bytes: int):
    """Update registry file size"""
    device_metrics.registry_size_bytes.set(size_bytes)


def update_registry_backup_age(age_seconds: float):
    """Update registry backup age"""
    device_metrics.registry_backup_age_seconds.set(age_seconds)


def track_heartbeat(hostname: str, status: str):
    """Track device heartbeat"""
    device_metrics.device_heartbeats_total.labels(hostname=hostname, status=status).inc()


def update_device_last_seen(hostname: str, seconds_ago: float):
    """Update device last seen timestamp"""
    device_metrics.device_last_seen_seconds.labels(hostname=hostname).set(seconds_ago)


def update_device_resources(hostname: str, cpu_cores: int, memory_gb: int, disk_gb: int):
    """Update device resource metrics"""
    device_metrics.device_resources.labels(hostname=hostname, resource_type="cpu_cores").set(
        cpu_cores
    )

    device_metrics.device_resources.labels(hostname=hostname, resource_type="memory_gb").set(
        memory_gb
    )

    device_metrics.device_resources.labels(hostname=hostname, resource_type="disk_gb").set(disk_gb)


def get_metrics() -> Tuple[bytes, str, int]:
    """
    Get Prometheus metrics in exposition format

    Returns:
        tuple: (metrics_bytes, content_type, status_code)
    """
    metrics_output = generate_latest(device_metrics.registry)
    return metrics_output, CONTENT_TYPE_LATEST, 200
