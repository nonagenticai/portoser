"""Keycloak configuration."""

import os
from functools import lru_cache


class KeycloakSettings:
    """Keycloak configuration settings."""

    def __init__(self):
        self.keycloak_url: str = os.getenv("KEYCLOAK_URL", "https://keycloak.example.local")
        self.realm_name: str = os.getenv("KEYCLOAK_REALM", "secure-apps")
        self.client_id: str = os.getenv("KEYCLOAK_CLIENT_ID", "portoser")
        self.client_secret: str = os.getenv("KEYCLOAK_CLIENT_SECRET", "")
        # Verify TLS by default. Set KEYCLOAK_SSL_VERIFY=false only for
        # self-signed dev certs.
        self.ssl_verify: bool = os.getenv("KEYCLOAK_SSL_VERIFY", "true").lower() == "true"
        # CA bundle path. Empty by default — when set, used to verify the
        # Keycloak server cert (e.g. for an internal CA).
        self.ca_cert_path: str = os.getenv("CA_CERT_PATH", "")

    @property
    def server_url(self) -> str:
        """Keycloak server URL."""
        return self.keycloak_url

    @property
    def realm(self) -> str:
        """Keycloak realm name."""
        return self.realm_name

    @property
    def token_url(self) -> str:
        """Token endpoint URL."""
        return f"{self.keycloak_url}/realms/{self.realm_name}/protocol/openid-connect/token"

    @property
    def jwks_url(self) -> str:
        """JWKS endpoint URL for public key."""
        return f"{self.keycloak_url}/realms/{self.realm_name}/protocol/openid-connect/certs"


@lru_cache()
def get_settings() -> KeycloakSettings:
    """Get cached Keycloak settings instance."""
    return KeycloakSettings()
