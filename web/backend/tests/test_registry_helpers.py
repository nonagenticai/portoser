"""Round-trip + error-mapping tests for services/registry_helpers."""

import yaml

from services.registry_helpers import load_registry, reset_for_tests, save_registry


def test_round_trip(tmp_path, monkeypatch):
    reg = tmp_path / "registry.yml"
    reg.write_text(
        yaml.safe_dump(
            {
                "domain": "x",
                "hosts": {"host-a": {"host": "192.0.2.10", "ssh_user": "ops"}},
                "services": {},
            }
        )
    )
    monkeypatch.setenv("CADDY_REGISTRY_PATH", str(reg))
    reset_for_tests()

    data = load_registry()
    assert data["domain"] == "x"
    assert "host-a" in data["hosts"]

    data["hosts"]["host-b"] = {"host": "192.0.2.20", "ssh_user": "ops"}
    save_registry(data)

    reloaded = load_registry()
    assert "host-b" in reloaded["hosts"]


def test_load_on_missing_path_creates_empty_registry(tmp_path, monkeypatch):
    """RegistryService auto-creates an empty registry on first read.

    The historical inline load_registry in main.py advertised a 404 on
    missing-file, but that path never actually fired — RegistryService
    creates the file. Documenting actual behaviour, not aspirational.
    """
    target = tmp_path / "does-not-exist.yml"
    monkeypatch.setenv("CADDY_REGISTRY_PATH", str(target))
    reset_for_tests()

    data = load_registry()
    assert data["machines"] == {}
    assert data["services"] == {}
    assert target.exists()  # registry was materialised on the way through


def test_save_writes_then_reload_sees_changes(tmp_path, monkeypatch):
    """save_registry persists, and a follow-up load_registry sees the change.

    (RegistryService is currently lenient about schema and only logs warnings,
    so we don't try to provoke a 400 here — that would be testing
    behaviour the underlying service doesn't actually have.)
    """
    reg = tmp_path / "registry.yml"
    reg.write_text(yaml.safe_dump({"domain": "x", "hosts": {}, "services": {}}))
    monkeypatch.setenv("CADDY_REGISTRY_PATH", str(reg))
    reset_for_tests()

    data = load_registry()
    data["services"]["k1"] = {"current_host": "host-a", "deployment_type": "docker"}
    save_registry(data)

    again = load_registry()
    assert "k1" in again["services"]
