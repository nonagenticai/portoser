# Security Policy

## Supported versions

Portoser is currently in **alpha**. Only the latest `1.0.x` line receives security
fixes. Older or pre-1.0 builds are not supported — please upgrade.

| Version | Supported          |
|---------|--------------------|
| 1.0.x   | Yes                |
| < 1.0   | No                 |

When the project reaches 1.x stability, this table will be updated to reflect a
clearer support window.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Preferred reporting channel:

- **GitHub Security Advisories** — open a private advisory at
  `https://github.com/nonagenticai/portoser/security/advisories/new`. This keeps the
  discussion private until a fix is ready.

If you cannot use GitHub Security Advisories (for example, you don't have a GitHub
account), open a regular issue titled `Security: please contact me privately` — do
**not** include vulnerability details — and a maintainer will reach out via the email
on your GitHub profile or via GitHub's contact form.

When reporting, please include:

- A clear description of the vulnerability and its impact.
- Steps to reproduce, ideally with a minimal proof of concept.
- Affected version(s) / commit hashes.
- Your suggested severity and any mitigations you've identified.
- Whether you'd like public credit when the advisory is published.

## Response expectations

- **Acknowledgment:** within **5 business days** of receiving your report.
- **Triage and severity assessment:** within **10 business days**.
- **Fix target:** **30 days** for high-severity issues; longer windows may apply for
  lower-severity findings or issues requiring architectural changes.
- **Coordinated disclosure window:** **90 days** from initial report. We will work with
  you on timing if more time is genuinely needed; otherwise we publish at day 90.

## Scope

**In scope:**

- Source code in this repository.
- Default configurations and deployment manifests shipped in this repo.
- Documentation that, if followed verbatim, would lead to insecure deployments.

**Out of scope:**

- Third-party services that Portoser integrates with (report to those vendors directly).
- Any specific deployment of Portoser operated by the author or a third party — only
  the upstream code is in scope here.
- Findings that require physical access to a machine, social engineering of maintainers,
  or denial-of-service via resource exhaustion against shared infrastructure.
- Vulnerabilities in dependencies that have not yet been fixed upstream (please report
  to the dependency's maintainers; we'll pick up patched releases promptly).

## Known limitations in 1.0.0-alpha

The following are intentional gaps in the alpha release. They are tracked
publicly here so operators can make informed deployment decisions:

- **WebSocket endpoints validate tokens but cannot use the Keycloak HTTP
  middleware.** `BaseHTTPMiddleware` in Starlette does not intercept
  WebSocket connections, so each `@app.websocket(...)` handler calls the
  shared `auth.websocket.authenticate_websocket()` helper as its first
  line. The helper accepts a Keycloak access token in any of three
  places (header / subprotocol / `?token=` query param), validates it
  against the same JWKS the HTTP middleware uses, and closes the socket
  with WebSocket close code `4401` (or `4403` if a required role is
  missing) before `accept()` runs. When `KEYCLOAK_ENABLED=false` the
  helper short-circuits to a sentinel dev user — same model as the HTTP
  middleware. If you add a new `@websocket` route, call this helper at
  the top or your endpoint will be reachable without authentication.
- **The web frontend does not attach a bearer token to API calls.** The React app
  works only when `KEYCLOAK_ENABLED=false`, against a backend that does not gate
  endpoints on authenticated identity. Production deployments with Keycloak
  enabled will return 401 for most pages until an OIDC client is wired into the
  frontend (planned for `1.0.0-beta`).
- **`KEYCLOAK_SSL_VERIFY` defaults to `true`.** If you point the backend at a
  Keycloak instance with a self-signed certificate, set
  `KEYCLOAK_SSL_VERIFY=false` explicitly, or supply a CA bundle via
  `CA_CERT_PATH=/path/to/ca.pem`. The previous default (`false`) was changed in
  `1.0.0-alpha` because it silently disabled TLS verification.
- **`uvicorn` defaults to `BIND_HOST=127.0.0.1` in development.** Set
  `BIND_HOST=0.0.0.0` only when you intend to expose the API beyond the local
  host (containerised deployments do this in their orchestration manifests).

## Hall of fame

We're grateful to the researchers and contributors who report issues responsibly. Once
the project receives its first reports, this section will list reporters who follow the
disclosure process and consent to public credit.

- *(no reports yet — your name could go here!)*
