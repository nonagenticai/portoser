"""Input validation and sanitization utilities"""

import logging
import re
from pathlib import Path
from typing import Optional

from fastapi import HTTPException, status

logger = logging.getLogger(__name__)


class ValidationError(Exception):
    """Custom validation error"""

    pass


class InputValidator:
    """Comprehensive input validation utilities"""

    # Regex patterns
    SERVICE_NAME_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,100}$")
    MACHINE_NAME_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,100}$")
    HOSTNAME_PATTERN = re.compile(
        r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"
    )
    PATH_PATTERN = re.compile(r"^[a-zA-Z0-9/_.-]{1,500}$")
    ALPHANUMERIC_PATTERN = re.compile(r"^[a-zA-Z0-9]+$")

    # Dangerous path components
    DANGEROUS_PATH_COMPONENTS = {
        "..",
        "~",
        "$",
        "`",
        "|",
        "&",
        ";",
        "<",
        ">",
        "(",
        ")",
        "{",
        "}",
        "[",
        "]",
    }

    @staticmethod
    def validate_service_name(name: str, field_name: str = "service") -> str:
        """
        Validate service name

        Rules:
        - Alphanumeric, underscore, hyphen only
        - 1-100 characters
        - No path traversal attempts

        Args:
            name: Service name to validate
            field_name: Name of field for error messages

        Returns:
            Validated service name

        Raises:
            HTTPException: If validation fails
        """
        if not name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} is required"
            )

        if not isinstance(name, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be a string"
            )

        if not InputValidator.SERVICE_NAME_PATTERN.match(name):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must contain only alphanumeric characters, hyphens, and underscores (1-100 chars)",
            )

        if ".." in name or name.startswith("."):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} contains invalid path traversal characters",
            )

        return name

    @staticmethod
    def validate_machine_name(name: str, field_name: str = "machine") -> str:
        """
        Validate machine name

        Rules:
        - Alphanumeric, underscore, hyphen only
        - 1-100 characters
        - No path traversal attempts

        Args:
            name: Machine name to validate
            field_name: Name of field for error messages

        Returns:
            Validated machine name

        Raises:
            HTTPException: If validation fails
        """
        if not name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} is required"
            )

        if not isinstance(name, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be a string"
            )

        if not InputValidator.MACHINE_NAME_PATTERN.match(name):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must contain only alphanumeric characters, hyphens, and underscores (1-100 chars)",
            )

        if ".." in name or name.startswith("."):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} contains invalid path traversal characters",
            )

        return name

    @staticmethod
    def validate_hostname(hostname: str, field_name: str = "hostname") -> str:
        """
        Validate hostname

        Rules:
        - Valid DNS hostname format
        - No dangerous characters

        Args:
            hostname: Hostname to validate
            field_name: Name of field for error messages

        Returns:
            Validated hostname

        Raises:
            HTTPException: If validation fails
        """
        if not hostname:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} is required"
            )

        if not isinstance(hostname, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be a string"
            )

        if len(hostname) > 253:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} exceeds maximum length of 253 characters",
            )

        if not InputValidator.HOSTNAME_PATTERN.match(hostname):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be a valid hostname",
            )

        return hostname

    @staticmethod
    def validate_file_path(
        path: str, field_name: str = "path", allow_absolute: bool = False
    ) -> str:
        """
        Validate file path for safety

        Rules:
        - No path traversal (../)
        - No dangerous shell characters
        - Alphanumeric, underscore, hyphen, slash, period only
        - Max 500 characters

        Args:
            path: File path to validate
            field_name: Name of field for error messages
            allow_absolute: Whether to allow absolute paths (starting with /)

        Returns:
            Validated path

        Raises:
            HTTPException: If validation fails
        """
        if not path:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} is required"
            )

        if not isinstance(path, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be a string"
            )

        # Check length
        if len(path) > 500:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} exceeds maximum length of 500 characters",
            )

        # Check for path traversal
        if ".." in path:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} contains path traversal sequence (..)",
            )

        # Check for dangerous characters
        for dangerous in InputValidator.DANGEROUS_PATH_COMPONENTS:
            if dangerous in path:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"{field_name} contains dangerous character: {dangerous}",
                )

        # Check absolute path restriction
        if not allow_absolute and path.startswith("/"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be a relative path (absolute paths not allowed)",
            )

        # Validate pattern
        if not InputValidator.PATH_PATTERN.match(path):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} contains invalid characters",
            )

        return path

    @staticmethod
    def validate_integer_range(
        value: int,
        min_value: Optional[int] = None,
        max_value: Optional[int] = None,
        field_name: str = "value",
    ) -> int:
        """
        Validate integer is within acceptable range

        Args:
            value: Integer value to validate
            min_value: Minimum allowed value (inclusive)
            max_value: Maximum allowed value (inclusive)
            field_name: Name of field for error messages

        Returns:
            Validated integer

        Raises:
            HTTPException: If validation fails
        """
        if not isinstance(value, int):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be an integer"
            )

        if min_value is not None and value < min_value:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be at least {min_value}",
            )

        if max_value is not None and value > max_value:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be at most {max_value}",
            )

        return value

    @staticmethod
    def validate_string_length(
        value: str,
        min_length: Optional[int] = None,
        max_length: Optional[int] = None,
        field_name: str = "value",
    ) -> str:
        """
        Validate string length

        Args:
            value: String to validate
            min_length: Minimum allowed length
            max_length: Maximum allowed length
            field_name: Name of field for error messages

        Returns:
            Validated string

        Raises:
            HTTPException: If validation fails
        """
        if not isinstance(value, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} must be a string"
            )

        if min_length is not None and len(value) < min_length:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be at least {min_length} characters",
            )

        if max_length is not None and len(value) > max_length:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{field_name} must be at most {max_length} characters",
            )

        return value

    @staticmethod
    def sanitize_log_message(message: str) -> str:
        """
        Sanitize message for safe logging (prevent log injection)

        Rules:
        - Remove/escape newlines
        - Remove/escape control characters

        Args:
            message: Message to sanitize

        Returns:
            Sanitized message
        """
        if not isinstance(message, str):
            return str(message)

        # Replace newlines with space
        message = message.replace("\n", " ").replace("\r", " ")

        # Remove other control characters
        message = "".join(char for char in message if ord(char) >= 32 or char == "\t")

        # Limit length to prevent log spam
        if len(message) > 1000:
            message = message[:1000] + "..."

        return message

    @staticmethod
    def validate_deployment_id(deployment_id: str) -> str:
        """
        Validate deployment ID format

        Args:
            deployment_id: Deployment ID to validate

        Returns:
            Validated deployment ID

        Raises:
            HTTPException: If validation fails
        """
        if not deployment_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="deployment_id is required"
            )

        if not isinstance(deployment_id, str):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="deployment_id must be a string"
            )

        # Deployment IDs follow pattern: deploy-YYYYMMDD-HHMMSS-XXXXXXXX
        if not re.match(r"^deploy-\d{8}-\d{6}-[a-f0-9]{8}$", deployment_id):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="deployment_id has invalid format"
            )

        return deployment_id


