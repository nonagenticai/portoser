#!/usr/bin/env python3
# =============================================================================
# seed-data.py — populate ~/.portoser/{deployments,knowledge,metrics_snapshots}
# with believable demo data so every UI surface renders something on first
# click instead of "No data".
#
# What it writes (all idempotent — re-runs replace):
#   ~/.portoser/deployments/<id>.json       30 deployment records spread over
#                                           the last 7 days, mixed status, mixed
#                                           services. Read by:
#                                             /api/history/deployments
#                                             /api/history/stats
#                                             /api/history/deployments/{id}
#
#   ~/.portoser/knowledge/problem_frequency.txt
#                                           ~150 pipe-separated lines feeding:
#                                             /api/diagnostics/problems/frequency
#                                             /api/knowledge/insights/<service>
#                                             /api/knowledge/stats
#
#   ~/.portoser/knowledge/patterns_history/<id>.json
#                                           ~25 applied-solution records.
#                                           Counted into ServiceInsights
#                                           solutions_applied.
#
#   ~/.portoser/knowledge/playbooks/*.md    8 additional playbooks beyond the
#                                           example one dev-up.sh seeds.
#                                           Read by:
#                                             /api/knowledge/playbooks
#
#   ~/.portoser/metrics_snapshots/snapshot_<ts>.json
#                                           60 snapshots (last hour, 1/minute)
#                                           for every (service, machine) so
#                                             /api/metrics/<svc>/<machine>?timeRange=1h
#                                           returns a non-empty time series.
#
# The fleet's registry.demo-cluster.yml drives which services / machines /
# arches we generate against — keep them in sync.
# =============================================================================
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import random
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
REGISTRY_PATH = HERE / "registry.demo-cluster.yml"

# (service, host) pairs hardcoded so this script has no PyYAML dependency.
# Source of truth is registry.demo-cluster.yml — keep this in sync if you add
# or move services. Listed in registry order so deployment-history sample
# rotates through them deterministically.
SERVICE_PAIRS: list[tuple[str, str]] = [
    ("jellyfin", "mac-mini"),
    ("homepage", "mac-mini"),
    ("gitea", "desktop-pc"),
    ("postgres", "desktop-pc"),
    ("redis", "desktop-pc"),
    ("go-fileserver", "desktop-pc"),
    ("pihole", "raspi-4"),
    ("homeassistant", "raspi-4"),
    ("python-sensors", "raspi-4"),
    ("vaultwarden", "synology-nas"),
    ("filebrowser", "synology-nas"),
    ("node-recipes", "synology-nas"),
    ("n8n", "framework-laptop"),
    ("uptime-kuma", "framework-laptop"),
    ("prometheus", "intel-nuc"),
    ("grafana", "intel-nuc"),
    ("caddy", "intel-nuc"),
]

# Deterministic data — same demo every run
random.seed(20260503)


def utcnow_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso(ts: _dt.datetime) -> str:
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=_dt.timezone.utc)
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def short_id(*parts) -> str:
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()[:12]


# ---------------------------------------------------------------------------
# Registry → (service, machine) pairs
# ---------------------------------------------------------------------------
def load_pairs() -> list[tuple[str, str]]:
    return list(SERVICE_PAIRS)


# ---------------------------------------------------------------------------
# Deployments
# ---------------------------------------------------------------------------
PROBLEM_CATALOG = [
    ("port_conflict", "Port already in use; another process bound first"),
    ("image_pull_failed", "Failed to pull image from registry"),
    ("insufficient_memory", "Container OOMKilled; raise memory limit"),
    ("network_unreachable", "Service couldn't reach upstream dependency"),
    ("permission_denied", "Volume mounted with wrong UID/GID"),
    ("dns_resolution", "Hostname did not resolve inside container"),
    ("disk_full", "Build cache filled the disk; pruned and retried"),
    ("config_invalid", "docker-compose.yml syntax error blocked deploy"),
]
SOLUTION_CATALOG = [
    ("kill_blocking_pid", "Stopped the conflicting process before retrying"),
    ("clear_image_cache", "docker system prune -af; re-pulled fresh"),
    ("raise_memory_limit", "Bumped mem_limit from 512m to 1g"),
    ("retry_with_backoff", "Restarted container after dependency healthy"),
    ("fix_volume_perms", "chown -R 1000:1000 on host-side volume"),
    ("flush_dns_cache", "Restarted host's resolved/dnsmasq"),
]


