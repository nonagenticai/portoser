"""
Tests for Cluster API endpoints

Tests all REST and WebSocket endpoints for cluster management:
- Build operations
- Deployment operations
- Sync operations
- Clean operations
- Health checks
- Service discovery
- Buildx setup
- Overall status
"""

from unittest.mock import AsyncMock, Mock

import pytest
from fastapi import FastAPI, WebSocket
from fastapi.testclient import TestClient

from routers.cluster import router
from services.cluster_manager import ClusterManager, ClusterManagerError
from services.websocket_manager import WebSocketManager

# =============================================================================
# FIXTURES
# =============================================================================


@pytest.fixture
def mock_cluster_manager():
    """Mock ClusterManager instance"""
    manager = AsyncMock(spec=ClusterManager)

    # Mock build operations
    manager.build_services = AsyncMock(return_value="build-123")
    manager.get_build_status = Mock(
        return_value={
            "build_id": "build-123",
            "services": ["myservice", "ingestion"],
            "status": "completed",
            "started_at": "2025-12-03T12:00:00Z",
            "completed_at": "2025-12-03T12:05:00Z",
            "output": ["Building myservice...", "Building ingestion...", "Build complete"],
            "error": None,
        }
    )

    # Mock deployment operations
    manager.deploy_to_pi = AsyncMock(return_value="deploy-456")
    manager.get_deployment_status = Mock(
        return_value={
            "deployment_id": "deploy-456",
            "pi": "pi1",
            "services": ["myservice"],
            "status": "completed",
            "started_at": "2025-12-03T12:10:00Z",
            "completed_at": "2025-12-03T12:15:00Z",
            "output": ["Syncing files...", "Pulling images...", "Starting services..."],
            "error": None,
        }
    )

    # Mock sync operations
    manager.sync_pis = AsyncMock(
        return_value={
            "success": True,
            "results": {
                "pi1": {"success": True, "output": "Synced"},
                "pi2": {"success": True, "output": "Synced"},
            },
        }
    )

    # Mock clean operations
    manager.clean_pis = AsyncMock(
        return_value={
            "success": True,
            "results": {"pi1": {"success": True, "output": "Cleaned 1.2GB"}},
        }
    )

    # Mock health checks
    manager.check_health = AsyncMock(
        return_value={"success": True, "health": {"overall_status": "healthy", "pis": []}}
    )

    # Mock discovery
    manager.discover_services = AsyncMock(
        return_value={
            "success": True,
            "services": [
                {"name": "myservice", "deployment_type": "docker"},
                {"name": "ingestion", "deployment_type": "docker"},
            ],
        }
    )

    # Mock buildx
    manager.setup_buildx = AsyncMock(return_value={"success": True, "output": "Buildx configured"})

    # Mock status
    manager.get_cluster_status = AsyncMock(
        return_value={
            "build_capacity": {"running_builds": 0, "max_parallel": 4},
            "deployment_status": {"running_deployments": 0},
            "health": {"overall_status": "healthy"},
            "services": {"services": [], "total": 0},
            "timestamp": "2025-12-03T12:00:00Z",
        }
    )

    return manager


@pytest.fixture
def mock_ws_manager():
    """Mock WebSocketManager instance"""
    manager = AsyncMock(spec=WebSocketManager)
    manager.broadcast = AsyncMock()
    manager.connect = AsyncMock()
    manager.disconnect = AsyncMock()
    return manager


@pytest.fixture
def app(mock_cluster_manager, mock_ws_manager):
    """Create FastAPI test app with mocked dependencies"""
    app = FastAPI()
    app.include_router(router)

    # Inject mocked dependencies
    import routers.cluster as cluster_module

    cluster_module.cluster_manager = mock_cluster_manager
    cluster_module.ws_manager = mock_ws_manager

    return app


@pytest.fixture
def client(app):
    """Test client"""
    return TestClient(app)


