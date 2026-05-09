"""
Comprehensive tests for metrics endpoints null/undefined handling

This test suite verifies:
1. All metrics endpoints return non-null values
2. get_all_machines() returns valid machine list
3. Edge cases (no data, missing machines, etc.)
4. Validators handle None/undefined gracefully
5. Default values are properly set
"""

import json
from datetime import datetime

import pytest

from models.metrics import (
    MachineMetrics,
    MetricsHistoryResponse,
    MetricsSnapshot,
    MetricsTimeRange,
    ResourceMetrics,
    ServiceMetrics,
)
from services.metrics_service import MetricsService


class TestServiceMetricsNullSafety:
    """Test ServiceMetrics model handles null/undefined values"""

    def test_service_metrics_all_fields_non_null(self):
        """Verify all numeric fields default to non-null values"""
        # Create ServiceMetrics with minimal data
        metrics = ServiceMetrics(service="test-service", machine="test-machine")

        # Verify all numeric fields are non-null and have defaults
        assert metrics.avg_cpu is not None
        assert metrics.avg_cpu == 0.0
        assert metrics.avg_memory is not None
        assert metrics.avg_memory == 0.0
        assert metrics.peak_cpu is not None
        assert metrics.peak_cpu == 0.0
        assert metrics.peak_memory is not None
        assert metrics.peak_memory == 0.0
        assert metrics.time_range is not None
        assert metrics.time_range == "1h"
        assert metrics.history is not None
        assert isinstance(metrics.history, list)
        assert len(metrics.history) == 0

    def test_service_metrics_none_values_converted_to_defaults(self):
        """Verify None values are converted to defaults by validators"""
        # Create with explicit None values
        metrics = ServiceMetrics(
            service="test",
            machine="test",
            avg_cpu=None,
            avg_memory=None,
            peak_cpu=None,
            peak_memory=None,
        )

        # All None values should be converted to 0.0
        assert metrics.avg_cpu == 0.0
        assert metrics.avg_memory == 0.0
        assert metrics.peak_cpu == 0.0
        assert metrics.peak_memory == 0.0

    def test_service_metrics_cpu_clamped_to_valid_range(self):
        """Verify CPU percentages are clamped to 0-100 range"""
        # Test values outside valid range
        metrics1 = ServiceMetrics(service="test", machine="test", avg_cpu=-10.0, peak_cpu=150.0)

        assert metrics1.avg_cpu == 0.0  # Negative clamped to 0
        assert metrics1.peak_cpu == 100.0  # Over 100 clamped to 100

    def test_service_metrics_empty_string_converted_to_default(self):
        """Verify empty strings are converted to defaults"""
        metrics = ServiceMetrics(service="test", machine="test", avg_cpu="", avg_memory="")

        assert metrics.avg_cpu == 0.0
        assert metrics.avg_memory == 0.0


class TestMachineMetricsNullSafety:
    """Test MachineMetrics model handles null/undefined values"""

    def test_machine_metrics_all_fields_non_null(self):
        """Verify all numeric fields default to non-null values"""
        now = datetime.now()
        metrics = MachineMetrics(machine="test-machine", timestamp=now)

        # Verify all numeric fields are non-null
        assert metrics.cpu_percent is not None
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_used_mb is not None
        assert metrics.memory_used_mb == 0.0
        assert metrics.memory_total_mb is not None
        assert metrics.memory_total_mb == 0.0
        assert metrics.memory_percent is not None
        assert metrics.memory_percent == 0.0
        assert metrics.disk_used_gb is not None
        assert metrics.disk_used_gb == 0.0
        assert metrics.disk_total_gb is not None
        assert metrics.disk_total_gb == 0.0
        assert metrics.disk_percent is not None
        assert metrics.disk_percent == 0.0
        assert metrics.services is not None
        assert isinstance(metrics.services, list)
        assert metrics.status == "ok"
        assert metrics.error == ""

    def test_machine_metrics_none_values_converted(self):
        """Verify None values are converted to defaults"""
        now = datetime.now()
        metrics = MachineMetrics(
            machine="test",
            timestamp=now,
            cpu_percent=None,
            memory_percent=None,
            disk_percent=None,
            memory_used_mb=None,
            memory_total_mb=None,
        )

        assert metrics.cpu_percent == 0.0
        assert metrics.memory_percent == 0.0
        assert metrics.disk_percent == 0.0
        assert metrics.memory_used_mb == 0.0
        assert metrics.memory_total_mb == 0.0

    def test_machine_metrics_percentages_clamped(self):
        """Verify percentages are clamped to 0-100 range"""
        now = datetime.now()
        metrics = MachineMetrics(
            machine="test",
            timestamp=now,
            cpu_percent=-5.0,
            memory_percent=150.0,
            disk_percent=200.0,
        )

        assert metrics.cpu_percent == 0.0
        assert metrics.memory_percent == 100.0
        assert metrics.disk_percent == 100.0

    def test_machine_metrics_negative_values_converted_to_zero(self):
        """Verify negative values for non-percentage fields are zeroed"""
        now = datetime.now()
        metrics = MachineMetrics(
            machine="test", timestamp=now, memory_used_mb=-100.0, disk_used_gb=-50.0
        )

        assert metrics.memory_used_mb == 0.0
        assert metrics.disk_used_gb == 0.0


