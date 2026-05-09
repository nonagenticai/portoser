"""
Tests for Registry Port Validation.

Covers the following validations:
1. validate_registry_file() function before parsing
2. validate_service_port() rejects port 8000
3. validate_parsed_service_data() validates all service ports
4. Registry read/write rejects services with port 8000
"""

import os
import tempfile
from pathlib import Path

import pytest
import yaml

from services.registry_service import (
    FORBIDDEN_PORT,
    RegistryService,
    validate_parsed_service_data,
    validate_registry_file,
    validate_service_port,
)


@pytest.fixture
def temp_registry_file():
    """Create a temporary registry file for testing"""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", delete=False) as f:
        # Create a valid registry with valid ports
        initial_data = {
            "machines": {
                "test-machine": {
                    "host": "192.0.2.100",
                    "ssh_user": "test",
                    "ip": "192.0.2.100",
                    "roles": ["worker"],
                }
            },
            "services": {
                "test-service": {
                    "current_host": "test-machine",
                    "deployment_type": "docker",
                    "port": 8080,  # Valid port
                }
            },
            "hosts": {
                "test-machine": {
                    "host": "192.0.2.100",
                    "ssh_user": "test",
                    "ip": "192.0.2.100",
                    "roles": ["worker"],
                }
            },
        }
        yaml.safe_dump(initial_data, f)
        temp_path = f.name

    yield temp_path

    # Cleanup
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    # Clean up backup files
    for backup in Path(temp_path).parent.glob(f"{Path(temp_path).name}.backup.*"):
        backup.unlink()
    # Clean up temp files
    for temp in Path(temp_path).parent.glob(f"{Path(temp_path).name}.tmp*"):
        temp.unlink()


