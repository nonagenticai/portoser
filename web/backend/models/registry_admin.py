"""Pydantic request models for /api/machines, /api/services, and /api/deployment.

These were previously declared inline in main.py. They live here so the
extracted routers (machines, services_admin, deployment) can import them
without pulling in main.
"""

from typing import List, Optional

from pydantic import BaseModel


class MachineCreate(BaseModel):
    name: str
    ip: str
    ssh_user: str
    roles: List[str] = []
    description: Optional[str] = None


class MachineUpdate(BaseModel):
    ip: Optional[str] = None
    ssh_user: Optional[str] = None
    roles: Optional[List[str]] = None
    description: Optional[str] = None


class ServiceCreate(BaseModel):
    name: str
    hostname: Optional[str] = None
    current_host: str
    deployment_type: str  # docker, native, local
    docker_compose: Optional[str] = None
    service_file: Optional[str] = None
    service_name: Optional[str] = None  # For multi-service docker-compose
    description: Optional[str] = None


class ServiceUpdate(BaseModel):
    hostname: Optional[str] = None
    current_host: Optional[str] = None
    deployment_type: Optional[str] = None
    docker_compose: Optional[str] = None
    service_file: Optional[str] = None
    service_name: Optional[str] = None
    description: Optional[str] = None


class ServiceMove(BaseModel):
    service_name: str
    from_machine: str
    to_machine: str


class DeploymentPlan(BaseModel):
    moves: List[ServiceMove]
    dry_run: bool = True


class DeploymentStatus(BaseModel):
    status: str  # pending, running, completed, failed
    current_step: Optional[str] = None
    progress: float = 0.0
    logs: List[str] = []
    error: Optional[str] = None