def gen_deployment(service: str, machine: str, when: _dt.datetime, idx: int) -> dict:
    # Pick action and status with realistic mix.
    action = random.choices(
        ["deploy", "restart", "rollback", "migrate"],
        weights=[55, 30, 5, 10],
    )[0]
    status = random.choices(
        ["success", "success", "success", "failure", "rolled_back"],
        weights=[70, 70, 70, 8, 2],
    )[0]
    duration_ms = random.randint(2_500, 45_000)
    if action == "rollback":
        duration_ms = random.randint(800, 4_000)

    phases = [
        {
            "name": "preflight",
            "status": "success",
            "duration_ms": random.randint(80, 350),
            "metadata": {},
        },
        {
            "name": "pull_image",
            "status": "success",
            "duration_ms": random.randint(400, 5_000),
            "metadata": {},
        },
        {
            "name": "stop_old",
            "status": "success",
            "duration_ms": random.randint(100, 1_500),
            "metadata": {},
        },
        {
            "name": "start_new",
            "status": status,
            "duration_ms": max(duration_ms - 1_000, 500),
            "metadata": {},
        },
        {
            "name": "healthcheck",
            "status": status,
            "duration_ms": random.randint(500, 4_000),
            "metadata": {},
        },
    ]

    problems = []
    solutions = []
    if status != "success":
        prob_type, prob_desc = random.choice(PROBLEM_CATALOG)
        problems.append(
            {
                "fingerprint": prob_type,
                "description": prob_desc,
                "timestamp": iso(when + _dt.timedelta(milliseconds=duration_ms - 500)),
            }
        )
        if status == "rolled_back":
            sol_type, sol_desc = random.choice(SOLUTION_CATALOG)
            solutions.append(
                {
                    "fingerprint": sol_type,
                    "action": sol_type,
                    "result": sol_desc,
                    "timestamp": iso(when + _dt.timedelta(milliseconds=duration_ms)),
                }
            )

    observations = [
        {
            "type": "info",
            "message": f"{action} of {service} on {machine}",
            "severity": "info",
            "timestamp": iso(when),
        }
    ]
    if problems:
        observations.append(
            {
                "type": "warning",
                "message": f"problem detected: {problems[0]['fingerprint']}",
                "severity": "warning",
                "timestamp": problems[0]["timestamp"],
            }
        )

    return {
        "id": short_id(service, machine, idx, when.isoformat()),
        "timestamp": iso(when),
        "service": service,
        "machine": machine,
        "action": action,
        "status": status,
        "duration_ms": duration_ms,
        "phases": phases,
        "observations": observations,
        "problems": problems,
        "solutions_applied": solutions,
        "config_snapshot": {
            "image_tag": f"{service}:demo",
            "ports": [],
        },
        "exit_code": 0 if status == "success" else 1,
    }


def write_deployments(portoser_home: Path, pairs: list[tuple[str, str]]) -> int:
    out = portoser_home / "deployments"
    out.mkdir(parents=True, exist_ok=True)
    # Wipe previously-seeded files so re-runs don't pile up.
    for old in out.glob("*.json"):
        if old.name != "latest.json":
            old.unlink()

    now = _dt.datetime.now(_dt.timezone.utc)
    count = 0
    for i in range(30):
        svc, mach = random.choice(pairs)
        # Spread over the last 7 days, weighted toward recent.
        delta_h = (i / 30) ** 1.4 * (7 * 24)
        when = now - _dt.timedelta(hours=delta_h, minutes=random.randint(0, 59))
        rec = gen_deployment(svc, mach, when, i)
        (out / f"{rec['id']}.json").write_text(json.dumps(rec, indent=2))
        count += 1
    return count