class TestValidateRegistryFile:
    """Test validate_registry_file() function"""

    def test_validate_existing_valid_file(self, temp_registry_file):
        """Test validation of existing valid registry file"""
        result = validate_registry_file(temp_registry_file)
        assert result is True

    def test_validate_nonexistent_file(self):
        """Test validation fails for nonexistent file"""
        with pytest.raises(FileNotFoundError):
            validate_registry_file("/nonexistent/registry.yml")

    def test_validate_invalid_yaml(self):
        """Test validation fails for invalid YAML"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", delete=False) as f:
            f.write("invalid: yaml: content:")
            temp_path = f.name

        try:
            with pytest.raises(ValueError, match="Invalid YAML"):
                validate_registry_file(temp_path)
        finally:
            os.unlink(temp_path)

    def test_validate_missing_required_keys(self):
        """Test validation fails when missing required keys"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", delete=False) as f:
            yaml.safe_dump({"other_key": "value"}, f)
            temp_path = f.name

        try:
            with pytest.raises(ValueError, match="must contain at least one of"):
                validate_registry_file(temp_path)
        finally:
            os.unlink(temp_path)

    def test_validate_not_a_dict(self):
        """Test validation fails when file doesn't contain a dict"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", delete=False) as f:
            yaml.safe_dump(["list", "not", "dict"], f)
            temp_path = f.name

        try:
            with pytest.raises(ValueError, match="must contain a YAML dictionary"):
                validate_registry_file(temp_path)
        finally:
            os.unlink(temp_path)


class TestValidateServicePort:
    """Test validate_service_port() function"""

    def test_valid_port(self):
        """Test validation passes for valid port"""
        validate_service_port("test-service", 8080)
        validate_service_port("test-service", 1)
        validate_service_port("test-service", 65535)
        # Should not raise

    def test_none_port_is_optional(self):
        """Test that None port is allowed (optional)"""
        validate_service_port("test-service", None)
        # Should not raise

    def test_forbidden_port_8000(self):
        """Test validation rejects port 8000"""
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_service_port("test-service", 8000)

    def test_forbidden_port_8000_as_string(self):
        """Test validation rejects port 8000 even as string"""
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_service_port("test-service", "8000")

    def test_invalid_port_type(self):
        """Test validation rejects non-numeric port"""
        with pytest.raises(ValueError, match="port must be an integer"):
            validate_service_port("test-service", "invalid")

    def test_port_too_low(self):
        """Test validation rejects port below 1"""
        with pytest.raises(ValueError, match="out of valid range"):
            validate_service_port("test-service", 0)
        with pytest.raises(ValueError, match="out of valid range"):
            validate_service_port("test-service", -1)

    def test_port_too_high(self):
        """Test validation rejects port above 65535"""
        with pytest.raises(ValueError, match="out of valid range"):
            validate_service_port("test-service", 65536)
        with pytest.raises(ValueError, match="out of valid range"):
            validate_service_port("test-service", 99999)


class TestValidateParsedServiceData:
    """Test validate_parsed_service_data() function"""

    def test_empty_services(self):
        """Test validation passes for empty services"""
        result = validate_parsed_service_data({})
        assert result == {}

    def test_none_services(self):
        """Test validation passes for None services"""
        validate_parsed_service_data(None) is None

    def test_service_without_port(self):
        """Test validation passes for service without port"""
        services = {"my-service": {"current_host": "localhost", "deployment_type": "docker"}}
        result = validate_parsed_service_data(services)
        assert result == services

    def test_service_with_valid_port(self):
        """Test validation passes for service with valid port"""
        services = {
            "my-service": {"current_host": "localhost", "deployment_type": "docker", "port": 8080}
        }
        result = validate_parsed_service_data(services)
        assert result == services

    def test_service_with_forbidden_port_8000(self):
        """Test validation rejects service with port 8000"""
        services = {
            "my-service": {"current_host": "localhost", "deployment_type": "docker", "port": 8000}
        }
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_parsed_service_data(services)

    def test_service_with_ports_list(self):
        """Test validation of service with ports list"""
        services = {
            "my-service": {
                "current_host": "localhost",
                "deployment_type": "docker",
                "ports": [8080, 8081, 8082],
            }
        }
        result = validate_parsed_service_data(services)
        assert result == services

    def test_service_with_forbidden_port_in_list(self):
        """Test validation rejects forbidden port in ports list"""
        services = {
            "my-service": {
                "current_host": "localhost",
                "deployment_type": "docker",
                "ports": [8080, 8000, 8082],
            }
        }
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_parsed_service_data(services)

    def test_docker_compose_port_mapping(self):
        """Test validation of docker-compose port mappings"""
        services = {
            "my-service": {
                "current_host": "localhost",
                "deployment_type": "docker",
                "docker_compose": {"services": {"web": {"ports": ["8080:80", "8081:443"]}}},
            }
        }
        result = validate_parsed_service_data(services)
        assert result == services

    def test_docker_compose_forbidden_port_mapping(self):
        """Test validation rejects forbidden port in docker-compose"""
        services = {
            "my-service": {
                "current_host": "localhost",
                "deployment_type": "docker",
                "docker_compose": {"services": {"web": {"ports": ["8080:80", "8000:8000"]}}},
            }
        }
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_parsed_service_data(services)

    def test_multiple_services_with_one_forbidden(self):
        """Test validation fails if any service has forbidden port"""
        services = {
            "service1": {"current_host": "localhost", "deployment_type": "docker", "port": 8080},
            "service2": {
                "current_host": "localhost",
                "deployment_type": "docker",
                "port": 8000,  # Forbidden!
            },
            "service3": {"current_host": "localhost", "deployment_type": "docker", "port": 9000},
        }
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            validate_parsed_service_data(services)


class TestRegistryServicePortValidation:
    """Test RegistryService integration with port validation"""

    def test_read_with_valid_ports(self, temp_registry_file):
        """Test reading registry with valid ports"""
        service = RegistryService(temp_registry_file)
        data = service.read()
        assert "test-service" in data["services"]
        assert data["services"]["test-service"]["port"] == 8080

    def test_read_with_forbidden_port(self):
        """Test reading registry with forbidden port 8000 is rejected"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", delete=False) as f:
            data = {
                "machines": {"test": {"host": "127.0.0.1"}},
                "services": {
                    "bad-service": {
                        "current_host": "test",
                        "deployment_type": "docker",
                        "port": 8000,  # Forbidden!
                    }
                },
                "hosts": {},
            }
            yaml.safe_dump(data, f)
            temp_path = f.name

        try:
            service = RegistryService(temp_path)
            with pytest.raises(ValueError, match="port 8000 is reserved"):
                service.read()
        finally:
            os.unlink(temp_path)
            for backup in Path(temp_path).parent.glob(f"{Path(temp_path).name}.backup.*"):
                backup.unlink()

    def test_write_with_valid_ports(self, temp_registry_file):
        """Test writing registry with valid ports"""
        service = RegistryService(temp_registry_file)
        data = service.read()

        # Add a new service with valid port
        data["services"]["new-service"] = {
            "current_host": "test-machine",
            "deployment_type": "docker",
            "port": 9000,
        }

        # Should succeed
        service.write(data)

        # Verify
        new_data = service.read()
        assert "new-service" in new_data["services"]
        assert new_data["services"]["new-service"]["port"] == 9000

    def test_write_with_forbidden_port(self, temp_registry_file):
        """Test writing registry with forbidden port 8000 is rejected"""
        service = RegistryService(temp_registry_file)
        data = service.read()

        # Try to add service with forbidden port
        data["services"]["bad-service"] = {
            "current_host": "test-machine",
            "deployment_type": "docker",
            "port": 8000,  # Forbidden!
        }

        # Should fail
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            service.write(data)

        # Verify original data wasn't changed
        verify_data = service.read()
        assert "bad-service" not in verify_data["services"]

    def test_forbidden_port_in_docker_compose_write(self, temp_registry_file):
        """Test that docker-compose with port 8000 is rejected on write"""
        service = RegistryService(temp_registry_file)
        data = service.read()

        # Add service with docker-compose using port 8000
        data["services"]["compose-service"] = {
            "current_host": "test-machine",
            "deployment_type": "docker",
            "docker_compose": {"services": {"web": {"ports": ["8000:8000"]}}},
        }

        # Should fail
        with pytest.raises(ValueError, match="port 8000 is reserved"):
            service.write(data)


class TestForbiddenPortConstant:
    """Test that forbidden port constant is correct"""

    def test_forbidden_port_is_8000(self):
        """Test that FORBIDDEN_PORT is set to 8000"""
        assert FORBIDDEN_PORT == 8000


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