class TestResourceMetricsNullSafety:
    """Test ResourceMetrics model handles null/undefined values"""

    def test_resource_metrics_all_fields_non_null(self):
        """Verify all fields have non-null defaults"""
        now = datetime.now()
        metrics = ResourceMetrics(timestamp=now)

        assert metrics.service == ""
        assert metrics.machine == ""
        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.memory_total_mb == 0.0
        assert metrics.disk_gb == 0.0
        assert metrics.disk_total_gb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0

    def test_resource_metrics_none_values_converted(self):
        """Verify None values are converted to defaults"""
        now = datetime.now()
        metrics = ResourceMetrics(
            timestamp=now,
            cpu_percent=None,
            memory_mb=None,
            network_rx_bytes=None,
            network_tx_bytes=None,
        )

        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0

    def test_resource_metrics_empty_string_converted(self):
        """Verify empty strings are converted to defaults"""
        now = datetime.now()
        metrics = ResourceMetrics(
            timestamp=now, cpu_percent="", memory_mb="", network_rx_bytes="", network_tx_bytes=""
        )

        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0

    def test_resource_metrics_invalid_types_converted(self):
        """Verify invalid types are handled gracefully"""
        now = datetime.now()
        metrics = ResourceMetrics(
            timestamp=now,
            cpu_percent="invalid",
            memory_mb="not_a_number",
            network_rx_bytes="abc",
            network_tx_bytes="xyz",
        )

        assert metrics.cpu_percent == 0.0
        assert metrics.memory_mb == 0.0
        assert metrics.network_rx_bytes == 0
        assert metrics.network_tx_bytes == 0


class TestGetAllMachinesFunction:
    """Test get_all_machines() returns the registry's machine list."""

    @pytest.fixture
    def registry_with_three_machines(self, tmp_path, monkeypatch):
        """Build a minimal registry.yml at a tmp path and point the service at it."""
        registry_yaml = """\
hosts:
  alpha:
    address: 192.0.2.10
  beta:
    address: 192.0.2.11
  gamma:
    address: 192.0.2.12
services: {}
"""
        registry_file = tmp_path / "registry.yml"
        registry_file.write_text(registry_yaml)
        monkeypatch.setenv("CADDY_REGISTRY_PATH", str(registry_file))
        return registry_file

    @pytest.mark.asyncio
    async def test_get_all_machines_returns_list(self, registry_with_three_machines):
        """Verify get_all_machines returns a list."""
        service = MetricsService()
        machines = await service.get_all_machines()

        assert machines is not None
        assert isinstance(machines, list)
        assert len(machines) == 3

    @pytest.mark.asyncio
    async def test_get_all_machines_contains_registry_machines(self, registry_with_three_machines):
        """Verify get_all_machines returns the names from the registry."""
        service = MetricsService()
        machines = await service.get_all_machines()

        for expected in ("alpha", "beta", "gamma"):
            assert expected in machines, f"Expected machine '{expected}' not found in {machines}"

    @pytest.mark.asyncio
    async def test_get_all_machines_no_nulls(self, registry_with_three_machines):
        """Verify get_all_machines returns no null values."""
        service = MetricsService()
        machines = await service.get_all_machines()

        assert None not in machines
        assert "" not in machines
        for machine in machines:
            assert machine is not None
            assert isinstance(machine, str)
            assert len(machine) > 0

    @pytest.mark.asyncio
    async def test_get_all_machines_returns_empty_without_registry(self, tmp_path, monkeypatch):
        """When no registry is reachable, return [] (no hardcoded fallback)."""
        missing = tmp_path / "does-not-exist.yml"
        monkeypatch.setenv("CADDY_REGISTRY_PATH", str(missing))
        service = MetricsService()
        machines = await service.get_all_machines()
        assert machines == []


