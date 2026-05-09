"""Cluster Manager Service - Wraps lib/cluster shell scripts"""

import asyncio
import json
import logging
import os
import uuid
from pathlib import Path
from typing import Any, AsyncGenerator, Dict, List, Optional

from utils.datetime_utils import utcnow
from utils.validation import FilePathValidator

logger = logging.getLogger(__name__)


class ClusterManagerError(Exception):
    """Exception raised when cluster operation fails"""

    pass


class ClusterManager:
    """
    Service for managing cluster operations via lib/cluster shell scripts.

    This service wraps the shell scripts created by the library agent:
    - lib/cluster/build.sh - Building Docker images
    - lib/cluster/deploy.sh - Deploying to Pis
    - lib/cluster/sync.sh - Syncing directories
    - lib/cluster/health.sh - Health checking
    - lib/cluster/discovery.sh - Service discovery
    - lib/cluster/buildx.sh - Buildx setup
    """

    def __init__(self, lib_path: Optional[str] = None, registry_path: Optional[str] = None):
        """
        Initialize the Cluster Manager service.

        Resolution order for lib_path:
            1. explicit ``lib_path`` argument
            2. ``CLUSTER_LIB_PATH`` environment variable
            3. ``<repo_root>/lib/cluster`` (source-checkout default)

        The env var lookup is what makes Docker work: in the container the
        backend lives at /app/ but the cluster lib is bind-mounted at
        /opt/portoser/lib/cluster, which the source-relative default would
        resolve to /lib/cluster (nonexistent).

        Args:
            lib_path: Path to lib/cluster directory.
            registry_path: Path to registry.yml (defaults to env var or repo root).
        """
        # Get base path relative to this file
        backend_dir = Path(__file__).parent.parent
        project_root = backend_dir.parent.parent

        if lib_path:
            self.lib_path = Path(lib_path)
        elif os.getenv("CLUSTER_LIB_PATH"):
            self.lib_path = Path(os.environ["CLUSTER_LIB_PATH"])
        else:
            self.lib_path = project_root / "lib" / "cluster"
        self.registry_path = (
            Path(registry_path)
            if registry_path
            else Path(os.getenv("CADDY_REGISTRY_PATH", str(project_root / "registry.yml")))
        )

        # Validate paths
        try:
            FilePathValidator.check_directory_exists(str(self.lib_path), "cluster library")
        except Exception as e:
            logger.warning(f"Cluster library path validation failed: {e}")

        try:
            FilePathValidator.check_file_exists(str(self.registry_path), "registry.yml")
        except Exception as e:
            logger.warning(f"Registry file validation failed: {e}")

        # In-memory storage for operation status
        self.operations: Dict[str, Dict[str, Any]] = {}

        logger.info(
            f"ClusterManager initialized with lib={self.lib_path}, registry={self.registry_path}"
        )

    def _get_script_path(self, script_name: str) -> Path:
        """Get the full path to a cluster script."""
        return self.lib_path / f"{script_name}.sh"

    @staticmethod
    def _build_bash_invocation(script_path: Path, function_name: str, args: List[str]) -> List[str]:
        """Construct a safe argv for `bash -c "source ... && fn \"$@\""` invocation.

        We must `source` the script file before calling the function, which
        forces us through `bash -c`. Inlining args into that command string
        would be a shell-injection vector, so we pass them positionally:
        bash sees ``$0`` = "bash", ``$1..$N`` = our args, and the function
        receives them via ``"$@"`` without re-parsing.

        function_name and script_path are internal, never user-controlled.
        """
        inner = f'source {script_path} && {function_name} "$@"'
        return ["bash", "-c", inner, "bash", *args]

    async def _execute_script(
        self, script_name: str, function_name: str, args: List[str], timeout: Optional[int] = 300
    ) -> Dict[str, Any]:
        """
        Execute a shell script function.

        Args:
            script_name: Name of the script (e.g., 'build', 'deploy')
            function_name: Function to call within the script
            args: Arguments to pass to the function
            timeout: Command timeout in seconds

        Returns:
            Dict containing success, output, error, and returncode
        """
        script_path = self._get_script_path(script_name)

        if not script_path.exists():
            raise ClusterManagerError(f"Script not found: {script_path}")

        argv = self._build_bash_invocation(script_path, function_name, args)
        logger.info(f"Executing: source {script_path} && {function_name} (with {len(args)} args)")

        process = None
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.lib_path),
            )

            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                process.communicate(), timeout=timeout
            )

            output = stdout_bytes.decode().strip()
            error = stderr_bytes.decode().strip()
            success = process.returncode == 0

            logger.debug(f"Command completed: success={success}, returncode={process.returncode}")

            return {
                "success": success,
                "output": output,
                "error": error if not success else None,
                "returncode": process.returncode,
            }

        except asyncio.TimeoutError:
            logger.error(f"Command timed out after {timeout}s")
            if process and process.returncode is None:
                try:
                    process.kill()
                    await asyncio.wait_for(process.wait(), timeout=2)
                except Exception:
                    pass
            raise ClusterManagerError(f"Command timed out after {timeout} seconds")

        except Exception as e:
            logger.error(f"Failed to execute script: {e}")
            if process and process.returncode is None:
                try:
                    process.kill()
                    await asyncio.wait_for(process.wait(), timeout=2)
                except Exception:
                    pass
            raise ClusterManagerError(f"Script execution failed: {str(e)}")

    async def _stream_script(
        self,
        script_name: str,
        function_name: str,
        args: List[str],
        websocket_callback: Optional[callable] = None,
    ) -> AsyncGenerator[str, None]:
        """
        Execute a script function and stream output.

        Args:
            script_name: Name of the script
            function_name: Function to call
            args: Arguments to pass
            websocket_callback: Optional callback for WebSocket streaming

        Yields:
            Output lines as they become available
        """
        script_path = self._get_script_path(script_name)

        if not script_path.exists():
            raise ClusterManagerError(f"Script not found: {script_path}")

        argv = self._build_bash_invocation(script_path, function_name, args)
        logger.info(f"Streaming: source {script_path} && {function_name} (with {len(args)} args)")

        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.lib_path),
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

            # Wait for process to complete
            await process.wait()

            # Check for errors
            stderr = await process.stderr.read()
            if stderr:
                error_msg = stderr.decode().strip()
                logger.error(f"Script error: {error_msg}")
                if websocket_callback:
                    await websocket_callback(
                        {"type": "error", "message": error_msg, "timestamp": utcnow().isoformat()}
                    )

            if process.returncode != 0:
                raise ClusterManagerError(f"Script failed with exit code {process.returncode}")

        except Exception as e:
            logger.error(f"Failed to stream script: {e}")
            raise ClusterManagerError(f"Script streaming failed: {str(e)}")

    # =========================================================================
    # BUILD OPERATIONS
    # =========================================================================

    async def build_services(
        self,
        services: List[str],
        rebuild: bool = False,
        batch_size: int = 4,
        websocket_callback: Optional[callable] = None,
    ) -> str:
        """
        Build Docker images for services.

        Calls lib/cluster/build.sh:build_services_parallel()

        Args:
            services: List of service names to build
            rebuild: Whether to rebuild without cache
            batch_size: Number of parallel builds
            websocket_callback: Optional callback for WebSocket streaming

        Returns:
            build_id: Unique identifier for this build operation
        """
        build_id = f"build-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"

        # Store operation
        self.operations[build_id] = {
            "type": "build",
            "build_id": build_id,
            "services": services,
            "status": "running",
            "started_at": utcnow().isoformat(),
            "completed_at": None,
            "output": [],
            "error": None,
        }

        # Start background task
        asyncio.create_task(
            self._run_build(build_id, services, rebuild, batch_size, websocket_callback)
        )

        return build_id

    async def _run_build(
        self,
        build_id: str,
        services: List[str],
        rebuild: bool,
        batch_size: int,
        websocket_callback: Optional[callable],
    ):
        """Background task to run build operation."""
        try:
            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "build_started",
                        "build_id": build_id,
                        "services": services,
                        "timestamp": utcnow().isoformat(),
                    }
                )

            output_lines = []

            # Call build script function
            # build_services_parallel <registry_file> <batch_size> <rebuild_flag> <services...>
            args = [str(self.registry_path), str(batch_size), "1" if rebuild else "0"] + services

            async for line in self._stream_script(
                "build", "build_services_parallel", args, websocket_callback
            ):
                output_lines.append(line)

            # Mark as completed
            self.operations[build_id].update(
                {
                    "status": "completed",
                    "completed_at": utcnow().isoformat(),
                    "output": output_lines,
                }
            )

            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "build_completed",
                        "build_id": build_id,
                        "timestamp": utcnow().isoformat(),
                    }
                )

        except Exception as e:
            logger.error(f"Build {build_id} failed: {e}")
            self.operations[build_id].update(
                {"status": "failed", "completed_at": utcnow().isoformat(), "error": str(e)}
            )

            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "build_failed",
                        "build_id": build_id,
                        "error": str(e),
                        "timestamp": utcnow().isoformat(),
                    }
                )

    def get_build_status(self, build_id: str) -> Optional[Dict[str, Any]]:
        """Get build operation status."""
        return self.operations.get(build_id)

    # =========================================================================
    # DEPLOYMENT OPERATIONS
    # =========================================================================

    async def deploy_to_pi(
        self, pi: str, services: List[str], websocket_callback: Optional[callable] = None
    ) -> str:
        """
        Deploy services to a Raspberry Pi.

        Calls lib/cluster/deploy.sh:deploy_to_pi()

        Args:
            pi: Target Pi (pi1, pi2, pi3, pi4)
            services: List of service names to deploy
            websocket_callback: Optional callback for WebSocket streaming

        Returns:
            deployment_id: Unique identifier for this deployment
        """
        deployment_id = f"deploy-{utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"

        # Store operation
        self.operations[deployment_id] = {
            "type": "deployment",
            "deployment_id": deployment_id,
            "pi": pi,
            "services": services,
            "status": "running",
            "started_at": utcnow().isoformat(),
            "completed_at": None,
            "output": [],
            "error": None,
        }

        # Start background task
        asyncio.create_task(self._run_deployment(deployment_id, pi, services, websocket_callback))

        return deployment_id

    async def _run_deployment(
        self,
        deployment_id: str,
        pi: str,
        services: List[str],
        websocket_callback: Optional[callable],
    ):
        """Background task to run deployment."""
        try:
            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "deploy_started",
                        "deployment_id": deployment_id,
                        "pi": pi,
                        "services": services,
                        "timestamp": utcnow().isoformat(),
                    }
                )

            output_lines = []

            # Call deploy script function
            # deploy_to_pi <pi_name> <registry_file> <services...>
            args = [pi, str(self.registry_path)] + services

            async for line in self._stream_script(
                "deploy", "deploy_to_pi", args, websocket_callback
            ):
                output_lines.append(line)

            # Mark as completed
            self.operations[deployment_id].update(
                {
                    "status": "completed",
                    "completed_at": utcnow().isoformat(),
                    "output": output_lines,
                }
            )

            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "deploy_completed",
                        "deployment_id": deployment_id,
                        "timestamp": utcnow().isoformat(),
                    }
                )

        except Exception as e:
            logger.error(f"Deployment {deployment_id} failed: {e}")
            self.operations[deployment_id].update(
                {"status": "failed", "completed_at": utcnow().isoformat(), "error": str(e)}
            )

            if websocket_callback:
                await websocket_callback(
                    {
                        "type": "deploy_failed",
                        "deployment_id": deployment_id,
                        "error": str(e),
                        "timestamp": utcnow().isoformat(),
                    }
                )

    def get_deployment_status(self, deployment_id: str) -> Optional[Dict[str, Any]]:
        """Get deployment operation status."""
        return self.operations.get(deployment_id)

    # =========================================================================
    # SYNC OPERATIONS
    # =========================================================================

    async def sync_pis(self, pis: List[str]) -> Dict[str, Any]:
        """
        Sync each Pi's per-host base directory (compose files, .env, certs).

        Calls lib/cluster/sync.sh:sync_pi()

        Args:
            pis: List of Pi names to sync (pi1, pi2, pi3, pi4)

        Returns:
            Dict with success status and output
        """
        logger.info(f"Syncing Pis: {pis}")

        results = {}
        for pi in pis:
            try:
                # sync_pi <pi_name> <registry_file>
                result = await self._execute_script(
                    "sync",
                    "sync_pi",
                    [pi, str(self.registry_path)],
                    timeout=600,  # Longer timeout for sync
                )
                results[pi] = result
            except Exception as e:
                logger.error(f"Failed to sync {pi}: {e}")
                results[pi] = {"success": False, "error": str(e)}

        # Overall success if all succeeded
        all_success = all(r.get("success", False) for r in results.values())

        return {
            "success": all_success,
            "results": results,
            "synced_pis": [pi for pi, r in results.items() if r.get("success")],
        }

    # =========================================================================
    # CLEAN OPERATIONS
    # =========================================================================

    async def clean_pis(self, pis: List[str], dry_run: bool = False) -> Dict[str, Any]:
        """
        Clean Docker resources on Pis (images, containers, volumes).

        Args:
            pis: List of Pi names to clean
            dry_run: If True, only show what would be cleaned

        Returns:
            Dict with success status and output
        """
        logger.info(f"Cleaning Pis: {pis} (dry_run={dry_run})")

        results = {}
        for pi in pis:
            process = None
            try:
                # For now, use SSH to clean Docker resources
                # This could be moved to a lib/cluster/clean.sh script
                cmd = "docker system prune -af --volumes" if not dry_run else "docker system df"

                # Async subprocess so we don't block the event loop while
                # the SSH/docker call (potentially up to 5 minutes) runs.
                # Args are passed as a list, so even a malicious `pi` value
                # can't break out into a shell.
                process = await asyncio.create_subprocess_exec(
                    "sshpass",
                    "-p",
                    "pi",
                    "ssh",
                    f"{pi}@{pi}.local",
                    cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout_bytes, stderr_bytes = await asyncio.wait_for(
                    process.communicate(), timeout=300
                )

                results[pi] = {
                    "success": process.returncode == 0,
                    "output": stdout_bytes.decode().strip(),
                    "error": (stderr_bytes.decode().strip() if process.returncode != 0 else None),
                }
            except asyncio.TimeoutError:
                logger.error(f"Clean timed out for {pi}")
                if process and process.returncode is None:
                    try:
                        process.kill()
                        await asyncio.wait_for(process.wait(), timeout=2)
                    except Exception:
                        pass
                results[pi] = {"success": False, "error": "timeout"}
            except Exception as e:
                logger.error(f"Failed to clean {pi}: {e}")
                results[pi] = {"success": False, "error": str(e)}

        all_success = all(r.get("success", False) for r in results.values())

        return {
            "success": all_success,
            "results": results,
            "cleaned_pis": [pi for pi, r in results.items() if r.get("success")],
        }

    # =========================================================================
    # HEALTH OPERATIONS
    # =========================================================================

    async def check_health(self) -> Dict[str, Any]:
        """
        Check cluster health status.

        Calls lib/cluster/health.sh:check_cluster_health(), but only if the
        registry actually has online hosts to probe. When every host is
        marked offline (typical for the dev/dummy-data case), the shell
        script would SSH-probe each one anyway and time out at ~5s/host —
        so we synthesize a "all-services-on-offline-hosts" health document
        from the registry directly and return it instantly.

        Returns:
            Dict with health status for all Pis and services
        """
        logger.info("Checking cluster health")

        try:
            from services.registry_service import RegistryService

            registry = RegistryService(registry_path=str(self.registry_path))
            data = registry.read()
            hosts_dict = data.get("hosts", {}) or {}
            services_dict = data.get("services", {}) or {}

            any_host_online = any(
                (cfg or {}).get("status") == "online" for cfg in hosts_dict.values()
            )

            if not any_host_online and hosts_dict:
                logger.info(
                    "No online hosts in registry; returning synthetic offline health "
                    "instead of running 120s SSH probe"
                )
                synthetic_services = [
                    {
                        "service": name,
                        "hostname": (cfg or {}).get("hostname") or (cfg or {}).get("current_host"),
                        "port": (cfg or {}).get("port"),
                        "status": "offline",
                    }
                    for name, cfg in services_dict.items()
                ]
                return {
                    "success": True,
                    "health": {
                        "timestamp": utcnow().isoformat(),
                        "services": synthetic_services,
                        "healthy": 0,
                        "degraded": 0,
                        "down": 0,  # "down" implies probed-and-down; offline ≠ down
                        "offline": len(synthetic_services),
                        "total": len(synthetic_services),
                    },
                }

            # check_cluster_health <registry_file> <verify_ssl> <output_format>
            result = await self._execute_script(
                "health",
                "check_cluster_health",
                [str(self.registry_path), "true", "json"],
                timeout=120,
            )

            output = result.get("output", "")

            try:
                health_data = json.loads(output)
                return {"success": result["success"], "health": health_data}
            except json.JSONDecodeError:
                return {
                    "success": result["success"],
                    "output": output,
                    "error": result.get("error"),
                }

        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return {"success": False, "error": str(e)}

    # =========================================================================
    # DISCOVERY OPERATIONS
    # =========================================================================

    async def discover_services(self) -> Dict[str, Any]:
        """
        Discover services from the registry — metadata only, no SSH.

        Originally this shelled out to lib/cluster/discovery.sh:discover_all_services,
        which SSH-scans every host to find docker-compose.yml / service.yml files.
        That's the right tool when you want to find services that exist on a
        host but aren't yet in the registry — but the FE just wants "what's
        in the registry," and the SSH scan blocks 30s+ per offline host.

        For the registry-listing use case (what every UI caller wants), we
        read registry.yml directly. The slow scan-the-hosts variant lives in
        the shell script for explicit cluster-side invocation.

        Returns:
            Dict with list of services and their configurations.
        """
        logger.info("Discovering services from registry (metadata-only)")

        try:
            from services.registry_service import RegistryService

            registry = RegistryService(registry_path=str(self.registry_path))
            data = registry.read()
            services_dict = data.get("services", {}) or {}

            services = []
            for name, cfg in services_dict.items():
                services.append(
                    {
                        "name": name,
                        "hostname": cfg.get("hostname"),
                        "current_host": cfg.get("current_host"),
                        "deployment_type": cfg.get("deployment_type"),
                        "port": cfg.get("port"),
                        "docker_compose": cfg.get("docker_compose"),
                        "service_file": cfg.get("service_file"),
                        "dependencies": cfg.get("dependencies", []) or [],
                    }
                )
            return {"success": True, "services": services}

        except Exception as e:
            logger.error(f"Service discovery failed: {e}")
            return {"success": False, "error": str(e)}

        except Exception as e:
            logger.error(f"Service discovery failed: {e}")
            return {"success": False, "error": str(e)}

    # =========================================================================
    # BUILDX OPERATIONS
    # =========================================================================

    async def setup_buildx(self) -> Dict[str, Any]:
        """
        Setup Docker buildx for multi-arch builds.

        Calls lib/cluster/buildx.sh:setup_buildx()

        Returns:
            Dict with setup status
        """
        logger.info("Setting up buildx")

        try:
            # setup_buildx
            result = await self._execute_script("buildx", "setup_buildx", [], timeout=120)

            return {
                "success": result["success"],
                "output": result.get("output"),
                "error": result.get("error"),
            }

        except Exception as e:
            logger.error(f"Buildx setup failed: {e}")
            return {"success": False, "error": str(e)}

    # =========================================================================
    # STATUS OPERATIONS
    # =========================================================================

    async def get_cluster_status(self) -> Dict[str, Any]:
        """
        Get overall cluster status.

        Returns:
            Dict with build capacity, deployment status, and health
        """
        logger.info("Getting cluster status")

        # Get health status
        health = await self.check_health()

        # Get service discovery
        services = await self.discover_services()

        # Count running operations
        running_builds = len(
            [
                op
                for op in self.operations.values()
                if op.get("type") == "build" and op.get("status") == "running"
            ]
        )

        running_deployments = len(
            [
                op
                for op in self.operations.values()
                if op.get("type") == "deployment" and op.get("status") == "running"
            ]
        )

        return {
            "build_capacity": {"running_builds": running_builds, "max_parallel": 4},
            "deployment_status": {"running_deployments": running_deployments},
            "health": health,
            "services": services,
            "timestamp": utcnow().isoformat(),
        }
