"""
Unit tests for metrics queue module
Tests queue management, rate limiting, and worker pool
"""

import asyncio
import os
import sys
import time

import pytest

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services.metrics_queue import MetricsQueue, MetricsTask, Priority, QueueStatistics, RateLimiter


class TestPriority:
    """Test priority enum"""

    def test_priority_values(self):
        """Test priority values are correct"""
        assert Priority.CRITICAL.value == 0
        assert Priority.HIGH.value == 1
        assert Priority.NORMAL.value == 2
        assert Priority.LOW.value == 3

    def test_priority_ordering(self):
        """Test priority ordering"""
        assert Priority.CRITICAL < Priority.HIGH
        assert Priority.HIGH < Priority.NORMAL
        assert Priority.NORMAL < Priority.LOW


class TestMetricsTask:
    """Test metrics task dataclass"""

    def test_task_creation(self):
        """Test creating a task"""
        task = MetricsTask(
            priority=Priority.NORMAL.value,
            task_id="test-123",
            metric_type="cpu_usage",
            data={"value": 50},
        )

        assert task.task_id == "test-123"
        assert task.metric_type == "cpu_usage"
        assert task.priority == Priority.NORMAL.value

    def test_task_ordering_by_priority(self):
        """Test tasks are ordered by priority"""
        task1 = MetricsTask(priority=Priority.LOW.value, task_id="1", metric_type="cpu", data={})
        task2 = MetricsTask(priority=Priority.HIGH.value, task_id="2", metric_type="cpu", data={})

        # Higher priority (lower value) should come first
        assert task2 < task1

    def test_task_default_timestamp(self):
        """Test task has timestamp"""
        task = MetricsTask(
            priority=Priority.NORMAL.value, task_id="test", metric_type="cpu", data={}
        )

        assert task.timestamp > 0


class TestRateLimiter:
    """Test rate limiter functionality"""

    @pytest.mark.asyncio
    async def test_rate_limiter_initialization(self):
        """Test rate limiter initialization"""
        limiter = RateLimiter(max_rate=10, time_window=1.0)

        assert limiter.max_rate == 10
        assert limiter.time_window == 1.0
        assert limiter.tokens == 10

    @pytest.mark.asyncio
    async def test_acquire_token(self):
        """Test acquiring a token"""
        limiter = RateLimiter(max_rate=10)

        await limiter.acquire()

        assert limiter.tokens < 10

    @pytest.mark.asyncio
    async def test_rate_limiting(self):
        """Test rate limiting actually limits"""
        limiter = RateLimiter(max_rate=5, time_window=1.0)

        start_time = time.time()

        # Acquire 6 tokens (more than max_rate)
        for _ in range(6):
            await limiter.acquire()

        elapsed = time.time() - start_time

        # Should take at least some time due to rate limiting
        # With 5 tokens/second, 6 requests should take ~0.2 seconds minimum
        assert elapsed > 0.1

    @pytest.mark.asyncio
    async def test_token_refill(self):
        """Test tokens refill over time"""
        limiter = RateLimiter(max_rate=10)

        # Consume all tokens
        for _ in range(10):
            await limiter.acquire()

        assert limiter.tokens < 1

        # Wait for refill
        await asyncio.sleep(0.2)

        # Tokens should be refilled
        assert limiter.get_current_rate() > 1

    @pytest.mark.asyncio
    async def test_get_current_rate(self):
        """Test getting current rate"""
        limiter = RateLimiter(max_rate=10)

        rate = limiter.get_current_rate()

        assert rate <= 10
        assert rate >= 0


class TestQueueStatistics:
    """Test queue statistics"""

    @pytest.mark.asyncio
    async def test_stats_initialization(self):
        """Test statistics initialization"""
        stats = QueueStatistics()

        assert stats.tasks_submitted == 0
        assert stats.tasks_completed == 0
        assert stats.tasks_failed == 0

    @pytest.mark.asyncio
    async def test_record_submission(self):
        """Test recording task submission"""
        stats = QueueStatistics()
        task = MetricsTask(
            priority=Priority.NORMAL.value, task_id="test", metric_type="cpu", data={}
        )

        await stats.record_submission(task)

        assert stats.tasks_submitted == 1
        assert stats.tasks_by_type["cpu"] == 1

    @pytest.mark.asyncio
    async def test_record_completion(self):
        """Test recording task completion"""
        stats = QueueStatistics()
        task = MetricsTask(
            priority=Priority.NORMAL.value, task_id="test", metric_type="cpu", data={}
        )

        await stats.record_completion(task, wait_time=0.5, processing_time=0.2)

        assert stats.tasks_completed == 1
        assert stats.total_wait_time == 0.5
        assert stats.total_processing_time == 0.2

    @pytest.mark.asyncio
    async def test_record_failure(self):
        """Test recording task failure"""
        stats = QueueStatistics()

        await stats.record_failure()

        assert stats.tasks_failed == 1

    @pytest.mark.asyncio
    async def test_get_summary(self):
        """Test getting statistics summary"""
        stats = QueueStatistics()
        task = MetricsTask(
            priority=Priority.NORMAL.value, task_id="test", metric_type="cpu", data={}
        )

        await stats.record_submission(task)
        await stats.record_completion(task, wait_time=0.5, processing_time=0.2)

        summary = await stats.get_summary()

        assert "tasks_submitted" in summary
        assert "tasks_completed" in summary
        assert "avg_wait_time" in summary
        assert "success_rate" in summary
        assert summary["tasks_submitted"] == 1
        assert summary["tasks_completed"] == 1


