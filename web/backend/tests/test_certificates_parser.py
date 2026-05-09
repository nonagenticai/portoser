"""Tests for the certificate-list parser in routers.certificates."""

from routers.certificates import _parse_certs_list_output


def test_parse_empty_output() -> None:
    """No CA, no client certs — parser returns an empty list."""
    stdout = (
        "Certificate Authority:\n"
        "  ✗ CA not found (run 'portoser certs init-ca')\n"
        "\n"
        "Client Certificates:\n"
        "  No client certificates found\n"
    )
    assert _parse_certs_list_output(stdout) == []


def test_parse_ca_only() -> None:
    """Just the CA exists — one CA entry, no client entries."""
    stdout = (
        "Certificate Authority:\n"
        "  ✓ CA Cert: /home/user/portoser/ca/certs/ca-cert.pem\n"
        "subject= /CN=Portoser CA\n"
        "notBefore=Jan  1 00:00:00 2026 GMT\n"
        "notAfter=Jan  1 00:00:00 2036 GMT\n"
        "\n"
        "Client Certificates:\n"
        "  No client certificates found\n"
    )
    certs = _parse_certs_list_output(stdout)
    assert len(certs) == 1
    ca = certs[0]
    assert ca.name == "ca"
    assert ca.type == "ca"
    assert ca.path == "/home/user/portoser/ca/certs/ca-cert.pem"
    assert ca.expires == "Jan  1 00:00:00 2036 GMT"
    assert ca.valid is True


def test_parse_client_certs_with_warnings() -> None:
    """A mix of valid and 'missing key' client certs."""
    stdout = (
        "Certificate Authority:\n"
        "  ✓ CA Cert: /tmp/ca.pem\n"
        "subject= /CN=Portoser CA\n"
        "notAfter=Jan  1 00:00:00 2036 GMT\n"
        "\n"
        "Client Certificates:\n"
        "  ✓ myservice\n"
        "    subject= /CN=myservice\n"
        "    notBefore=Jan  1 00:00:00 2026 GMT\n"
        "    notAfter=Jan  1 00:00:00 2027 GMT\n"
        "  ⚠ orphan (missing key)\n"
        "  ✓ ingestion\n"
        "    notAfter=Feb  2 00:00:00 2027 GMT\n"
    )
    certs = _parse_certs_list_output(stdout)

    by_name = {c.name: c for c in certs}
    assert set(by_name) == {"ca", "myservice", "orphan", "ingestion"}

    assert by_name["ca"].type == "ca"
    assert by_name["ca"].expires == "Jan  1 00:00:00 2036 GMT"

    assert by_name["myservice"].type == "client"
    assert by_name["myservice"].valid is True
    assert by_name["myservice"].expires == "Jan  1 00:00:00 2027 GMT"

    assert by_name["orphan"].type == "client"
    assert by_name["orphan"].valid is False  # missing key

    assert by_name["ingestion"].type == "client"
    assert by_name["ingestion"].expires == "Feb  2 00:00:00 2027 GMT"
