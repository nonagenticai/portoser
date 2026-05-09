"""Test metrics models for proper handling of None/undefined values"""

from datetime import datetime

import pytest

from models.metrics import MachineMetrics, ResourceMetrics


class TestResourceMetrics:
    """Test ResourceMetrics model validation"""

    def test_valid_metrics(self):
        """Test creating metrics with valid data"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=15.5,
            memory_mb=256.0,
            memory_total_mb=2048.0,
            disk_gb=5.2,
            disk_total_gb=100.0,
            network_rx_bytes=1024000,
            network_tx_bytes=2048000,
        )
        assert metrics.cpu_percent == 15.5
        assert metrics.memory_mb == 256.0
        assert metrics.network_rx_bytes == 1024000

    def test_none_cpu_percent(self):
        """Test that None cpu_percent is converted to 0.0"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=None,  # Should become 0.0
            memory_mb=256.0,
            memory_total_mb=2048.0,
        )
        assert metrics.cpu_percent == 0.0

    def test_none_memory_values(self):
        """Test that None memory values are converted to 0.0"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=15.5,
            memory_mb=None,  # Should become 0.0
            memory_total_mb=None,  # Should become 0.0
        )
        assert metrics.memory_mb == 0.0
        assert metrics.memory_total_mb == 0.0

    def test_none_disk_values(self):
        """Test that None disk values are converted to 0.0"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            disk_gb=None,  # Should become 0.0
            disk_total_gb=None,  # Should become 0.0
        )
        assert metrics.disk_gb == 0.0
        assert metrics.disk_total_gb == 0.0

    def test_none_network_values(self):
        """Test that None network values are converted to 0"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            network_rx_bytes=None,  # Should become 0
            network_tx_bytes=None,  # Should become 0
        )
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0

    def test_empty_string_values(self):
        """Test that empty strings are converted to defaults"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent="",  # Should become 0.0
            memory_mb="",  # Should become 0.0
            network_rx_bytes="",  # Should become 0
        )
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.network_rx_bytes == 0

    def test_cpu_percent_clamping(self):
        """Test that cpu_percent is clamped between 0 and 100"""
        # Test over 100
        metrics1 = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=150.0,  # Should be clamped to 100.0
        )
        assert metrics1.cpu_percent == 100.0

        # Test negative
        metrics2 = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=-10.0,  # Should be clamped to 0.0
        )
        assert metrics2.cpu_percent == 0.0

    def test_negative_values_clamped(self):
        """Test that negative values are clamped to 0"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            memory_mb=-100.0,  # Should become 0.0
            disk_gb=-50.0,  # Should become 0.0
            network_rx_bytes=-1000,  # Should become 0
        )
        assert metrics.memory_mb == 0.0
        assert metrics.disk_gb == 0.0
        assert metrics.network_rx_bytes == 0

    def test_invalid_type_conversion(self):
        """Test that invalid types are converted to defaults"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent="invalid",  # Should become 0.0
            memory_mb="not_a_number",  # Should become 0.0
            network_rx_bytes="bad_int",  # Should become 0
        )
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.network_rx_bytes == 0

    def test_all_defaults(self):
        """Test creating metrics with all default values"""
        metrics = ResourceMetrics(service="nginx", machine="web01", timestamp=datetime.now())
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.memory_total_mb == 0.0
        assert metrics.disk_gb == 0.0
        assert metrics.disk_total_gb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0

    def test_json_serialization(self):
        """Test that metrics can be serialized to JSON"""
        metrics = ResourceMetrics(
            service="nginx",
            machine="web01",
            timestamp=datetime.now(),
            cpu_percent=15.5,
            memory_mb=256.0,
        )
        json_data = metrics.model_dump()
        assert json_data["cpu_percent"] == 15.5
        assert json_data["memory_mb"] == 256.0
        assert json_data["service"] == "nginx"

    def test_from_dict_with_none_values(self):
        """Test creating metrics from dict with None values"""
        data = {
            "service": "nginx",
            "machine": "web01",
            "timestamp": datetime.now(),
            "cpu_percent": None,
            "memory_mb": None,
            "memory_total_mb": None,
            "disk_gb": None,
            "disk_total_gb": None,
            "network_rx_bytes": None,
            "network_tx_bytes": None,
        }
        metrics = ResourceMetrics(**data)
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.memory_total_mb == 0.0
        assert metrics.disk_gb == 0.0
        assert metrics.disk_total_gb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0


class TestMachineMetrics:
    """Test MachineMetrics model"""

    def test_default_values(self):
        """Test that MachineMetrics has proper defaults"""
        metrics = MachineMetrics(machine="web01", timestamp=datetime.now())
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_used_mb == 0.0
        assert metrics.memory_total_mb == 0.0
        assert metrics.memory_percent == 0.0
        assert metrics.disk_used_gb == 0.0
        assert metrics.disk_total_gb == 0.0
        assert metrics.disk_percent == 0.0
        assert metrics.status == "ok"
        assert metrics.error is None or metrics.error == ""
        assert metrics.services == []

    def test_with_error(self):
        """Test MachineMetrics with error status"""
        metrics = MachineMetrics(
            machine="web01", timestamp=datetime.now(), status="error", error="Connection timeout"
        )
        assert metrics.status == "error"
        assert metrics.error == "Connection timeout"
        assert metrics.cpu_percent == 0.0  # Should still have safe defaults


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
