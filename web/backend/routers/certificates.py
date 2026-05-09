"""Certificate management router"""

import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from auth.dependencies import require_any_role, require_role
from auth.models import KeycloakUser
from models.certificates import (
    BrowserCertStatusResponse,
    CertificateInfo,
    CertificateListResponse,
    CertificateOperationResponse,
    CertificateValidationResponse,
)
from services.cli_runner import run_portoser_command as _run_cli

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/certificates", tags=["certificates"])


async def run_portoser_command(
    args: List[str], timeout: int = 60, return_partial_on_timeout: bool = True
) -> tuple[str, str, int]:
    """Adapter: cert endpoints expect (stdout, stderr, returncode) tuples;
    the shared cli_runner returns a dict. Translate here so the endpoints
    don't need to change.
    """
    result = await _run_cli(
        args,
        stream=False,
        timeout=timeout,
        return_partial_on_timeout=return_partial_on_timeout,
    )
    return result["output"], result.get("error") or "", result["returncode"]


def _parse_certs_list_output(stdout: str) -> List[CertificateInfo]:
    """Parse the human-readable output of `portoser certs list`.

    The shell helper (lib/certificates.sh:list_certs) emits two sections:

        Certificate Authority:
          ✓ CA Cert: /path/to/ca-cert.pem
          subject= /CN=...
          notBefore=Jan 1 00:00:00 2026 GMT
          notAfter=Jan 1 00:00:00 2027 GMT

        Client Certificates:
          ✓ myservice
              subject= /CN=myservice
              notBefore=...
              notAfter=...
          ⚠ orphan (missing key)

    or, when nothing exists:

        Certificate Authority:
          ✗ CA not found (run 'portoser certs init-ca')

        Client Certificates:
          No client certificates found
    """
    certs: List[CertificateInfo] = []
    section: Optional[str] = None
    pending: Optional[dict] = None

    def _flush() -> None:
        if not pending:
            return
        certs.append(
            CertificateInfo(
                name=pending["name"],
                service=pending["name"],
                type=pending["type"],
                path=pending.get("path", ""),
                expires=pending.get("expires"),
                valid=pending.get("valid", True),
            )
        )

    for raw in stdout.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            continue

        if stripped.startswith("Certificate Authority"):
            _flush()
            pending = None
            section = "ca"
            continue
        if stripped.startswith("Client Certificates"):
            _flush()
            pending = None
            section = "client"
            continue

        if section == "ca":
            if stripped.startswith("✓ CA Cert:"):
                _flush()
                pending = {
                    "name": "ca",
                    "type": "ca",
                    "path": stripped.split(":", 1)[1].strip(),
                    "valid": True,
                }
            elif stripped.startswith("✗"):
                _flush()
                pending = None
            elif pending is not None and stripped.startswith("notAfter="):
                pending["expires"] = stripped.split("=", 1)[1].strip()

        elif section == "client":
            if stripped.startswith("No client certificates"):
                _flush()
                pending = None
            elif stripped.startswith("✓ ") or stripped.startswith("⚠ "):
                _flush()
                marker, _, rest = stripped.partition(" ")
                name = rest.split(" (", 1)[0].strip()
                pending = {
                    "name": name,
                    "type": "client",
                    "path": "",
                    "valid": marker == "✓",
                }
            elif pending is not None and stripped.startswith("notAfter="):
                pending["expires"] = stripped.split("=", 1)[1].strip()

    _flush()
    return certs


@router.get("/list", response_model=CertificateListResponse)
async def list_certificates():
    """
    List all certificates with expiry information

    Returns:
        List of certificates with details
    """
    logger.info("Listing all certificates")

    stdout, stderr, code = await run_portoser_command(["certs", "list"], timeout=30)

    if code != 0:
        logger.error(f"Failed to list certificates: {stderr}")
        raise HTTPException(status_code=500, detail=f"Failed to list certificates: {stderr}")

    certificates = _parse_certs_list_output(stdout)

    return {
        "success": True,
        "output": stdout,
        "certificates": certificates,
    }