# ---------------------------------------------------------------------------
# Knowledge: problem_frequency.txt + patterns_history/*.json
# ---------------------------------------------------------------------------
def write_problem_frequency(portoser_home: Path, pairs: list[tuple[str, str]]) -> int:
    out = portoser_home / "knowledge" / "problem_frequency.txt"
    out.parent.mkdir(parents=True, exist_ok=True)

    now = _dt.datetime.now(_dt.timezone.utc)
    lines: list[str] = []
    # ~10 entries per service, weighted toward a handful of common problem types.
    services = sorted({s for s, _ in pairs})
    for svc in services:
        for _ in range(random.randint(6, 12)):
            ts = now - _dt.timedelta(
                days=random.randint(0, 30),
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59),
            )
            problem = random.choices(
                [p[0] for p in PROBLEM_CATALOG],
                weights=[40, 25, 12, 10, 5, 3, 3, 2],
            )[0]
            severity = random.choices(
                ["info", "warning", "error"], weights=[30, 50, 20]
            )[0]
            lines.append(f"{iso(ts)}|{problem}|{svc}|{severity}")

    lines.sort(reverse=True)
    out.write_text("\n".join(lines) + "\n")
    return len(lines)


def write_patterns_history(portoser_home: Path, pairs: list[tuple[str, str]]) -> int:
    out = portoser_home / "knowledge" / "patterns_history"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.json"):
        old.unlink()

    now = _dt.datetime.now(_dt.timezone.utc)
    count = 0
    for i in range(25):
        svc, mach = random.choice(pairs)
        prob_type, _ = random.choice(PROBLEM_CATALOG)
        sol_type, sol_desc = random.choice(SOLUTION_CATALOG)
        when = now - _dt.timedelta(hours=random.randint(1, 30 * 24))
        record = {
            "id": short_id("pattern", svc, mach, i),
            "service": svc,
            "machine": mach,
            "timestamp": iso(when),
            "problem": prob_type,
            "solution": sol_type,
            "result": sol_desc,
            "duration_ms": random.randint(200, 5_000),
            "applied_by": "auto",
        }
        (out / f"{record['id']}.json").write_text(json.dumps(record, indent=2))
        count += 1
    return count


