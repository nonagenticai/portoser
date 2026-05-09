"""
Circuit Breaker Pattern for SSH Connections

Implements a circuit breaker to prevent cascading failures when SSH connections fail.
Tracks failures per machine and implements CLOSED, OPEN, and HALF_OPEN states.
"""

import asyncio
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, Optional


class CircuitState(Enum):
    """Circuit breaker states"""

    CLOSED = "closed"  # Normal operation, requests allowed
    OPEN = "open"  # Circuit tripped, requests blocked
    HALF_OPEN = "half_open"  # Testing if circuit can close


@dataclass
class CircuitBreakerConfig:
    """Configuration for circuit breaker behavior"""

    failure_threshold: int = 5  # Consecutive failures before opening
    recovery_timeout: int = 60  # Seconds before attempting half-open
    success_threshold: int = 1  # Successes needed to close from half-open


@dataclass
class CircuitStats:
    """Statistics for a circuit breaker"""

    state: CircuitState = CircuitState.CLOSED
    failure_count: int = 0
    success_count: int = 0
    last_failure_time: Optional[float] = None
    last_state_change: float = field(default_factory=time.time)
    total_failures: int = 0
    total_successes: int = 0
    total_rejected: int = 0


class CircuitBreakerError(Exception):
    """Raised when circuit breaker is open"""

    pass


class CircuitBreaker:
    """
    Circuit breaker for a single machine/resource.

    States:
    - CLOSED: Normal operation, failures are counted
    - OPEN: Circuit is open, all requests fail fast
    - HALF_OPEN: Testing if service recovered, limited requests allowed
    """

    def __init__(self, name: str, config: Optional[CircuitBreakerConfig] = None):
        self.name = name
        self.config = config or CircuitBreakerConfig()
        self.stats = CircuitStats()
        self._lock = asyncio.Lock()

    async def call(self, func: Callable, *args, **kwargs) -> Any:
        """
        Execute a function with circuit breaker protection.

        Args:
            func: Async function to execute
            *args: Positional arguments for func
            **kwargs: Keyword arguments for func

        Returns:
            Result of func execution

        Raises:
            CircuitBreakerError: If circuit is open
            Exception: Any exception from func execution
        """
        async with self._lock:
            await self._check_state()

            if self.stats.state == CircuitState.OPEN:
                self.stats.total_rejected += 1
                raise CircuitBreakerError(
                    f"Circuit breaker '{self.name}' is OPEN. Fast-failing request."
                )

        # Execute the function
        try:
            result = await func(*args, **kwargs)
            await self._on_success()
            return result
        except Exception:
            await self._on_failure()
            raise

    @asynccontextmanager
    async def protect(self):
        """
        Async context manager for circuit breaker protection.

        Usage:
            async with circuit_breaker.protect():
                # Your SSH connection code here
                pass
        """
        async with self._lock:
            await self._check_state()

            if self.stats.state == CircuitState.OPEN:
                self.stats.total_rejected += 1
                raise CircuitBreakerError(
                    f"Circuit breaker '{self.name}' is OPEN. Fast-failing request."
                )

        try:
            yield
            await self._on_success()
        except Exception:
            await self._on_failure()
            raise

    async def _check_state(self):
        """Check if circuit should transition from OPEN to HALF_OPEN"""
        if self.stats.state == CircuitState.OPEN:
            if self.stats.last_failure_time is not None:
                elapsed = time.time() - self.stats.last_failure_time
                if elapsed >= self.config.recovery_timeout:
                    await self._transition_to_half_open()

    async def _on_success(self):
        """Handle successful operation"""
        async with self._lock:
            self.stats.total_successes += 1

            if self.stats.state == CircuitState.HALF_OPEN:
                self.stats.success_count += 1
                if self.stats.success_count >= self.config.success_threshold:
                    await self._transition_to_closed()
            elif self.stats.state == CircuitState.CLOSED:
                # Reset failure count on success in closed state
                self.stats.failure_count = 0

    async def _on_failure(self):
        """Handle failed operation"""
        async with self._lock:
            self.stats.total_failures += 1
            self.stats.failure_count += 1
            self.stats.last_failure_time = time.time()

            if self.stats.state == CircuitState.HALF_OPEN:
                # Any failure in half-open state returns to open
                await self._transition_to_open()
            elif self.stats.state == CircuitState.CLOSED:
                if self.stats.failure_count >= self.config.failure_threshold:
                    await self._transition_to_open()

    async def _transition_to_open(self):
        """Transition circuit to OPEN state"""
        self.stats.state = CircuitState.OPEN
        self.stats.last_state_change = time.time()
        self.stats.success_count = 0

    async def _transition_to_half_open(self):
        """Transition circuit to HALF_OPEN state"""
        self.stats.state = CircuitState.HALF_OPEN
        self.stats.last_state_change = time.time()
        self.stats.failure_count = 0
        self.stats.success_count = 0

    async def _transition_to_closed(self):
        """Transition circuit to CLOSED state"""
        self.stats.state = CircuitState.CLOSED
        self.stats.last_state_change = time.time()
        self.stats.failure_count = 0
        self.stats.success_count = 0

    async def reset(self):
        """Manually reset the circuit breaker to CLOSED state"""
        async with self._lock:
            await self._transition_to_closed()

    def get_state(self) -> CircuitState:
        """Get current circuit state"""
        return self.stats.state

    def get_stats(self) -> Dict[str, Any]:
        """Get circuit breaker statistics"""
        return {
            "name": self.name,
            "state": self.stats.state.value,
            "failure_count": self.stats.failure_count,
            "success_count": self.stats.success_count,
            "total_failures": self.stats.total_failures,
            "total_successes": self.stats.total_successes,
            "total_rejected": self.stats.total_rejected,
            "last_failure_time": self.stats.last_failure_time,
            "last_state_change": self.stats.last_state_change,
            "time_since_last_failure": (
                time.time() - self.stats.last_failure_time if self.stats.last_failure_time else None
            ),
            "time_in_current_state": time.time() - self.stats.last_state_change,
        }


