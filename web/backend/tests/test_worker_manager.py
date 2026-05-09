"""
Tests for WorkerManager and CircuitBreaker
"""

import asyncio

import pytest

from services.worker_manager import CircuitBreaker, WorkerManager


class TestCircuitBreaker:
    """Test CircuitBreaker functionality"""

    @pytest.mark.asyncio
    async def test_circuit_breaker_closed_state(self):
        """Test circuit breaker starts in closed state"""
        cb = CircuitBreaker(failure_threshold=3, timeout=60)
        assert cb.state == "closed"
        assert cb.failure_count == 0

    @pytest.mark.asyncio
    async def test_circuit_breaker_successful_call(self):
        """Test successful function call through circuit breaker"""
        cb = CircuitBreaker(failure_threshold=3, timeout=60)

        async def success_func():
            return "success"

        result = await cb.call(success_func)
        assert result == "success"
        assert cb.state == "closed"
        assert cb.failure_count == 0

    @pytest.mark.asyncio
    async def test_circuit_breaker_opens_on_failures(self):
        """Test circuit breaker opens after threshold failures"""
        cb = CircuitBreaker(failure_threshold=3, timeout=60)

        async def failing_func():
            raise Exception("Test failure")

        # First failure
        with pytest.raises(Exception):
            await cb.call(failing_func)
        assert cb.state == "closed"
        assert cb.failure_count == 1

        # Second failure
        with pytest.raises(Exception):
            await cb.call(failing_func)
        assert cb.state == "closed"
        assert cb.failure_count == 2

        # Third failure - should open circuit
        with pytest.raises(Exception):
            await cb.call(failing_func)
        assert cb.state == "open"
        assert cb.failure_count == 3

    @pytest.mark.asyncio
    async def test_circuit_breaker_stays_open(self):
        """Test circuit breaker stays open during timeout"""
        cb = CircuitBreaker(failure_threshold=2, timeout=60)

        async def failing_func():
            raise Exception("Test failure")

        # Trigger circuit open
        for _ in range(2):
            with pytest.raises(Exception):
                await cb.call(failing_func)

        assert cb.state == "open"

        # Should reject calls while open
        async def success_func():
            return "success"

        with pytest.raises(Exception, match="Circuit breaker is OPEN"):
            await cb.call(success_func)

    @pytest.mark.asyncio
    async def test_circuit_breaker_half_open_transition(self):
        """Test circuit breaker transitions to half-open after timeout"""
        cb = CircuitBreaker(failure_threshold=2, timeout=1)  # 1 second timeout

        async def failing_func():
            raise Exception("Test failure")

        # Open the circuit
        for _ in range(2):
            with pytest.raises(Exception):
                await cb.call(failing_func)

        assert cb.state == "open"

        # Wait for timeout
        await asyncio.sleep(1.1)

        # Next call should transition to half-open
        async def success_func():
            return "success"

        result = await cb.call(success_func)
        assert result == "success"
        assert cb.state == "closed"  # Success closes circuit
        assert cb.failure_count == 0

    @pytest.mark.asyncio
    async def test_circuit_breaker_get_state(self):
        """Test circuit breaker state retrieval"""
        cb = CircuitBreaker(failure_threshold=3, timeout=60)

        state = cb.get_state()
        assert state["state"] == "closed"
        assert state["failure_count"] == 0
        assert state["last_failure_time"] is None