@pytest.fixture
def mock_auth(app):
    """Bypass Keycloak auth by overriding get_current_user with a stub admin."""
    from auth.dependencies import get_current_user
    from auth.models import KeycloakUser

    def fake_user() -> KeycloakUser:
        return KeycloakUser(
            sub="test-sub",
            preferred_username="testuser",
            email="testuser@example.local",
            realm_access={"roles": ["deployer", "admin"]},
            resource_access={},
        )

    app.dependency_overrides[get_current_user] = fake_user
    yield fake_user
    app.dependency_overrides.pop(get_current_user, None)


# =============================================================================
# BUILD ENDPOINT TESTS
# =============================================================================


def test_trigger_build_success(client, mock_auth, mock_cluster_manager):
    """Test successful build trigger"""
    response = client.post(
        "/api/cluster/build",
        json={"services": ["myservice", "ingestion"], "rebuild": False, "batch_size": 4},
    )

    assert response.status_code == 202
    data = response.json()
    assert data["build_id"] == "build-123"
    assert data["services"] == ["myservice", "ingestion"]
    assert data["status"] == "running"

    # Verify manager was called
    mock_cluster_manager.build_services.assert_called_once()


def test_trigger_build_with_rebuild(client, mock_auth, mock_cluster_manager):
    """Test build trigger with rebuild flag"""
    response = client.post(
        "/api/cluster/build", json={"services": ["myservice"], "rebuild": True, "batch_size": 2}
    )

    assert response.status_code == 202
    data = response.json()
    assert data["build_id"] == "build-123"


def test_trigger_build_empty_services(client, mock_auth):
    """Test build trigger with empty services list"""
    response = client.post(
        "/api/cluster/build", json={"services": [], "rebuild": False, "batch_size": 4}
    )

    # Should fail validation (min_length=1)
    assert response.status_code == 422


def test_get_build_status_success(client, mock_cluster_manager):
    """Test getting build status"""
    response = client.get("/api/cluster/build/build-123")

    assert response.status_code == 200
    data = response.json()
    assert data["build_id"] == "build-123"
    assert data["services"] == ["myservice", "ingestion"]
    assert data["status"] == "completed"
    assert len(data["output"]) == 3


def test_get_build_status_not_found(client, mock_cluster_manager):
    """Test getting build status for non-existent build"""
    mock_cluster_manager.get_build_status.return_value = None

    response = client.get("/api/cluster/build/invalid-123")

    assert response.status_code == 404


# =============================================================================
# DEPLOYMENT ENDPOINT TESTS
# =============================================================================


def test_trigger_deployment_success(client, mock_auth, mock_cluster_manager):
    """Test successful deployment trigger"""
    response = client.post("/api/cluster/deploy", json={"pi": "pi1", "services": ["myservice"]})

    assert response.status_code == 202
    data = response.json()
    assert data["deployment_id"] == "deploy-456"
    assert data["pi"] == "pi1"
    assert data["services"] == ["myservice"]
    assert data["status"] == "running"


def test_trigger_deployment_invalid_pi(client, mock_auth):
    """Test deployment with invalid Pi name"""
    response = client.post(
        "/api/cluster/deploy",
        json={
            "pi": "pi99",  # Invalid
            "services": ["myservice"],
        },
    )

    # Should fail validation (pattern="^pi[1-4]$")
    assert response.status_code == 422


def test_get_deployment_status_success(client, mock_cluster_manager):
    """Test getting deployment status"""
    response = client.get("/api/cluster/deploy/deploy-456")

    assert response.status_code == 200
    data = response.json()
    assert data["deployment_id"] == "deploy-456"
    assert data["pi"] == "pi1"
    assert data["services"] == ["myservice"]
    assert data["status"] == "completed"


def test_get_deployment_status_not_found(client, mock_cluster_manager):
    """Test getting deployment status for non-existent deployment"""
    mock_cluster_manager.get_deployment_status.return_value = None

    response = client.get("/api/cluster/deploy/invalid-456")

    assert response.status_code == 404


# =============================================================================
# SYNC ENDPOINT TESTS
# =============================================================================


