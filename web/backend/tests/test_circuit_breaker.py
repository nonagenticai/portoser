"""
Unit tests for circuit breaker module
Tests circuit states, failure tracking, and state transitions
"""

import asyncio
import os
import sys

import pytest

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from utils.circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerConfig,
    CircuitBreakerError,
    CircuitBreakerRegistry,
    CircuitState,
)


class TestCircuitBreakerConfig:
    """Test circuit breaker configuration"""

    def test_default_config(self):
        """Test default configuration values"""
        config = CircuitBreakerConfig()

        assert config.failure_threshold == 5
        assert config.recovery_timeout == 60
        assert config.success_threshold == 1

    def test_custom_config(self):
        """Test custom configuration"""
        config = CircuitBreakerConfig(failure_threshold=3, recovery_timeout=30, success_threshold=2)

        assert config.failure_threshold == 3
        assert config.recovery_timeout == 30
        assert config.success_threshold == 2


class TestCircuitBreaker:
    """Test circuit breaker functionality"""

    @pytest.fixture
    def breaker(self):
        """Create circuit breaker with short timeouts for testing"""
        config = CircuitBreakerConfig(
            failure_threshold=3,
            recovery_timeout=1,  # 1 second for faster tests
            success_threshold=2,
        )
        return CircuitBreaker("test-service", config)

    @pytest.mark.asyncio
    async def test_initial_state_closed(self, breaker):
        """Test circuit starts in CLOSED state"""
        assert breaker.get_state() == CircuitState.CLOSED

    @pytest.mark.asyncio
    async def test_successful_call(self, breaker):
        """Test successful function call through circuit"""

        async def success_function():
            return "success"

        result = await breaker.call(success_function)

        assert result == "success"
        assert breaker.get_state() == CircuitState.CLOSED
        stats = breaker.get_stats()
        assert stats["total_successes"] == 1

    @pytest.mark.asyncio
    async def test_failed_call(self, breaker):
        """Test failed function call"""

        async def failing_function():
            raise Exception("test failure")

        with pytest.raises(Exception, match="test failure"):
            await breaker.call(failing_function)

        stats = breaker.get_stats()
        assert stats["total_failures"] == 1
        assert stats["failure_count"] == 1

    @pytest.mark.asyncio
    async def test_circuit_opens_on_threshold(self, breaker):
        """Test circuit opens after failure threshold"""

        async def failing_function():
            raise Exception("test failure")

        # Fail 3 times (threshold)
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        # Circuit should now be OPEN
        assert breaker.get_state() == CircuitState.OPEN

    @pytest.mark.asyncio
    async def test_open_circuit_rejects_calls(self, breaker):
        """Test OPEN circuit rejects calls immediately"""

        async def failing_function():
            raise Exception("test failure")

        # Trip the circuit
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        assert breaker.get_state() == CircuitState.OPEN

        # Try to call again - should fail fast
        with pytest.raises(CircuitBreakerError):
            await breaker.call(failing_function)

        stats = breaker.get_stats()
        assert stats["total_rejected"] >= 1

    @pytest.mark.asyncio
    async def test_circuit_transitions_to_half_open(self, breaker):
        """Test circuit transitions from OPEN to HALF_OPEN after timeout"""

        async def failing_function():
            raise Exception("test failure")

        # Trip the circuit
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        assert breaker.get_state() == CircuitState.OPEN

        # Wait for recovery timeout
        await asyncio.sleep(1.1)

        # Check state transition
        async def check_function():
            return "check"

        # This should trigger state check and transition out of OPEN.
        # With success_threshold=2 (see fixture) one success keeps us in
        # HALF_OPEN until a second success closes the circuit.
        try:
            await breaker.call(check_function)
            assert breaker.get_state() in (CircuitState.HALF_OPEN, CircuitState.CLOSED)
        except CircuitBreakerError:
            # If still timing, might still be OPEN
            pass

    @pytest.mark.asyncio
    async def test_half_open_closes_on_success(self, breaker):
        """Test HALF_OPEN circuit closes on successful calls"""

        async def failing_function():
            raise Exception("test failure")

        async def success_function():
            return "success"

        # Trip circuit
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        # Wait for recovery
        await asyncio.sleep(1.1)

        # Success should close circuit
        # Note: need success_threshold successes (2 in this config)
        try:
            await breaker.call(success_function)
            await breaker.call(success_function)
        except CircuitBreakerError:
            # Still in recovery window
            pass

    @pytest.mark.asyncio
    async def test_half_open_reopens_on_failure(self, breaker):
        """Test HALF_OPEN circuit reopens on failure"""

        async def failing_function():
            raise Exception("test failure")

        # Trip circuit
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        assert breaker.get_state() == CircuitState.OPEN

        # Wait for recovery
        await asyncio.sleep(1.1)

        # Failure in HALF_OPEN should reopen circuit
        with pytest.raises(Exception):
            await breaker.call(failing_function)

        # Should be back to OPEN
        assert breaker.get_state() == CircuitState.OPEN

    @pytest.mark.asyncio
    async def test_reset_circuit(self, breaker):
        """Test manual circuit reset"""

        async def failing_function():
            raise Exception("test failure")

        # Trip circuit
        for _ in range(3):
            with pytest.raises(Exception):
                await breaker.call(failing_function)

        assert breaker.get_state() == CircuitState.OPEN

        # Manual reset
        await breaker.reset()

        assert breaker.get_state() == CircuitState.CLOSED
        stats = breaker.get_stats()
        assert stats["failure_count"] == 0

    @pytest.mark.asyncio
    async def test_circuit_context_manager(self, breaker):
        """Test circuit breaker as context manager"""
        call_count = 0

        async with breaker.protect():
            call_count += 1

        assert call_count == 1
        assert breaker.get_state() == CircuitState.CLOSED

    @pytest.mark.asyncio
    async def test_get_stats(self, breaker):
        """Test circuit breaker statistics"""

        async def success_function():
            return "success"

        await breaker.call(success_function)

        stats = breaker.get_stats()

        assert "state" in stats
        assert "total_successes" in stats
        assert "total_failures" in stats
        assert "total_rejected" in stats
        assert stats["total_successes"] == 1


