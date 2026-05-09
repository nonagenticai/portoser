"""Environment variable validation for startup"""

import logging
import os
import sys
from typing import List, Tuple

logger = logging.getLogger(__name__)


class EnvironmentValidator:
    """Validates required environment variables at startup"""

    @staticmethod
    def validate_required_vars(required_vars: List[str]) -> Tuple[bool, List[str]]:
        """
        Validate that required environment variables are set

        Args:
            required_vars: List of required environment variable names

        Returns:
            Tuple of (all_valid: bool, missing_vars: List[str])
        """
        missing = []
        for var in required_vars:
            if not os.getenv(var):
                missing.append(var)

        return len(missing) == 0, missing

    @staticmethod
    def validate_production_requirements() -> Tuple[bool, List[str]]:
        """
        Validate production-specific requirements

        Returns:
            Tuple of (valid: bool, errors: List[str])
        """
        errors = []
        environment = os.getenv("ENVIRONMENT", "development")

        if environment != "production":
            return True, []  # Only validate in production

        logger.info("🔒 Production mode detected - validating security requirements...")

        # Check JWT secret
        jwt_secret = os.getenv("JWT_SECRET_KEY", "")
        if not jwt_secret or jwt_secret == "dev-secret-key-change-in-production":
            errors.append(
                "JWT_SECRET_KEY must be set to a strong secret in production. "
                "Generate with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
            )

        # Check database password
        db_password = os.getenv("POSTGRES_PASSWORD", "postgres")
        if db_password == "postgres":
            errors.append(
                "POSTGRES_PASSWORD is using default value 'postgres'. "
                "Set a strong password for production!"
            )

        # Check Keycloak client secret
        keycloak_secret = os.getenv("KEYCLOAK_CLIENT_SECRET", "")
        if not keycloak_secret:
            logger.warning(
                "⚠️  KEYCLOAK_CLIENT_SECRET not set - Keycloak authentication may not work!"
            )

        # Warn about debug mode
        debug_mode = os.getenv("DEBUG", "0")
        if debug_mode == "1":
            logger.warning(
                "⚠️  DEBUG mode is enabled in production! This may leak sensitive information."
            )

        return len(errors) == 0, errors

    @staticmethod
    def validate_urls() -> Tuple[bool, List[str]]:
        """
        Validate URL environment variables

        Returns:
            Tuple of (valid: bool, errors: List[str])
        """
        errors = []

        # Check Keycloak URL
        keycloak_url = os.getenv("KEYCLOAK_URL", "")
        if keycloak_url and not keycloak_url.startswith(("http://", "https://")):
            errors.append(f"KEYCLOAK_URL must start with http:// or https:// (got: {keycloak_url})")

        # Check Vault URL
        vault_url = os.getenv("VAULT_ADDR", "")
        if vault_url and not vault_url.startswith(("http://", "https://")):
            errors.append(f"VAULT_ADDR must start with http:// or https:// (got: {vault_url})")

        return len(errors) == 0, errors

    @staticmethod
    def validate_paths() -> Tuple[bool, List[str]]:
        """
        Validate path environment variables

        Returns:
            Tuple of (valid: bool, errors: List[str])
        """
        errors = []

        # Check critical paths exist
        registry_path = os.getenv("CADDY_REGISTRY_PATH", "")
        if registry_path and not os.path.exists(registry_path):
            logger.warning(f"⚠️  CADDY_REGISTRY_PATH does not exist: {registry_path}")

        return len(errors) == 0, errors

    @staticmethod
    def validate_all() -> None:
        """
        Validate all environment requirements

        Exits with error code 1 if critical validation fails
        """
        all_valid = True
        all_errors = []

        # Check production requirements
        valid, errors = EnvironmentValidator.validate_production_requirements()
        if not valid:
            all_valid = False
            all_errors.extend(errors)

        # Check URLs
        valid, errors = EnvironmentValidator.validate_urls()
        if not valid:
            all_valid = False
            all_errors.extend(errors)

        # Check paths (warnings only)
        EnvironmentValidator.validate_paths()

        # Report errors
        if not all_valid:
            logger.error("❌ Environment validation failed:")
            for error in all_errors:
                logger.error(f"   • {error}")
            logger.error("\n⚠️  Fix the above errors before starting the application in production!")
            sys.exit(1)
        else:
            environment = os.getenv("ENVIRONMENT", "development")
            if environment == "production":
                logger.info("✅ All production environment requirements validated successfully")
            else:
                logger.info(f"✅ Environment validated (mode: {environment})")

    @staticmethod
    def log_environment_info() -> None:
        """Log non-sensitive environment information for debugging"""
        logger.info("📊 Environment Configuration:")
        logger.info(f"   • ENVIRONMENT: {os.getenv('ENVIRONMENT', 'development')}")
        logger.info(f"   • SERVICE_NAME: {os.getenv('SERVICE_NAME', 'portoser-web')}")
        logger.info(f"   • VERSION: {os.getenv('VERSION', '1.0.0')}")

        # Log feature flags
        mcp_enabled = os.getenv("MCP_ENABLED", "true").lower() == "true"
        logger.info(f"   • MCP_ENABLED: {mcp_enabled}")

        # Log URLs (without revealing full paths)
        keycloak_url = os.getenv("KEYCLOAK_URL", "not set")
        if keycloak_url != "not set":
            # Just show domain, not full URL
            import urllib.parse

            parsed = urllib.parse.urlparse(keycloak_url)
            logger.info(f"   • KEYCLOAK_URL: {parsed.scheme}://{parsed.netloc}")
        else:
            logger.info(f"   • KEYCLOAK_URL: {keycloak_url}")

        vault_addr = os.getenv("VAULT_ADDR", "not set")
        if vault_addr != "not set":
            import urllib.parse

            parsed = urllib.parse.urlparse(vault_addr)
            logger.info(f"   • VAULT_ADDR: {parsed.scheme}://{parsed.netloc}")
        else:
            logger.info(f"   • VAULT_ADDR: {vault_addr}")