class TestMetricsServiceMissingDataHandling:
    """Test MetricsService handles missing data gracefully"""

    @pytest.mark.asyncio
    async def test_service_metrics_with_no_cli_data(self):
        """Verify service handles missing CLI data gracefully by returning synthetic metrics."""
        service = MetricsService(cli_path="/nonexistent/cli")

        # Mock _run_cli_command to return failed result
        async def mock_run_cli_command(args, timeout=30):
            return {"success": False, "output": "", "error": "CLI not found", "returncode": -1}

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_service_metrics("test", "machine1")

        # Falls back to synthetic zeroed ServiceMetrics so the UI doesn't flash
        # broken cards on first-boot transients (see metrics_service.py).
        assert metrics is not None
        assert metrics.service == "test"
        assert metrics.machine == "machine1"
        assert metrics.current.cpu_percent == 0.0
        assert metrics.current.memory_mb == 0.0
        assert metrics.history == []

    @pytest.mark.asyncio
    async def test_machine_metrics_with_no_cli_data(self):
        """Verify machine metrics handle missing CLI data"""
        service = MetricsService(cli_path="/nonexistent/cli")

        async def mock_run_cli_command(args, timeout=30):
            return {"success": False, "output": "", "error": "CLI not found", "returncode": -1}

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_machine_metrics("machine1")

        # Should return None, not crash
        assert metrics is None

    @pytest.mark.asyncio
    async def test_service_metrics_with_invalid_json(self):
        """Verify service handles invalid JSON gracefully by returning synthetic metrics."""
        service = MetricsService()

        async def mock_run_cli_command(args, timeout=30):
            return {"success": True, "output": "not valid json{{{", "error": None, "returncode": 0}

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_service_metrics("test", "machine1")

        # Same fallback contract as the missing-CLI case.
        assert metrics is not None
        assert metrics.service == "test"
        assert metrics.machine == "machine1"
        assert metrics.current.cpu_percent == 0.0
        assert metrics.history == []

    @pytest.mark.asyncio
    async def test_machine_metrics_with_partial_data(self):
        """Verify machine metrics use defaults for missing fields"""
        service = MetricsService()

        # Mock CLI response with minimal data
        async def mock_run_cli_command(args, timeout=30):
            minimal_data = {
                "timestamp": datetime.now().isoformat(),
                "services": [],
                # Missing cpu_percent, memory, disk, etc.
            }
            return {
                "success": True,
                "output": json.dumps(minimal_data),
                "error": None,
                "returncode": 0,
            }

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_machine_metrics("machine1")

        # Should have default values for missing fields
        if metrics:
            assert metrics.cpu_percent == 0.0
            assert metrics.memory_used_mb == 0.0
            assert metrics.memory_total_mb == 0.0
            assert metrics.disk_used_gb == 0.0
            assert metrics.disk_total_gb == 0.0


