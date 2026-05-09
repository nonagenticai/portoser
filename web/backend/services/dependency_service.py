"""
Dependency service for managing service dependencies via CLI.
"""

import json
import os
import subprocess
from pathlib import Path
from typing import List, Optional

from models.dependencies import (
    DependencyEdge,
    DependencyGraph,
    DependencyList,
    DependencyNode,
    DependencyOperationResponse,
    DependencyValidation,
    DeploymentOrder,
    ImpactAnalysis,
    ServiceDependencies,
    ServiceDependencyInfo,
)

# Default CLI path: <repo-root>/portoser. services/dependency_service.py ->
# parents[2] is the repo root.
_DEFAULT_PORTOSER_CLI = str(Path(__file__).resolve().parents[2] / "portoser")


class DependencyService:
    """Service for managing dependencies using portoser CLI."""

    def __init__(self, cli_path: Optional[str] = None):
        self.cli_path = cli_path or os.getenv("PORTOSER_CLI", _DEFAULT_PORTOSER_CLI)

    def _run_cli_command(self, command: List[str]) -> dict:
        """Run a portoser CLI command and return JSON output."""
        try:
            result = subprocess.run(
                [self.cli_path] + command + ["--json-output"],
                capture_output=True,
                text=True,
                timeout=30,
            )

            if result.returncode != 0:
                # Try to parse error as JSON
                try:
                    return json.loads(result.stdout)
                except Exception:
                    return {
                        "error": True,
                        "message": result.stderr or result.stdout or "Command failed",
                    }

            return json.loads(result.stdout)
        except subprocess.TimeoutExpired:
            return {"error": True, "message": "Command timed out"}
        except json.JSONDecodeError as e:
            return {"error": True, "message": f"Failed to parse JSON: {str(e)}"}
        except Exception as e:
            return {"error": True, "message": str(e)}

    async def get_dependency_graph(self) -> DependencyGraph:
        """Get complete dependency graph with nodes and edges."""
        result = self._run_cli_command(["dependencies", "graph"])

        if result.get("error"):
            raise Exception(result.get("message", "Failed to get dependency graph"))

        # Parse nodes
        nodes = [
            DependencyNode(
                id=node["id"],
                label=node["label"],
                type=node["type"],
                host=node["host"],
                hostname=node["hostname"],
                health=node.get("health", "unknown"),
            )
            for node in result.get("nodes", [])
        ]

        # Parse edges
        edges = [
            DependencyEdge(
                from_service=edge["from"],
                to_service=edge["to"],
                type=edge.get("type", "required"),
            )
            for edge in result.get("edges", [])
        ]

        return DependencyGraph(nodes=nodes, edges=edges)

    async def get_service_dependencies(self, service_name: str) -> ServiceDependencies:
        """Get dependencies for a specific service."""
        result = self._run_cli_command(["dependencies", "info", service_name])

        if result.get("error"):
            raise Exception(result.get("message", f"Failed to get dependencies for {service_name}"))

        # Parse dependencies
        dependencies = [
            ServiceDependencyInfo(
                name=dep["name"],
                host=dep["host"],
                type=dep["type"],
            )
            for dep in result.get("dependencies", [])
        ]

        # Parse dependents
        dependents = [
            ServiceDependencyInfo(
                name=dep["name"],
                host=dep["host"],
                type=dep["type"],
            )
            for dep in result.get("dependents", [])
        ]

        return ServiceDependencies(
            service=service_name,
            dependencies=dependencies,
            dependents=dependents,
        )

    async def calculate_deployment_order(self, service_name: str) -> DeploymentOrder:
        """Calculate deployment order for a service and its dependencies."""
        result = self._run_cli_command(["dependencies", "order", service_name])

        if result.get("error"):
            raise Exception(
                result.get("message", f"Failed to calculate deployment order for {service_name}")
            )

        return DeploymentOrder(
            service=result.get("service", service_name),
            deployment_order=result.get("deployment_order", []),
            total_services=result.get("total_services", 0),
        )

    async def validate_dependencies(self) -> DependencyValidation:
        """Validate all dependencies (check for circular deps, missing services)."""
        result = self._run_cli_command(["dependencies", "check"])

        if result.get("error"):
            raise Exception(result.get("message", "Failed to validate dependencies"))

        return DependencyValidation(
            valid=result.get("valid", False),
            errors=result.get("errors", []),
            total_errors=result.get("total_errors", 0),
        )

    async def add_dependency(self, service: str, dependency: str) -> DependencyOperationResponse:
        """Add a dependency to a service."""
        result = self._run_cli_command(["dependencies", "add", service, dependency])

        if result.get("error"):
            return DependencyOperationResponse(
                success=False,
                service=service,
                dependency=dependency,
                message=result.get("message", "Failed to add dependency"),
            )

        return DependencyOperationResponse(
            success=result.get("success", True),
            service=result.get("service", service),
            dependency=result.get("dependency", dependency),
            message=result.get("message", "Dependency added successfully"),
        )

    async def remove_dependency(self, service: str, dependency: str) -> DependencyOperationResponse:
        """Remove a dependency from a service."""
        result = self._run_cli_command(["dependencies", "remove", service, dependency])

        if result.get("error"):
            return DependencyOperationResponse(
                success=False,
                service=service,
                dependency=dependency,
                message=result.get("message", "Failed to remove dependency"),
            )

        return DependencyOperationResponse(
            success=result.get("success", True),
            service=result.get("service", service),
            dependency=result.get("dependency", dependency),
            message=result.get("message", "Dependency removed successfully"),
        )

    async def get_impact_analysis(self, service_name: str) -> ImpactAnalysis:
        """Get impact analysis for a service (what depends on it)."""
        result = self._run_cli_command(["dependencies", "impact", service_name])

        if result.get("error"):
            raise Exception(
                result.get("message", f"Failed to get impact analysis for {service_name}")
            )

        return ImpactAnalysis(
            service=result.get("service", service_name),
            direct_dependents=result.get("direct_dependents", []),
            all_dependents=result.get("all_dependents", []),
            impact_level=result.get("impact_level", "low"),
            total_affected=result.get("total_affected", 0),
        )

    async def detect_circular_dependencies(self) -> bool:
        """Detect if there are circular dependencies."""
        validation = await self.validate_dependencies()
        return not validation.valid and any(
            "circular" in error.lower() for error in validation.errors
        )

    async def get_all_dependencies(self) -> DependencyList:
        """Get list of all services with their dependencies."""
        result = self._run_cli_command(["dependencies", "list"])

        if result.get("error"):
            raise Exception(result.get("message", "Failed to get dependency list"))

        return DependencyList(
            dependencies=result.get("dependencies", {}),
            total_services=result.get("total_services", 0),
        )
