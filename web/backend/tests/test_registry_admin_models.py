"""Verify the registry-admin Pydantic models accept the shapes the
inline endpoints accept today, and reject the shapes they reject today."""

import pytest
from pydantic import ValidationError

from models.registry_admin import (
    DeploymentPlan,
    DeploymentStatus,
    MachineCreate,
    MachineUpdate,
    ServiceCreate,
    ServiceMove,
    ServiceUpdate,
)


def test_machine_create_minimal():
    m = MachineCreate(name="host-a", ip="192.0.2.10", ssh_user="ops")
    assert m.roles == []
    assert m.description is None


def test_machine_create_rejects_missing_required():
    with pytest.raises(ValidationError):
        MachineCreate(ip="192.0.2.10", ssh_user="ops")  # missing name


def test_machine_update_all_optional():
    u = MachineUpdate()
    assert u.ip is None and u.roles is None


def test_service_create_minimal():
    s = ServiceCreate(name="myservice", current_host="host-a", deployment_type="docker")
    assert s.hostname is None


def test_service_update_all_optional():
    u = ServiceUpdate()
    assert u.deployment_type is None


def test_service_move_required_fields():
    m = ServiceMove(service_name="myservice", from_machine="host-a", to_machine="host-b")
    assert m.service_name == "myservice"


def test_deployment_plan_defaults_dry_run_true():
    p = DeploymentPlan(
        moves=[ServiceMove(service_name="myservice", from_machine="host-a", to_machine="host-b")]
    )
    assert p.dry_run is True


def test_deployment_status_progress_bounds():
    s = DeploymentStatus(status="running")
    assert s.progress == 0.0
    assert s.logs == []
