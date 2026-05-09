# Troubleshooting

Common failure modes and how to diagnose them. For the full feature surface and concept docs, see [https://portoser-docs.netlify.app/](https://portoser-docs.netlify.app/).

## First commands when something is wrong

```bash
./portoser registry validate          # YAML + required fields
./portoser dependencies check         # circular deps, missing services
./portoser remote test-connections    # SSH reachability for every host
./portoser status                     # what does Portoser think is running?
```

If those four pass and you're still stuck, the failing operation is almost always a service-level issue. Run:

```bash
./portoser diagnose <SERVICE> <MACHINE>
./portoser diagnose <SERVICE> <MACHINE> --json-output  # machine-readable
```

`diagnose` walks the same observation pipeline a deploy uses, in read-only mode, and produces an analyzer fingerprint (e.g. `PROBLEM_PORT_CONFLICT`) that points at the specific failure class.

## "Registry file not found"

```
Error: Registry file is invalid or not found
```

Portoser expects `registry.yml` at the same directory as the `portoser` script by default. Either:

- `cp registry.example.yml registry.yml` and edit, or
- Set `CADDY_REGISTRY_PATH=/absolute/path/to/registry.yml` in `.env`.

If you cloned to a non-standard location and `.env` overrides the path with `${HOME}/portoser/registry.yml`, comment out the override — the script's default (`$SCRIPT_DIR/registry.yml`) is correct for clone-anywhere setups.

## SSH connectivity failures

```bash
./portoser remote test-connections
```

If a host shows red, the CLI cannot reach it over SSH. Check in this order:

1. **Key-based auth.** Portoser does not handle interactive password prompts. `ssh <user>@<host>` from the control machine must succeed without typing anything. If it doesn't:
   - Run `ssh-copy-id <user>@<host>` to install your public key, or
   - Confirm `~/.ssh/authorized_keys` on the host contains your key.
2. **Hostname / IP.** The `ssh_hostname` (or `ip`) field in `registry.yml` must resolve. `ssh <hostname>` should work; if not, fix DNS / `/etc/hosts` / mDNS first.
3. **Port + user.** `ssh_port` defaults to 22, `ssh_user` is required. Mismatches here surface as connection-refused or permission-denied.

## "Port in use" during deploy

```
Port 8080 on m1: In use (PID 12345)
```

Portoser's analyzer fingerprints this as `PROBLEM_PORT_CONFLICT`. With auto-heal enabled (the default), it will attempt the matching playbook automatically. If you want to inspect first:

```bash
./portoser deploy m1 my-service --no-auto-heal      # see the diagnosis, don't apply
./portoser learn playbook PROBLEM_PORT_CONFLICT     # what the auto-heal would do
```

If the conflicting process is something you actually need running, change the service's `port` in `registry.yml`. Otherwise stop it on the host (`sudo lsof -i :8080`, `kill <PID>`) and retry the deploy.

## Docker daemon not running on target

```
PROBLEM_DOCKER_NOT_RUNNING on m1
```

Portoser cannot deploy `docker`-type services to a host without a running Docker daemon. SSH in and:

- Linux: `sudo systemctl start docker` (or `sudo systemctl enable --now docker`).
- macOS: open Docker Desktop. The CLI's `docker info` must succeed before Portoser can do anything.

Verify with `./portoser remote exec <host> 'docker info'`.

## Disk space pressure

```
PROBLEM_DISK_SPACE_LOW on m1: 95% full
```

Auto-heal will attempt the matching cleanup playbook (image pruning, log rotation). Inspect manually with:

```bash
./portoser remote exec <host> 'df -h /'
./portoser remote exec <host> 'docker system prune -af --volumes'   # only if safe
```

## "Registry file is invalid" with a real registry.yml present

Run `./portoser registry validate`. The most common causes:

- YAML syntax error (use `yq eval registry.yml` to confirm).
- Missing required top-level keys: `domain`, `hosts`, `services`.
- A service declares a `host:` that isn't in the `hosts:` map.
- A service declares `dependencies:` referencing a non-existent service. `./portoser dependencies check` catches this independently.

## Circular dependencies

```
✗ Circular dependency detected: A → B → A
```

`./portoser dependencies check` exits non-zero on cycles. Edit `registry.yml` so the `dependencies:` chain is a DAG. A common mistake: listing a metrics-collection service (e.g. Prometheus) as depending on its scrape targets — Prometheus doesn't *depend* on the targets it scrapes; the targets depend on Prometheus to be observable. Same direction error breaks deploy ordering.

## CLI exits silently with no output

The Bash CLI runs under `set -euo pipefail`. If you see an exit-1 with no message, the most common cause is an unbound-variable trap inside a sub-routine. Re-run with `--debug`:

```bash
./portoser --debug <subcommand> <args>
```

This enables `set -x`-style tracing and shows the exact line where the function exited.

## Web UI: 401 / "no access token" loop

The web UI authenticates via Keycloak. If you redeploy the web stack and the UI gets stuck redirecting:

- Clear browser session storage for `localhost:8989` (or whatever you bound it to).
- Confirm the Keycloak realm is up: `curl -fsS http://localhost:8990/realms/secure-apps/.well-known/openid-configuration` should return JSON, not HTML.
- Check the API can reach Keycloak by hostname: `docker logs portoser-api 2>&1 | grep -i keycloak`.

For dev mode, the seed users are `admin/admin` (admin + viewer roles) and `viewer/viewer` (viewer only).

## Web UI: dependency graph renders nodes but no edges

If you see service nodes laid out vertically with no edges drawn, you're on a build that predates the ReactFlow Handle fix. Pull main, rebuild the frontend (`cd web/frontend && npm run build`), and redeploy the bundle.

## Bash test suite is failing locally

```bash
./tests/run_tests.sh             # all suites
./tests/run_tests.sh --verbose   # see each assertion
```

Common causes for "passes in CI, fails locally":

- macOS Bash 3.2 — install Bash 5+ via `brew install bash`. The CLI requires Bash 4+ for associative arrays and `[[ -v VAR ]]` checks.
- `yq` is the wrong flavor — Portoser uses Mike Farah's Go-based `yq` v4. The Python `yq` is incompatible. `brew install yq` on macOS gives the right one.
- `jq` not installed.

## CI status

The `main` branch runs four parallel GitHub Actions jobs:

| Job | Tool | Failure usually means |
|---|---|---|
| ShellCheck (style) | shellcheck v0.9 (apt) | New `set -euo pipefail` violation, useless-cat, or `A && B \|\| C` pattern |
| Bash test framework | `tests/run_tests.sh` | Logic regression in lib/ |
| Python lint + tests | ruff + pytest | Backend code or test changes |
| Frontend build | tsc + vitest + vite | TS error or component test failure |

If your CI is green but local fails, your local toolchain version probably differs from the workflow's pinned versions — run `cat .github/workflows/ci.yml` to see exact versions.

## Still stuck?

- File a GitHub issue with: `./portoser --version`, your platform (`uname -a`), the exact command, and the full output. The issue template asks for these explicitly.
- For sensitive disclosures (security or operational secrets), see [`SECURITY.md`](SECURITY.md) — please don't paste tokens or hostnames into a public issue.
