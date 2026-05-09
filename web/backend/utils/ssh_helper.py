"""
SSH execution helper utilities

Provides common SSH execution patterns with proper error handling,
connection pooling via multiplexing, and retry logic.
"""

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)


@dataclass
class SSHConfig:
    """SSH connection configuration"""

    hostname: str
    user: str
    port: int = 22
    key_file: Optional[str] = None
    connect_timeout: int = 10
    command_timeout: int = 30


class SSHCommandError(Exception):
    """Exception raised when SSH command fails"""

    def __init__(self, message: str, returncode: int, stderr: str):
        super().__init__(message)
        self.returncode = returncode
        self.stderr = stderr


async def execute_ssh_command(
    config: SSHConfig, command: str, use_multiplexing: bool = True, retries: int = 1
) -> Tuple[str, str, int]:
    """
    Execute SSH command with connection multiplexing and retries

    Args:
        config: SSH connection configuration
        command: Command to execute remotely
        use_multiplexing: Whether to use SSH connection multiplexing
        retries: Number of retry attempts on failure

    Returns:
        Tuple of (stdout, stderr, returncode)

    Raises:
        SSHCommandError: If command fails after all retries
        asyncio.TimeoutError: If command times out

    Example:
        >>> config = SSHConfig(hostname="server.local", user="deploy")
        >>> stdout, stderr, code = await execute_ssh_command(config, "uptime")
        >>> print(stdout)
    """
    ssh_args = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"ConnectTimeout={config.connect_timeout}",
        "-o",
        "ServerAliveInterval=60",
        "-o",
        "ServerAliveCountMax=3",
    ]

    # Add connection multiplexing for performance
    if use_multiplexing:
        control_path = f"/tmp/ssh-portoser-{config.user}@{config.hostname}:{config.port}"
        ssh_args.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                f"ControlPath={control_path}",
                "-o",
                "ControlPersist=600",  # 10 minutes
            ]
        )

    # Add port if non-standard
    if config.port != 22:
        ssh_args.extend(["-p", str(config.port)])

    # Add key file if specified
    if config.key_file:
        ssh_args.extend(["-i", config.key_file])

    # Add target and command
    ssh_args.append(f"{config.user}@{config.hostname}")
    ssh_args.append(command)

    # Retry loop
    last_error = None
    for attempt in range(retries):
        try:
            logger.debug(f"SSH command attempt {attempt + 1}/{retries}: {config.hostname}")

            process = await asyncio.create_subprocess_exec(
                *ssh_args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )

            stdout, stderr = await asyncio.wait_for(
                process.communicate(), timeout=config.command_timeout
            )

            stdout_str = stdout.decode("utf-8", errors="replace")
            stderr_str = stderr.decode("utf-8", errors="replace")

            if process.returncode == 0:
                logger.debug(f"SSH command succeeded: {config.hostname}")
                return stdout_str, stderr_str, process.returncode
            else:
                logger.warning(
                    f"SSH command failed (attempt {attempt + 1}): "
                    f"returncode={process.returncode}, stderr={stderr_str[:100]}"
                )
                last_error = SSHCommandError(
                    f"SSH command failed with exit code {process.returncode}",
                    process.returncode,
                    stderr_str,
                )

        except asyncio.TimeoutError:
            logger.error(f"SSH command timed out after {config.command_timeout}s")
            # Kill the process
            try:
                process.kill()
                await process.wait()
            except Exception:
                pass
            last_error = asyncio.TimeoutError(
                f"SSH command timed out after {config.command_timeout}s"
            )

        except Exception as e:
            logger.error(f"SSH command error: {e}")
            last_error = e

        # Wait before retry (exponential backoff)
        if attempt < retries - 1:
            wait_time = 2**attempt
            logger.debug(f"Retrying in {wait_time}s...")
            await asyncio.sleep(wait_time)

    # All retries failed
    if isinstance(last_error, SSHCommandError):
        raise last_error
    elif isinstance(last_error, asyncio.TimeoutError):
        raise last_error
    else:
        raise SSHCommandError(
            f"SSH command failed after {retries} attempts: {str(last_error)}", -1, str(last_error)
        )


