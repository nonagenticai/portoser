#!/bin/sh
# =============================================================================
# fakehost-entrypoint — boots sshd + dockerd in parallel, then deploys the
# host's seed services.
#
# Order matters: sshd starts FIRST so portoser-api can SSH in (and probe
# port 22) immediately — without waiting for dockerd init or image pulls.
# dockerd starts in parallel; the seed compose runs once the daemon is ready.
#
# tini (PID 1, set by Dockerfile ENTRYPOINT) reaps zombies and forwards
# SIGTERM. The script blocks on dockerd; if it dies the container exits.
# =============================================================================
set -eu

log() { printf '[fakehost %s] %s\n' "$(hostname)" "$*"; }

# ---- 1. Authorized keys ----------------------------------------------------
if [ -f /run/portoser/authorized_keys ]; then
    install -o portoser -g portoser -m 600 \
        /run/portoser/authorized_keys /home/portoser/.ssh/authorized_keys
    log "installed authorized_keys"
else
    log "WARN: no /run/portoser/authorized_keys — sshd will refuse all logins"
fi

# ---- 2. dockerd daemon.json ------------------------------------------------
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["http://${REGISTRY_MIRROR_HOST:-demo-mirror}:5000"]
}
EOF

# ---- 3. sshd (foreground sub-process via -D in background) ------------------
# Run sshd in the background so portoser-api can SSH in immediately, even
# while dockerd is still starting and images are still pulling.
log "starting sshd on :22 (key-auth only, user 'portoser')"
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# ---- 4. dockerd ------------------------------------------------------------
log "starting dockerd"
dockerd > /var/log/dockerd.log 2>&1 &
DOCKERD_PID=$!

# ---- 5. wait for dockerd, then deploy seed services ------------------------
i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1))
    if [ $i -ge 90 ]; then
        log "dockerd never became ready — last 40 lines:"
        tail -n 40 /var/log/dockerd.log >&2 || true
        kill "$DOCKERD_PID" "$SSHD_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done
log "dockerd ready after ${i}s"

if [ -f /srv/services.yml ]; then
    log "deploying seed services from /srv/services.yml (this can take a while on first run)"
    if docker compose -f /srv/services.yml up -d --remove-orphans 2>&1 | sed 's/^/[seed] /'; then
        log "seed compose up"
    else
        log "WARN: seed compose returned non-zero — fleet-up.sh's reconcile pass will retry"
    fi
else
    log "no /srv/services.yml — host will appear empty in the registry"
fi

# ---- 6. block on dockerd; tini will reap when this exits ---------------------
log "ready"
wait "$DOCKERD_PID"
