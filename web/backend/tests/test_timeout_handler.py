"""
Unit tests for timeout handler module
Tests timeout handling, retry logic, and error categorization
"""

import asyncio
import os
import sys
from unittest.mock import patch

import pytest

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from utils.timeout_handler import (
    ErrorCategory,
    ExecutionResult,
    async_subprocess_with_timeout,
    categorize_error,
    handle_graceful_degradation,
    retry_with_backoff,
    ssh_execute_with_timeout,
)


class TestErrorCategorization:
    """Test error categorization logic"""

    def test_categorize_timeout_error(self):
        """Test timeout error categorization"""
        error = asyncio.TimeoutError("timeout")
        category = categorize_error(error)
        assert category == ErrorCategory.TIMEOUT

    def test_categorize_connection_refused(self):
        """Test connection refused error"""
        error = Exception("Connection refused")
        category = categorize_error(error)
        assert category == ErrorCategory.CONNECTION_REFUSED

    def test_categorize_permission_denied(self):
        """Test permission denied error"""
        error = Exception("Permission denied")
        category = categorize_error(error, "permission denied (publickey)")
        assert category == ErrorCategory.PERMISSION_DENIED

    def test_categorize_authentication_failed(self):
        """Test authentication failure"""
        error = Exception("Authentication failed")
        category = categorize_error(error)
        assert category == ErrorCategory.AUTHENTICATION_FAILED

    def test_categorize_command_not_found(self):
        """Test command not found"""
        error = Exception("error")
        category = categorize_error(error, "command not found")
        assert category == ErrorCategory.COMMAND_NOT_FOUND

    def test_categorize_unknown_error(self):
        """Test unknown error defaults correctly"""
        error = Exception("some random error")
        category = categorize_error(error)
        assert category == ErrorCategory.UNKNOWN


class TestAsyncSubprocessWithTimeout:
    """Test async subprocess execution with timeout"""

    @pytest.mark.asyncio
    async def test_successful_execution(self):
        """Test successful command execution"""
        result = await async_subprocess_with_timeout(["echo", "test"], timeout=5.0)

        assert result.success is True
        assert result.stdout == "test"
        assert result.return_code == 0
        assert result.error_category is None

    @pytest.mark.asyncio
    async def test_command_timeout(self):
        """Test command that exceeds timeout"""
        result = await async_subprocess_with_timeout(["sleep", "10"], timeout=0.5)

        assert result.success is False
        assert result.error_category == ErrorCategory.TIMEOUT
        assert "timeout" in result.error_message.lower()

    @pytest.mark.asyncio
    async def test_failed_command(self):
        """Test command that fails with non-zero exit"""
        result = await async_subprocess_with_timeout(["ls", "/nonexistent/path/12345"], timeout=5.0)

        assert result.success is False
        assert result.return_code != 0
        assert len(result.stderr) > 0

    @pytest.mark.asyncio
    async def test_execution_time_recorded(self):
        """Test that execution time is recorded"""
        result = await async_subprocess_with_timeout(["sleep", "0.1"], timeout=5.0)

        assert result.execution_time >= 0.1
        assert result.execution_time < 1.0


