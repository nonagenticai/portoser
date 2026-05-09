"""
Service Authentication Module for OAuth2 Client Credentials Flow

This module provides a thread-safe, production-ready authenticator for
microservices to authenticate with each other using OAuth2 client credentials
flow via Keycloak.

Features:
- Automatic token caching and refresh
- Thread-safe operations
- Retry logic for transient failures
- Comprehensive error handling
- Logging support

Example:
    >>> import os
    >>> auth = ServiceAuthenticator(
    ...     keycloak_url=os.environ["KEYCLOAK_URL"],
    ...     realm="secure-apps",
    ...     client_id="my-service",
    ...     client_secret="secret-key"
    ... )
    >>> response = auth.make_authenticated_request("https://api.example.local/data")
"""

import logging
import threading
from datetime import datetime, timedelta
from typing import Any, Dict, Optional
from urllib.parse import urljoin

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from utils.datetime_utils import utcnow

logger = logging.getLogger(__name__)


class AuthenticationError(Exception):
    """Raised when authentication fails."""

    pass


class TokenRefreshError(Exception):
    """Raised when token refresh fails."""

    pass


class ServiceAuthenticator:
    """
    OAuth2 client credentials authenticator for microservices.

    This class manages OAuth2 tokens from Keycloak, including automatic
    caching, refresh, and retry logic. All operations are thread-safe.

    Attributes:
        keycloak_url: Base URL of Keycloak server
        realm: Keycloak realm name
        client_id: OAuth2 client ID
        client_secret: OAuth2 client secret
    """

    def __init__(
        self,
        keycloak_url: str,
        realm: str,
        client_id: str,
        client_secret: str,
        token_refresh_buffer: int = 60,
        max_retries: int = 3,
        retry_backoff: float = 0.5,
    ):
        """
        Initialize the service authenticator.

        Args:
            keycloak_url: Base URL of Keycloak (e.g., the value of $KEYCLOAK_URL)
            realm: Keycloak realm name
            client_id: OAuth2 client ID for this service
            client_secret: OAuth2 client secret for this service
            token_refresh_buffer: Seconds before expiry to refresh token (default: 60)
            max_retries: Maximum retry attempts for failed requests (default: 3)
            retry_backoff: Backoff factor for retries (default: 0.5)
        """
        self.keycloak_url = keycloak_url.rstrip("/")
        self.realm = realm
        self.client_id = client_id
        self.client_secret = client_secret
        self.token_refresh_buffer = token_refresh_buffer
        self.max_retries = max_retries
        self.retry_backoff = retry_backoff

        # Token cache
        self._access_token: Optional[str] = None
        self._token_expiry: Optional[datetime] = None
        self._lock = threading.RLock()

        # Build token endpoint URL
        self._token_url = urljoin(
            f"{self.keycloak_url}/", f"realms/{self.realm}/protocol/openid-connect/token"
        )

        # Configure HTTP session with retry logic
        self._session = self._create_session()

        logger.info(
            f"ServiceAuthenticator initialized for client_id={client_id}, "
            f"realm={realm}, keycloak_url={keycloak_url}"
        )

    def _create_session(self) -> requests.Session:
        """
        Create a requests session with retry configuration.

        Returns:
            Configured requests.Session object
        """
        session = requests.Session()

        # Configure retry strategy for transient failures
        retry_strategy = Retry(
            total=self.max_retries,
            backoff_factor=self.retry_backoff,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["POST", "GET", "PUT", "DELETE", "PATCH"],
        )

        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session

    def _is_token_valid(self) -> bool:
        """
        Check if the current cached token is valid.

        Returns:
            True if token exists and is not expired (with buffer), False otherwise
        """
        if not self._access_token or not self._token_expiry:
            return False

        # Consider token invalid if it expires within the buffer window
        expiry_with_buffer = self._token_expiry - timedelta(seconds=self.token_refresh_buffer)
        return utcnow() < expiry_with_buffer

    def _fetch_new_token(self) -> None:
        """
        Fetch a new access token from Keycloak.

        Raises:
            AuthenticationError: If token fetch fails after retries
        """
        logger.debug(f"Fetching new access token for client_id={self.client_id}")

        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
        }

        try:
            response = self._session.post(self._token_url, data=data, timeout=10)
            response.raise_for_status()

            token_data = response.json()

            # Extract token and expiry
            self._access_token = token_data.get("access_token")
            expires_in = token_data.get("expires_in", 300)  # Default 5 minutes

            if not self._access_token:
                raise AuthenticationError("No access_token in response")

            self._token_expiry = utcnow() + timedelta(seconds=expires_in)

            logger.info(
                f"Successfully obtained access token for client_id={self.client_id}, "
                f"expires_in={expires_in}s"
            )

        except requests.exceptions.HTTPError as e:
            error_msg = f"HTTP error during token fetch: {e}"
            logger.error(error_msg)
            if e.response is not None:
                logger.error(f"Response body: {e.response.text}")
            raise AuthenticationError(error_msg) from e

        except requests.exceptions.RequestException as e:
            error_msg = f"Network error during token fetch: {e}"
            logger.error(error_msg)
            raise AuthenticationError(error_msg) from e

        except (KeyError, ValueError) as e:
            error_msg = f"Invalid token response format: {e}"
            logger.error(error_msg)
            raise AuthenticationError(error_msg) from e

    def get_access_token(self) -> str:
        """
        Get a valid access token, refreshing if necessary.

        This method is thread-safe and will cache tokens to avoid
        unnecessary requests to Keycloak.

        Returns:
            Valid OAuth2 access token

        Raises:
            AuthenticationError: If unable to obtain a valid token
        """
        with self._lock:
            if not self._is_token_valid():
                logger.debug("Token invalid or expired, fetching new token")
                self._fetch_new_token()
            else:
                logger.debug("Using cached access token")

            return self._access_token

    def get_auth_header(self) -> Dict[str, str]:
        """
        Get authorization header with bearer token.

        Returns:
            Dictionary with Authorization header, e.g.:
            {"Authorization": "Bearer eyJhbGc..."}

        Raises:
            AuthenticationError: If unable to obtain a valid token
        """
        token = self.get_access_token()
        return {"Authorization": f"Bearer {token}"}

    def make_authenticated_request(
        self, url: str, method: str = "GET", **kwargs
    ) -> requests.Response:
        """
        Make an HTTP request with automatic authentication.

        This method automatically adds the Authorization header and handles
        token refresh if needed. It will retry once with a fresh token if
        the request fails with 401 Unauthorized.

        Args:
            url: Target URL for the request
            method: HTTP method (GET, POST, PUT, DELETE, etc.)
            **kwargs: Additional arguments passed to requests.request()

        Returns:
            requests.Response object

        Raises:
            AuthenticationError: If authentication fails
            requests.exceptions.RequestException: For other HTTP errors

        Example:
            >>> response = auth.make_authenticated_request(
            ...     "https://api.example.com/users",
            ...     method="POST",
            ...     json={"name": "Alice"}
            ... )
        """
        # Get current headers or create new dict
        headers = kwargs.pop("headers", {})

        # Add authorization header
        auth_header = self.get_auth_header()
        headers.update(auth_header)

        logger.debug(f"Making authenticated {method} request to {url}")

        try:
            # First attempt
            response = self._session.request(method=method, url=url, headers=headers, **kwargs)

            # If we get 401, token might have been invalidated
            # Try refreshing and retrying once
            if response.status_code == 401:
                logger.warning("Received 401 Unauthorized, attempting token refresh")

                with self._lock:
                    # Force token refresh
                    self._access_token = None
                    self._token_expiry = None
                    auth_header = self.get_auth_header()

                headers.update(auth_header)

                # Retry request with fresh token
                response = self._session.request(method=method, url=url, headers=headers, **kwargs)

            response.raise_for_status()
            logger.debug(f"Request to {url} succeeded with status {response.status_code}")
            return response

        except requests.exceptions.RequestException as e:
            logger.error(f"Request to {url} failed: {e}")
            raise

    def invalidate_token(self) -> None:
        """
        Manually invalidate the cached token.

        This forces the next authentication request to fetch a fresh token.
        Useful for testing or when you know the token has been revoked.
        """
        with self._lock:
            logger.info("Manually invalidating cached token")
            self._access_token = None
            self._token_expiry = None

    def get_token_info(self) -> Dict[str, Any]:
        """
        Get information about the current token state.

        Returns:
            Dictionary with token status information
        """
        with self._lock:
            if not self._access_token:
                return {
                    "has_token": False,
                    "is_valid": False,
                    "expires_at": None,
                    "seconds_until_expiry": None,
                }

            is_valid = self._is_token_valid()
            seconds_until_expiry = None

            if self._token_expiry:
                time_delta = self._token_expiry - utcnow()
                seconds_until_expiry = int(time_delta.total_seconds())

            return {
                "has_token": True,
                "is_valid": is_valid,
                "expires_at": self._token_expiry.isoformat() if self._token_expiry else None,
                "seconds_until_expiry": seconds_until_expiry,
            }

    def close(self) -> None:
        """
        Close the underlying HTTP session.

        Call this when you're done with the authenticator to clean up
        connection pools.
        """
        logger.debug("Closing ServiceAuthenticator session")
        self._session.close()

    def __enter__(self):
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - closes session."""
        self.close()
        return False