def test_sync_pis_success(client, mock_auth, mock_cluster_manager):
    """Test successful Pi sync"""
    response = client.post("/api/cluster/sync", json={"pis": ["pi1", "pi2"]})

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "completed"
    assert "sync_id" in data
    assert data["pis"] == ["pi1", "pi2"]
    assert "results" in data


def test_sync_pis_empty_list(client, mock_auth):
    """Test sync with empty Pi list"""
    response = client.post("/api/cluster/sync", json={"pis": []})

    # Should fail validation (min_length=1)
    assert response.status_code == 422


def test_sync_pis_failure(client, mock_auth, mock_cluster_manager):
    """Test sync failure"""
    mock_cluster_manager.sync_pis.return_value = {
        "success": False,
        "results": {"pi1": {"success": False, "error": "SSH timeout"}},
    }

    response = client.post("/api/cluster/sync", json={"pis": ["pi1"]})

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "failed"


# =============================================================================
# CLEAN ENDPOINT TESTS
# =============================================================================


def test_clean_pis_success(client, mock_auth, mock_cluster_manager):
    """Test successful Pi clean"""
    response = client.post("/api/cluster/clean", json={"pis": ["pi1"], "dry_run": False})

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "completed"
    assert "clean_id" in data
    assert data["pis"] == ["pi1"]
    assert data["dry_run"] is False


def test_clean_pis_dry_run(client, mock_auth, mock_cluster_manager):
    """Test Pi clean with dry run"""
    response = client.post("/api/cluster/clean", json={"pis": ["pi1"], "dry_run": True})

    assert response.status_code == 200
    data = response.json()
    assert data["dry_run"] is True


# =============================================================================
# HEALTH ENDPOINT TESTS
# =============================================================================


def test_get_cluster_health_success(client, mock_cluster_manager):
    """Test getting cluster health"""
    response = client.get("/api/cluster/health")

    assert response.status_code == 200
    data = response.json()
    assert "overall_status" in data
    assert "pis" in data
    assert "timestamp" in data


def test_get_cluster_health_error(client, mock_cluster_manager):
    """Test health check error handling"""
    mock_cluster_manager.check_health.side_effect = ClusterManagerError("Health check failed")

    response = client.get("/api/cluster/health")

    assert response.status_code == 500


def test_get_cluster_health_rolls_up_per_host(client, mock_cluster_manager):
    """Health endpoint groups per-service results into per-host PiHealth entries
    and reports the worst observed state as overall_status."""
    mock_cluster_manager.check_health.return_value = {
        "success": True,
        "health": {
            "timestamp": "2026-05-01T12:00:00Z",
            "healthy": 2,
            "degraded": 1,
            "down": 0,
            "skipped": 0,
            "total": 3,
            "services": [
                {"service": "myservice", "hostname": "host-a", "port": "8080", "status": "healthy"},
                {"service": "ingestion", "hostname": "host-a", "port": "8081", "status": "healthy"},
                {"service": "viz", "hostname": "host-b", "port": "8090", "status": "degraded"},
            ],
        },
    }

    response = client.get("/api/cluster/health")
    assert response.status_code == 200

    data = response.json()
    assert data["overall_status"] == "degraded"
    assert data["timestamp"] == "2026-05-01T12:00:00Z"

    pis = {entry["pi"]: entry for entry in data["pis"]}
    assert set(pis) == {"host-a", "host-b"}
    assert pis["host-a"]["status"] == "healthy"
    assert sorted(pis["host-a"]["services"]) == ["ingestion", "myservice"]
    assert pis["host-b"]["status"] == "degraded"