# ---------------------------------------------------------------------------
# Knowledge: extra playbooks beyond the dev-up sample
# ---------------------------------------------------------------------------
EXTRA_PLAYBOOKS: list[tuple[str, str]] = [
    (
        "image-pull-fail.md",
        """---
title: Image Pull Failed
category: troubleshooting
tags: [registry, networking, docker]
related_problems: [image_pull_failed]
---

# Image Pull Failed

## Problem Description
`docker compose up` fails with `Error response from daemon: pull access denied`
or a TCP/TLS error against the registry.

## Symptoms
- `pull access denied for <image>` in compose output
- Tag works in browser, fails from this host
- Other services on the same host pull fine

## Solution Pattern
`refresh_registry_credentials_or_clear_cache`

## Stats
- Occurrences: 14
- Success Rate: 92%

## Steps
1. Check the daemon's auth: `cat ~/.docker/config.json | jq .auths`.
2. Re-login if the token is stale: `docker login <registry>`.
3. Prune dangling layers: `docker system prune -af`.
4. Retry the pull explicitly: `docker pull <image>`.
""",
    ),
    (
        "oom-kill.md",
        """---
title: Container OOMKilled
category: troubleshooting
tags: [memory, limits, resources]
related_problems: [insufficient_memory]
---

# Container OOMKilled

## Problem Description
A container repeatedly crashes; `docker inspect` shows
`State.OOMKilled: true`.

## Symptoms
- Service flaps between healthy and exited
- `dmesg | grep -i oom` shows the cgroup OOM kill
- Memory graph hits the limit cleanly before the kill

## Solution Pattern
`raise_memory_limit_then_observe`

## Stats
- Occurrences: 9
- Success Rate: 88%

## Steps
1. Inspect the current limit: `docker inspect <ctr> | jq .[0].HostConfig.Memory`.
2. Raise it 50% in `docker-compose.yml` under `mem_limit:`.
3. `docker compose up -d <svc>` and watch RSS for 24h.
4. If it climbs again, investigate the leak rather than raising further.
""",
    ),
    (
        "tls-handshake.md",
        """---
title: TLS Handshake Failure
category: troubleshooting
tags: [tls, certificates, networking]
related_problems: [network_unreachable]
---

# TLS Handshake Failure

## Problem Description
Service-to-service mTLS fails with
`certificate verify failed: unable to get local issuer certificate`.

## Symptoms
- Curl with `-v` shows `SSL_ERROR_SYSCALL` or `unable to get local issuer`
- Service logs name an upstream by hostname; DNS resolves but TLS won't
- Sister services on the same host succeed

## Solution Pattern
`redistribute_ca_then_restart_caller`

## Stats
- Occurrences: 5
- Success Rate: 100%

## Steps
1. `portoser certificates list` — confirm the upstream's CA cert exists.
2. `portoser certificates deploy ca <calling-service> <machine>`.
3. Restart the caller; do **not** restart the upstream — the cert is fine.
4. Verify with `openssl s_client -connect <upstream>:<port> -CAfile <ca>`.
""",
    ),
    (
        "disk-full.md",
        """---
title: Disk Full Blocking Build
category: troubleshooting
tags: [disk, builds, cache]
related_problems: [disk_full]
---

# Disk Full Blocking Build

## Problem Description
A build fails with `no space left on device`, often during a layer extraction.

## Symptoms
- `df -h` shows `/var/lib/docker` at 100%
- Multiple stale `<none>:<none>` images in `docker images`
- BuildKit cache mounts have not been pruned in a long time

## Solution Pattern
`prune_then_retry`

## Stats
- Occurrences: 7
- Success Rate: 100%

## Steps
1. Identify the worst offender: `docker system df -v | head -40`.
2. Prune: `docker buildx prune -af && docker system prune -af --volumes`.
3. If still tight, drop old images explicitly: `docker images --filter "dangling=true" -q | xargs docker rmi -f`.
4. Re-run the build.
""",
    ),
    (
        "rollback-procedure.md",
        """---
title: Manual Rollback Procedure
category: runbook
tags: [rollback, deploy, recovery]
related_problems: []
---

# Manual Rollback Procedure

## Problem Description
A new deploy ships a regression; you need to revert quickly while keeping the
audit trail intact.

## Solution Pattern
`pin_previous_image_then_redeploy`

## Stats
- Occurrences: 11
- Success Rate: 100%

## Steps
1. `portoser history list <service> --limit 5` — note the previous successful
   deployment id.
2. `portoser history rollback <id> --dry-run` to see exactly what'll change.
3. Run for real: `portoser history rollback <id>`.
4. Verify: `portoser cluster health`.
""",
    ),
    (
        "dns-resolution.md",
        """---
title: DNS Resolution Failures Inside Containers
category: troubleshooting
tags: [dns, networking, containers]
related_problems: [dns_resolution]
---

# DNS Resolution Failures Inside Containers

## Problem Description
A container can ping IPs but `getent hosts <name>` returns nothing.

## Symptoms
- `cat /etc/resolv.conf` is empty or points at an unreachable resolver
- `nslookup <name>` from the host succeeds, from inside the container fails
- Other containers on the same network are fine

## Solution Pattern
`restart_dnsmasq_or_join_correct_network`

## Stats
- Occurrences: 4
- Success Rate: 75%

## Steps
1. Check which network the container is on: `docker inspect <ctr> | jq .[0].NetworkSettings.Networks`.
2. If wrong, recreate joined to the right network in compose.
3. If correct but still failing, restart the host-side dnsmasq.
4. Last-resort: hard-code the hostname in `extra_hosts:`.
""",
    ),
    (
        "permission-denied-volume.md",
        """---
title: Permission Denied on Volume Mount
category: troubleshooting
tags: [volumes, permissions, uid]
related_problems: [permission_denied]
---

# Permission Denied on Volume Mount

## Problem Description
Service writes to a bind-mounted directory and gets `EACCES`, even though the
host directory looks writable.

## Symptoms
- Logs: `open(...): permission denied`
- Container ran as a non-root UID; host dir owned by `root`
- `chmod 777` "fixes" it, which is a smell

## Solution Pattern
`align_uid_then_chown`

## Stats
- Occurrences: 6
- Success Rate: 100%

## Steps
1. Find the in-container UID: `docker exec <ctr> id`.
2. `sudo chown -R <uid>:<gid> <host-dir>` to match it.
3. If the image insists on UID 0, set `user: "0:0"` in compose, but document why.
4. Restart the container; tail the log.
""",
    ),
    (
        "config-syntax.md",
        """---
title: Compose File Failed to Parse
category: troubleshooting
tags: [yaml, compose, config]
related_problems: [config_invalid]
---

# Compose File Failed to Parse

## Problem Description
`docker compose up` aborts with `yaml.scanner.ScannerError` or
`Additional property X is not allowed`.

## Symptoms
- Error message names a line/column
- Other compose files on the same host parse fine
- The change that broke it is recent and small

## Solution Pattern
`yamllint_then_fix`

## Stats
- Occurrences: 3
- Success Rate: 100%

## Steps
1. `yamllint docker-compose.yml` — get the exact column.
2. Common culprits: tab indentation, missing `:`, unquoted YAML 1.1 booleans
   (`yes`/`no`/`on`/`off` without quotes).
3. `docker compose config` to validate after the fix.
4. Commit the fix with a comment explaining what tripped you up.
""",
    ),
]