class TestMetricsServiceEdgeCases:
    """Test edge cases and boundary conditions"""

    @pytest.mark.asyncio
    async def test_get_all_metrics_with_no_machines(self):
        """Verify get_all_metrics handles no machines gracefully"""
        service = MetricsService()

        # Mock get_all_machines to return empty list
        async def mock_get_all_machines():
            return []

        service.get_all_machines = mock_get_all_machines

        async def mock_run_cli_command(args, timeout=30):
            return {
                "success": True,
                "output": json.dumps({"machines": []}),
                "error": None,
                "returncode": 0,
            }

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_all_metrics()

        # Should return empty list, not crash
        assert metrics is not None
        assert isinstance(metrics, list)
        assert len(metrics) == 0

    @pytest.mark.asyncio
    async def test_get_metrics_history_with_no_snapshots(self):
        """Verify metrics history returns empty list with no snapshots"""
        service = MetricsService()

        history = await service.get_metrics_history(
            "test-service", "test-machine", MetricsTimeRange.HOUR
        )

        # Should return empty list, not None
        assert history is not None
        assert isinstance(history, list)

    @pytest.mark.asyncio
    async def test_calculate_average_metrics_with_empty_history(self):
        """Verify average calculation handles empty history"""
        service = MetricsService()

        averages = await service.calculate_average_metrics([])

        # Should return dict with zero values
        assert averages is not None
        assert isinstance(averages, dict)
        assert averages["avg_cpu"] == 0.0
        assert averages["avg_memory"] == 0.0
        assert averages["peak_cpu"] == 0.0
        assert averages["peak_memory"] == 0.0

    @pytest.mark.asyncio
    async def test_service_metrics_with_null_fields_in_cli_response(self):
        """Verify service metrics handle null fields in CLI response"""
        service = MetricsService()

        # Mock CLI response with null/missing fields
        async def mock_run_cli_command(args, timeout=30):
            data_with_nulls = {
                "timestamp": datetime.now().isoformat(),
                "cpu_percent": None,
                "memory_mb": None,
                "memory_total_mb": 0,
                "disk_gb": None,
                "disk_total_gb": 0,
            }
            return {
                "success": True,
                "output": json.dumps(data_with_nulls),
                "error": None,
                "returncode": 0,
            }

        service._run_cli_command = mock_run_cli_command

        # Mock get_metrics_history to return empty list
        async def mock_get_metrics_history(service_name, machine, time_range):
            return []

        service.get_metrics_history = mock_get_metrics_history

        metrics = await service.get_service_metrics("test", "machine1")

        # Should handle null values gracefully
        if metrics:
            assert metrics.current.cpu_percent == 0.0
            assert metrics.current.memory_mb == 0.0
            assert metrics.current.disk_gb == 0.0


class TestMetricsSnapshotNullSafety:
    """Test MetricsSnapshot model null safety"""

    def test_metrics_snapshot_defaults(self):
        """Verify MetricsSnapshot has proper defaults"""
        snapshot = MetricsSnapshot()

        assert snapshot.service == ""
        assert snapshot.machine == ""
        assert snapshot.all is False
        assert snapshot.status == "pending"
        assert snapshot.message == ""

    def test_metrics_snapshot_no_nulls(self):
        """Verify MetricsSnapshot never has null values"""
        snapshot = MetricsSnapshot(
            service="test", machine="test-machine", all=True, status="completed", message="Done"
        )

        assert snapshot.service is not None
        assert snapshot.machine is not None
        assert snapshot.all is not None
        assert snapshot.status is not None
        assert snapshot.message is not None


class TestMetricsHistoryResponseNullSafety:
    """Test MetricsHistoryResponse model null safety"""

    def test_metrics_history_response_defaults(self):
        """Verify MetricsHistoryResponse has proper defaults"""
        response = MetricsHistoryResponse()

        assert response.service == ""
        assert response.machine == ""
        assert response.time_range == "24h"
        assert response.interval == "15m"
        assert response.data_points is not None
        assert isinstance(response.data_points, list)
        assert len(response.data_points) == 0
        assert response.summary is not None
        assert isinstance(response.summary, dict)

    def test_metrics_history_response_no_nulls(self):
        """Verify MetricsHistoryResponse never has null values"""
        response = MetricsHistoryResponse(
            service="test", machine="test-machine", time_range="1h", interval="5m"
        )

        assert response.service is not None
        assert response.machine is not None
        assert response.time_range is not None
        assert response.interval is not None
        assert response.data_points is not None
        assert response.summary is not None


class TestMetricsServiceCacheNullSafety:
    """Test MetricsService cache handles null values"""

    @pytest.mark.asyncio
    async def test_cache_returns_none_for_missing_key(self):
        """Verify cache returns None for missing keys"""
        service = MetricsService()

        cached = service.cache.get("nonexistent-key")
        assert cached is None

    @pytest.mark.asyncio
    async def test_cache_handles_null_value_storage(self):
        """Verify cache can store and retrieve None values"""
        service = MetricsService()

        # Store None value
        service.cache.set("test-key", None)

        # Should retrieve None
        cached = service.cache.get("test-key")
        assert cached is None

    @pytest.mark.asyncio
    async def test_invalidate_cache_with_none_params(self):
        """Verify cache invalidation handles None parameters"""
        service = MetricsService()

        # Should not crash with None parameters
        service.invalidate_cache(service=None, machine=None)
        service.invalidate_cache(service="test", machine=None)
        service.invalidate_cache(service=None, machine="test")