class InputSanitizer:
    """Input sanitization utilities to prevent injection attacks"""

    @staticmethod
    def sanitize_service_name(name: str) -> str:
        """
        Sanitize service name by removing/escaping dangerous characters

        This complements validation by safely handling input even if validation passes.

        Args:
            name: Service name to sanitize

        Returns:
            Sanitized service name
        """
        if not isinstance(name, str):
            name = str(name)

        # Remove leading/trailing whitespace
        name = name.strip()

        # Remove any null bytes
        name = name.replace("\0", "")

        # Remove control characters (except tab)
        name = "".join(char for char in name if ord(char) >= 32 or char == "\t")

        # Replace spaces with underscores for safety
        name = name.replace(" ", "_")

        return name

    @staticmethod
    def sanitize_hostname(hostname: str) -> str:
        """
        Sanitize hostname by removing/escaping dangerous characters

        Args:
            hostname: Hostname to sanitize

        Returns:
            Sanitized hostname
        """
        if not isinstance(hostname, str):
            hostname = str(hostname)

        # Remove leading/trailing whitespace
        hostname = hostname.strip()

        # Convert to lowercase for consistency
        hostname = hostname.lower()

        # Remove null bytes
        hostname = hostname.replace("\0", "")

        # Remove control characters
        hostname = "".join(char for char in hostname if ord(char) >= 32)

        return hostname

    @staticmethod
    def sanitize_path(path: str) -> str:
        """
        Sanitize file path by removing/escaping dangerous characters

        Args:
            path: File path to sanitize

        Returns:
            Sanitized path
        """
        if not isinstance(path, str):
            path = str(path)

        # Remove leading/trailing whitespace
        path = path.strip()

        # Remove null bytes
        path = path.replace("\0", "")

        # Remove control characters
        path = "".join(char for char in path if ord(char) >= 32 or char == "\t")

        # Normalize path separators to forward slashes
        path = path.replace("\\", "/")

        # Collapse multiple consecutive slashes (except for protocol://)
        import re as regex

        path = regex.sub(r"/+", "/", path)

        return path

    @staticmethod
    def sanitize_machine_name(name: str) -> str:
        """
        Sanitize machine name by removing/escaping dangerous characters

        Args:
            name: Machine name to sanitize

        Returns:
            Sanitized machine name
        """
        if not isinstance(name, str):
            name = str(name)

        # Remove leading/trailing whitespace
        name = name.strip()

        # Remove null bytes
        name = name.replace("\0", "")

        # Remove control characters (except tab)
        name = "".join(char for char in name if ord(char) >= 32 or char == "\t")

        # Replace spaces with hyphens for safety
        name = name.replace(" ", "-")

        return name