def write_extra_playbooks(portoser_home: Path) -> int:
    out = portoser_home / "knowledge" / "playbooks"
    out.mkdir(parents=True, exist_ok=True)
    for name, body in EXTRA_PLAYBOOKS:
        (out / name).write_text(body)
    return len(EXTRA_PLAYBOOKS)


# ---------------------------------------------------------------------------
# Metrics snapshots — backfilled time series so charts have shape
# ---------------------------------------------------------------------------
def gen_resource_metrics(
    service: str, machine: str, ts: _dt.datetime, profile: dict[str, float]
) -> dict:
    """Generate one ResourceMetrics payload with a wavy time series."""
    # Per-service jitter and base CPU/memory.
    seed_h = int(hashlib.sha256(service.encode()).hexdigest(), 16)
    phase = (seed_h % 360) / 360.0
    t = ts.timestamp() / 60.0  # per-minute beat
    sine = math.sin(t / 7.0 + phase * 6.28)
    cpu = max(
        0.5, profile["cpu"] + sine * profile["cpu_amp"] + random.uniform(-1.5, 1.5)
    )
    mem = max(20, profile["mem"] + sine * profile["mem_amp"] + random.uniform(-8, 8))

    return {
        "service": service,
        "machine": machine,
        "timestamp": ts.replace(microsecond=0, tzinfo=None).isoformat(),
        "cpu_percent": round(cpu, 2),
        "memory_mb": round(mem, 1),
        "memory_total_mb": profile["mem_total"],
        "disk_gb": round(profile["disk"], 2),
        "disk_total_gb": profile["disk_total"],
        "network_rx_bytes": int(profile["net_base"] + random.randint(0, 1_000_000)),
        "network_tx_bytes": int(profile["net_base"] / 4 + random.randint(0, 250_000)),
    }


