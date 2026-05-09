#!/usr/bin/env bash
# =============================================================================
# fleet-down.sh — undo what fleet-up.sh did.
#
#   - `docker compose down -v` for the fleet stack (drops fakehost containers,
#     dockerd graph volumes, and the registry mirror cache).
#   - Restore web/registry/registry.yml from the .pre-fleet.bak if present.
#   - Remove the operator's ~/.ssh/portoser_demo* and the Include line.
#   - Restart portoser-api so it picks the original registry back up.
# =============================================================================
set -euo pipefail

FLEET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
WEB_DIR="$REPO_ROOT/web"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
step() { printf "${BLUE}==>${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}✓${NC}  %s\n" "$1"; }
warn() { printf "${YELLOW}!! ${NC}%s\n" "$1" >&2; }

PURGE_KEYS=0
for arg in "$@"; do
    case "$arg" in
        --purge-keys) PURGE_KEYS=1 ;;
        -h|--help)
            cat <<EOF
Usage: fleet-down.sh [--purge-keys]

  --purge-keys   Also delete demo/fleet/keys/. Default keeps them so a later
                 fleet-up.sh reuses the same keypair.
EOF
            exit 0 ;;
        *) warn "unknown arg: $arg" ;;
    esac
done

# ---- compose down ----------------------------------------------------------
step "docker compose down -v"
docker compose -f "$FLEET_DIR/compose.fleet.yml" --project-directory "$FLEET_DIR" down -v --remove-orphans || true
ok "fleet stack stopped"

# ---- registry restore ------------------------------------------------------
step "restore web/registry/registry.yml"
if [ -f "$WEB_DIR/registry/registry.yml.pre-fleet.bak" ]; then
    mv "$WEB_DIR/registry/registry.yml.pre-fleet.bak" "$WEB_DIR/registry/registry.yml"
    ok "restored from .pre-fleet.bak"
else
    warn "no .pre-fleet.bak — leaving registry.yml in place"
fi

# Restart portoser-api if it's running so it picks up the restored registry.
if docker inspect -f '{{.State.Status}}' portoser-api 2>/dev/null | grep -q running; then
    docker restart portoser-api >/dev/null
    ok "restarted portoser-api"
fi

# ---- remove SSH wiring -----------------------------------------------------
step "remove operator ~/.ssh wiring"
rm -f "$HOME/.ssh/portoser_demo" "$HOME/.ssh/portoser_demo.pub" "$HOME/.ssh/portoser_demo.config"
if [ -f "$HOME/.ssh/config" ]; then
    grep -v 'Include ~/.ssh/portoser_demo.config' "$HOME/.ssh/config" > "$HOME/.ssh/config.tmp" || true
    mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
fi
ok "wiped portoser_demo entries"

# ---- optionally purge demo keys -------------------------------------------
if [ "$PURGE_KEYS" = "1" ]; then
    rm -rf "$FLEET_DIR/keys"
    ok "purged $FLEET_DIR/keys"
else
    ok "keeping $FLEET_DIR/keys (use --purge-keys to remove)"
fi

cat <<BANNER

${GREEN}Fleet torn down.${NC}
  Web stack still up (use web/docker-compose.yml down to stop it).
  Re-bring up with demo/fleet/fleet-up.sh.
BANNER
