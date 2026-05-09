"""Pydantic models for certificate management"""

from typing import List, Optional

from pydantic import BaseModel, Field


class CertificateInfo(BaseModel):
    """Individual certificate information"""

    name: str
    service: str
    type: str  # "client", "server", "ca"
    path: str
    expires: Optional[str] = None
    valid: bool = True


class CertificateListResponse(BaseModel):
    """Response for certificate list"""

    success: bool
    output: str
    certificates: List[CertificateInfo]


class BrowserCertStatusResponse(BaseModel):
    """Browser certificate installation status"""

    installed: int = Field(..., description="Number of certificates installed")
    missing: int = Field(..., description="Number of certificates missing")
    total: int = Field(..., description="Total number of certificates")
    all_installed: bool = Field(..., description="True if all are installed")
    output: str = Field(..., description="Raw command output")


class CertificateOperationResponse(BaseModel):
    """Generic certificate operation response"""

    success: bool
    message: str
    output: str
    error: Optional[str] = None


class CertificateValidationResponse(BaseModel):
    """Service certificate validation response"""

    service: str
    valid: bool
    missing_certificates: List[str]
    output: str
    recommendations: List[str]
