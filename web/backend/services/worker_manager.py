"""
Worker Manager Service
Manages background workers with timeouts, circuit breakers, and readiness checks.
"""

import asyncio
import logging
import time
from typing import Any, Callable, Dict

logger = logging.getLogger(__name__)


class CircuitBreaker:
    """Circuit breaker to prevent cascading failures in background workers"""

    def __init__(self, failure_threshold: int = 3, timeout: int = 60):
        """
        Initialize circuit breaker

        Args:
            failure_threshold: Number of failures before opening circuit
            timeout: Seconds to wait before attempting half-open state
        """
        self.failure_count = 0
        self.failure_threshold = failure_threshold
        self.timeout = timeout
        self.last_failure_time = None
        self.state = "closed"  # closed, open, half-open

    async def call(self, func: Callable, *args, **kwargs):
        """
        Execute function with circuit breaker protection

        Args:
            func: Async function to execute
            *args: Function arguments
            **kwargs: Function keyword arguments

        Returns:
            Function result

        Raises:
            Exception: If circuit is open or function fails
        """
        if self.state == "open":
            if time.time() - self.last_failure_time > self.timeout:
                self.state = "half-open"
                logger.info("Circuit breaker entering half-open state")
            else:
                raise Exception("Circuit breaker is OPEN")

        try:
            result = await func(*args, **kwargs)
            if self.state == "half-open":
                self.state = "closed"
                self.failure_count = 0
                logger.info("Circuit breaker closed after successful call")
            return result
        except Exception:
            self.failure_count += 1
            self.last_failure_time = time.time()
            if self.failure_count >= self.failure_threshold:
                self.state = "open"
                logger.error(f"Circuit breaker opened after {self.failure_count} failures")
            raise

    def get_state(self) -> Dict[str, Any]:
        """Get current circuit breaker state"""
        return {
            "state": self.state,
            "failure_count": self.failure_count,
            "last_failure_time": self.last_failure_time,
        }


class WorkerManager:
    """Manages background workers with timeouts and circuit breakers"""

    def __init__(self):
        """Initialize worker manager"""
        self.workers: Dict[str, asyncio.Task] = {}
        self.circuit_breakers: Dict[str, CircuitBreaker] = {}
        self._shutdown = False

    async def start_worker(
        self,
        name: str,
        func: Callable,
        timeout: int = 30,
        enabled: bool = True,
        failure_threshold: int = 3,
        circuit_timeout: int = 60,
        backoff_seconds: int = 10,
        long_running: bool = False,
    ):
        """
        Start a background worker with timeout and circuit breaker

        Args:
            name: Worker name for identification
            func: Async function to run (should handle its own loop if needed)
            timeout: Timeout in seconds for each execution (ignored if long_running=True)
            enabled: Whether worker is enabled
            failure_threshold: Circuit breaker failure threshold
            circuit_timeout: Circuit breaker timeout
            backoff_seconds: Seconds to wait between retries after failure
            long_running: If True, worker runs indefinitely without timeout (for infinite loops)
        """
        if not enabled:
            logger.info(f"Worker {name} is disabled")
            return

        # Add circuit breaker
        cb = CircuitBreaker(failure_threshold=failure_threshold, timeout=circuit_timeout)
        self.circuit_breakers[name] = cb

        async def wrapped_task():
            """Wrapper task with timeout and circuit breaker"""
            while not self._shutdown:
                try:
                    if long_running:
                        # No timeout for infinite loop workers; if they return, do not spin
                        logger.debug(f"Worker {name} starting (long-running)...")
                        await cb.call(func)
                        logger.info(f"Long-running worker {name} exited normally; not restarting")
                        break
                    else:
                        # Apply timeout for short-lived tasks
                        logger.debug(f"Worker {name} executing (timeout={timeout}s)...")
                        await asyncio.wait_for(cb.call(func), timeout=timeout)
                        # Small delay between successful executions
                        await asyncio.sleep(1)
                except asyncio.TimeoutError:
                    if not long_running:
                        logger.error(f"Worker {name} timed out after {timeout}s")
                        await asyncio.sleep(backoff_seconds)
                except Exception as e:
                    logger.error(f"Worker {name} failed: {e}")
                    await asyncio.sleep(backoff_seconds)

        task = asyncio.create_task(wrapped_task())
        self.workers[name] = task
        if long_running:
            logger.info(f"Worker {name} started (long-running, no timeout)")
        else:
            logger.info(f"Worker {name} started with {timeout}s timeout")

    async def stop_worker(self, name: str):
        """
        Stop a specific worker

        Args:
            name: Worker name
        """
        if name in self.workers:
            task = self.workers[name]
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            del self.workers[name]
            logger.info(f"Worker {name} stopped")

    async def shutdown(self):
        """Shutdown all workers gracefully"""
        self._shutdown = True
        logger.info(f"Shutting down {len(self.workers)} workers...")

        for name, task in self.workers.items():
            task.cancel()

        # Wait for all tasks to complete
        if self.workers:
            await asyncio.gather(*self.workers.values(), return_exceptions=True)

        self.workers.clear()
        logger.info("All workers shut down")

    def get_status(self) -> Dict[str, Any]:
        """Get status of all workers"""
        return {
            "workers": {
                name: {
                    "running": not task.done(),
                    "circuit_breaker": self.circuit_breakers[name].get_state()
                    if name in self.circuit_breakers
                    else None,
                }
                for name, task in self.workers.items()
            }
        }
