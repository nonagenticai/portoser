"""
HashiCorp Vault Client for Portoser Web

Handles all interactions with Vault for secrets management.
"""

import logging
from typing import Any, Dict, List

import hvac

logger = logging.getLogger(__name__)


class VaultClient:
    """Client for HashiCorp Vault operations"""

    def __init__(self, url: str, token: str):
        """
        Initialize Vault client

        Args:
            url: Vault server URL (e.g., http://localhost:8200)
            token: Vault authentication token
        """
        self.url = url
        self.token = token
        self.client = hvac.Client(url=url, token=token)

        # Verify connection
        if not self.client.is_authenticated():
            raise Exception("Failed to authenticate with Vault")

        logger.info("✅ Vault client initialized successfully")

    def get_secret(self, path: str, mount_point: str = "secret") -> Dict[str, Any]:
        """
        Get a secret from Vault

        Args:
            path: Secret path (e.g., "portoser/postgres")
            mount_point: KV mount point (default: "secret")

        Returns:
            Dictionary of secret key-value pairs
        """
        try:
            response = self.client.secrets.kv.v2.read_secret_version(
                path=path, mount_point=mount_point
            )
            return response["data"]["data"]
        except Exception as e:
            logger.error(f"Failed to read secret {path}: {e}")
            raise

    def set_secret(self, path: str, data: Dict[str, Any], mount_point: str = "secret") -> bool:
        """
        Set a secret in Vault

        Args:
            path: Secret path (e.g., "portoser/postgres")
            data: Dictionary of key-value pairs to store
            mount_point: KV mount point (default: "secret")

        Returns:
            True if successful
        """
        try:
            self.client.secrets.kv.v2.create_or_update_secret(
                path=path, secret=data, mount_point=mount_point
            )
            logger.info(f"✅ Secret written to {path}")
            return True
        except Exception as e:
            logger.error(f"Failed to write secret {path}: {e}")
            raise

    def delete_secret(self, path: str, mount_point: str = "secret") -> bool:
        """
        Delete a secret from Vault

        Args:
            path: Secret path (e.g., "portoser/postgres")
            mount_point: KV mount point (default: "secret")

        Returns:
            True if successful
        """
        try:
            self.client.secrets.kv.v2.delete_metadata_and_all_versions(
                path=path, mount_point=mount_point
            )
            logger.info(f"✅ Secret deleted: {path}")
            return True
        except Exception as e:
            logger.error(f"Failed to delete secret {path}: {e}")
            raise

    def list_secrets(self, path: str = "", mount_point: str = "secret") -> List[str]:
        """
        List secrets at a path

        Args:
            path: Directory path (e.g., "portoser")
            mount_point: KV mount point (default: "secret")

        Returns:
            List of secret names
        """
        try:
            response = self.client.secrets.kv.v2.list_secrets(path=path, mount_point=mount_point)
            return response["data"]["keys"]
        except Exception as e:
            logger.error(f"Failed to list secrets at {path}: {e}")
            return []

    def health_check(self) -> Dict[str, Any]:
        """
        Check Vault health status

        Returns:
            Dictionary with health status
        """
        try:
            health = self.client.sys.read_health_status()
            return {
                "healthy": True,
                "initialized": health.get("initialized", False),
                "sealed": health.get("sealed", True),
                "version": health.get("version", "unknown"),
            }
        except Exception as e:
            logger.error(f"Vault health check failed: {e}")
            return {"healthy": False, "error": str(e)}
