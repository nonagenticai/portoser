#!/usr/bin/env python3
"""
Build API Server for Portoser - HARDENED VERSION
Handles build requests, queue management, and multi-arch builds
Features: SQLite persistence, authentication, input validation, rate limiting
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends, Request
from pydantic import BaseModel, validator
from typing import List, Optional
from datetime import datetime
import uuid
import subprocess
import os
from enum import Enum
import asyncio
from collections import deque, defaultdict
import time
import re
import json

# Import security components
from .middleware.auth import verify_build_token
from .models.build_job import BuildJob, init_db, get_db, SessionLocal

app = FastAPI(title="Portoser Build API - Secured", version="2.0.0")

# Configuration
REGISTRY = os.getenv("REGISTRY", "registry.portoser.local")
BUILDX_BUILDER = os.getenv("BUILDX_BUILDER", "multiarch")
REPO_PATH = os.getenv("REPO_PATH", "/opt/portoser")

# Validation patterns
VALID_SERVICE_NAME = re.compile(r'^[a-z0-9-]+$')
VALID_GIT_REF = re.compile(r'^[a-zA-Z0-9._/-]+$')
VALID_MACHINE_NAME = re.compile(r'^[a-z0-9-]+$')

# Allowed services (whitelist)
ALLOWED_SERVICES = os.getenv("ALLOWED_SERVICES", "web,api,worker,ingestion,secrets,licenses").split(",")

# Build queue and status storage
class BuildStatus(str, Enum):
    QUEUED = "queued"
    BUILDING = "building"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

class Priority(str, Enum):
    CRITICAL = "critical"  # 0-5 min
    HIGH = "high"          # 5-15 min
    NORMAL = "normal"      # 15-30 min
    LOW = "low"            # 30+ min

class BuildRequest(BaseModel):
    machine: str
    services: List[str]
    architectures: List[str] = ["amd64", "arm64"]
    priority: Priority = Priority.NORMAL
    git_ref: str = "main"
    callback_url: Optional[str] = None
    tag: str = "latest"

    @validator('machine')
    def validate_machine(cls, v):
        if not VALID_MACHINE_NAME.match(v):
            raise ValueError(f"Invalid machine name: {v}. Must be lowercase alphanumeric with hyphens.")
        if len(v) > 50:
            raise ValueError("Machine name too long (max 50 chars)")
        return v

    @validator('services')
    def validate_services(cls, v):
        if not v:
            raise ValueError("At least one service required")
        if len(v) > 10:
            raise ValueError("Too many services (max 10)")
        for service in v:
            if not VALID_SERVICE_NAME.match(service):
                raise ValueError(f"Invalid service name: {service}")
            if service not in ALLOWED_SERVICES:
                raise ValueError(f"Service not allowed: {service}. Allowed: {', '.join(ALLOWED_SERVICES)}")
        return v

    @validator('git_ref')
    def validate_git_ref(cls, v):
        if not VALID_GIT_REF.match(v):
            raise ValueError(f"Invalid git ref: {v}")
        if '..' in v:
            raise ValueError("Path traversal not allowed in git ref")
        if len(v) > 200:
            raise ValueError("Git ref too long (max 200 chars)")
        return v

    @validator('architectures')
    def validate_architectures(cls, v):
        allowed = ['amd64', 'arm64', 'arm/v7']
        for arch in v:
            if arch not in allowed:
                raise ValueError(f"Invalid architecture: {arch}. Allowed: {', '.join(allowed)}")
        return v

    @validator('tag')
    def validate_tag(cls, v):
        if not re.match(r'^[a-zA-Z0-9._-]+$', v):
            raise ValueError(f"Invalid tag: {v}")
        if len(v) > 128:
            raise ValueError("Tag too long (max 128 chars)")
        return v

class BuildInfo(BaseModel):
    build_id: str
    machine: str
    services: List[str]
    architectures: List[str]
    priority: Priority
    status: BuildStatus
    requested_at: datetime
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    worker_id: Optional[str] = None
    error: Optional[str] = None
    images: List[str] = []
    logs: List[str] = []

# Rate Limiter
class RateLimiter:
    def __init__(self, requests_per_minute: int = 10):
        self.requests = defaultdict(list)
        self.limit = requests_per_minute

    async def check(self, request: Request):
        """Check if request is within rate limit"""
        client = request.client.host
        now = time.time()

        # Clean old requests (older than 60 seconds)
        self.requests[client] = [
            t for t in self.requests[client]
            if now - t < 60
        ]

        if len(self.requests[client]) >= self.limit:
            raise HTTPException(
                status_code=429,
                detail=f"Rate limit exceeded. Max {self.limit} requests per minute."
            )

        self.requests[client].append(now)
        return True

# Global rate limiter
rate_limiter = RateLimiter(requests_per_minute=10)

# Initialize database
init_db()

# In-memory queue (persist across restarts via DB queries)
build_queues = {
    Priority.CRITICAL: deque(),
    Priority.HIGH: deque(),
    Priority.NORMAL: deque(),
    Priority.LOW: deque()
}
active_builds = []
MAX_CONCURRENT_BUILDS = 3

def load_queued_builds():
    """Load queued builds from database on startup"""
    db = SessionLocal()
    try:
        queued = db.query(BuildJob).filter(BuildJob.status == "queued").order_by(BuildJob.created_at).all()
        for job in queued:
            priority = Priority(job.priority)
            if job.build_id not in build_queues[priority]:
                build_queues[priority].append(job.build_id)
    finally:
        db.close()

# Load queued builds on startup
load_queued_builds()

def get_next_build() -> Optional[str]:
    """Get next build from queue based on priority"""
    for priority in [Priority.CRITICAL, Priority.HIGH, Priority.NORMAL, Priority.LOW]:
        if build_queues[priority]:
            return build_queues[priority].popleft()
    return None

async def execute_build(build_id: str):
    """Execute a build using docker buildx"""
    db = SessionLocal()
    try:
        build_job = db.query(BuildJob).filter(BuildJob.build_id == build_id).first()
        if not build_job:
            return

        build_job.status = "building"
        build_job.started_at = datetime.utcnow()
        build_job.worker_id = f"worker-{os.getpid()}"
        db.commit()

        try:
            # Verify buildx builder exists
            build_job.append_log(f"Verifying buildx builder: {BUILDX_BUILDER}")
            db.commit()

            result = subprocess.run(
                ["docker", "buildx", "inspect", BUILDX_BUILDER],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                raise Exception(f"Buildx builder '{BUILDX_BUILDER}' not found. Run scripts/setup-buildx.sh first")

            # Update git repository
            build_job.append_log(f"Updating repository to {build_job.git_ref}")
            db.commit()

            result = subprocess.run(
                ["git", "fetch", "origin"],
                cwd=REPO_PATH,
                capture_output=True,
                text=True,
                timeout=300
            )
            if result.returncode != 0:
                raise Exception(f"Git fetch failed: {result.stderr}")

            result = subprocess.run(
                ["git", "checkout", build_job.git_ref],
                cwd=REPO_PATH,
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                raise Exception(f"Git checkout failed: {result.stderr}")

            # Build each service
            services = build_job.service.split(",")
            images_built = []

            for service in services:
                service_path = os.path.join(REPO_PATH, "services", service)

                if not os.path.exists(service_path):
                    raise Exception(f"Service path not found: {service_path}")

                # Construct platform string
                platforms = ",".join([f"linux/{arch}" for arch in build_job.architectures.split(",")])
                image_name = f"{REGISTRY}/portoser/{service}:{build_job.machine}-latest"

                build_job.append_log(f"Building {service} for {platforms}")
                db.commit()

                # Build command
                cmd = [
                    "docker", "buildx", "build",
                    "--builder", BUILDX_BUILDER,
                    "--platform", platforms,
                    "--tag", image_name,
                    "--push",
                    service_path
                ]

                build_job.append_log(f"Command: {' '.join(cmd)}")
                db.commit()

                # Execute build
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    cwd=REPO_PATH
                )

                # Stream logs with timeout protection
                timeout = 3600  # 1 hour max per service
                start_time = datetime.utcnow()

                for line in process.stdout:
                    build_job.append_log(line.strip())
                    if (datetime.utcnow() - start_time).total_seconds() > timeout:
                        process.kill()
                        raise Exception(f"Build timeout exceeded ({timeout}s) for {service}")
                    # Commit every 10 lines to avoid memory issues
                    db.commit()

                process.wait()

                if process.returncode != 0:
                    # Capture last 20 lines for error context
                    error_logs = "\n".join((build_job.logs or "").split("\n")[-20:])
                    raise Exception(f"Build failed for {service} with code {process.returncode}\nLast logs:\n{error_logs}")

                images_built.append(image_name)
                build_job.append_log(f"Successfully built and pushed {image_name}")
                db.commit()

            # Mark as completed
            build_job.status = "completed"
            build_job.completed_at = datetime.utcnow()
            build_job.images = json.dumps(images_built)
            build_job.append_log("Build completed successfully")
            db.commit()

        except Exception as e:
            build_job.status = "failed"
            build_job.completed_at = datetime.utcnow()
            build_job.error = str(e)
            build_job.append_log(f"Build failed: {e}")
            db.commit()

    finally:
        db.close()
        if build_id in active_builds:
            active_builds.remove(build_id)
        # Start next build if any
        asyncio.create_task(process_queue())

async def process_queue():
    """Process build queue"""
    if len(active_builds) >= MAX_CONCURRENT_BUILDS:
        return

    build_id = get_next_build()
    if build_id:
        active_builds.append(build_id)
        asyncio.create_task(execute_build(build_id))

@app.post("/api/v1/builds", response_model=dict, dependencies=[Depends(verify_build_token)])
async def create_build(
    request: BuildRequest,
    background_tasks: BackgroundTasks,
    http_request: Request,
    _rate_limit: bool = Depends(rate_limiter.check)
):
    """Trigger a new build (authenticated)"""
    # Generate build ID
    build_id = str(uuid.uuid4())

    db = SessionLocal()
    try:
        # Check for existing queued/building builds for this machine
        existing = db.query(BuildJob).filter(
            BuildJob.machine == request.machine,
            BuildJob.status.in_(["queued", "building"])
        ).first()

        if existing:
            raise HTTPException(
                status_code=409,
                detail=f"Build already in progress for {request.machine}"
            )

        # Create build job in database
        build_job = BuildJob(
            build_id=build_id,
            machine=request.machine,
            service=",".join(request.services),
            git_ref=request.git_ref,
            status="queued",
            architectures=",".join(request.architectures),
            priority=request.priority.value,
            created_at=datetime.utcnow()
        )

        db.add(build_job)
        db.commit()

        # Add to in-memory queue
        build_queues[request.priority].append(build_id)

        # Process queue
        background_tasks.add_task(process_queue)

        return {
            "build_id": build_id,
            "status": "queued",
            "status_url": f"/api/v1/builds/{build_id}/status",
            "position_in_queue": len(build_queues[request.priority])
        }
    finally:
        db.close()

@app.get("/api/v1/builds/{build_id}", response_model=BuildInfo, dependencies=[Depends(verify_build_token)])
async def get_build(build_id: str):
    """Get build details (authenticated)"""
    db = SessionLocal()
    try:
        build_job = db.query(BuildJob).filter(BuildJob.build_id == build_id).first()
        if not build_job:
            raise HTTPException(status_code=404, detail="Build not found")

        return BuildInfo(
            build_id=build_job.build_id,
            machine=build_job.machine,
            services=build_job.service.split(","),
            architectures=build_job.architectures.split(","),
            priority=Priority(build_job.priority),
            status=BuildStatus(build_job.status),
            requested_at=build_job.created_at,
            started_at=build_job.started_at,
            completed_at=build_job.completed_at,
            worker_id=build_job.worker_id,
            error=build_job.error,
            images=json.loads(build_job.images) if build_job.images else [],
            logs=(build_job.logs or "").split("\n") if build_job.logs else []
        )
    finally:
        db.close()

@app.get("/api/v1/builds/{build_id}/status", dependencies=[Depends(verify_build_token)])
async def get_build_status(build_id: str):
    """Get current build status (authenticated)"""
    db = SessionLocal()
    try:
        build_job = db.query(BuildJob).filter(BuildJob.build_id == build_id).first()
        if not build_job:
            raise HTTPException(status_code=404, detail="Build not found")

        services = build_job.service.split(",")
        images_count = len(json.loads(build_job.images)) if build_job.images else 0

        # Calculate estimated time
        estimated_time = None
        if build_job.status == "queued":
            base_times = {
                "critical": 300,
                "high": 600,
                "normal": 1200,
                "low": 1800
            }
            estimated_time = base_times.get(build_job.priority, 1200)
        elif build_job.status == "building" and build_job.started_at:
            elapsed = (datetime.utcnow() - build_job.started_at).total_seconds()
            estimated_time = max(0, 900 - elapsed)  # 15 min average

        return {
            "status": build_job.status,
            "progress": images_count / len(services) * 100 if services else 0,
            "estimated_time": estimated_time,
            "images_built": images_count,
            "total_services": len(services)
        }
    finally:
        db.close()

@app.get("/api/v1/builds/{build_id}/logs", dependencies=[Depends(verify_build_token)])
async def get_build_logs(build_id: str, tail: int = 100):
    """Get build logs (authenticated)"""
    db = SessionLocal()
    try:
        build_job = db.query(BuildJob).filter(BuildJob.build_id == build_id).first()
        if not build_job:
            raise HTTPException(status_code=404, detail="Build not found")

        logs = (build_job.logs or "").split("\n") if build_job.logs else []

        return {
            "build_id": build_id,
            "logs": logs[-tail:] if tail else logs,
            "log_size": len(build_job.logs or "")
        }
    finally:
        db.close()

@app.get("/api/v1/queue", dependencies=[Depends(verify_build_token)])
async def get_queue():
    """View build queue (authenticated)"""
    db = SessionLocal()
    try:
        queue_status = {}
        for priority in Priority:
            builds = []
            queued_jobs = db.query(BuildJob).filter(
                BuildJob.status == "queued",
                BuildJob.priority == priority.value
            ).order_by(BuildJob.created_at).all()

            for job in queued_jobs:
                builds.append({
                    "build_id": job.build_id,
                    "machine": job.machine,
                    "services": job.service.split(","),
                    "requested_at": job.created_at.isoformat()
                })
            queue_status[priority.value] = builds

        return {
            "active_builds": len(active_builds),
            "max_concurrent": MAX_CONCURRENT_BUILDS,
            "queues": queue_status
        }
    finally:
        db.close()

@app.delete("/api/v1/builds/{build_id}", dependencies=[Depends(verify_build_token)])
async def cancel_build(build_id: str):
    """Cancel a build (authenticated)"""
    db = SessionLocal()
    try:
        build_job = db.query(BuildJob).filter(BuildJob.build_id == build_id).first()
        if not build_job:
            raise HTTPException(status_code=404, detail="Build not found")

        if build_job.status == "queued":
            # Remove from queue
            priority = Priority(build_job.priority)
            if build_id in build_queues[priority]:
                build_queues[priority].remove(build_id)

            build_job.status = "cancelled"
            build_job.completed_at = datetime.utcnow()
            db.commit()
            return {"message": "Build cancelled"}

        elif build_job.status == "building":
            raise HTTPException(
                status_code=409,
                detail="Cannot cancel build in progress"
            )
        else:
            raise HTTPException(
                status_code=409,
                detail=f"Cannot cancel build with status {build_job.status}"
            )
    finally:
        db.close()

@app.get("/api/v1/workers", dependencies=[Depends(verify_build_token)])
async def get_workers():
    """Get worker status (authenticated)"""
    db = SessionLocal()
    try:
        current_builds = []
        for bid in active_builds:
            job = db.query(BuildJob).filter(BuildJob.build_id == bid).first()
            if job:
                current_builds.append({
                    "build_id": bid,
                    "machine": job.machine,
                    "services": job.service.split(",")
                })

        return {
            "active_workers": len(active_builds),
            "max_workers": MAX_CONCURRENT_BUILDS,
            "current_builds": current_builds
        }
    finally:
        db.close()

@app.get("/health")
async def health_check():
    """Health check endpoint (unauthenticated)"""
    db = SessionLocal()
    try:
        queued_count = db.query(BuildJob).filter(BuildJob.status == "queued").count()
        return {
            "status": "healthy",
            "active_builds": len(active_builds),
            "queued_builds": queued_count
        }
    finally:
        db.close()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
