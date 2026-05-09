#!/usr/bin/env bash
# =============================================================================
# web/dev-up.sh — one-shot local Docker bring-up for the Portoser web stack.
#
# Brings up: Postgres, Redis, Keycloak (with realm + admin/viewer users),
# the FastAPI backend, and the Vite-built frontend (served by nginx).
# All services run on the host's docker daemon, on the existing
# `workflow-system-network`. No external infra required (no real Postgres,
# no real Keycloak, no Vault).
#
# Idempotent: re-runs are safe; only missing scaffolding is created.
# =============================================================================

set -euo pipefail

# Resolve repo paths relative to this script so the user can run it from any cwd.
WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$WEB_DIR/.." && pwd)"

# ANSI-C quoting ($'...') so the variables hold real ESC chars rather than
# the literal 4-char string "\033...".
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
RED=$'\033[0;31m'
NC=$'\033[0m'

step()  { printf "${BLUE}==>${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!! ${NC}%s\n" "$1" >&2; }
ok()    { printf "${GREEN}✓${NC}  %s\n" "$1"; }
die()   { printf "${RED}✗  %s${NC}\n" "$1" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

step "Preflight checks"
command -v docker >/dev/null || die "docker not on PATH"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (is Docker Desktop running?)"
ok "docker daemon reachable"

# ----------------------------------------------------------------------------
# Scaffolding: ensure registry dir, cert stubs, .env, network
# ----------------------------------------------------------------------------

step "Scaffolding (registry dir, cert stubs, .env, docker network)"

# Registry directory: backend writes registry.yml inside it. If absent, copy
# the example from the repo root.
mkdir -p "$WEB_DIR/registry"
if [ ! -f "$WEB_DIR/registry/registry.yml" ]; then
    if [ -f "$REPO_ROOT/registry.yml" ]; then
        cp "$REPO_ROOT/registry.yml" "$WEB_DIR/registry/registry.yml"
        ok "seeded $WEB_DIR/registry/registry.yml from repo root"
    else
        warn "no $REPO_ROOT/registry.yml to seed from; creating empty registry"
        printf "services: {}\nhosts: {}\n" > "$WEB_DIR/registry/registry.yml"
    fi
else
    ok "registry/registry.yml exists"
fi

# Knowledge base directory — read-only mount target. Linux refuses the mount
# if the host source path doesn't exist, so create the layout the CLI writes
# (playbooks/, patterns_history/) and seed a sample playbook on first run so
# the empty-state demo isn't completely blank.
PORTOSER_HOME="${PORTOSER_HOME:-$HOME/.portoser}"
KB_DIR="$PORTOSER_HOME/knowledge"
# All three dirs the docker-compose mounts read-only must exist or the mount
# fails. Create them up front whether or not anything's been seeded yet.
mkdir -p "$KB_DIR/playbooks" "$KB_DIR/patterns_history" \
         "$PORTOSER_HOME/deployments" \
         "$PORTOSER_HOME/metrics_snapshots"
SAMPLE_SRC="$WEB_DIR/dev/sample-knowledge/example.md"
SAMPLE_DST="$KB_DIR/playbooks/example.md"
if [ -f "$SAMPLE_SRC" ] && [ ! -e "$SAMPLE_DST" ]; then
    cp "$SAMPLE_SRC" "$SAMPLE_DST"
    ok "seeded sample playbook → $SAMPLE_DST"
fi
ok "portoser home dirs ready under $PORTOSER_HOME"

# Cert stubs: the compose mounts these as read-only files; Linux refuses the
# mount if the source path doesn't exist. Local dev runs sslmode=disable so
# the contents are unread — empty files are sufficient.
mkdir -p "$WEB_DIR/certs"
for cert in ca-cert.pem portoser-web-cert.pem portoser-web-key.pem keycloak-ca-cert.pem; do
    [ -f "$WEB_DIR/certs/$cert" ] || touch "$WEB_DIR/certs/$cert"
done
ok "cert stubs in place under web/certs/"

# .env: only create if missing — never overwrite existing user secrets.
if [ ! -f "$WEB_DIR/.env" ]; then
    cat > "$WEB_DIR/.env" <<'ENVEOF'
# Local-dev .env for web/docker-compose.yml — gitignored.
# ENVIRONMENT is intentionally NOT set here (compose pins it to "development"
# at the container level; setting it here would leak into pytest via dotenv).
POSTGRES_PASSWORD_PORTOSER=portoser-local-dev-password
KEYCLOAK_ENABLED=true
KEYCLOAK_CLIENT_SECRET=portoser-local-dev-secret
KC_ADMIN_USER=keycloak-admin
KC_ADMIN_PASSWORD=keycloak-admin
JWT_SECRET_KEY=local-dev-jwt-secret-replace-in-production-3eF9kL2mN8pQ4rS
VAULT_TOKEN=unused
ENVEOF
    ok "wrote default $WEB_DIR/.env"
else
    ok ".env exists (not overwriting)"
fi

# The compose file declares `workflow-system-network` as `external: true`,
# so docker won't create it for us.
if ! docker network inspect workflow-system-network >/dev/null 2>&1; then
    docker network create workflow-system-network >/dev/null
    ok "created docker network workflow-system-network"
else
    ok "docker network workflow-system-network exists"
fi

# ----------------------------------------------------------------------------
# Bring up the stack
# ----------------------------------------------------------------------------

step "docker compose up --build (this may take several minutes on first run)"
docker compose -f "$WEB_DIR/docker-compose.yml" --project-directory "$WEB_DIR" up -d --build

# ----------------------------------------------------------------------------
# Wait for everything healthy
# ----------------------------------------------------------------------------

step "Waiting for services to report healthy"

services=(portoser-postgres portoser-redis portoser-keycloak portoser-api portoser-ui)
deadline=$(( $(date +%s) + 300 ))   # 5-minute hard cap
for svc in "${services[@]}"; do
    while true; do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "missing")
        case "$status" in
            healthy) ok "$svc"; break ;;
            missing|"")
                if [ "$(date +%s)" -gt "$deadline" ]; then die "$svc never appeared"; fi
                sleep 2
                ;;
            unhealthy)
                docker logs --tail 30 "$svc" >&2 || true
                die "$svc reported unhealthy — see logs above"
                ;;
            *)
                if [ "$(date +%s)" -gt "$deadline" ]; then
                    docker logs --tail 30 "$svc" >&2 || true
                    die "$svc still '$status' after 5 minutes"
                fi
                sleep 3
                ;;
        esac
    done
