"""Service layer for interacting with Portoser CLI"""

import asyncio
import json
import logging
import os
from typing import Any, AsyncGenerator, Dict, List, Optional

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class PortoserCLIError(Exception):
    """Exception raised when CLI command fails"""

    pass


class PortoserCLI:
    """Service for executing Portoser CLI commands"""

    def __init__(self, cli_path: Optional[str] = None):
        """
        Initialize the CLI service

        Args:
            cli_path: Path to portoser CLI binary (defaults to env var or /usr/local/bin/portoser)
        """
        self.cli_path = cli_path or os.getenv("PORTOSER_CLI", "/usr/local/bin/portoser")

        if not os.path.exists(self.cli_path):
            logger.warning(f"Portoser CLI not found at {self.cli_path}")

    async def execute_command(
        self, args: List[str], timeout: Optional[int] = 300, parse_json: bool = False
    ) -> Dict[str, Any]:
        """
        Execute a Portoser CLI command

        Args:
            args: Command arguments (e.g., ["deploy", "machine", "service"])
            timeout: Command timeout in seconds
            parse_json: Whether to parse output as JSON

        Returns:
            Dict containing success, output, error, and returncode

        Raises:
            PortoserCLIError: If command execution fails
        """
        cmd = [self.cli_path] + args
        logger.info(f"Executing: {' '.join(cmd)}")

        process = None
        try:
            # Use the async subprocess so we don't block the event loop while
            # CLI commands run (some take 30+ seconds against remote hosts).
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                process.communicate(), timeout=timeout
            )

            output = stdout_bytes.decode().strip()
            error = stderr_bytes.decode().strip()
            success = process.returncode == 0

            parsed_output = None
            if parse_json and output:
                try:
                    parsed_output = json.loads(output)
                except json.JSONDecodeError:
                    logger.warning(f"Failed to parse JSON output: {output[:100]}...")

            return {
                "success": success,
                "output": output,
                "parsed_output": parsed_output,
                "error": error if not success else None,
                "returncode": process.returncode,
            }

        except asyncio.TimeoutError:
            logger.error(f"Command timed out after {timeout}s: {' '.join(cmd)}")
            if process and process.returncode is None:
                try:
                    process.kill()
                    await asyncio.wait_for(process.wait(), timeout=2)
                except Exception:
                    pass
            raise PortoserCLIError(f"Command timed out after {timeout} seconds")

        except Exception as e:
            logger.error(f"Failed to execute command: {e}")
            if process and process.returncode is None:
                try:
                    process.kill()
                    await asyncio.wait_for(process.wait(), timeout=2)
                except Exception:
                    pass
            raise PortoserCLIError(f"Command execution failed: {str(e)}")

    async def stream_command(
        self, args: List[str], websocket_callback: Optional[callable] = None
    ) -> AsyncGenerator[str, None]:
        """
        Execute a command and stream output line by line

        Args:
            args: Command arguments
            websocket_callback: Optional callback for WebSocket streaming

        Yields:
            Output lines as they become available
        """
        cmd = [self.cli_path] + args
        logger.info(f"Streaming: {' '.join(cmd)}")

        try:
            process = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )

            # Stream stdout
            async for line in process.stdout:
                decoded = line.decode().strip()
                if decoded:
                    logger.debug(f"Output: {decoded}")
                    yield decoded

                    if websocket_callback:
                        await websocket_callback(
                            {
                                "type": "output",
                                "message": decoded,
                                "timestamp": utcnow().isoformat(),
                            }
                        )

                        # Emit parsed JSON lines for phase-aware UI updates
                        try:
                            parsed = json.loads(decoded)
                            await websocket_callback(
                                {
                                    "type": "json",
                                    "payload": parsed,
                                    "timestamp": utcnow().isoformat(),
                                }
                            )
                        except json.JSONDecodeError:
                            pass

            # Wait for process to complete
            await process.wait()

            # Check for errors
            stderr = await process.stderr.read()
            if process.returncode != 0:
                error_msg = stderr.decode().strip()
                logger.error(f"Command failed with code {process.returncode}: {error_msg}")

                if websocket_callback:
                    await websocket_callback(
                        {"type": "error", "message": error_msg, "returncode": process.returncode}
                    )

                raise PortoserCLIError(f"Command failed: {error_msg}")

        except Exception as e:
            logger.error(f"Streaming command failed: {e}")
            if websocket_callback:
                await websocket_callback({"type": "error", "message": str(e)})
            raise

    async def deploy_intelligent(
        self,
        service: str,
        machine: str,
        auto_heal: bool = False,
        dry_run: bool = False,
        websocket_callback: Optional[callable] = None,
    ) -> Dict[str, Any]:
        """
        Execute intelligent deployment with 4-phase streaming

        Args:
            service: Service name
            machine: Target machine
            auto_heal: Enable auto-healing
            dry_run: Preview only
            websocket_callback: WebSocket callback for streaming

        Returns:
            Deployment result
        """
        args = ["deploy", machine, service]

        if auto_heal:
            args.append("--auto-heal")
        if dry_run:
            args.append("--dry-run")

        # Always add --json-output for machine-readable output
        args.append("--json-output")

        try:
            if websocket_callback:
                # Stream with WebSocket support
                output_lines = []
                async for line in self.stream_command(args, websocket_callback):
                    output_lines.append(line)

                # Try to parse final JSON output
                if output_lines:
                    try:
                        return json.loads(output_lines[-1])
                    except json.JSONDecodeError:
                        return {"success": True, "output": "\n".join(output_lines)}
            else:
                # Simple execution
                return await self.execute_command(args, parse_json=True)

        except Exception as e:
            logger.error(f"Intelligent deployment failed: {e}")
            raise PortoserCLIError(f"Deployment failed: {str(e)}")

    async def run_diagnostics(
        self, service: str, machine: str, websocket_callback: Optional[callable] = None
    ) -> Dict[str, Any]:
        """
        Run diagnostics for a service

        Args:
            service: Service name
            machine: Machine name
            websocket_callback: WebSocket callback for updates

        Returns:
            Diagnostic results
        """
        args = ["diagnose", service, machine, "--json-output"]

        try:
            result = await self.execute_command(args, parse_json=True)

            if result["parsed_output"]:
                return result["parsed_output"]
            else:
                # Fallback if JSON parsing failed
                return {
                    "success": result["success"],
                    "service": service,
                    "machine": machine,
                    "output": result["output"],
                    "error": result.get("error"),
                }

        except Exception as e:
            logger.error(f"Diagnostics failed: {e}")
            raise PortoserCLIError(f"Diagnostics failed: {str(e)}")

    async def apply_fix(
        self,
        service: str,
        machine: str,
        solution_id: str,
        websocket_callback: Optional[callable] = None,
    ) -> Dict[str, Any]:
        """
        Apply a diagnostic solution

        Args:
            service: Service name
            machine: Machine name
            solution_id: Solution to apply
            websocket_callback: WebSocket callback for updates

        Returns:
            Fix application result
        """
        args = ["diagnostics", "apply-fix", service, machine, solution_id, "--json"]

        try:
            if websocket_callback:
                output_lines = []
                async for line in self.stream_command(args, websocket_callback):
                    output_lines.append(line)

                if output_lines:
                    try:
                        return json.loads(output_lines[-1])
                    except json.JSONDecodeError:
                        return {"success": True, "output": "\n".join(output_lines)}
            else:
                return await self.execute_command(args, parse_json=True)

        except Exception as e:
            logger.error(f"Apply fix failed: {e}")
            raise PortoserCLIError(f"Apply fix failed: {str(e)}")

    async def get_deployment_phases(self, deployment_id: str) -> Dict[str, Any]:
        """
        Get detailed phase breakdown for a deployment

        Args:
            deployment_id: Deployment identifier

        Returns:
            Phase breakdown
        """
        args = ["deploy", "phases", deployment_id, "--json"]

        try:
            result = await self.execute_command(args, parse_json=True)

            if result["parsed_output"]:
                return result["parsed_output"]
            else:
                raise PortoserCLIError("Failed to parse phase information")

        except Exception as e:
            logger.error(f"Get phases failed: {e}")
            raise PortoserCLIError(f"Get phases failed: {str(e)}")

    async def dry_run_deployment(self, service: str, machine: str) -> Dict[str, Any]:
        """
        Preview deployment without executing

        Args:
            service: Service name
            machine: Target machine

        Returns:
            Dry run preview
        """
        return await self.deploy_intelligent(
            service=service, machine=machine, auto_heal=False, dry_run=True
        )

    async def health_check(self, service: str) -> Dict[str, Any]:
        """
        Check health of a service

        Args:
            service: Service name

        Returns:
            Health check result
        """
        args = ["health", "check", service, "--json"]

        try:
            return await self.execute_command(args, parse_json=True)
        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return {"success": False, "error": str(e)}

    def is_available(self) -> bool:
        """Check if CLI is available"""
        return os.path.exists(self.cli_path) and os.access(self.cli_path, os.X_OK)
