"""
Metrics Collection Task Queue System with Rate Limiting

Features:
- asyncio.Queue for task management
- Worker pool with 5 workers
- Rate limiting (max 10 requests/second)
- Backpressure handling
- Priority queue support (real-time requests get high priority)
"""

import asyncio
import random
import time
from collections import defaultdict
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any, Callable, Dict, List, Optional


class Priority(IntEnum):
    """Task priority levels"""

    LOW = 3
    NORMAL = 2
    HIGH = 1  # Real-time requests
    CRITICAL = 0


@dataclass(order=True)
class MetricsTask:
    """Represents a metrics collection task with priority"""

    priority: int
    task_id: str = field(compare=False)
    metric_type: str = field(compare=False)
    data: Dict[str, Any] = field(compare=False)
    timestamp: float = field(default_factory=time.time, compare=False)
    retries: int = field(default=0, compare=False)
    callback: Optional[Callable] = field(default=None, compare=False, repr=False)


class RateLimiter:
    """
    Token bucket rate limiter for controlling request rate
    Allows max 10 requests per second
    """

    def __init__(self, max_rate: int = 10, time_window: float = 1.0):
        self.max_rate = max_rate
        self.time_window = time_window
        self.tokens = max_rate
        self.last_update = time.time()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        """Acquire a token, waiting if necessary"""
        async with self._lock:
            while True:
                now = time.time()
                elapsed = now - self.last_update

                # Refill tokens based on elapsed time
                self.tokens = min(
                    self.max_rate, self.tokens + elapsed * (self.max_rate / self.time_window)
                )
                self.last_update = now

                if self.tokens >= 1:
                    self.tokens -= 1
                    return

                # Calculate wait time for next token
                wait_time = (1 - self.tokens) * (self.time_window / self.max_rate)
                await asyncio.sleep(wait_time)

    def get_current_rate(self) -> float:
        """Get current token availability (computed lazily from elapsed time)."""
        now = time.time()
        elapsed = now - self.last_update
        return min(
            self.max_rate,
            self.tokens + elapsed * (self.max_rate / self.time_window),
        )


class QueueStatistics:
    """Track queue and worker statistics"""

    def __init__(self):
        self.tasks_submitted = 0
        self.tasks_completed = 0
        self.tasks_failed = 0
        self.tasks_by_priority = defaultdict(int)
        self.tasks_by_type = defaultdict(int)
        self.total_wait_time = 0.0
        self.total_processing_time = 0.0
        self.backpressure_events = 0
        self.rate_limit_waits = 0
        self._lock = asyncio.Lock()

    async def record_submission(self, task: MetricsTask) -> None:
        """Record task submission"""
        async with self._lock:
            self.tasks_submitted += 1
            self.tasks_by_priority[Priority(task.priority).name] += 1
            self.tasks_by_type[task.metric_type] += 1

    async def record_completion(
        self, task: MetricsTask, wait_time: float, processing_time: float
    ) -> None:
        """Record task completion"""
        async with self._lock:
            self.tasks_completed += 1
            self.total_wait_time += wait_time
            self.total_processing_time += processing_time

    async def record_failure(self) -> None:
        """Record task failure"""
        async with self._lock:
            self.tasks_failed += 1

    async def record_backpressure(self) -> None:
        """Record backpressure event"""
        async with self._lock:
            self.backpressure_events += 1

    async def record_rate_limit(self) -> None:
        """Record rate limit wait"""
        async with self._lock:
            self.rate_limit_waits += 1

    async def get_summary(self) -> Dict[str, Any]:
        """Get statistics summary"""
        async with self._lock:
            avg_wait = self.total_wait_time / max(1, self.tasks_completed)
            avg_processing = self.total_processing_time / max(1, self.tasks_completed)

            return {
                "tasks_submitted": self.tasks_submitted,
                "tasks_completed": self.tasks_completed,
                "tasks_failed": self.tasks_failed,
                "tasks_pending": self.tasks_submitted - self.tasks_completed - self.tasks_failed,
                "tasks_by_priority": dict(self.tasks_by_priority),
                "tasks_by_type": dict(self.tasks_by_type),
                "avg_wait_time": round(avg_wait, 4),
                "avg_processing_time": round(avg_processing, 4),
                "backpressure_events": self.backpressure_events,
                "rate_limit_waits": self.rate_limit_waits,
                "success_rate": round(self.tasks_completed / max(1, self.tasks_submitted) * 100, 2),
            }