class TestMetricsParsingEdgeCases:
    """Test metrics parsing edge cases"""

    @pytest.mark.asyncio
    async def test_parse_machine_metrics_with_error_field(self):
        """Verify _parse_machine_metrics handles error field"""
        service = MetricsService()

        machine_data = {"machine": "test-machine", "metrics": {"error": "metrics_unavailable"}}

        metrics = service._parse_machine_metrics(machine_data)

        assert metrics is not None
        assert metrics.machine == "test-machine"
        assert metrics.status == "unavailable"
        assert metrics.error == "metrics_unavailable"

    @pytest.mark.asyncio
    async def test_parse_machine_metrics_with_missing_machine_name(self):
        """Verify _parse_machine_metrics handles missing machine name"""
        service = MetricsService()

        machine_data = {"metrics": {"cpu_percent": 50.0}}

        metrics = service._parse_machine_metrics(machine_data)

        assert metrics is not None
        assert metrics.machine == "unknown"

    @pytest.mark.asyncio
    async def test_parse_machine_metrics_with_string_numbers(self):
        """Verify _parse_machine_metrics converts string numbers"""
        service = MetricsService()

        machine_data = {
            "machine": "test",
            "metrics": {
                "cpu_percent": "50.5",
                "memory_used_mb": "1024.0",
                "memory_total_mb": "2048.0",
                "disk_used_gb": "100.5",
                "disk_total_gb": "500.0",
            },
        }

        metrics = service._parse_machine_metrics(machine_data)

        assert metrics is not None
        assert metrics.cpu_percent == 50.5
        assert metrics.memory_used_mb == 1024.0
        assert metrics.memory_total_mb == 2048.0
        assert metrics.disk_used_gb == 100.5
        assert metrics.disk_total_gb == 500.0


# Integration-style tests
class TestEndToEndNullSafety:
    """End-to-end tests verifying null safety through entire flow"""

    @pytest.mark.asyncio
    async def test_full_service_metrics_flow_with_minimal_data(self):
        """Test complete flow from CLI response to ServiceMetrics with minimal data"""
        service = MetricsService()

        # Mock minimal CLI response
        async def mock_run_cli_command(args, timeout=30):
            minimal_data = {"timestamp": datetime.now().isoformat()}
            return {
                "success": True,
                "output": json.dumps(minimal_data),
                "error": None,
                "returncode": 0,
            }

        service._run_cli_command = mock_run_cli_command

        # Mock empty history
        async def mock_get_metrics_history(service_name, machine, time_range):
            return []

        service.get_metrics_history = mock_get_metrics_history

        metrics = await service.get_service_metrics("test", "machine1")

        # Verify all fields have proper defaults
        if metrics:
            assert metrics.service is not None
            assert metrics.machine is not None
            assert metrics.avg_cpu is not None
            assert metrics.avg_memory is not None
            assert metrics.peak_cpu is not None
            assert metrics.peak_memory is not None
            assert metrics.history is not None

    @pytest.mark.asyncio
    async def test_full_machine_metrics_flow_with_error_services(self):
        """Test machine metrics with services that have errors"""
        service = MetricsService()

        async def mock_run_cli_command(args, timeout=30):
            data = {
                "timestamp": datetime.now().isoformat(),
                "cpu_percent": 25.0,
                "memory_used_mb": 1024.0,
                "memory_total_mb": 2048.0,
                "disk_used_gb": 50.0,
                "disk_total_gb": 100.0,
                "services": [
                    {
                        "service": "service1",
                        "cpu_percent": None,  # Null value
                        "memory_mb": None,
                    },
                    {
                        "service": "service2",
                        "cpu_percent": "",  # Empty string
                        "memory_mb": "",
                    },
                ],
            }
            return {"success": True, "output": json.dumps(data), "error": None, "returncode": 0}

        service._run_cli_command = mock_run_cli_command

        metrics = await service.get_machine_metrics("machine1")

        # Verify machine metrics and service metrics have defaults
        if metrics:
            assert metrics.cpu_percent == 25.0
            assert len(metrics.services) == 2
            for svc in metrics.services:
                assert svc.cpu_percent == 0.0  # Null/empty converted to 0.0
                assert svc.memory_mb == 0.0
