"""
Keycloak Client for Portoser Web

Handles authentication and user management via Keycloak.
"""

import logging
import os
from typing import Any, Dict, Optional

import requests

logger = logging.getLogger(__name__)

# Timeout for Keycloak HTTP calls. Without this, an unreachable IdP would hang
# request workers indefinitely.
KEYCLOAK_HTTP_TIMEOUT = float(os.getenv("KEYCLOAK_HTTP_TIMEOUT", "10"))


class KeycloakClient:
    """Client for Keycloak operations"""

    def __init__(
        self, server_url: str, realm: str, client_id: str, client_secret: Optional[str] = None
    ):
        """
        Initialize Keycloak client

        Args:
            server_url: Keycloak server URL (e.g., http://localhost:8080)
            realm: Keycloak realm name
            client_id: Client ID for this application
            client_secret: Client secret (optional for public clients)
        """
        self.server_url = server_url.rstrip("/")
        self.realm = realm
        self.client_id = client_id
        self.client_secret = client_secret

        # SSL verification setup
        # Check if SSL verification should be disabled or use CA cert
        ssl_verify_env = os.getenv("KEYCLOAK_SSL_VERIFY", "true").lower()
        ca_cert_path = os.getenv("CA_CERT_PATH")

        if ssl_verify_env == "false":
            self.verify = False
            logger.warning("SSL verification disabled for Keycloak (INSECURE)")
        elif ca_cert_path and os.path.exists(ca_cert_path):
            self.verify = ca_cert_path
            logger.info(f"Using CA certificate for Keycloak: {ca_cert_path}")
        else:
            self.verify = True
            logger.info("Using system CA certificates for Keycloak")

        # Keycloak URLs
        self.realm_url = f"{self.server_url}/realms/{self.realm}"
        self.admin_url = f"{self.server_url}/admin/realms/{self.realm}"
        self.token_url = f"{self.realm_url}/protocol/openid-connect/token"
        self.userinfo_url = f"{self.realm_url}/protocol/openid-connect/userinfo"

        # Test connection
        try:
            response = requests.get(
                f"{self.realm_url}/.well-known/openid-configuration", timeout=5, verify=self.verify
            )
            response.raise_for_status()
            logger.info("Keycloak client initialized successfully")
        except Exception as e:
            logger.error(f"Failed to connect to Keycloak: {e}")
            raise

    def get_admin_token(self, admin_username: str, admin_password: str) -> str:
        """
        Get admin access token

        Args:
            admin_username: Admin username
            admin_password: Admin password

        Returns:
            Access token string
        """
        data = {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": admin_username,
            "password": admin_password,
        }

        response = requests.post(
            f"{self.server_url}/realms/master/protocol/openid-connect/token",
            data=data,
            verify=self.verify,
            timeout=KEYCLOAK_HTTP_TIMEOUT,
        )
        response.raise_for_status()
        body = response.json()
        token = body.get("access_token")
        if not token:
            raise RuntimeError(
                f"Keycloak admin token response missing 'access_token' (keys: {sorted(body)})"
            )
        return token

    def authenticate(self, username: str, password: str) -> Dict[str, Any]:
        """
        Authenticate user with username/password

        Args:
            username: Username
            password: Password

        Returns:
            Dictionary with tokens and user info
        """
        data = {
            "grant_type": "password",
            "client_id": self.client_id,
            "username": username,
            "password": password,
            # Keycloak 18+ requires the openid scope for /userinfo to return
            # 200 — without it, the token doesn't get marked as an OIDC
            # access token and userinfo responds 403. profile+email are
            # standard scopes used by the rest of the codebase.
            "scope": "openid profile email",
        }

        if self.client_secret:
            data["client_secret"] = self.client_secret

        try:
            response = requests.post(
                self.token_url, data=data, verify=self.verify, timeout=KEYCLOAK_HTTP_TIMEOUT
            )
            response.raise_for_status()
            tokens = response.json()

            access_token = tokens.get("access_token")
            if not access_token:
                raise RuntimeError(
                    f"Keycloak token response missing 'access_token' (keys: {sorted(tokens)})"
                )

            # Get user info
            user_info = self.get_user_info(access_token)

            return {
                "access_token": access_token,
                "refresh_token": tokens.get("refresh_token"),
                "expires_in": tokens.get("expires_in", 3600),
                "user": user_info,
            }
        except requests.exceptions.HTTPError as e:
            logger.error(f"Authentication failed: {e}")
            raise Exception("Invalid credentials")

    def refresh_token(self, refresh_token: str) -> Dict[str, Any]:
        """
        Refresh access token

        Args:
            refresh_token: Refresh token

        Returns:
            New tokens
        """
        data = {
            "grant_type": "refresh_token",
            "client_id": self.client_id,
            "refresh_token": refresh_token,
        }

        if self.client_secret:
            data["client_secret"] = self.client_secret

        response = requests.post(
            self.token_url, data=data, verify=self.verify, timeout=KEYCLOAK_HTTP_TIMEOUT
        )
        response.raise_for_status()
        return response.json()

    def get_user_info(self, access_token: str) -> Dict[str, Any]:
        """
        Get user information from access token

        Args:
            access_token: Access token

        Returns:
            User information dictionary
        """
        headers = {"Authorization": f"Bearer {access_token}"}
        response = requests.get(
            self.userinfo_url, headers=headers, verify=self.verify, timeout=KEYCLOAK_HTTP_TIMEOUT
        )
        response.raise_for_status()
        return response.json()

    def validate_token(self, access_token: str) -> bool:
        """
        Validate access token

        Args:
            access_token: Access token to validate

        Returns:
            True if valid, False otherwise
        """
        try:
            self.get_user_info(access_token)
            return True
        except Exception as e:
            logger.debug(f"Token validation failed: {e}")
            return False

    def logout(self, refresh_token: str) -> bool:
        """
        Logout user (revoke tokens)

        Args:
            refresh_token: Refresh token

        Returns:
            True if successful
        """
        data = {"client_id": self.client_id, "refresh_token": refresh_token}

        if self.client_secret:
            data["client_secret"] = self.client_secret

        try:
            response = requests.post(
                f"{self.realm_url}/protocol/openid-connect/logout",
                data=data,
                verify=self.verify,
                timeout=KEYCLOAK_HTTP_TIMEOUT,
            )
            response.raise_for_status()
            return True
        except Exception as e:
            logger.error(f"Logout failed: {e}")
            return False

    def health_check(self) -> Dict[str, Any]:
        """
        Check Keycloak health

        Returns:
            Health status dictionary
        """
        try:
            response = requests.get(
                f"{self.realm_url}/.well-known/openid-configuration", timeout=5, verify=self.verify
            )
            response.raise_for_status()
            return {"healthy": True, "realm": self.realm, "server": self.server_url}
        except Exception as e:
            return {"healthy": False, "error": str(e)}