async def execute_ssh_commands_parallel(
    config: SSHConfig, commands: List[str], max_concurrent: int = 5
) -> List[Tuple[str, str, int]]:
    """
    Execute multiple SSH commands in parallel with concurrency limit

    Args:
        config: SSH connection configuration
        commands: List of commands to execute
        max_concurrent: Maximum number of concurrent commands

    Returns:
        List of (stdout, stderr, returncode) tuples

    Example:
        >>> config = SSHConfig(hostname="server.local", user="deploy")
        >>> commands = ["uptime", "free -m", "df -h"]
        >>> results = await execute_ssh_commands_parallel(config, commands)
        >>> for i, (stdout, stderr, code) in enumerate(results):
        ...     print(f"Command {i}: {stdout}")
    """
    semaphore = asyncio.Semaphore(max_concurrent)

    async def run_with_limit(cmd: str) -> Tuple[str, str, int]:
        async with semaphore:
            return await execute_ssh_command(config, cmd)

    tasks = [run_with_limit(cmd) for cmd in commands]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Convert exceptions to error tuples
    processed_results = []
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            logger.error(f"Command {i} failed: {result}")
            processed_results.append(("", str(result), -1))
        else:
            processed_results.append(result)

    return processed_results


async def copy_file_to_remote(
    config: SSHConfig, local_path: str, remote_path: str, use_multiplexing: bool = True
) -> bool:
    """
    Copy file to remote host using SCP

    Args:
        config: SSH connection configuration
        local_path: Local file path
        remote_path: Remote destination path
        use_multiplexing: Whether to use SSH connection multiplexing

    Returns:
        True if successful

    Raises:
        SSHCommandError: If copy fails
        FileNotFoundError: If local file doesn't exist

    Example:
        >>> config = SSHConfig(hostname="server.local", user="deploy")
        >>> success = await copy_file_to_remote(
        ...     config, "/local/config.yml", "/remote/config.yml"
        ... )
    """
    if not Path(local_path).exists():
        raise FileNotFoundError(f"Local file not found: {local_path}")

    scp_args = [
        "scp",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"ConnectTimeout={config.connect_timeout}",
    ]

    # Add connection multiplexing
    if use_multiplexing:
        control_path = f"/tmp/ssh-portoser-{config.user}@{config.hostname}:{config.port}"
        scp_args.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                f"ControlPath={control_path}",
                "-o",
                "ControlPersist=600",
            ]
        )

    # Add port if non-standard
    if config.port != 22:
        scp_args.extend(["-P", str(config.port)])

    # Add key file if specified
    if config.key_file:
        scp_args.extend(["-i", config.key_file])

    # Add source and destination
    scp_args.append(local_path)
    scp_args.append(f"{config.user}@{config.hostname}:{remote_path}")

    try:
        process = await asyncio.create_subprocess_exec(
            *scp_args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )

        stdout, stderr = await asyncio.wait_for(
            process.communicate(), timeout=config.command_timeout
        )

        if process.returncode == 0:
            logger.info(f"File copied successfully: {local_path} -> {remote_path}")
            return True
        else:
            error_msg = stderr.decode("utf-8", errors="replace")
            logger.error(f"SCP failed: {error_msg}")
            raise SSHCommandError(
                f"SCP failed with exit code {process.returncode}", process.returncode, error_msg
            )

    except asyncio.TimeoutError:
        logger.error(f"SCP timed out after {config.command_timeout}s")
        try:
            process.kill()
            await process.wait()
        except Exception:
            pass
        raise asyncio.TimeoutError(f"SCP timed out after {config.command_timeout}s")


def get_ssh_config_from_registry(registry: Dict[str, Any], machine_name: str) -> SSHConfig:
    """
    Create SSHConfig from registry data

    Args:
        registry: Registry dictionary
        machine_name: Machine name in registry

    Returns:
        SSHConfig instance

    Raises:
        ValueError: If machine not found in registry

    Example:
        >>> registry = load_registry()
        >>> config = get_ssh_config_from_registry(registry, "web-server")
        >>> stdout, _, _ = await execute_ssh_command(config, "uptime")
    """
    if machine_name not in registry.get("hosts", {}):
        raise ValueError(f"Machine '{machine_name}' not found in registry")

    machine = registry["hosts"][machine_name]

    return SSHConfig(
        hostname=machine.get("ip") or f"{machine_name}.local",
        user=machine.get("ssh_user", "deploy"),
        port=machine.get("ssh_port", 22),
        key_file=machine.get("ssh_key_file"),
    )


async def cleanup_ssh_multiplexing() -> None:
    """
    Cleanup SSH multiplexing control sockets

    Should be called on application shutdown.

    Example:
        >>> await cleanup_ssh_multiplexing()
    """
    try:
        # Find and remove control sockets
        control_dir = Path("/tmp")
        pattern = "ssh-portoser-*"

        for socket_path in control_dir.glob(pattern):
            try:
                socket_path.unlink()
                logger.debug(f"Removed SSH control socket: {socket_path}")
            except Exception as e:
                logger.warning(f"Failed to remove control socket {socket_path}: {e}")

    except Exception as e:
        logger.error(f"Error cleaning up SSH multiplexing: {e}")