class FilePathValidator:
    """File and directory path validation utilities"""

    @staticmethod
    def check_file_exists(file_path: str, file_name: str = "file") -> Path:
        """
        Check if a file exists and is readable.

        Args:
            file_path: Path to the file to check
            file_name: Name of the file for error messages (e.g., "registry.yml")

        Returns:
            Path object if file exists and is readable

        Raises:
            HTTPException: If file doesn't exist or isn't readable
        """
        try:
            path = Path(file_path)

            # Check if path exists
            if not path.exists():
                logger.error(f"{file_name} file not found at {file_path}")
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"{file_name} file not found at {file_path}",
                )

            # Check if it's actually a file (not a directory)
            if not path.is_file():
                logger.error(f"{file_name} path is not a file: {file_path}")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"{file_name} path must be a file, not a directory: {file_path}",
                )

            # Check if file is readable
            if not path.stat().st_mode & 0o400:
                logger.error(f"{file_name} file is not readable: {file_path}")
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=f"{file_name} file is not readable: {file_path}",
                )

            logger.debug(f"{file_name} file validation passed: {file_path}")
            return path

        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error validating {file_name} file: {e}")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Error validating {file_name} file: {str(e)}",
            )

    @staticmethod
    def check_directory_exists(dir_path: str, dir_name: str = "directory") -> Path:
        """
        Check if a directory exists and is accessible.

        Args:
            dir_path: Path to the directory to check
            dir_name: Name of the directory for error messages (e.g., "data directory")

        Returns:
            Path object if directory exists and is accessible

        Raises:
            HTTPException: If directory doesn't exist or isn't accessible
        """
        try:
            path = Path(dir_path)

            # Check if path exists
            if not path.exists():
                logger.error(f"{dir_name} directory not found at {dir_path}")
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"{dir_name} directory not found at {dir_path}",
                )

            # Check if it's actually a directory (not a file)
            if not path.is_dir():
                logger.error(f"{dir_name} path is not a directory: {dir_path}")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"{dir_name} path must be a directory, not a file: {dir_path}",
                )

            # Check if directory is readable
            if not path.stat().st_mode & 0o500:
                logger.error(f"{dir_name} directory is not accessible: {dir_path}")
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=f"{dir_name} directory is not accessible: {dir_path}",
                )

            logger.debug(f"{dir_name} directory validation passed: {dir_path}")
            return path

        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error validating {dir_name} directory: {e}")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Error validating {dir_name} directory: {str(e)}",
            )