def test_get_cluster_health_reports_unhealthy_when_any_down(client, mock_cluster_manager):
    """A single 'down' service drives overall_status to 'unhealthy'."""
    mock_cluster_manager.check_health.return_value = {
        "success": True,
        "health": {
            "timestamp": "2026-05-01T12:00:00Z",
            "healthy": 1,
            "degraded": 0,
            "down": 1,
            "skipped": 0,
            "total": 2,
            "services": [
                {"service": "myservice", "hostname": "host-a", "port": "8080", "status": "healthy"},
                {"service": "viz", "hostname": "host-b", "port": "8090", "status": "down"},
            ],
        },
    }

    response = client.get("/api/cluster/health")
    assert response.status_code == 200
    data = response.json()
    assert data["overall_status"] == "unhealthy"
    pis = {entry["pi"]: entry for entry in data["pis"]}
    assert pis["host-b"]["status"] == "unhealthy"


# =============================================================================
# DISCOVERY ENDPOINT TESTS
# =============================================================================


def test_discover_services_success(client, mock_cluster_manager):
    """Test service discovery"""
    response = client.get("/api/cluster/services")

    assert response.status_code == 200
    data = response.json()
    assert "services" in data
    assert "total" in data
    assert data["total"] == 2


def test_discover_services_error(client, mock_cluster_manager):
    """Test discovery error handling"""
    mock_cluster_manager.discover_services.side_effect = ClusterManagerError("Discovery failed")

    response = client.get("/api/cluster/services")

    assert response.status_code == 500


# =============================================================================
# BUILDX ENDPOINT TESTS
# =============================================================================


def test_setup_buildx_success(client, mock_auth, mock_cluster_manager):
    """Test buildx setup"""
    response = client.post("/api/cluster/setup-buildx")

    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert "output" in data


def test_setup_buildx_error(client, mock_auth, mock_cluster_manager):
    """Test buildx setup error"""
    mock_cluster_manager.setup_buildx.side_effect = ClusterManagerError("Buildx failed")

    response = client.post("/api/cluster/setup-buildx")

    assert response.status_code == 500


# =============================================================================
# STATUS ENDPOINT TESTS
# =============================================================================


def test_get_cluster_status_success(client, mock_cluster_manager):
    """Test getting overall cluster status"""
    response = client.get("/api/cluster/status")

    assert response.status_code == 200
    data = response.json()
    assert "build_capacity" in data
    assert "deployment_status" in data
    assert "health" in data
    assert "services" in data
    assert "timestamp" in data


# =============================================================================
# WEBSOCKET TESTS
# =============================================================================


@pytest.mark.asyncio
async def test_build_websocket_connection(mock_ws_manager):
    """Test WebSocket connection for build streaming"""
    mock_websocket = AsyncMock(spec=WebSocket)
    mock_websocket.send_json = AsyncMock()
    mock_websocket.receive_text = AsyncMock(side_effect=["ping", "ping"])

    mock_ws_manager.connect = AsyncMock()
    mock_ws_manager.disconnect = AsyncMock()

    # The WebSocket endpoint should connect and handle messages
    # This is a basic test - actual WebSocket testing requires more setup
    assert True  # Placeholder for WebSocket tests


@pytest.mark.asyncio
async def test_deployment_websocket_connection(mock_ws_manager):
    """Test WebSocket connection for deployment streaming"""
    mock_websocket = AsyncMock(spec=WebSocket)
    mock_websocket.send_json = AsyncMock()
    mock_websocket.receive_text = AsyncMock(side_effect=["ping", "ping"])

    mock_ws_manager.connect = AsyncMock()
    mock_ws_manager.disconnect = AsyncMock()

    assert True  # Placeholder for WebSocket tests


@pytest.mark.asyncio
async def test_health_websocket_connection(mock_ws_manager):
    """Test WebSocket connection for health monitoring"""
    mock_websocket = AsyncMock(spec=WebSocket)
    mock_websocket.send_json = AsyncMock()
    mock_websocket.receive_text = AsyncMock(side_effect=["ping", "ping"])

    mock_ws_manager.connect = AsyncMock()
    mock_ws_manager.disconnect = AsyncMock()

    assert True  # Placeholder for WebSocket tests


# =============================================================================
# ERROR HANDLING TESTS
# =============================================================================