@router.get("/browser-status", response_model=BrowserCertStatusResponse)
async def check_browser_certs(
    service: Optional[str] = Query(None, description="Specific service to check, or 'all'"),
):
    """
    Check which CA certificates are installed in browser keychain

    Args:
        service: Specific service name, or None for all

    Returns:
        Browser certificate status
    """
    logger.info(f"Checking browser certificates for: {service or 'all'}")

    args = ["certs", "check-browser"]
    if service:
        args.append(service)

    stdout, stderr, code = await run_portoser_command(args, timeout=30)

    # Parse output to extract installed/missing counts
    installed = 0
    missing = 0

    for line in stdout.split("\n"):
        if "Installed:" in line:
            try:
                installed = int(line.split(":")[1].strip())
            except Exception:
                pass
        elif "Missing:" in line:
            try:
                missing = int(line.split(":")[1].strip())
            except Exception:
                pass

    return {
        "installed": installed,
        "missing": missing,
        "total": installed + missing,
        "output": stdout,
        "all_installed": missing == 0,
    }


@router.post("/browser/install", response_model=CertificateOperationResponse)
async def install_browser_certs(
    service: Optional[str] = Query(None, description="Specific service or 'all'"),
    user: KeycloakUser = Depends(require_role("admin")),
):
    """
    Install CA certificates to System Keychain for browser trust

    Args:
        service: Specific service name, or None for all

    Returns:
        Installation result
    """
    logger.info(f"Installing browser certificates for: {service or 'all'}")

    args = ["certs", "install-browser"]
    if service:
        args.append(service)

    # This command requires sudo, so it may fail without proper permissions
    stdout, stderr, code = await run_portoser_command(args, timeout=60)

    return {
        "success": code == 0,
        "message": "Certificate installation initiated" if code == 0 else "Installation failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.delete("/browser/uninstall", response_model=CertificateOperationResponse)
async def uninstall_browser_certs(
    service: Optional[str] = Query(None, description="Specific service or 'all'"),
    user: KeycloakUser = Depends(require_role("admin")),
):
    """
    Remove CA certificates from System Keychain

    Args:
        service: Specific service name, or None for all

    Returns:
        Uninstallation result
    """
    logger.info(f"Uninstalling browser certificates for: {service or 'all'}")

    args = ["certs", "uninstall-browser"]
    if service:
        args.append(service)

    stdout, stderr, code = await run_portoser_command(args, timeout=60)

    return {
        "success": code == 0,
        "message": "Certificate uninstallation complete" if code == 0 else "Uninstallation failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.get("/validate/{service}", response_model=CertificateValidationResponse)
async def validate_service_certs(service: str):
    """
    Validate that a service has all required certificates

    Args:
        service: Service name to validate

    Returns:
        Validation result with missing certificates
    """
    logger.info(f"Validating certificates for service: {service}")

    stdout, stderr, code = await run_portoser_command(["certs", "validate", service], timeout=30)

    # Parse validation output
    missing_certs = []
    all_valid = "All certificates valid" in stdout

    # Extract missing certificates from output
    for line in stdout.split("\n"):
        if "MISSING" in line:
            # Extract cert name from line like "    ✗ ca-cert.pem - MISSING"
            parts = line.strip().split()
            if len(parts) >= 2:
                missing_certs.append(parts[1])

    return {
        "service": service,
        "valid": all_valid,
        "missing_certificates": missing_certs,
        "output": stdout,
        "recommendations": []
        if all_valid
        else [
            f"Generate PostgreSQL client certs: portoser certs generate {service}",
            f"Deploy to machine: portoser certs deploy {service} MACHINE",
            f"Copy Keycloak CA: portoser certs copy-keycloak-ca {service}",
            f"Generate Caddy server certs: portoser certs generate-server {service}",
        ],
    }


@router.post("/keycloak-ca/copy/{service}", response_model=CertificateOperationResponse)
async def copy_keycloak_ca(
    service: str, user: KeycloakUser = Depends(require_any_role("deployer", "admin"))
):
    """
    Copy Keycloak CA certificate to service directory

    Args:
        service: Service name

    Returns:
        Copy operation result
    """
    logger.info(f"Copying Keycloak CA to service: {service}")

    stdout, stderr, code = await run_portoser_command(
        ["certs", "copy-keycloak-ca", service], timeout=30
    )

    return {
        "success": code == 0,
        "message": f"Keycloak CA copied to {service}" if code == 0 else "Copy failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.post("/keycloak-ca/copy-all", response_model=CertificateOperationResponse)
async def copy_keycloak_ca_all(user: KeycloakUser = Depends(require_any_role("deployer", "admin"))):
    """
    Copy Keycloak CA certificate to all services that need it

    Returns:
        Copy operation result
    """
    logger.info("Copying Keycloak CA to all services")

    stdout, stderr, code = await run_portoser_command(["certs", "copy-keycloak-ca-all"], timeout=60)

    return {
        "success": code == 0,
        "message": "Keycloak CA copied to all services" if code == 0 else "Copy failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.post("/generate/{service}", response_model=CertificateOperationResponse)
async def generate_client_cert(
    service: str, user: KeycloakUser = Depends(require_any_role("deployer", "admin"))
):
    """
    Generate PostgreSQL mTLS client certificate for service

    Args:
        service: Service name

    Returns:
        Generation result
    """
    logger.info(f"Generating client certificate for: {service}")

    stdout, stderr, code = await run_portoser_command(["certs", "generate", service], timeout=60)

    return {
        "success": code == 0,
        "message": f"Client certificate generated for {service}"
        if code == 0
        else "Generation failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.post("/generate-server/{service}", response_model=CertificateOperationResponse)
async def generate_server_cert(
    service: str, user: KeycloakUser = Depends(require_any_role("deployer", "admin"))
):
    """
    Generate HTTPS server certificate for service (for Caddy)

    Args:
        service: Service name

    Returns:
        Generation result
    """
    logger.info(f"Generating server certificate for: {service}")

    stdout, stderr, code = await run_portoser_command(
        ["certs", "generate-server", service], timeout=60
    )

    return {
        "success": code == 0,
        "message": f"Server certificate generated for {service}"
        if code == 0
        else "Generation failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.post("/deploy/{service}/{machine}", response_model=CertificateOperationResponse)
async def deploy_cert(
    service: str, machine: str, user: KeycloakUser = Depends(require_any_role("deployer", "admin"))
):
    """
    Deploy client certificate to remote machine

    Args:
        service: Service name
        machine: Target machine name

    Returns:
        Deployment result
    """
    logger.info(f"Deploying certificate for {service} to {machine}")

    stdout, stderr, code = await run_portoser_command(
        ["certs", "deploy", service, machine], timeout=60
    )

    return {
        "success": code == 0,
        "message": f"Certificate deployed to {machine}" if code == 0 else "Deployment failed",
        "output": stdout,
        "error": stderr if code != 0 else None,
    }


@router.get("/check-expiry", response_model=CertificateOperationResponse)
async def check_cert_expiry(
    service: Optional[str] = Query(None, description="Specific service or 'all'"),
):
    """
    Check certificate expiry dates

    Args:
        service: Specific service name, or None for all

    Returns:
        Expiry check result
    """
    logger.info(f"Checking certificate expiry for: {service or 'all'}")

    args = ["certs", "check"]
    if service:
        args.append(service)

    stdout, stderr, code = await run_portoser_command(args, timeout=30)

    return {
        "success": True,
        "message": "Certificate expiry checked",
        "output": stdout,
        "error": None,
    }
