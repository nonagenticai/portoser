"""
Configuration Management for Portoser Web

Loads configuration from environment variables and .env file.
Supports Vault and Keycloak integration.
"""

import os
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

# Load .env file if it exists. Look next to this file (web/backend/.env) —
# matching the .env.example template that sits beside it. The docker-compose
# .env at web/.env is consumed by docker-compose itself for variable
# substitution and is forwarded into the container via the `environment:`
# block; we deliberately do NOT pick that one up here, because it would
# leak into pytest (which loads config.py at collection time and would see
# values from a developer's local docker-compose env).
env_file = Path(__file__).parent / ".env"
if env_file.exists():
    load_dotenv(env_file)


class Config:
    """Application configuration"""

    @property
    def environment(self) -> str:
        return os.getenv("ENVIRONMENT", "production")

    # Registry
    @property
    def registry_path(self) -> str:
        # Default falls back to <repo-root>/registry.yml computed from this file's location
        # (web/backend/config.py -> parents[2] is the repo root).
        default_path = str(Path(__file__).resolve().parents[2] / "registry.yml")
        return os.getenv("CADDY_REGISTRY_PATH", default_path)

    # Keycloak settings
    @property
    def keycloak_url(self) -> str:
        url = os.getenv("KEYCLOAK_URL", "http://localhost:8080")
        # In production, fail fast if Keycloak is enabled but URL not properly configured
        if (
            self.environment == "production"
            and self.keycloak_enabled
            and url == "http://localhost:8080"
        ):
            raise ValueError(
                "KEYCLOAK_URL must be explicitly set in production. "
                "Default localhost URL is not allowed in production."
            )
        return url

    @property
    def keycloak_realm(self) -> str:
        return os.getenv("KEYCLOAK_REALM", "portoser")

    @property
    def keycloak_client_id(self) -> str:
        return os.getenv("KEYCLOAK_CLIENT_ID", "portoser-web")

    @property
    def keycloak_client_secret(self) -> Optional[str]:
        return os.getenv("KEYCLOAK_CLIENT_SECRET")

    @property
    def keycloak_enabled(self) -> bool:
        # In production, default to enabled (secure by default)
        # In development/staging, default to disabled
        default_value = "true" if self.environment == "production" else "false"
        return os.getenv("KEYCLOAK_ENABLED", default_value).lower() == "true"

    # Vault settings
    @property
    def vault_url(self) -> str:
        return os.getenv("VAULT_URL", "http://localhost:8200")

    @property
    def vault_token(self) -> Optional[str]:
        return os.getenv("VAULT_TOKEN")

    @property
    def vault_enabled(self) -> bool:
        return os.getenv("VAULT_ENABLED", "false").lower() == "true"

    # JWT settings
    @property
    def jwt_secret_key(self) -> str:
        secret = os.getenv("JWT_SECRET_KEY", "")
        # In production, require JWT secret to be set
        if self.environment == "production" and not secret:
            raise ValueError(
                "JWT_SECRET_KEY must be set in production. "
                "Generate a strong secret with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
            )
        # Return secret or dev default
        return secret if secret else "dev-secret-key-change-in-production"

    @property
    def jwt_algorithm(self) -> str:
        return "HS256"

    @property
    def jwt_expiration_minutes(self) -> int:
        return 60

    # Background worker settings
    @property
    def enable_background_workers(self) -> bool:
        """Enable/disable all background workers (enabled by default for live metrics)"""
        return os.getenv("ENABLE_BACKGROUND_WORKERS", "true").lower() == "true"

    @property
    def worker_timeout(self) -> int:
        """Timeout for background worker tasks in seconds"""
        return int(os.getenv("WORKER_TIMEOUT", "30"))

    @property
    def worker_failure_threshold(self) -> int:
        """Number of failures before circuit breaker opens"""
        return int(os.getenv("WORKER_FAILURE_THRESHOLD", "3"))

    @property
    def worker_circuit_timeout(self) -> int:
        """Seconds to wait before attempting to close circuit breaker"""
        return int(os.getenv("WORKER_CIRCUIT_TIMEOUT", "60"))

    @property
    def log_level(self) -> str:
        """Get log level from environment"""
        return os.getenv("LOG_LEVEL", "INFO")

    def validate(self) -> bool:
        """Validate configuration - fail fast on security misconfigurations"""

        # Production environment checks
        if self.environment == "production":
            # In production, authentication MUST be enabled
            if not self.keycloak_enabled:
                raise ValueError(
                    "CRITICAL SECURITY ERROR: Authentication is REQUIRED in production. "
                    "Set KEYCLOAK_ENABLED=true or use ENVIRONMENT=development for testing."
                )

            # In production, Keycloak URL must be set
            if self.keycloak_enabled and not os.getenv("KEYCLOAK_URL"):
                raise ValueError(
                    "KEYCLOAK_URL must be explicitly set in production environment. "
                    "Cannot use default localhost URL."
                )

        # Keycloak validation (all environments)
        if self.keycloak_enabled:
            if not self.keycloak_client_secret:
                raise ValueError("KEYCLOAK_CLIENT_SECRET is required when Keycloak is enabled")

            # Trigger URL validation which includes production checks
            _ = self.keycloak_url

        # Vault validation
        if self.vault_enabled and not self.vault_token:
            raise ValueError("VAULT_TOKEN is required when Vault is enabled")

        return True

    def validate_startup_config(self) -> list[str]:
        """
        Validate configuration at startup, return list of warnings.

        This method performs non-fatal validation checks and returns
        warnings for dangerous or suboptimal configurations.

        Returns:
            List of warning messages (empty if no warnings)
        """
        from typing import List

        warnings: List[str] = []

        # Check environment consistency
        if self.environment == "production":
            if not self.keycloak_enabled:
                warnings.append(
                    "🔴 CRITICAL: Production mode but Keycloak is DISABLED - API is unauthenticated!"
                )

            if not self.enable_background_workers:
                warnings.append(
                    "⚠️  WARNING: Production mode but background workers DISABLED - metrics will be stale"
                )

            if self.jwt_secret_key == "dev-secret-key-change-in-production":
                warnings.append("🔴 CRITICAL: Using default JWT secret in production!")

        # Check background workers
        if not self.enable_background_workers:
            warnings.append(
                "ℹ️  INFO: Background workers disabled - metrics and device health will not update"
            )

        # Check Vault configuration
        if self.vault_enabled and not self.vault_token:
            warnings.append("⚠️  WARNING: Vault is enabled but VAULT_TOKEN is not set")

        # Check development mode in production-like settings
        if self.environment == "development" and self.keycloak_enabled:
            warnings.append(
                "ℹ️  INFO: Development mode with Keycloak enabled - ensure this is intentional"
            )

        return warnings


# Global config instance
config = Config()
