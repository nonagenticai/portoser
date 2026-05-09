"""
Timeout Handler and Retry Logic for Metrics Collection

This module provides robust timeout handling and retry mechanisms for
subprocess calls and SSH connections during metrics collection.

Features:
- Subprocess execution with configurable timeout
- Exponential backoff retry logic
- SSH connection timeout handling
- Error categorization and graceful degradation
- Detailed logging for debugging
"""

import asyncio
import functools
import logging
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, List, Optional

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class ErrorCategory(Enum):
    """Categorization of errors for better handling and reporting."""

    TIMEOUT = "timeout"
    CONNECTION_REFUSED = "connection_refused"
    AUTHENTICATION_FAILED = "authentication_failed"
    COMMAND_NOT_FOUND = "command_not_found"
    PERMISSION_DENIED = "permission_denied"
    NETWORK_UNREACHABLE = "network_unreachable"
    SSH_ERROR = "ssh_error"
    UNKNOWN = "unknown"


@dataclass
class ExecutionResult:
    """Result of a command execution with metadata."""

    success: bool
    stdout: str = ""
    stderr: str = ""
    return_code: Optional[int] = None
    execution_time: float = 0.0
    error_category: Optional[ErrorCategory] = None
    error_message: str = ""
    attempts: int = 1


class TimeoutError(Exception):
    """Custom timeout error for better error handling."""

    pass


def categorize_error(error: Exception, stderr: str = "") -> ErrorCategory:
    """
    Categorize an error based on its type and message.

    Args:
        error: The exception that occurred
        stderr: Standard error output from the command

    Returns:
        ErrorCategory enum value
    """
    error_str = str(error).lower()
    stderr_lower = stderr.lower()

    # Check for timeout
    if isinstance(error, (asyncio.TimeoutError, TimeoutError)):
        return ErrorCategory.TIMEOUT

    # Check stderr and error message for known patterns
    if "connection refused" in error_str or "connection refused" in stderr_lower:
        return ErrorCategory.CONNECTION_REFUSED

    if "permission denied" in error_str or "permission denied" in stderr_lower:
        return ErrorCategory.PERMISSION_DENIED

    if "authentication" in error_str or "authentication" in stderr_lower:
        return ErrorCategory.AUTHENTICATION_FAILED

    if "command not found" in stderr_lower or "no such file" in stderr_lower:
        return ErrorCategory.COMMAND_NOT_FOUND

    if "network is unreachable" in error_str or "network is unreachable" in stderr_lower:
        return ErrorCategory.NETWORK_UNREACHABLE

    if "ssh" in error_str or "ssh" in stderr_lower:
        return ErrorCategory.SSH_ERROR

    return ErrorCategory.UNKNOWN


async def async_subprocess_with_timeout(
    command: List[str],
    timeout: float = 5.0,
    shell: bool = False,
    cwd: Optional[str] = None,
    env: Optional[dict] = None,
) -> ExecutionResult:
    """
    Execute a subprocess command with timeout handling.

    Args:
        command: Command and arguments as a list
        timeout: Timeout in seconds (default: 5.0)
        shell: Whether to execute through shell
        cwd: Working directory for command execution
        env: Environment variables dictionary

    Returns:
        ExecutionResult object with execution details

    Raises:
        TimeoutError: If command execution exceeds timeout
    """
    start_time = time.time()
    logger.debug(f"Executing command: {' '.join(command)} (timeout: {timeout}s)")

    try:
        if shell:
            # If shell is True, command should be a string
            cmd = " ".join(command) if isinstance(command, list) else command
            process = await asyncio.create_subprocess_shell(
                cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd,
                env=env,
            )
        else:
            process = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd,
                env=env,
            )

        # Wait for command completion with timeout
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            # Kill the process if it times out
            try:
                process.kill()
                await process.wait()
            except ProcessLookupError:
                pass

            execution_time = time.time() - start_time
            logger.warning(f"Command timed out after {execution_time:.2f}s: {' '.join(command)}")

            raise TimeoutError(f"Command execution exceeded {timeout}s timeout")

        execution_time = time.time() - start_time
        stdout_str = stdout.decode("utf-8", errors="replace").strip()
        stderr_str = stderr.decode("utf-8", errors="replace").strip()

        success = process.returncode == 0

        if success:
            logger.debug(f"Command completed successfully in {execution_time:.2f}s")
        else:
            logger.warning(
                f"Command failed with return code {process.returncode} "
                f"in {execution_time:.2f}s: {stderr_str}"
            )

        return ExecutionResult(
            success=success,
            stdout=stdout_str,
            stderr=stderr_str,
            return_code=process.returncode,
            execution_time=execution_time,
            error_category=None if success else categorize_error(Exception(stderr_str), stderr_str),
        )

    except TimeoutError as e:
        execution_time = time.time() - start_time
        return ExecutionResult(
            success=False,
            stderr=str(e),
            execution_time=execution_time,
            error_category=ErrorCategory.TIMEOUT,
            error_message=str(e),
        )

    except Exception as e:
        execution_time = time.time() - start_time
        logger.error(f"Command execution failed: {str(e)}")

        return ExecutionResult(
            success=False,
            stderr=str(e),
            execution_time=execution_time,
            error_category=categorize_error(e),
            error_message=str(e),
        )