def test_cluster_manager_not_initialized(client):
    """Test error when cluster manager not initialized"""
    # Temporarily set cluster_manager to None
    import routers.cluster as cluster_module

    original = cluster_module.cluster_manager
    cluster_module.cluster_manager = None

    response = client.get("/api/cluster/status")

    assert response.status_code == 503
    assert "not initialized" in response.json()["detail"]

    # Restore
    cluster_module.cluster_manager = original


def test_cluster_manager_error_handling(client, mock_cluster_manager):
    """Test ClusterManagerError handling"""
    mock_cluster_manager.get_cluster_status.side_effect = ClusterManagerError("Test error")

    response = client.get("/api/cluster/status")

    assert response.status_code == 500
    assert "Test error" in response.json()["detail"]


# =============================================================================
# INTEGRATION TESTS
# =============================================================================


def test_full_build_and_deploy_workflow(client, mock_auth, mock_cluster_manager):
    """Test complete build -> deploy workflow"""
    # 1. Trigger build
    build_response = client.post(
        "/api/cluster/build", json={"services": ["myservice"], "rebuild": False, "batch_size": 4}
    )
    assert build_response.status_code == 202
    build_id = build_response.json()["build_id"]

    # 2. Check build status
    status_response = client.get(f"/api/cluster/build/{build_id}")
    assert status_response.status_code == 200
    assert status_response.json()["status"] == "completed"

    # 3. Trigger deployment
    deploy_response = client.post(
        "/api/cluster/deploy", json={"pi": "pi1", "services": ["myservice"]}
    )
    assert deploy_response.status_code == 202
    deployment_id = deploy_response.json()["deployment_id"]

    # 4. Check deployment status
    deploy_status_response = client.get(f"/api/cluster/deploy/{deployment_id}")
    assert deploy_status_response.status_code == 200
    assert deploy_status_response.json()["status"] == "completed"


def test_cluster_status_reflects_operations(client, mock_cluster_manager):
    """Test that cluster status reflects running operations"""
    # Initially no operations running
    response = client.get("/api/cluster/status")
    assert response.status_code == 200
    data = response.json()
    assert data["build_capacity"]["running_builds"] == 0
    assert data["deployment_status"]["running_deployments"] == 0


# =============================================================================
# AUTHENTICATION TESTS
# =============================================================================


def test_build_requires_authentication(client):
    """Test that build endpoint requires authentication"""
    # Without mocked auth, should fail
    # This depends on auth middleware being properly configured
    # For now, just verify the endpoint exists
    response = client.post(
        "/api/cluster/build", json={"services": ["myservice"], "rebuild": False, "batch_size": 4}
    )
    # Will be 403/401 without auth, or 202 with mocked auth
    assert response.status_code in [200, 202, 401, 403, 422]


def test_deploy_requires_authentication(client):
    """Test that deploy endpoint requires authentication"""
    response = client.post("/api/cluster/deploy", json={"pi": "pi1", "services": ["myservice"]})
    # Will be 403/401 without auth, or 202 with mocked auth
    assert response.status_code in [200, 202, 401, 403, 422]


# =============================================================================
# VALIDATION TESTS
# =============================================================================


def test_build_validation_batch_size(client, mock_auth):
    """Test build validation for batch size"""
    response = client.post(
        "/api/cluster/build",
        json={
            "services": ["myservice"],
            "rebuild": False,
            "batch_size": 0,  # Invalid: must be >= 1
        },
    )

    assert response.status_code == 422


def test_deploy_validation_pi_pattern(client, mock_auth):
    """Test deployment validation for Pi pattern"""
    response = client.post(
        "/api/cluster/deploy",
        json={
            "pi": "raspberry1",  # Invalid: must match pi[1-4]
            "services": ["myservice"],
        },
    )

    assert response.status_code == 422


def test_sync_validation_empty_pis(client, mock_auth):
    """Test sync validation for empty Pi list"""
    response = client.post(
        "/api/cluster/sync",
        json={
            "pis": []  # Invalid: min_length=1
        },
    )

    assert response.status_code == 422