# Per-service shape — heavier for media/db, light for tiny services.
PROFILES: dict[str, dict[str, float]] = {
    "jellyfin": {
        "cpu": 18,
        "cpu_amp": 12,
        "mem": 512,
        "mem_amp": 80,
        "mem_total": 4096,
        "disk": 12.4,
        "disk_total": 100,
        "net_base": 5_000_000,
    },
    "homepage": {
        "cpu": 1,
        "cpu_amp": 1,
        "mem": 60,
        "mem_amp": 8,
        "mem_total": 512,
        "disk": 0.1,
        "disk_total": 10,
        "net_base": 200_000,
    },
    "gitea": {
        "cpu": 6,
        "cpu_amp": 6,
        "mem": 256,
        "mem_amp": 40,
        "mem_total": 2048,
        "disk": 3.5,
        "disk_total": 50,
        "net_base": 1_500_000,
    },
    "postgres": {
        "cpu": 4,
        "cpu_amp": 4,
        "mem": 480,
        "mem_amp": 60,
        "mem_total": 4096,
        "disk": 9.8,
        "disk_total": 80,
        "net_base": 400_000,
    },
    "redis": {
        "cpu": 2,
        "cpu_amp": 2,
        "mem": 90,
        "mem_amp": 12,
        "mem_total": 512,
        "disk": 0.2,
        "disk_total": 10,
        "net_base": 600_000,
    },
    "go-fileserver": {
        "cpu": 0.5,
        "cpu_amp": 0.5,
        "mem": 18,
        "mem_amp": 3,
        "mem_total": 256,
        "disk": 0.1,
        "disk_total": 10,
        "net_base": 100_000,
    },
    "pihole": {
        "cpu": 3,
        "cpu_amp": 2,
        "mem": 180,
        "mem_amp": 30,
        "mem_total": 1024,
        "disk": 1.1,
        "disk_total": 20,
        "net_base": 800_000,
    },
    "homeassistant": {
        "cpu": 9,
        "cpu_amp": 6,
        "mem": 380,
        "mem_amp": 50,
        "mem_total": 2048,
        "disk": 2.4,
        "disk_total": 40,
        "net_base": 600_000,
    },
    "python-sensors": {
        "cpu": 0.4,
        "cpu_amp": 0.4,
        "mem": 35,
        "mem_amp": 5,
        "mem_total": 256,
        "disk": 0.05,
        "disk_total": 10,
        "net_base": 150_000,
    },
    "vaultwarden": {
        "cpu": 1,
        "cpu_amp": 1,
        "mem": 85,
        "mem_amp": 10,
        "mem_total": 512,
        "disk": 0.4,
        "disk_total": 10,
        "net_base": 200_000,
    },
    "filebrowser": {
        "cpu": 0.5,
        "cpu_amp": 0.5,
        "mem": 25,
        "mem_amp": 3,
        "mem_total": 256,
        "disk": 0.05,
        "disk_total": 10,
        "net_base": 100_000,
    },
    "node-recipes": {
        "cpu": 0.6,
        "cpu_amp": 0.6,
        "mem": 45,
        "mem_amp": 6,
        "mem_total": 256,
        "disk": 0.05,
        "disk_total": 10,
        "net_base": 120_000,
    },
    "n8n": {
        "cpu": 4,
        "cpu_amp": 4,
        "mem": 320,
        "mem_amp": 50,
        "mem_total": 2048,
        "disk": 1.8,
        "disk_total": 30,
        "net_base": 500_000,
    },
    "uptime-kuma": {
        "cpu": 2,
        "cpu_amp": 1,
        "mem": 130,
        "mem_amp": 15,
        "mem_total": 512,
        "disk": 0.6,
        "disk_total": 10,
        "net_base": 300_000,
    },
    "prometheus": {
        "cpu": 5,
        "cpu_amp": 4,
        "mem": 410,
        "mem_amp": 60,
        "mem_total": 2048,
        "disk": 4.2,
        "disk_total": 60,
        "net_base": 700_000,
    },
    "grafana": {
        "cpu": 3,
        "cpu_amp": 3,
        "mem": 220,
        "mem_amp": 30,
        "mem_total": 1024,
        "disk": 0.9,
        "disk_total": 20,
        "net_base": 400_000,
    },
    "caddy": {
        "cpu": 1,
        "cpu_amp": 1,
        "mem": 70,
        "mem_amp": 10,
        "mem_total": 512,
        "disk": 0.2,
        "disk_total": 10,
        "net_base": 600_000,
    },
}