class CircuitBreakerRegistry:
    """
    Registry managing circuit breakers for multiple machines.

    Automatically creates circuit breakers per machine on first access.
    """

    def __init__(self, config: Optional[CircuitBreakerConfig] = None):
        self.config = config or CircuitBreakerConfig()
        self._breakers: Dict[str, CircuitBreaker] = {}
        self._lock = asyncio.Lock()

    async def get_breaker(self, machine_id: str) -> CircuitBreaker:
        """
        Get or create a circuit breaker for a machine.

        Args:
            machine_id: Unique identifier for the machine

        Returns:
            CircuitBreaker instance for the machine
        """
        if machine_id not in self._breakers:
            async with self._lock:
                # Double-check after acquiring lock
                if machine_id not in self._breakers:
                    self._breakers[machine_id] = CircuitBreaker(name=machine_id, config=self.config)
        return self._breakers[machine_id]

    @asynccontextmanager
    async def protect(self, machine_id: str):
        """
        Context manager for protecting operations for a specific machine.

        Usage:
            async with registry.protect("server-01"):
                # SSH connection code here
                pass
        """
        breaker = await self.get_breaker(machine_id)
        async with breaker.protect():
            yield

    async def call(self, machine_id: str, func: Callable, *args, **kwargs) -> Any:
        """
        Execute a function with circuit breaker protection for a machine.

        Args:
            machine_id: Unique identifier for the machine
            func: Async function to execute
            *args: Positional arguments for func
            **kwargs: Keyword arguments for func

        Returns:
            Result of func execution
        """
        breaker = await self.get_breaker(machine_id)
        return await breaker.call(func, *args, **kwargs)

    async def reset(self, machine_id: str):
        """Reset circuit breaker for a specific machine"""
        if machine_id in self._breakers:
            await self._breakers[machine_id].reset()

    async def reset_all(self):
        """Reset all circuit breakers"""
        for breaker in self._breakers.values():
            await breaker.reset()

    def get_all_stats(self) -> Dict[str, Dict[str, Any]]:
        """Get statistics for all circuit breakers"""
        return {machine_id: breaker.get_stats() for machine_id, breaker in self._breakers.items()}

    def get_machine_stats(self, machine_id: str) -> Optional[Dict[str, Any]]:
        """Get statistics for a specific machine"""
        if machine_id in self._breakers:
            return self._breakers[machine_id].get_stats()
        return None

    def list_machines(self) -> list[str]:
        """List all machines with circuit breakers"""
        return list(self._breakers.keys())


# Example usage and demonstration
async def example_ssh_connection(host: str, port: int = 22) -> str:
    """
    Simulated SSH connection function.
    Replace with actual SSH connection logic.
    """
    # Simulate connection
    await asyncio.sleep(0.1)

    # Simulate random failures for demonstration
    import random

    if random.random() < 0.3:  # 30% failure rate
        raise ConnectionError(f"Failed to connect to {host}:{port}")

    return f"Connected to {host}:{port}"


async def main():
    """Example usage of circuit breaker pattern"""

    # Create registry with custom config
    config = CircuitBreakerConfig(failure_threshold=5, recovery_timeout=60, success_threshold=1)
    registry = CircuitBreakerRegistry(config)

    machines = ["server-01", "server-02", "server-03"]

    # Simulate multiple connection attempts
    for i in range(20):
        for machine in machines:
            try:
                # Method 1: Using context manager
                async with registry.protect(machine):
                    result = await example_ssh_connection(machine)
                    print(f"[{i}] {machine}: {result}")

            except CircuitBreakerError:
                print(f"[{i}] {machine}: CIRCUIT OPEN - Fast fail")
            except Exception as e:
                print(f"[{i}] {machine}: Connection failed - {e}")

        await asyncio.sleep(0.5)

    # Print final statistics
    print("\n=== Final Statistics ===")
    stats = registry.get_all_stats()
    for machine_id, machine_stats in stats.items():
        print(f"\n{machine_id}:")
        print(f"  State: {machine_stats['state']}")
        print(f"  Total Successes: {machine_stats['total_successes']}")
        print(f"  Total Failures: {machine_stats['total_failures']}")
        print(f"  Total Rejected: {machine_stats['total_rejected']}")


if __name__ == "__main__":
    asyncio.run(main())