class TestRetryWithBackoff:
    """Test retry logic with exponential backoff"""

    @pytest.mark.asyncio
    async def test_success_on_first_attempt(self):
        """Test function that succeeds on first attempt"""
        call_count = 0

        @retry_with_backoff(max_attempts=3, base_delay=0.1)
        async def mock_function():
            nonlocal call_count
            call_count += 1
            return ExecutionResult(success=True, stdout="success")

        result = await mock_function()

        assert result.success is True
        assert result.attempts == 1
        assert call_count == 1

    @pytest.mark.asyncio
    async def test_retry_on_timeout(self):
        """Test retry on timeout error"""
        call_count = 0

        @retry_with_backoff(max_attempts=3, base_delay=0.1)
        async def mock_function():
            nonlocal call_count
            call_count += 1

            if call_count < 2:
                return ExecutionResult(
                    success=False, error_category=ErrorCategory.TIMEOUT, error_message="timeout"
                )

            return ExecutionResult(success=True, stdout="success")

        result = await mock_function()

        assert result.success is True
        assert result.attempts == 2
        assert call_count == 2

    @pytest.mark.asyncio
    async def test_max_retries_exhausted(self):
        """Test when all retries are exhausted"""
        call_count = 0

        @retry_with_backoff(max_attempts=3, base_delay=0.1)
        async def mock_function():
            nonlocal call_count
            call_count += 1
            return ExecutionResult(
                success=False, error_category=ErrorCategory.TIMEOUT, error_message="timeout"
            )

        result = await mock_function()

        assert result.success is False
        assert result.attempts == 3
        assert call_count == 3

    @pytest.mark.asyncio
    async def test_no_retry_on_permission_denied(self):
        """Test that permission denied errors don't trigger retry"""
        call_count = 0

        @retry_with_backoff(max_attempts=3, base_delay=0.1)
        async def mock_function():
            nonlocal call_count
            call_count += 1
            return ExecutionResult(
                success=False,
                error_category=ErrorCategory.PERMISSION_DENIED,
                error_message="permission denied",
            )

        result = await mock_function()

        assert result.success is False
        assert result.attempts == 1
        assert call_count == 1  # Should not retry

    @pytest.mark.asyncio
    async def test_exponential_backoff_timing(self):
        """Test exponential backoff delays"""
        import time

        call_times = []

        @retry_with_backoff(max_attempts=3, base_delay=0.1, exponential=True)
        async def mock_function():
            call_times.append(time.time())
            return ExecutionResult(
                success=False, error_category=ErrorCategory.TIMEOUT, error_message="timeout"
            )

        await mock_function()

        # Verify delays increase exponentially (within tolerance)
        if len(call_times) >= 2:
            delay1 = call_times[1] - call_times[0]
            assert delay1 >= 0.1  # First retry after base_delay

        if len(call_times) >= 3:
            delay2 = call_times[2] - call_times[1]
            assert delay2 >= 0.2  # Second retry after 2 * base_delay


class TestSSHExecuteWithTimeout:
    """Test SSH command execution"""

    @pytest.mark.asyncio
    @patch("utils.timeout_handler.async_subprocess_with_timeout")
    async def test_ssh_command_construction(self, mock_subprocess):
        """Test SSH command is constructed correctly"""
        mock_subprocess.return_value = ExecutionResult(success=True, stdout="output")

        await ssh_execute_with_timeout(
            host="testhost", command="uptime", user="testuser", port=22, timeout=5.0
        )

        # Verify subprocess was called
        assert mock_subprocess.called
        call_args = mock_subprocess.call_args
        command = call_args[0][0]

        # Verify SSH command structure
        assert "ssh" in command
        assert "testuser@testhost" in command
        assert "uptime" in command

    @pytest.mark.asyncio
    @patch("utils.timeout_handler.async_subprocess_with_timeout")
    async def test_ssh_with_custom_port(self, mock_subprocess):
        """Test SSH with custom port"""
        mock_subprocess.return_value = ExecutionResult(success=True, stdout="output")

        await ssh_execute_with_timeout(host="testhost", command="uptime", port=2222, timeout=5.0)

        call_args = mock_subprocess.call_args
        command = call_args[0][0]

        assert "-p" in command
        assert "2222" in command


class TestGracefulDegradation:
    """Test graceful degradation handling"""

    def test_handle_graceful_degradation(self):
        """Test graceful degradation creates proper fallback"""
        result = ExecutionResult(
            success=False,
            error_category=ErrorCategory.TIMEOUT,
            error_message="Connection timeout",
            attempts=3,
        )

        degraded = handle_graceful_degradation(result, "cpu_usage")

        assert degraded["metric"] == "cpu_usage"
        assert degraded["value"] is None
        assert degraded["status"] == "degraded"
        assert degraded["fallback"] is True
        assert degraded["error"]["category"] == "timeout"
        assert degraded["error"]["attempts"] == 3


class TestExecutionResult:
    """Test ExecutionResult dataclass"""

    def test_execution_result_creation(self):
        """Test creating ExecutionResult"""
        result = ExecutionResult(
            success=True, stdout="output", stderr="", return_code=0, execution_time=0.5, attempts=1
        )

        assert result.success is True
        assert result.stdout == "output"
        assert result.execution_time == 0.5

    def test_execution_result_with_error(self):
        """Test ExecutionResult with error"""
        result = ExecutionResult(
            success=False,
            error_category=ErrorCategory.CONNECTION_REFUSED,
            error_message="Connection refused",
            attempts=3,
        )

        assert result.success is False
        assert result.error_category == ErrorCategory.CONNECTION_REFUSED
        assert result.attempts == 3