class MetricsQueue:
    """
    Main metrics collection queue system
    Manages worker pool, rate limiting, and task distribution
    """

    def __init__(
        self,
        num_workers: int = 5,
        max_queue_size: int = 1000,
        max_rate: int = 10,
        max_retries: int = 3,
    ):
        self.num_workers = num_workers
        self.max_queue_size = max_queue_size
        self.max_retries = max_retries

        # Priority queue for tasks
        self.queue: asyncio.PriorityQueue = asyncio.PriorityQueue(maxsize=max_queue_size)

        # Rate limiter
        self.rate_limiter = RateLimiter(max_rate=max_rate)

        # Statistics
        self.stats = QueueStatistics()

        # Worker management
        self.workers: List[asyncio.Task] = []
        self.worker_stats: Dict[int, Dict[str, Any]] = {}
        self._shutdown = False
        self._running = False

    async def submit_task(
        self,
        task_id: str,
        metric_type: str,
        data: Dict[str, Any],
        priority: Priority = Priority.NORMAL,
        callback: Optional[Callable] = None,
    ) -> bool:
        """
        Submit a metrics collection task
        Returns True if task was queued, False if queue is full (backpressure)
        """
        task = MetricsTask(
            priority=priority.value,
            task_id=task_id,
            metric_type=metric_type,
            data=data,
            callback=callback,
        )

        try:
            # Non-blocking put - handle backpressure
            self.queue.put_nowait(task)
            await self.stats.record_submission(task)
            return True
        except asyncio.QueueFull:
            await self.stats.record_backpressure()
            return False

    async def submit_realtime_task(
        self,
        task_id: str,
        metric_type: str,
        data: Dict[str, Any],
        callback: Optional[Callable] = None,
    ) -> bool:
        """Submit a high-priority real-time task"""
        return await self.submit_task(
            task_id=task_id,
            metric_type=metric_type,
            data=data,
            priority=Priority.HIGH,
            callback=callback,
        )

    async def _process_task(self, task: MetricsTask) -> bool:
        """
        Process a single metrics task
        This is where actual metrics collection would happen
        """
        try:
            # Simulate metrics collection work
            await asyncio.sleep(random.uniform(0.05, 0.2))

            # Simulate occasional failures
            if random.random() < 0.05:  # 5% failure rate
                raise Exception(f"Failed to collect {task.metric_type}")

            # Execute callback if provided
            if task.callback:
                await task.callback(task)

            return True

        except Exception as e:
            print(f"Task {task.task_id} failed: {e}")
            return False

    async def _worker(self, worker_id: int) -> None:
        """
        Worker coroutine that processes tasks from the queue
        """
        self.worker_stats[worker_id] = {
            "tasks_processed": 0,
            "tasks_failed": 0,
            "total_processing_time": 0.0,
        }

        print(f"Worker {worker_id} started")

        while not self._shutdown:
            try:
                # Get task from priority queue with timeout
                task = await asyncio.wait_for(self.queue.get(), timeout=1.0)

                wait_time = time.time() - task.timestamp

                # Apply rate limiting
                rate_limit_start = time.time()
                await self.rate_limiter.acquire()
                rate_limit_wait = time.time() - rate_limit_start

                if rate_limit_wait > 0.001:  # Only count significant waits
                    await self.stats.record_rate_limit()

                # Process the task
                processing_start = time.time()
                success = await self._process_task(task)
                processing_time = time.time() - processing_start

                # Update statistics
                if success:
                    await self.stats.record_completion(task, wait_time, processing_time)
                    self.worker_stats[worker_id]["tasks_processed"] += 1
                    self.worker_stats[worker_id]["total_processing_time"] += processing_time
                else:
                    # Handle retry logic
                    if task.retries < self.max_retries:
                        task.retries += 1
                        # Re-queue with lower priority
                        await self.queue.put(task)
                        print(
                            f"Task {task.task_id} re-queued (retry {task.retries}/{self.max_retries})"
                        )
                    else:
                        await self.stats.record_failure()
                        self.worker_stats[worker_id]["tasks_failed"] += 1
                        print(
                            f"Task {task.task_id} failed permanently after {self.max_retries} retries"
                        )

                # Mark task as done
                self.queue.task_done()

            except asyncio.TimeoutError:
                # No tasks available, continue waiting
                continue
            except Exception as e:
                print(f"Worker {worker_id} error: {e}")
                await asyncio.sleep(0.1)

        print(f"Worker {worker_id} stopped")

    async def start(self) -> None:
        """Start the worker pool"""
        if self._running:
            print("Queue system already running")
            return

        self._running = True
        self._shutdown = False

        # Start worker tasks
        for i in range(self.num_workers):
            worker = asyncio.create_task(self._worker(i))
            self.workers.append(worker)

        print(f"MetricsQueue started with {self.num_workers} workers")
        print(f"Rate limit: {self.rate_limiter.max_rate} requests/second")
        print(f"Max queue size: {self.max_queue_size}")

    async def stop(self, wait_for_completion: bool = True) -> None:
        """Stop the worker pool"""
        if not self._running:
            return

        print("Stopping MetricsQueue...")

        if wait_for_completion:
            # Wait for all queued tasks to complete
            await self.queue.join()

        # Signal workers to shutdown
        self._shutdown = True

        # Wait for all workers to finish
        await asyncio.gather(*self.workers, return_exceptions=True)

        self.workers.clear()
        self._running = False

        print("MetricsQueue stopped")

    def get_queue_size(self) -> int:
        """Get current queue size"""
        return self.queue.qsize()

    def is_backpressure(self) -> bool:
        """Check if queue is experiencing backpressure"""
        return self.queue.qsize() >= self.max_queue_size * 0.8

    async def get_statistics(self) -> Dict[str, Any]:
        """Get comprehensive statistics"""
        stats = await self.stats.get_summary()
        stats["queue_size"] = self.get_queue_size()
        stats["max_queue_size"] = self.max_queue_size
        stats["backpressure"] = self.is_backpressure()
        stats["worker_stats"] = self.worker_stats
        stats["num_workers"] = self.num_workers
        stats["rate_limit"] = f"{self.rate_limiter.max_rate}/s"
        stats["current_tokens"] = round(self.rate_limiter.get_current_rate(), 2)
        return stats