done

# ----------------------------------------------------------------------------
# Smoke-test
# ----------------------------------------------------------------------------

step "Smoke-tests"

# /ping (no auth)
ping_status=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://localhost:8988/ping || echo "000")
if [ "$ping_status" = "200" ]; then
    ok "backend /ping"
else
    die "backend /ping returned $ping_status"
fi

# Frontend
ui_status=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://localhost:8989/ || echo "000")
if [ "$ui_status" = "200" ]; then
    ok "frontend /"
else
    die "frontend / returned $ui_status"
fi

# Login + token + protected endpoint
TOKEN=$(curl -s -m 10 -X POST http://localhost:8988/api/auth/login \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin"}' \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && [ "${#TOKEN}" -gt 100 ]; then
    me_status=$(curl -s -o /dev/null -m 5 -w "%{http_code}" \
                -H "Authorization: Bearer $TOKEN" http://localhost:8988/api/auth/me || echo "000")
    if [ "$me_status" = "200" ]; then
        ok "login + bearer auth (admin/admin)"
    else
        warn "login OK but /api/auth/me returned $me_status"
    fi
else
    warn "login failed — Keycloak may still be initializing; rerun if so"
fi

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------

cat <<BANNER

${GREEN}========================================${NC}
${GREEN} Portoser Web — local dev stack is up   ${NC}
${GREEN}========================================${NC}

  ${BLUE}Frontend  ${NC}  http://localhost:8989
  ${BLUE}Backend   ${NC}  http://localhost:8988
  ${BLUE}API docs  ${NC}  http://localhost:8988/docs
  ${BLUE}OpenAPI   ${NC}  http://localhost:8988/openapi.json
  ${BLUE}Keycloak  ${NC}  http://localhost:8990  (admin: keycloak-admin / keycloak-admin)
  ${BLUE}Postgres  ${NC}  localhost:8985        (portoser_user / portoser-local-dev-password)
  ${BLUE}Redis     ${NC}  localhost:8987

  ${YELLOW}Test users (in realm "secure-apps"):${NC}
    admin  / admin    (roles: admin, viewer)
    viewer / viewer   (roles: viewer)

  ${YELLOW}Stop:${NC}    docker compose -f web/docker-compose.yml --project-directory web down
  ${YELLOW}Reset:${NC}   docker compose -f web/docker-compose.yml --project-directory web down -v
            (drops postgres, redis, keycloak data; next dev-up.sh re-imports realm)

BANNER
