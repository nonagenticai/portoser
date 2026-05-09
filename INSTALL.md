# Installing Portoser

There are three supported install paths, in increasing order of commitment:

1. **Single-machine eval via Docker Compose** — the fastest way to see what Portoser does.
2. **Multi-host via the example cluster scripts** — a real deployment across two or more machines.
3. **From source / development** — what you'll want if you plan to hack on Portoser itself.

Pick whichever matches your goal. You can always start with path 1 and graduate to path 2 later.

---

## Path 1 — Single-machine eval via Docker Compose

**Use case:** "I just want to see what this thing does."

### Requirements

- Docker 24+
- `docker compose` v2 (the plugin, not the legacy `docker-compose` binary)
- ~1 GB free RAM
- Port `8080` free on the host (override with `PORTOSER_DEMO_PORT` in `.env`)

### Steps

```bash
git clone https://github.com/nonagenticai/portoser.git
cd portoser
cp .env.example .env
docker compose up -d
```

The defaults in `.env.example` are wired for a self-contained demo, so
you don't need to edit anything to get a working install. The compose
file brings up:

- A small **demo backend** (FastAPI) that loads a tiny demo registry
  (`demo/registry.demo.yml`), polls each service's health endpoint,
  and serves a minimal dashboard.
- A **Caddy** reverse proxy on `:8080` fronting the demo backend.
- One **dummy registered service** (an `nginx:alpine`) so the dashboard
  isn't empty on first load and you can validate that the
  orchestration loop works end-to-end.

This path-1 stack is intentionally lightweight: it does *not* bring up
the production web UI/MCP server, Postgres, Redis, or Keycloak. For
the full stack, see Path 3 (from source) below or run
`web/docker-compose.yml` after configuring `.env`.

### Verify the install

```bash
curl http://localhost:8080/api/health
# Expect: {"status":"ok"} (HTTP 200)

curl http://localhost:8080/api/services
# Expect: JSON listing the dummy service with health.status=="healthy"
```

Then open <http://localhost:8080> in a browser. You should see the
dashboard with the dummy service listed and reporting healthy.

### Tear it down

```bash
docker compose down -v
```

The `-v` flag also removes the demo network volume — handy when you
want a fresh slate.

---

## Path 2 — Multi-host via the example cluster scripts

**Use case:** A real deployment across two or more hosts (the
home-lab / small-cluster scenario Portoser is built for).

### Requirements

- All of Path 1's requirements, on each host that will run services.
- SSH key-based access from the machine you'll run `cluster-compose.sh`
  on, to every host listed in `cluster.conf`.
- A shared on-disk path layout — by default Portoser expects services
  to live under a common parent (e.g. `~/portoser/<service>/`), but this
  is configurable per host in `cluster.conf`.

#### CLI prerequisites

The `portoser` CLI and `cluster-compose.sh` shell out to a number of
standard tools. Install whichever of these are missing on the control
machine:

| Tool        | Required for                                 | Install                                  |
|-------------|----------------------------------------------|------------------------------------------|
| `bash` 4+   | Everything (macOS ships 3.2)                 | `brew install bash`                      |
| `yq`        | Reading the YAML registry                    | `brew install yq` / `apt install yq`     |
| `jq`        | JSON output / inspection                     | `brew install jq` / `apt install jq`     |
| `ssh`, `scp`| Multi-host orchestration                     | bundled with OpenSSH                     |
| `curl`      | Health checks, Caddy admin API               | usually preinstalled                     |
| `rsync`     | Code/config sync between hosts               | `brew install rsync` / `apt install rsync` |
| `openssl`   | Cert generation under `client-certs/`        | preinstalled on most distros             |
| `htpasswd`  | Container registry basic-auth (optional)     | `brew install httpd` / `apt install apache2-utils` |
| `step`      | Smallstep CA workflows (optional)            | <https://smallstep.com/docs/step-cli/installation> |
| `vault`     | If you store secrets in HashiCorp Vault      | <https://developer.hashicorp.com/vault/install> |
| `caddy`     | If running Caddy outside Docker              | <https://caddyserver.com/docs/install>   |
| `python3`   | The `portoser onboard` / `device` subcommands| preinstalled on most distros             |
| `sshpass`   | Only the optional `scripts/clean-pis.sh`     | `brew install hudochenkov/sshpass/sshpass` / `apt install sshpass` |

### Configure your cluster

```bash
cp cluster.conf.example cluster.conf
$EDITOR cluster.conf       # host map, paths, arch per host

cp .env.example .env
$EDITOR .env               # hostnames, registry URL, demo secrets

cp registry.example.yml registry.yml
$EDITOR registry.yml       # which services run, on which host, with what config
```

`cluster.conf` is the host inventory: it maps logical names (e.g.
`worker-1`) to IPs, SSH usernames, architectures, and on-disk service
roots.

`registry.yml` is the service inventory: it maps service names to
images / compose files, target hosts, ports, dependencies, and TLS
settings. See the registry schema docs at https://portoser-docs.netlify.app/configuration/registry for the
full field reference.

### Bring the cluster up

```bash
./cluster-compose.sh up
```

This walks the registry, SSHes to each target host, and brings up the
services per the `cluster.conf` mapping. Re-running `up` is idempotent
— services that are already up and healthy are left alone.

Useful related commands:

```bash
./cluster-compose.sh ps            # show service status across hosts
./cluster-compose.sh logs <svc>    # tail logs for a service
./cluster-compose.sh down          # stop everything
```

For advanced flows (rolling updates, per-host targeting, dry-run mode,
local image builds) see https://portoser-docs.netlify.app/.

### mTLS between hosts

If your services use mTLS (the default for `*.internal` hostnames),
you'll want each host to trust the local CA so service-to-service
calls validate cleanly:

```bash
./install_ca_on_hosts.sh
```

This distributes the CA cert from the control machine to every host
listed in `cluster.conf`.

---

## Path 3 — From source / development

**Use case:** You want to modify Portoser, run the test suite, or work
on the frontend / backend directly.

### Requirements

- Python 3.12+
- Node 20+
- bash 4+ (macOS users: `brew install bash` — the system bash is 3.2)
- `yq` and `docker` available on `PATH`

### Set up the backend

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ./web/backend
```

Run the backend in dev mode (auto-reload on file change):

```bash
uvicorn web.backend.main:app --reload --port 8080
```

### Set up the frontend

```bash
cd web/frontend
npm ci
npm run build       # production build
# or:
npm run dev         # Vite dev server with HMR
```

### Run the tests

```bash
bash tests/run_tests.sh
```

The test runner exercises the bash orchestration libs, the FastAPI
backend, and the registry parser. Individual layers can be run on their
own — see `tests/` for the sub-runners.

---

## Troubleshooting

If something goes wrong during a multi-host deploy — SSH timeouts,
missing dependencies on a worker, port conflicts, certificate trust
errors — start at [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md),
which catalogues the common failure modes and their fixes.

For single-machine demo issues, check `docker compose logs` first —
most problems are either a port conflict on `:8080` or a missing
`.env` file.