# Example usage and demonstration
async def sample_callback(task: MetricsTask):
    """Sample callback for task completion"""
    print(f"✓ Callback: Task {task.task_id} ({task.metric_type}) completed")


async def demo():
    """Demonstrate the metrics queue system"""
    print("=" * 70)
    print("METRICS QUEUE SYSTEM DEMONSTRATION")
    print("=" * 70)
    print()

    # Create and start the queue system
    metrics_queue = MetricsQueue(num_workers=5, max_queue_size=100, max_rate=10, max_retries=3)

    await metrics_queue.start()
    print()

    # Submit various types of tasks
    print("Submitting tasks...")
    print("-" * 70)

    # Submit normal priority tasks
    for i in range(20):
        await metrics_queue.submit_task(
            task_id=f"task-{i}",
            metric_type="cpu_usage",
            data={"value": random.uniform(0, 100), "host": f"server-{i % 5}"},
            priority=Priority.NORMAL,
        )

    # Submit high-priority real-time tasks
    for i in range(10):
        await metrics_queue.submit_realtime_task(
            task_id=f"realtime-{i}",
            metric_type="response_time",
            data={"value": random.uniform(10, 500), "endpoint": "/api/v1/data"},
            callback=sample_callback,
        )

    # Submit low priority batch tasks
    for i in range(15):
        await metrics_queue.submit_task(
            task_id=f"batch-{i}",
            metric_type="disk_usage",
            data={"value": random.uniform(0, 100), "volume": f"/dev/sda{i % 3}"},
            priority=Priority.LOW,
        )

    print("Submitted 45 tasks total")
    print()

    # Monitor progress
    print("Processing tasks...")
    print("-" * 70)

    for _ in range(5):
        await asyncio.sleep(1)
        stats = await metrics_queue.get_statistics()
        print(
            f"Progress: {stats['tasks_completed']}/{stats['tasks_submitted']} completed, "
            f"Queue size: {stats['queue_size']}, "
            f"Backpressure: {stats['backpressure']}"
        )

    print()
    print("Waiting for all tasks to complete...")
    await metrics_queue.stop(wait_for_completion=True)

    # Display final statistics
    print()
    print("=" * 70)
    print("FINAL STATISTICS")
    print("=" * 70)

    stats = await metrics_queue.get_statistics()

    print("\nOverall Metrics:")
    print(f"  Total Submitted:     {stats['tasks_submitted']}")
    print(f"  Total Completed:     {stats['tasks_completed']}")
    print(f"  Total Failed:        {stats['tasks_failed']}")
    print(f"  Success Rate:        {stats['success_rate']}%")
    print(f"  Backpressure Events: {stats['backpressure_events']}")
    print(f"  Rate Limit Waits:    {stats['rate_limit_waits']}")

    print("\nTiming Metrics:")
    print(f"  Avg Wait Time:       {stats['avg_wait_time']}s")
    print(f"  Avg Processing Time: {stats['avg_processing_time']}s")

    print("\nTasks by Priority:")
    for priority, count in stats["tasks_by_priority"].items():
        print(f"  {priority:8s}: {count}")

    print("\nTasks by Type:")
    for metric_type, count in stats["tasks_by_type"].items():
        print(f"  {metric_type:15s}: {count}")

    print("\nWorker Statistics:")
    for worker_id, worker_stats in stats["worker_stats"].items():
        avg_time = worker_stats["total_processing_time"] / max(1, worker_stats["tasks_processed"])
        print(
            f"  Worker {worker_id}: {worker_stats['tasks_processed']} tasks, "
            f"{worker_stats['tasks_failed']} failed, "
            f"avg {avg_time:.4f}s"
        )

    print()
    print("=" * 70)
    print("DEMONSTRATION COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    # Run the demonstration
    asyncio.run(demo())
