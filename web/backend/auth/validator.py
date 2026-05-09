"""Token validation logic."""

import logging
import os
import time
from functools import lru_cache
from typing import Dict, Optional

from jose import JWTError, jwt
from keycloak import KeycloakOpenID

from .config import get_settings

logger = logging.getLogger(__name__)

# Re-fetch the IdP public key at most this often. Keycloak rotation is rare,
# but caching forever (the original behaviour) means a key rotation strands
# every running instance until it's restarted.
PUBLIC_KEY_TTL_SECONDS = int(os.getenv("KEYCLOAK_PUBLIC_KEY_TTL", "3600"))


class TokenValidator:
    """Validates JWT tokens from Keycloak."""

    def __init__(self):
        self.settings = get_settings()
        self._public_key: Optional[str] = None
        self._public_key_fetched_at: float = 0.0
        self._keycloak_openid = None

    @property
    def keycloak_openid(self) -> KeycloakOpenID:
        """Lazy-load Keycloak OpenID client."""
        if not self._keycloak_openid:
            self._keycloak_openid = KeycloakOpenID(
                server_url=self.settings.keycloak_url,
                client_id=self.settings.client_id,
                realm_name=self.settings.realm_name,
                client_secret_key=self.settings.client_secret,
                verify=self.settings.ssl_verify,
            )
        return self._keycloak_openid

    def get_public_key(self) -> str:
        """Fetch Keycloak's public key for JWT validation.

        Cached for ``PUBLIC_KEY_TTL_SECONDS``; after that we re-fetch so a
        rotated IdP key gets picked up without a process restart.

        Returns:
            PEM-formatted public key
        """
        now = time.monotonic()
        is_stale = (
            self._public_key is None or (now - self._public_key_fetched_at) > PUBLIC_KEY_TTL_SECONDS
        )
        if is_stale:
            self._public_key = (
                "-----BEGIN PUBLIC KEY-----\n"
                + self.keycloak_openid.public_key()
                + "\n-----END PUBLIC KEY-----"
            )
            self._public_key_fetched_at = now
            logger.info("Fetched Keycloak public key (TTL %ss)", PUBLIC_KEY_TTL_SECONDS)
        return self._public_key

    async def validate_token(self, token: str) -> Dict:
        """Validate JWT token.

        Args:
            token: JWT access token from Authorization header

        Returns:
            Decoded token payload with user claims

        Raises:
            JWTError: If token is invalid, expired, or signature doesn't match
        """
        try:
            payload = jwt.decode(
                token,
                self.get_public_key(),
                algorithms=["RS256"],
                options={
                    "verify_signature": True,
                    "verify_aud": False,  # Keycloak doesn't always set audience
                    "verify_exp": True,  # Verify token hasn't expired
                },
            )
            logger.debug(f"Token validated for user: {payload.get('preferred_username')}")
            return payload
        except JWTError as e:
            logger.warning(f"Token validation failed: {e}")
            raise

    def introspect_token(self, token: str) -> Dict:
        """Introspect token via Keycloak (alternative to JWT decode).

        Use this when you need real-time token status from Keycloak.
        JWT decode is faster but doesn't check revocation.

        Args:
            token: Access token

        Returns:
            Token introspection result
        """
        return self.keycloak_openid.introspect(token)


@lru_cache()
def get_validator() -> TokenValidator:
    """Get cached validator instance."""
    return TokenValidator()