class TestWorkerManager:
    """Test WorkerManager functionality"""

    @pytest.mark.asyncio
    async def test_worker_manager_initialization(self):
        """Test WorkerManager initializes correctly"""
        wm = WorkerManager()
        assert len(wm.workers) == 0
        assert len(wm.circuit_breakers) == 0
        assert wm._shutdown is False

    @pytest.mark.asyncio
    async def test_start_simple_worker(self):
        """Test starting a simple worker"""
        wm = WorkerManager()
        call_count = 0

        async def simple_worker():
            nonlocal call_count
            call_count += 1
            await asyncio.sleep(0.1)

        await wm.start_worker(name="test_worker", func=simple_worker, timeout=5, enabled=True)

        assert "test_worker" in wm.workers
        assert "test_worker" in wm.circuit_breakers

        # Give worker time to execute
        await asyncio.sleep(0.5)

        # Worker should have been called at least once
        assert call_count >= 1

        await wm.shutdown()

    @pytest.mark.asyncio
    async def test_worker_disabled(self):
        """Test that disabled workers are not started"""
        wm = WorkerManager()
        call_count = 0

        async def disabled_worker():
            nonlocal call_count
            call_count += 1

        await wm.start_worker(
            name="disabled_worker", func=disabled_worker, timeout=5, enabled=False
        )

        assert "disabled_worker" not in wm.workers
        await asyncio.sleep(0.2)
        assert call_count == 0

    @pytest.mark.asyncio
    async def test_worker_timeout(self):
        """Test worker timeout handling"""
        wm = WorkerManager()
        timeout_count = 0

        async def slow_worker():
            nonlocal timeout_count
            timeout_count += 1
            await asyncio.sleep(10)  # Longer than timeout

        await wm.start_worker(
            name="slow_worker",
            func=slow_worker,
            timeout=0.1,  # Very short timeout
            enabled=True,
            backoff_seconds=0.2,
        )

        # Give time for timeout to occur
        await asyncio.sleep(0.5)

        # Worker should have timed out at least once
        assert timeout_count >= 1

        await wm.shutdown()

    @pytest.mark.asyncio
    async def test_worker_error_handling(self):
        """Test worker error handling with backoff"""
        wm = WorkerManager()
        error_count = 0

        async def failing_worker():
            nonlocal error_count
            error_count += 1
            raise Exception("Test error")

        await wm.start_worker(
            name="failing_worker", func=failing_worker, timeout=5, enabled=True, backoff_seconds=0.1
        )

        # Give time for multiple failures
        await asyncio.sleep(0.5)

        # Worker should have failed multiple times
        assert error_count >= 2

        await wm.shutdown()

    @pytest.mark.asyncio
    async def test_worker_circuit_breaker_integration(self):
        """Test worker integrates with circuit breaker"""
        wm = WorkerManager()
        call_count = 0

        async def circuit_test_worker():
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise Exception("Fail to trigger circuit")
            return "success"

        await wm.start_worker(
            name="circuit_worker",
            func=circuit_test_worker,
            timeout=5,
            enabled=True,
            failure_threshold=2,  # Open after 2 failures
            backoff_seconds=0.1,
        )

        # Give time for circuit to open
        await asyncio.sleep(0.5)

        # Circuit breaker should be open
        cb = wm.circuit_breakers["circuit_worker"]
        assert cb.state == "open"

        await wm.shutdown()

    @pytest.mark.asyncio
    async def test_stop_specific_worker(self):
        """Test stopping a specific worker"""
        wm = WorkerManager()
        call_count = 0

        async def stoppable_worker():
            nonlocal call_count
            call_count += 1
            await asyncio.sleep(0.1)

        await wm.start_worker(name="stoppable", func=stoppable_worker, timeout=5, enabled=True)

        await asyncio.sleep(0.2)
        initial_count = call_count

        # Stop the worker
        await wm.stop_worker("stoppable")

        assert "stoppable" not in wm.workers

        # Give time to verify it's stopped
        await asyncio.sleep(0.3)

        # Count should not increase significantly after stopping
        assert call_count <= initial_count + 2  # Allow for in-flight execution

    @pytest.mark.asyncio
    async def test_shutdown_all_workers(self):
        """Test shutting down all workers"""
        wm = WorkerManager()

        async def worker1():
            await asyncio.sleep(0.1)

        async def worker2():
            await asyncio.sleep(0.1)

        await wm.start_worker("worker1", worker1, timeout=5, enabled=True)
        await wm.start_worker("worker2", worker2, timeout=5, enabled=True)

        assert len(wm.workers) == 2

        await wm.shutdown()

        assert len(wm.workers) == 0
        assert wm._shutdown is True

    @pytest.mark.asyncio
    async def test_get_status(self):
        """Test getting worker manager status"""
        wm = WorkerManager()

        async def status_worker():
            await asyncio.sleep(0.1)

        await wm.start_worker(name="status_test", func=status_worker, timeout=5, enabled=True)

        status = wm.get_status()

        assert "workers" in status
        assert "status_test" in status["workers"]
        assert status["workers"]["status_test"]["running"] is True
        assert status["workers"]["status_test"]["circuit_breaker"] is not None

        await wm.shutdown()

    @pytest.mark.asyncio
    async def test_multiple_workers_concurrently(self):
        """Test running multiple workers concurrently"""
        wm = WorkerManager()
        counts = {"worker1": 0, "worker2": 0, "worker3": 0}

        async def make_worker(name):
            async def worker():
                counts[name] += 1
                await asyncio.sleep(0.05)

            return worker

        for name in ["worker1", "worker2", "worker3"]:
            worker_func = await make_worker(name)
            await wm.start_worker(name=name, func=worker_func, timeout=5, enabled=True)

        # Let workers run
        await asyncio.sleep(0.3)

        # All workers should have executed
        assert counts["worker1"] >= 1
        assert counts["worker2"] >= 1
        assert counts["worker3"] >= 1

        await wm.shutdown()


class TestWorkerManagerEdgeCases:
    """Test edge cases and error conditions"""

    @pytest.mark.asyncio
    async def test_shutdown_with_no_workers(self):
        """Test shutdown when no workers are running"""
        wm = WorkerManager()
        await wm.shutdown()  # Should not raise
        assert len(wm.workers) == 0

    @pytest.mark.asyncio
    async def test_stop_nonexistent_worker(self):
        """Test stopping a worker that doesn't exist"""
        wm = WorkerManager()
        # Should not raise an exception
        await wm.stop_worker("nonexistent")

    @pytest.mark.asyncio
    async def test_worker_with_custom_circuit_breaker_settings(self):
        """Test worker with custom circuit breaker configuration"""
        wm = WorkerManager()
        error_count = 0

        async def custom_worker():
            nonlocal error_count
            error_count += 1
            raise Exception("Intentional failure")

        await wm.start_worker(
            name="custom_cb",
            func=custom_worker,
            timeout=5,
            enabled=True,
            failure_threshold=5,  # Custom threshold
            circuit_timeout=30,  # Custom timeout
            backoff_seconds=0.05,
        )

        # Wait for failures to accumulate
        await asyncio.sleep(0.4)

        cb = wm.circuit_breakers["custom_cb"]

        # Should have failed multiple times but may or may not be open yet
        # depending on exact timing
        assert cb.failure_count >= 1

        await wm.shutdown()
