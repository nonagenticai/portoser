"""History Manager - Deployment history and rollback service"""

import json
import logging
import os
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

from models.history import (
    ConfigDiff,
    DeploymentListResponse,
    DeploymentRecord,
    DeploymentStats,
    DeploymentTimeline,
    DeploymentTimelineResponse,
    RollbackPreview,
    RollbackResult,
)
from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class HistoryManager:
    """Manages deployment history and rollback operations"""

    def __init__(self, cli_path: str = None):
        # Default CLI path: <repo-root>/portoser. services/history_manager.py ->
        # parents[2] is the repo root.
        default_cli = str(Path(__file__).resolve().parents[2] / "portoser")
        self.cli_path = cli_path or os.getenv("PORTOSER_CLI", default_cli)
        self.history_base = Path.home() / ".portoser" / "deployments"

    def _run_cli_command(self, args: List[str], json_output: bool = True) -> Dict[str, Any]:
        """Run portoser CLI command"""
        cmd = [self.cli_path, "history"] + args
        if json_output and "--json-output" not in args:
            cmd.append("--json-output")

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

            if result.returncode == 0 and json_output:
                try:
                    return json.loads(result.stdout)
                except json.JSONDecodeError:
                    return {"raw_output": result.stdout}
            else:
                return {"error": result.stderr or result.stdout, "returncode": result.returncode}

        except subprocess.TimeoutExpired:
            logger.error("CLI command timed out")
            return {"error": "Command timed out"}
        except Exception as e:
            logger.error(f"CLI command failed: {e}")
            return {"error": str(e)}

    def list_deployments(
        self,
        service: Optional[str] = None,
        machine: Optional[str] = None,
        status: Optional[str] = None,
        limit: int = 50,
        offset: int = 0,
        from_date: Optional[str] = None,
        to_date: Optional[str] = None,
    ) -> DeploymentListResponse:
        """List deployments with filters"""
        # Get all deployments via CLI
        args = []
        if service:
            args.append(service)

        result = self._run_cli_command(["list"] + args)

        if "error" in result:
            return DeploymentListResponse(deployments=[], total=0)

        deployments = result.get("deployments", [])

        # Parse into DeploymentRecord objects
        parsed_deployments = []
        for dep in deployments:
            try:
                parsed_deployments.append(DeploymentRecord(**dep))
            except Exception as e:
                logger.warning(f"Failed to parse deployment record: {e}")

        # Apply filters
        filtered = parsed_deployments

        if machine:
            filtered = [d for d in filtered if d.machine == machine]

        if status:
            filtered = [d for d in filtered if d.status == status]

        if from_date:
            from_dt = datetime.fromisoformat(from_date.replace("Z", "+00:00"))
            filtered = [
                d
                for d in filtered
                if datetime.fromisoformat(d.timestamp.replace("Z", "+00:00")) >= from_dt
            ]

        if to_date:
            to_dt = datetime.fromisoformat(to_date.replace("Z", "+00:00"))
            filtered = [
                d
                for d in filtered
                if datetime.fromisoformat(d.timestamp.replace("Z", "+00:00")) <= to_dt
            ]

        # Apply pagination
        total = len(filtered)
        paginated = filtered[offset : offset + limit]

        return DeploymentListResponse(
            deployments=paginated,
            total=total,
            filtered=len(filtered),
            service_filter=service,
            limit=limit,
            offset=offset,
        )

    def get_deployment(self, deployment_id: str) -> Optional[DeploymentRecord]:
        """Get specific deployment by ID"""
        result = self._run_cli_command(["show", deployment_id])

        if "error" in result:
            return None

        try:
            return DeploymentRecord(**result)
        except Exception as e:
            logger.error(f"Failed to parse deployment record: {e}")
            return None

    def preview_rollback(self, deployment_id: str) -> Optional[RollbackPreview]:
        """Preview what will change during rollback"""
        # Get deployment record
        deployment = self.get_deployment(deployment_id)
        if not deployment:
            return None

        # Get current configuration
        try:
            from services.portoser_cli import PortoserCLI

            cli = PortoserCLI(cli_path=self.cli_path)
            current_config = cli.get_service_config(deployment.service)
        except Exception as e:
            logger.error(f"Failed to get current config: {e}")
            current_config = {}

        target_config = deployment.config_snapshot

        # Calculate differences
        differences = self._calculate_config_diff(current_config, target_config)

        # Determine if safe to rollback
        warnings = []
        safe_to_rollback = True

        if deployment.status != "success":
            warnings.append("Target deployment was not successful")
            safe_to_rollback = False

        if not differences:
            warnings.append("No configuration changes detected")

        return RollbackPreview(
            deployment_id=deployment_id,
            service=deployment.service,
            machine=deployment.machine,
            current_config=current_config,
            target_config=target_config,
            differences=differences,
            warnings=warnings,
            safe_to_rollback=safe_to_rollback,
        )

    def _calculate_config_diff(
        self, current: Dict[str, Any], target: Dict[str, Any]
    ) -> List[ConfigDiff]:
        """Calculate configuration differences"""
        differences = []

        all_keys = set(current.keys()) | set(target.keys())

        for key in all_keys:
            if key not in current:
                differences.append(
                    ConfigDiff(
                        field=key, current_value=None, target_value=target[key], change_type="added"
                    )
                )
            elif key not in target:
                differences.append(
                    ConfigDiff(
                        field=key,
                        current_value=current[key],
                        target_value=None,
                        change_type="removed",
                    )
                )
            elif current[key] != target[key]:
                differences.append(
                    ConfigDiff(
                        field=key,
                        current_value=current[key],
                        target_value=target[key],
                        change_type="modified",
                    )
                )

        return differences

    def rollback_deployment(
        self, deployment_id: str, confirm: bool = False, dry_run: bool = False
    ) -> RollbackResult:
        """Execute rollback to a previous deployment"""
        if dry_run:
            # Just return preview
            preview = self.preview_rollback(deployment_id)
            if not preview:
                return RollbackResult(
                    success=False,
                    deployment_id=deployment_id,
                    message="Deployment not found",
                    error="Deployment not found",
                )

            return RollbackResult(
                success=True, deployment_id=deployment_id, message="Dry run - no changes made"
            )

        if not confirm:
            return RollbackResult(
                success=False,
                deployment_id=deployment_id,
                message="Rollback not confirmed",
                error="Confirmation required",
            )

        # Execute rollback via CLI
        args = ["rollback", deployment_id, "--force"]
        result = self._run_cli_command(args, json_output=False)

        success = result.get("returncode", 1) == 0

        return RollbackResult(
            success=success,
            deployment_id=deployment_id,
            rollback_deployment_id=None,  # Would be extracted from CLI output
            message="Rollback completed successfully" if success else "Rollback failed",
            error=result.get("error") if not success else None,
        )

    def get_timeline(
        self, days: int = 30, service: Optional[str] = None
    ) -> DeploymentTimelineResponse:
        """Get timeline view of deployments grouped by date"""
        # Get deployments
        from_date = (utcnow() - timedelta(days=days)).isoformat()

        response = self.list_deployments(service=service, from_date=from_date, limit=1000)

        # Group by date
        timeline_dict: Dict[str, List[DeploymentTimeline]] = {}

        for deployment in response.deployments:
            # Parse timestamp and get date
            dt = datetime.fromisoformat(deployment.timestamp.replace("Z", "+00:00"))
            date_key = dt.strftime("%Y-%m-%d")

            timeline_entry = DeploymentTimeline(
                id=deployment.id,
                service=deployment.service,
                machine=deployment.machine,
                action=deployment.action,
                status=deployment.status,
                timestamp=deployment.timestamp,
                duration_ms=deployment.duration_ms,
                problems_count=len(deployment.problems),
                solutions_count=len(deployment.solutions_applied),
            )

            if date_key not in timeline_dict:
                timeline_dict[date_key] = []

            timeline_dict[date_key].append(timeline_entry)

        return DeploymentTimelineResponse(timeline=timeline_dict, total=len(response.deployments))

    def get_stats(self, service: Optional[str] = None, days: int = 30) -> DeploymentStats:
        """Get deployment statistics"""
        # Pass empty string for service even when None — the bash CLI takes
        # SERVICE as $1 and DAYS as $2 positionally. Skipping $1 would shift
        # `days` into the SERVICE slot and the days slot would absorb the
        # `--json-output` flag instead, returning all zeros.
        args = ["stats", service or "", str(days)]
        result = self._run_cli_command(args)

        if "error" in result:
            return DeploymentStats(
                total=0,
                success=0,
                failure=0,
                rolled_back=0,
                success_rate=0.0,
                avg_duration_ms=0,
                days=days,
            )

        return DeploymentStats(
            total=result.get("total", 0),
            success=result.get("success", 0),
            failure=result.get("failure", 0),
            rolled_back=result.get("rolled_back", 0),
            success_rate=result.get("success_rate", 0.0),
            avg_duration_ms=result.get("avg_duration_ms", 0),
            days=days,
        )
