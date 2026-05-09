"""Integration tests for the machines API.

These tests pin the *current* behavior of the inline /api/machines endpoints
in main.py so a planned extraction to routers/machines.py is a no-op
visible-side-effects-wise.

Each test gets a fresh registry.yml in a temp dir; the env var
``CADDY_REGISTRY_PATH`` is patched so the RegistryService points at it.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest
import yaml
from fastapi.testclient import TestClient


@pytest.fixture
def fresh_registry(monkeypatch):
    """Provide a temp registry.yml and route the backend at it."""
    tmpdir = tempfile.mkdtemp(prefix="portoser-test-registry-")
    registry_path = Path(tmpdir) / "registry.yml"
    registry_path.write_text(yaml.safe_dump({"domain": "test.local", "hosts": {}, "services": {}}))

    monkeypatch.setenv("CADDY_REGISTRY_PATH", str(registry_path))
    monkeypatch.setenv("KEYCLOAK_ENABLED", "false")
    monkeypatch.setenv("REGISTRY_PATH", str(registry_path))
    # Production requires auth; force development so the env validator
    # doesn't refuse to start the app under TestClient.
    monkeypatch.setenv("ENVIRONMENT", "development")

    yield registry_path


@pytest.fixture
def client(fresh_registry, monkeypatch):
    """A TestClient that's wired to the temp registry.

    main.py builds module-level state (RegistryService cache, ws_manager)
    on import. We force fresh resolution by clearing the module cache for
    everything that closes over the env vars.
    """
    import sys

    # Clear cached singletons so the registry path resolves freshly. Note:
    # any module that imported `from services.registry_helpers import
    # load_registry` retains a *function reference* whose enclosing module
    # is whatever was loaded at the time of that import. So we must drop
    # routers/* too — otherwise routers.machines.load_registry still calls
    # into the OLD services.registry_helpers (with the previous test's
    # cached path).
    to_clear = [
        m
        for m in list(sys.modules)
        if m == "main"
        or m == "config"
        or m == "routers"
        or m.startswith("routers.")
        or m == "services.registry_service"
        or m == "services.registry_helpers"
    ]
    for mod in to_clear:
        sys.modules.pop(mod, None)

    # registry_helpers caches the RegistryService singleton in a module
    # global; force it to re-resolve against the new env-driven path.
    import services.registry_helpers as rh
    from config import config  # noqa: F401  (forces re-evaluation)
    from main import app

    rh.reset_for_tests()

    with TestClient(app) as client:
        yield client


def test_list_machines_starts_empty(client):
    resp = client.get("/api/machines")
    assert resp.status_code == 200
    assert resp.json() == {"machines": []}


def test_create_machine_then_list_includes_it(client):
    resp = client.post(
        "/api/machines",
        json={"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops", "roles": ["builder"]},
    )
    assert resp.status_code == 200
    assert resp.json() == {"success": True, "machine": "host-a"}

    resp = client.get("/api/machines")
    machines = resp.json()["machines"]
    assert len(machines) == 1
    assert machines[0]["name"] == "host-a"
    assert machines[0]["ip"] == "192.0.2.10"
    assert machines[0]["ssh_user"] == "ops"
    assert machines[0]["roles"] == ["builder"]
    assert machines[0]["services_count"] == 0


def _err_message(json_body: dict) -> str:
    """Extract error text from either the wrapped or bare HTTPException shape.

    The app's http_exception_handler wraps errors as
    ``{"error": {"message": ..., ...}}``; legacy clients still see
    ``{"detail": ...}`` — accept either so tests aren't tied to one shape.
    """
    if isinstance(json_body, dict):
        if "error" in json_body and isinstance(json_body["error"], dict):
            return str(json_body["error"].get("message", ""))
        if "detail" in json_body:
            return str(json_body["detail"])
    return ""


def test_create_duplicate_machine_400(client):
    payload = {"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops"}
    assert client.post("/api/machines", json=payload).status_code == 200
    resp = client.post("/api/machines", json=payload)
    assert resp.status_code == 400
    assert "already exists" in _err_message(resp.json()).lower()


def test_get_machine_returns_full_record(client):
    client.post(
        "/api/machines",
        json={"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops"},
    )
    resp = client.get("/api/machines/host-a")
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "host-a"
    assert body["ip"] == "192.0.2.10"
    assert body["services"] == []


def test_get_unknown_machine_404(client):
    resp = client.get("/api/machines/ghost")
    assert resp.status_code == 404


def test_update_machine_patches_fields(client):
    client.post(
        "/api/machines",
        json={"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops"},
    )
    resp = client.put(
        "/api/machines/host-a",
        json={"ip": "192.0.2.20", "roles": ["builder", "k8s"]},
    )
    assert resp.status_code == 200

    resp = client.get("/api/machines/host-a")
    assert resp.json()["ip"] == "192.0.2.20"
    assert resp.json()["roles"] == ["builder", "k8s"]
    # ssh_user untouched
    assert resp.json()["ssh_user"] == "ops"


def test_update_unknown_machine_404(client):
    resp = client.put("/api/machines/ghost", json={"ip": "10.0.0.1"})
    assert resp.status_code == 404


def test_delete_machine_succeeds_when_no_services(client):
    client.post(
        "/api/machines",
        json={"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops"},
    )
    resp = client.delete("/api/machines/host-a")
    assert resp.status_code == 200

    resp = client.get("/api/machines")
    assert resp.json() == {"machines": []}


def test_delete_machine_400_when_services_present(client, fresh_registry):
    # Create the machine plus a service that lives on it.
    client.post(
        "/api/machines",
        json={"name": "host-a", "ip": "192.0.2.10", "ssh_user": "ops"},
    )
    # Inject a service directly into the registry — the service-creation API
    # is exercised in test_inline_services; here we just need a service that
    # lives on host-a.
    data = yaml.safe_load(fresh_registry.read_text())
    data["services"]["myservice"] = {"current_host": "host-a", "deployment_type": "docker"}
    fresh_registry.write_text(yaml.safe_dump(data))

    # Bust the registry cache by reading once
    client.get("/api/machines")

    resp = client.delete("/api/machines/host-a")
    assert resp.status_code == 400
    assert "myservice" in _err_message(resp.json())