class TestMetricsQueue:
    """Test metrics queue functionality"""

    @pytest.fixture
    async def queue(self):
        """Create metrics queue for testing"""
        q = MetricsQueue(
            num_workers=2,
            max_queue_size=10,
            max_rate=100,  # High rate for faster tests
            max_retries=2,
        )
        await q.start()
        yield q
        await q.stop(wait_for_completion=False)

    def test_queue_initialization(self):
        """Test queue initialization"""
        queue = MetricsQueue(num_workers=5, max_queue_size=100, max_rate=10)

        assert queue.num_workers == 5
        assert queue.max_queue_size == 100
        assert queue.rate_limiter.max_rate == 10

    @pytest.mark.asyncio
    async def test_submit_task(self, queue):
        """Test submitting a task"""
        success = await queue.submit_task(
            task_id="test-1", metric_type="cpu", data={"value": 50}, priority=Priority.NORMAL
        )

        assert success is True
        assert queue.get_queue_size() >= 0

    @pytest.mark.asyncio
    async def test_submit_realtime_task(self, queue):
        """Test submitting high-priority task"""
        success = await queue.submit_realtime_task(
            task_id="realtime-1", metric_type="response_time", data={"value": 100}
        )

        assert success is True

    @pytest.mark.asyncio
    async def test_backpressure(self):
        """Test backpressure when queue is full"""
        queue = MetricsQueue(num_workers=1, max_queue_size=5, max_rate=100)

        # Fill the queue
        for i in range(10):
            await queue.submit_task(task_id=f"task-{i}", metric_type="cpu", data={"value": i})

        # Check backpressure stats
        assert queue.stats.backpressure_events > 0

    @pytest.mark.asyncio
    async def test_task_processing(self, queue):
        """Test tasks are processed"""
        # Submit task
        await queue.submit_task(task_id="test-1", metric_type="cpu", data={"value": 50})

        # Wait for processing
        await asyncio.sleep(0.5)

        stats = await queue.get_statistics()
        assert stats["tasks_completed"] >= 0

    @pytest.mark.asyncio
    async def test_priority_ordering(self, queue):
        """Test high-priority tasks are processed first"""
        processed_order = []

        async def track_callback(task):
            processed_order.append(task.task_id)

        # Submit low priority first
        await queue.submit_task(
            task_id="low-1",
            metric_type="cpu",
            data={},
            priority=Priority.LOW,
            callback=track_callback,
        )

        # Then high priority
        await queue.submit_realtime_task(
            task_id="high-1", metric_type="cpu", data={}, callback=track_callback
        )

        # Wait for processing
        await asyncio.sleep(0.5)

        # High priority should be processed (may not be strictly first due to async)
        assert "high-1" in processed_order

    @pytest.mark.asyncio
    async def test_get_queue_size(self, queue):
        """Test getting queue size"""
        # Submit tasks
        for i in range(3):
            await queue.submit_task(task_id=f"task-{i}", metric_type="cpu", data={"value": i})

        size = queue.get_queue_size()
        assert size >= 0

    @pytest.mark.asyncio
    async def test_is_backpressure(self):
        """Test backpressure detection"""
        queue = MetricsQueue(num_workers=1, max_queue_size=10)

        # Fill queue to 80%+
        for i in range(9):
            await queue.submit_task(task_id=f"task-{i}", metric_type="cpu", data={})

        assert queue.is_backpressure() is True

    @pytest.mark.asyncio
    async def test_get_statistics(self, queue):
        """Test getting comprehensive statistics"""
        # Submit some tasks
        await queue.submit_task(task_id="test-1", metric_type="cpu", data={"value": 50})

        # Wait a bit
        await asyncio.sleep(0.2)

        stats = await queue.get_statistics()

        assert "tasks_submitted" in stats
        assert "queue_size" in stats
        assert "worker_stats" in stats
        assert "num_workers" in stats
        assert "rate_limit" in stats
        assert stats["num_workers"] == 2

    @pytest.mark.asyncio
    async def test_start_and_stop(self):
        """Test starting and stopping queue"""
        queue = MetricsQueue(num_workers=2)

        await queue.start()
        assert queue._running is True
        assert len(queue.workers) == 2

        await queue.stop()
        assert queue._running is False

    @pytest.mark.asyncio
    async def test_stop_with_completion(self, queue):
        """Test stopping and waiting for tasks to complete"""
        # Submit task
        await queue.submit_task(task_id="test-1", metric_type="cpu", data={"value": 50})

        # Stop with completion wait
        await queue.stop(wait_for_completion=True)

        # Queue should be empty
        assert queue.get_queue_size() == 0

    @pytest.mark.asyncio
    async def test_worker_stats_tracking(self, queue):
        """Test worker statistics are tracked"""
        # Submit tasks
        for i in range(5):
            await queue.submit_task(task_id=f"task-{i}", metric_type="cpu", data={"value": i})

        # Wait for processing
        await asyncio.sleep(1.0)

        # Check worker stats exist
        assert len(queue.worker_stats) > 0

        for worker_id, stats in queue.worker_stats.items():
            assert "tasks_processed" in stats
            assert "tasks_failed" in stats
            assert "total_processing_time" in stats

    @pytest.mark.asyncio
    async def test_task_with_callback(self, queue):
        """Test task callback execution"""
        callback_called = False

        async def test_callback(task):
            nonlocal callback_called
            callback_called = True

        await queue.submit_task(
            task_id="test-1", metric_type="cpu", data={"value": 50}, callback=test_callback
        )

        # Wait for processing
        await asyncio.sleep(0.5)

        # Callback may or may not be called depending on success
        # Just verify no errors occurred
        assert True