def retry_with_backoff(
    max_attempts: int = 3,
    base_delay: float = 1.0,
    exponential: bool = True,
    retry_on_categories: Optional[List[ErrorCategory]] = None,
):
    """
    Decorator for retry logic with exponential backoff.

    Args:
        max_attempts: Maximum number of retry attempts (default: 3)
        base_delay: Base delay in seconds (default: 1.0)
        exponential: Use exponential backoff (delays: 1s, 2s, 4s)
        retry_on_categories: List of error categories to retry on (None = retry all)

    Returns:
        Decorated function with retry logic

    Example:
        @retry_with_backoff(max_attempts=3, base_delay=1.0)
        async def fetch_metrics():
            return await async_subprocess_with_timeout(['ssh', 'host', 'uptime'])
    """
    if retry_on_categories is None:
        # Default: retry on timeout and connection errors
        retry_on_categories = [
            ErrorCategory.TIMEOUT,
            ErrorCategory.CONNECTION_REFUSED,
            ErrorCategory.NETWORK_UNREACHABLE,
            ErrorCategory.SSH_ERROR,
        ]

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def wrapper(*args, **kwargs) -> ExecutionResult:
            last_result = None

            for attempt in range(1, max_attempts + 1):
                try:
                    logger.debug(f"Attempt {attempt}/{max_attempts} for {func.__name__}")

                    result = await func(*args, **kwargs)

                    # If successful, return immediately
                    if result.success:
                        result.attempts = attempt
                        if attempt > 1:
                            logger.info(f"{func.__name__} succeeded on attempt {attempt}")
                        return result

                    last_result = result

                    # Check if we should retry based on error category
                    if result.error_category not in retry_on_categories:
                        logger.info(
                            f"Error category {result.error_category.value} not retryable, "
                            f"failing immediately"
                        )
                        result.attempts = attempt
                        return result

                    # Don't sleep after the last attempt
                    if attempt < max_attempts:
                        if exponential:
                            delay = base_delay * (2 ** (attempt - 1))
                        else:
                            delay = base_delay

                        logger.info(
                            f"Attempt {attempt} failed with {result.error_category.value}, "
                            f"retrying in {delay}s..."
                        )
                        await asyncio.sleep(delay)
                    else:
                        logger.warning(f"All {max_attempts} attempts failed for {func.__name__}")

                except Exception as e:
                    logger.error(f"Unexpected error in {func.__name__}: {str(e)}")
                    last_result = ExecutionResult(
                        success=False,
                        error_category=categorize_error(e),
                        error_message=str(e),
                        attempts=attempt,
                    )

                    if attempt < max_attempts:
                        delay = base_delay * (2 ** (attempt - 1)) if exponential else base_delay
                        await asyncio.sleep(delay)

            # Return the last failed result
            if last_result:
                last_result.attempts = max_attempts
                return last_result

            return ExecutionResult(
                success=False,
                error_category=ErrorCategory.UNKNOWN,
                error_message="All retry attempts exhausted",
                attempts=max_attempts,
            )

        return wrapper

    return decorator


