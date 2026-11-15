# Portoser

A declarative service registry, web UI, and MCP server for orchestrating Docker-based services across heterogeneous hosts — without adopting full Kubernetes.

[![CI](https://github.com/nonagenticai/portoser/actions/workflows/ci.yml/badge.svg)](https://github.com/nonagenticai/portoser/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nonagenticai/portoser)](https://github.com/nonagenticai/portoser/releases)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#status)

**Website:** https://portoser.netlify.app/ &nbsp;·&nbsp; **Documentation:** https://portoser-docs.netlify.app/

## What is Portoser?

Portoser turns a YAML file into a running cluster. You declare your services
(image, ports, host, dependencies, mTLS settings) in a single registry, and
Portoser deploys, monitors, and re-routes them across however many machines
you have lying around. It is built for home-labs, small studios, and
hobbyist clusters that want a single declarative source of truth and a
real web UI, but don't want to learn — or pay for — a full Kubernetes
control plane. The same registry drives the CLI (bash), the FastAPI/React
web UI, and an MCP server that lets AI assistants inspect and operate the
cluster.

## Key features

- Declarative YAML service registry — one source of truth for your cluster.
- Web UI that shows live service health, machine assignments, and per-service controls.
- MCP server so Claude, Cursor, and other AI assistants can inspect and operate the cluster.
- Multi-host orchestration over plain SSH — no agents to install on workers.
- mTLS between services, with a built-in CA-distribution helper for adding new hosts.
- Mixed-architecture clusters supported (amd64 + arm64, Linux + macOS).
- Idempotent compose-style deployments — re-running is safe.

## Status

Alpha. The `v1.0.0` tag is the first public release, but APIs may still
change. The main contributor's home-lab is the primary deployment target
today, so some defaults assume that environment. The platform parts
(registry schema, web UI, MCP server, `lib/` orchestration primitives) are
designed to be re-usable; the example cluster layout is not the only valid
one. Issues and PRs are welcome.

## Quick start (single-machine via Docker Compose)

```bash
git clone https://github.com/nonagenticai/portoser.git
cd portoser
cp .env.example .env
docker compose up
# Open http://localhost:8080
```

This brings up a self-contained demo: a small FastAPI dashboard, Caddy
on `:8080`, and one dummy registered service so you can verify the
orchestration loop end-to-end without touching configuration. For the
full production web UI / MCP server / multi-host orchestration, see
[`INSTALL.md`](INSTALL.md) paths 2 and 3.

## Usage

The CLI is the `portoser` script at the repository root. It reads the
registry named by `CADDY_REGISTRY_PATH` (default: `registry.yml` beside the
script), so start from the checked-in example:

```bash
cp registry.example.yml registry.yml
bash ./portoser registry list-machines
# m1
# mini1
# mini2
# pi1
# pi2
# pi3
# pi4
```

`bash ./portoser registry validate` checks the file and every service entry;
`bash ./portoser registry list-services` lists the services. `bash ./portoser --help`
lists the deploy, health, Caddy, DNS, certificate, Keycloak and registry commands.

## Configuration

Copy [`.env.example`](.env.example) to `.env`. The single-machine demo's
`docker-compose.yml` reads only `PORTOSER_DEMO_PORT`; the other values are read
by the `portoser` CLI and the multi-host scripts:

| Variable | Default | Meaning |
|---|---|---|
| `PORTOSER_DEMO_PORT` | `8080` | Host port the demo Caddy front end binds to (`docker-compose.yml`). |
| `CADDY_REGISTRY_PATH` | `<repo>/registry.yml` | Registry YAML read by the CLI and the web backend (`portoser`, `web/backend/config.py`). |
| `SERVICES_ROOT` | the repository directory | Root under which service trees live (`portoser`). |
| `CADDY_ADMIN_API` | `http://127.0.0.1:2019` | Caddy admin endpoint used for config reloads (`portoser`). |
| `PIDS_DIR` | `<repo>/.pids` | PID files for services started locally (`portoser`). |
| `LOGS_DIR` | the parent of the repository directory | Log files for services started locally (`portoser`). |
| `SSH_USER` | the current user | Default SSH user for cluster hosts (`portoser`). |
| `DOCKER_NETWORK` | `workflow-system-network` | Shared Docker network created and joined by service compose files. |
| `REGISTRY_HOST` | empty | Image registry host; empty disables image pushes (`lib/docker_registry.sh`). |
| `HEALTH_CHECK_TIMEOUT` / `HEALTH_CHECK_INTERVAL` | `30` / `2` | Per-probe timeout and polling interval, in seconds. |
| `POSTGRES_HOST` / `POSTGRES_PORT` | `localhost` / `5432` | Postgres (or PgBouncer) used by the password-sync and backend scripts. |
| `POSTGRES_SUPERUSER` | `postgres` | Superuser the password-sync script connects as (`postgres_pw_sync.sh`). |
| `KEYCLOAK_URL` / `KEYCLOAK_REALM` | `http://localhost:8080` / `portoser` in `config.py`; `https://keycloak.example.local` / `secure-apps` in `.env.example` | Keycloak base URL and realm for service auth. |

The full web backend has its own [`web/backend/.env.example`](web/backend/.env.example).
It adds `ENVIRONMENT` (`production` by default in `config.py`; `development` in the
template), `JWT_SECRET_KEY` (required in production), `KEYCLOAK_ENABLED` (true by
default in production, false otherwise), `MCP_ENABLED`, `BACKEND_PORT` (`8988`),
`REDIS_URL`, `ENABLE_BACKGROUND_WORKERS`, `LOG_LEVEL` and the `VAULT_*` settings;
`config.py` is the source of its defaults.

## Going further

- **Project site:** [portoser.netlify.app](https://portoser.netlify.app/) — feature overview, hardware setups, embedded demos.
- **Full documentation:** [portoser-docs.netlify.app](https://portoser-docs.netlify.app/) — quickstart, CLI reference, HTTP/WebSocket API, concepts, comparison with Portainer / Coolify / k3s / Nomad, registry YAML schema, system architecture.
- [`INSTALL.md`](INSTALL.md) — single-machine, multi-host, and from-source install paths.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failure modes and how to diagnose them.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute, run tests, and submit PRs.
- [`SECURITY.md`](SECURITY.md) — responsible disclosure for security issues.

## Development

Requires Python 3.12+, Node.js 20+, Bash 4+ (on macOS: `brew install bash`) and
Docker; the full setup is in [`CONTRIBUTING.md`](CONTRIBUTING.md). These are the
commands CI runs (`.github/workflows/ci.yml`):

```bash
# Bash framework: lib/, registry parser, CLI
bash tests/run_tests.sh

# Python backend (web/backend)
pip install -e ./web/backend
pip install ruff pytest pytest-asyncio
ruff check web/backend
ruff format --check web/backend
cd web/backend && pytest

# Frontend (web/frontend)
cd web/frontend
npm ci
npx tsc --noEmit
npm test
npm run build
```

CI also runs `shellcheck -x -S style` over the repository's shell scripts.

## Security

Report vulnerabilities privately through the repository's Security tab — see
[`SECURITY.md`](SECURITY.md). Do not open a public issue for a security problem.

## Contributing

Issues and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for this repository's workflow and the
[organisation-wide rules](https://github.com/nonagenticai/.github/blob/main/CONTRIBUTING.md);
setup, test and lint commands are in **Development** above. Commits carry DCO sign-off.

## Licensing

The code in this repository is Apache-2.0 and needs no licence key to build, test or run.
It contains no licence-enforcement code: the Apache-2.0 licence in [`LICENSE`](LICENSE) is the
only licence that applies, and no licence server is involved.

## License

Apache 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