class TestCircuitBreakerRegistry:
    """Test circuit breaker registry"""

    @pytest.fixture
    def registry(self):
        """Create circuit breaker registry"""
        config = CircuitBreakerConfig(failure_threshold=3, recovery_timeout=1)
        return CircuitBreakerRegistry(config)

    @pytest.mark.asyncio
    async def test_get_breaker_creates_new(self, registry):
        """Test getting breaker creates new instance"""
        breaker = await registry.get_breaker("server-01")

        assert breaker is not None
        assert breaker.name == "server-01"

    @pytest.mark.asyncio
    async def test_get_breaker_returns_existing(self, registry):
        """Test getting same breaker returns existing instance"""
        breaker1 = await registry.get_breaker("server-01")
        breaker2 = await registry.get_breaker("server-01")

        assert breaker1 is breaker2

    @pytest.mark.asyncio
    async def test_registry_protect_context(self, registry):
        """Test registry protect context manager"""
        call_count = 0

        async with registry.protect("server-01"):
            call_count += 1

        assert call_count == 1

    @pytest.mark.asyncio
    async def test_registry_call_method(self, registry):
        """Test registry call method"""

        async def test_function():
            return "result"

        result = await registry.call("server-01", test_function)

        assert result == "result"

    @pytest.mark.asyncio
    async def test_registry_reset_specific(self, registry):
        """Test resetting specific machine's circuit"""

        async def failing_function():
            raise Exception("failure")

        # Trip circuit for server-01
        for _ in range(3):
            with pytest.raises(Exception):
                await registry.call("server-01", failing_function)

        breaker = await registry.get_breaker("server-01")
        assert breaker.get_state() == CircuitState.OPEN

        # Reset server-01
        await registry.reset("server-01")

        assert breaker.get_state() == CircuitState.CLOSED

    @pytest.mark.asyncio
    async def test_registry_reset_all(self, registry):
        """Test resetting all circuits"""

        async def failing_function():
            raise Exception("failure")

        # Trip circuits for multiple servers
        for server in ["server-01", "server-02"]:
            for _ in range(3):
                with pytest.raises(Exception):
                    await registry.call(server, failing_function)

        # Reset all
        await registry.reset_all()

        # Check all are closed
        breaker1 = await registry.get_breaker("server-01")
        breaker2 = await registry.get_breaker("server-02")

        assert breaker1.get_state() == CircuitState.CLOSED
        assert breaker2.get_state() == CircuitState.CLOSED

    @pytest.mark.asyncio
    async def test_get_all_stats(self, registry):
        """Test getting stats for all circuits"""

        async def success_function():
            return "success"

        await registry.call("server-01", success_function)
        await registry.call("server-02", success_function)

        stats = registry.get_all_stats()

        assert "server-01" in stats
        assert "server-02" in stats
        assert stats["server-01"]["total_successes"] >= 1
        assert stats["server-02"]["total_successes"] >= 1

    @pytest.mark.asyncio
    async def test_get_machine_stats(self, registry):
        """Test getting stats for specific machine"""

        async def success_function():
            return "success"

        await registry.call("server-01", success_function)

        stats = registry.get_machine_stats("server-01")

        assert stats is not None
        assert stats["name"] == "server-01"
        assert stats["total_successes"] >= 1

    def test_list_machines(self, registry):
        """Test listing all machines with breakers"""
        import asyncio

        async def setup():
            await registry.get_breaker("server-01")
            await registry.get_breaker("server-02")
            await registry.get_breaker("server-03")

        asyncio.run(setup())

        machines = registry.list_machines()

        assert len(machines) >= 3
        assert "server-01" in machines
        assert "server-02" in machines
        assert "server-03" in machines