async def ssh_execute_with_timeout(
    host: str,
    command: str,
    user: Optional[str] = None,
    port: int = 22,
    timeout: float = 5.0,
    ssh_options: Optional[List[str]] = None,
) -> ExecutionResult:
    """
    Execute SSH command with timeout and proper error handling.

    Args:
        host: Remote host address
        command: Command to execute on remote host
        user: SSH user (optional, uses current user if None)
        port: SSH port (default: 22)
        timeout: Command timeout in seconds (default: 5.0)
        ssh_options: Additional SSH options

    Returns:
        ExecutionResult object with execution details
    """
    ssh_cmd = ["ssh"]

    # Add common SSH options for better timeout handling
    default_options = [
        "-o",
        "ConnectTimeout=5",
        "-o",
        "ServerAliveInterval=2",
        "-o",
        "ServerAliveCountMax=2",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "BatchMode=yes",
    ]

    ssh_cmd.extend(default_options)

    # Add custom SSH options
    if ssh_options:
        ssh_cmd.extend(ssh_options)

    # Add port if not default
    if port != 22:
        ssh_cmd.extend(["-p", str(port)])

    # Add user@host or just host
    if user:
        ssh_cmd.append(f"{user}@{host}")
    else:
        ssh_cmd.append(host)

    # Add command
    ssh_cmd.append(command)

    return await async_subprocess_with_timeout(ssh_cmd, timeout=timeout)


@retry_with_backoff(max_attempts=3, base_delay=1.0)
async def ssh_execute_with_retry(
    host: str,
    command: str,
    user: Optional[str] = None,
    port: int = 22,
    timeout: float = 5.0,
    ssh_options: Optional[List[str]] = None,
) -> ExecutionResult:
    """
    Execute SSH command with automatic retry on failure.

    This function combines ssh_execute_with_timeout with retry_with_backoff
    decorator for robust SSH command execution.

    Args:
        host: Remote host address
        command: Command to execute on remote host
        user: SSH user (optional)
        port: SSH port (default: 22)
        timeout: Command timeout in seconds (default: 5.0)
        ssh_options: Additional SSH options

    Returns:
        ExecutionResult object with execution details
    """
    return await ssh_execute_with_timeout(host, command, user, port, timeout, ssh_options)


def handle_graceful_degradation(result: ExecutionResult, metric_name: str) -> dict:
    """
    Handle graceful degradation when metrics collection fails.

    Args:
        result: ExecutionResult from failed execution
        metric_name: Name of the metric that failed

    Returns:
        Dictionary with fallback metric values and error information
    """
    logger.warning(
        f"Graceful degradation for {metric_name}: "
        f"{result.error_category.value if result.error_category else 'unknown error'}"
    )

    return {
        "metric": metric_name,
        "value": None,
        "status": "degraded",
        "error": {
            "category": result.error_category.value if result.error_category else "unknown",
            "message": result.error_message or result.stderr,
            "attempts": result.attempts,
            "timestamp": utcnow().isoformat(),
        },
        "fallback": True,
    }


async def collect_metric_with_fallback(
    primary_func: Callable, fallback_func: Optional[Callable] = None, metric_name: str = "unknown"
) -> dict:
    """
    Collect a metric with fallback mechanism.

    Args:
        primary_func: Primary function to collect metric
        fallback_func: Optional fallback function if primary fails
        metric_name: Name of the metric for logging

    Returns:
        Dictionary with metric data or degraded response
    """
    try:
        result = await primary_func()

        if result.success:
            return {
                "metric": metric_name,
                "value": result.stdout,
                "status": "success",
                "execution_time": result.execution_time,
                "attempts": result.attempts,
            }

        # Try fallback if available
        if fallback_func:
            logger.info(f"Trying fallback method for {metric_name}")
            fallback_result = await fallback_func()

            if fallback_result.success:
                return {
                    "metric": metric_name,
                    "value": fallback_result.stdout,
                    "status": "fallback_success",
                    "execution_time": fallback_result.execution_time,
                    "attempts": fallback_result.attempts,
                    "primary_error": result.error_category.value if result.error_category else None,
                }

        # Graceful degradation
        return handle_graceful_degradation(result, metric_name)

    except Exception as e:
        logger.error(f"Unexpected error collecting {metric_name}: {str(e)}")
        return handle_graceful_degradation(
            ExecutionResult(
                success=False, error_category=categorize_error(e), error_message=str(e)
            ),
            metric_name,
        )
