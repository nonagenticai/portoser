# Portoser

A declarative service registry, web UI, and MCP server for orchestrating Docker-based services across heterogeneous hosts — without adopting full Kubernetes.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Status: Alpha](https://img.shields.io/badge/Status-alpha-orange.svg)](#status)
[![Tests](https://github.com/nonagenticai/portoser/actions/workflows/ci.yml/badge.svg)](https://github.com/nonagenticai/portoser/actions/workflows/ci.yml)

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

Alpha. APIs may change. The main contributor's home-lab is the primary
deployment target today, so some defaults assume that environment. The
platform parts (registry schema, web UI, MCP server, `lib/` orchestration
primitives) are designed to be re-usable; the example cluster layout is
not the only valid one. Issues and PRs are welcome.

## 5-minute quickstart (single-machine via Docker Compose)

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

## Going further

- **Marketing site:** [portoser.netlify.app](https://portoser.netlify.app/) — feature overview, hardware setups, embedded demos.
- **Full documentation:** [portoser-docs.netlify.app](https://portoser-docs.netlify.app/) — quickstart, CLI reference, HTTP/WebSocket API, concepts, comparison with Portainer / Coolify / k3s / Nomad, registry YAML schema, system architecture.
- [`INSTALL.md`](INSTALL.md) — single-machine, multi-host, and from-source install paths.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failure modes and how to diagnose them.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute, run tests, and submit PRs.
- [`SECURITY.md`](SECURITY.md) — responsible disclosure for security issues.

## License

Apache 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
