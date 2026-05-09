"""Tests for the auth router (login / refresh / logout / me)."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.auth import router as auth_router


class FakeKeycloakClient:
    """Stand-in for KeycloakClient that returns predictable token responses."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple, dict]] = []

    def authenticate(self, username: str, password: str):
        self.calls.append(("authenticate", (username, password), {}))
        if password != "correct":
            raise Exception("Invalid credentials")
        return {
            "access_token": f"acc-for-{username}",
            "refresh_token": f"ref-for-{username}",
            "expires_in": 1800,
            "user": {"sub": "uid-1", "preferred_username": username},
        }

    def refresh_token(self, refresh_token: str):
        self.calls.append(("refresh_token", (refresh_token,), {}))
        if refresh_token == "expired":
            raise Exception("Refresh token expired")
        if refresh_token == "no_access":
            return {"refresh_token": "rotated", "expires_in": 1800}  # missing access_token
        return {
            "access_token": "new-access",
            "refresh_token": "rotated",
            "expires_in": 1800,
        }

    def logout(self, refresh_token: str) -> bool:
        self.calls.append(("logout", (refresh_token,), {}))
        return refresh_token != "fail"


@pytest.fixture
def fake_keycloak() -> FakeKeycloakClient:
    return FakeKeycloakClient()


@pytest.fixture
def app(fake_keycloak, monkeypatch):
    """Build an app with the auth router mounted and Keycloak forced ON.

    monkeypatch.setattr handles cleanup automatically, so the override of
    `config.keycloak_enabled` doesn't leak into other test files.
    """
    app = FastAPI()
    app.include_router(auth_router)
    import routers.auth as auth_module

    monkeypatch.setattr(auth_module, "keycloak_client", fake_keycloak)

    # Replace the property on the Config CLASS so every instance reads the
    # patched value. monkeypatch reverts this on teardown.
    from config import Config

    monkeypatch.setattr(Config, "keycloak_enabled", property(lambda _: True))

    yield app


@pytest.fixture
def client(app):
    return TestClient(app)


def test_login_success_returns_tokens(client, fake_keycloak):
    resp = client.post("/api/auth/login", json={"username": "alice", "password": "correct"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"] == "acc-for-alice"
    assert body["refresh_token"] == "ref-for-alice"
    assert body["expires_in"] == 1800
    assert body["token_type"] == "Bearer"
    assert body["user"]["preferred_username"] == "alice"


def test_login_wrong_password_returns_401(client):
    resp = client.post("/api/auth/login", json={"username": "alice", "password": "wrong"})
    assert resp.status_code == 401
    assert resp.json()["detail"] == "Invalid credentials"


def test_login_validates_min_length(client):
    resp = client.post("/api/auth/login", json={"username": "", "password": ""})
    assert resp.status_code == 422  # pydantic validation


def test_refresh_success(client):
    resp = client.post("/api/auth/refresh", json={"refresh_token": "valid"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"] == "new-access"
    assert body["refresh_token"] == "rotated"


def test_refresh_expired_returns_401(client):
    resp = client.post("/api/auth/refresh", json={"refresh_token": "expired"})
    assert resp.status_code == 401


def test_refresh_missing_access_token_in_response_returns_502(client):
    """If Keycloak ever returns a refresh response without access_token,
    treat it as an upstream protocol error rather than passing the bad shape on."""
    resp = client.post("/api/auth/refresh", json={"refresh_token": "no_access"})
    assert resp.status_code == 502


def test_logout_returns_success(client, fake_keycloak):
    resp = client.post("/api/auth/logout", json={"refresh_token": "any"})
    assert resp.status_code == 200
    assert resp.json() == {"success": True}


def test_logout_returns_success_false_when_keycloak_says_so(client):
    resp = client.post("/api/auth/logout", json={"refresh_token": "fail"})
    # Logout is idempotent — we still 200 even when revocation failed.
    assert resp.status_code == 200
    assert resp.json() == {"success": False}


def test_endpoints_503_when_keycloak_disabled(client, monkeypatch):
    """If config.keycloak_enabled flips to False, /login + /refresh 503."""
    from config import Config

    monkeypatch.setattr(Config, "keycloak_enabled", property(lambda _: False))
    for path, body in [
        ("/api/auth/login", {"username": "u", "password": "p"}),
        ("/api/auth/refresh", {"refresh_token": "x"}),
        ("/api/auth/logout", {"refresh_token": "x"}),
    ]:
        resp = client.post(path, json=body)
        assert resp.status_code == 503, f"{path} did not 503"


def test_endpoints_503_when_keycloak_client_missing(client, monkeypatch):
    """Even if config says keycloak_enabled, the client must be initialized."""
    import routers.auth as auth_module

    monkeypatch.setattr(auth_module, "keycloak_client", None)
    resp = client.post("/api/auth/login", json={"username": "u", "password": "p"})
    assert resp.status_code == 503