def write_metrics_snapshots(portoser_home: Path, pairs: list[tuple[str, str]]) -> int:
    out = portoser_home / "metrics_snapshots"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("snapshot_*.json"):
        old.unlink()

    now = _dt.datetime.now(_dt.timezone.utc).replace(second=0, microsecond=0)
    count = 0
    # 60 minute-spaced snapshots over the last hour. Each snapshot is one
    # bundled file containing all (service, machine) entries — matches the
    # shape _read_metrics_history_sync expects.
    for minute in range(60, 0, -1):
        ts = now - _dt.timedelta(minutes=minute)
        # write per-service snapshots (the simpler shape)
        for svc, mach in pairs:
            if svc not in PROFILES:
                continue
            data = {
                "service": svc,
                "machine": mach,
                "current": gen_resource_metrics(svc, mach, ts, PROFILES[svc]),
            }
            snapshot = {
                "timestamp": ts.replace(microsecond=0, tzinfo=None).isoformat(),
                "type": "service",
                "data": data,
            }
            stamp = ts.strftime("%Y%m%d_%H%M%S")
            path = out / f"snapshot_{stamp}_{svc}_{mach}.json"
            path.write_text(json.dumps(snapshot))
            count += 1
    return count


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Seed demo data for portoser fleet.")
    parser.add_argument(
        "--portoser-home",
        default=str(HERE / "state" / "portoser_home"),
        help=(
            "The portoser home dir (the path that PORTOSER_HOME points at, "
            "i.e. the equivalent of ~/.portoser). Seeder writes "
            "<dir>/{deployments,knowledge,metrics_snapshots}/ here. Default: "
            "demo/fleet/state/portoser_home, which web/docker-compose.yml "
            "bind-mounts into portoser-api when fleet-up.sh sets PORTOSER_HOME."
        ),
    )
    parser.add_argument(
        "--skip-metrics-history",
        action="store_true",
        help="Skip writing the 60×17 metrics_snapshots files (fast mode).",
    )
    args = parser.parse_args(argv)
    portoser_home = Path(args.portoser_home).expanduser().resolve()

    pairs = load_pairs()
    print(f"  registry pairs: {len(pairs)}", file=sys.stderr)

    n_dep = write_deployments(portoser_home, pairs)
    print(
        f"  deployments:        {n_dep:>4} files in {portoser_home}/deployments/",
        file=sys.stderr,
    )

    n_freq = write_problem_frequency(portoser_home, pairs)
    print(
        f"  problem_frequency:  {n_freq:>4} lines in problem_frequency.txt",
        file=sys.stderr,
    )

    n_pat = write_patterns_history(portoser_home, pairs)
    print(
        f"  patterns_history:   {n_pat:>4} files in knowledge/patterns_history/",
        file=sys.stderr,
    )

    n_pb = write_extra_playbooks(portoser_home)
    print(
        f"  playbooks:          {n_pb:>4} extra files in knowledge/playbooks/",
        file=sys.stderr,
    )

    if args.skip_metrics_history:
        print("  metrics_snapshots:  (skipped)", file=sys.stderr)
    else:
        n_snap = write_metrics_snapshots(portoser_home, pairs)
        print(
            f"  metrics_snapshots:  {n_snap:>4} files in metrics_snapshots/",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
