#!/usr/bin/env python3
# ==============================================================================
# Compare Registry - Registry Verification Tool
# ==============================================================================
# Purpose: Compare the portoser registry.yml against actual services found
#          in the filesystem to identify:
#          - Services in registry but not found in filesystem
#          - Services in filesystem but missing from registry
#          - Port mismatches between registry and actual configuration
#
# Usage: python3 compare-registry.py
#
# Output: Detailed verification report with discrepancies
#
# Dependencies: pyyaml (pip install pyyaml)
#
# Note: Update the actual_services dictionary when running this script
#       after scanning the filesystem with scan scripts
#
# Inputs:
#   * Registry path:  $REGISTRY env var, or <repo>/registry.yml
#   * Actual services snapshot:  $SERVICES_JSON env var pointing at a JSON
#     file with the shape:
#         {
#           "<host_key>": {
#             "<service_name>": {"port": 8080, "type": "docker"},
#             ...
#           },
#           ...
#         }
#     The host keys should match the keys you use in cluster.conf. You can
#     produce this file by running extract-ports.py on each host and merging
#     the JSON output, or by writing it by hand.
# ==============================================================================

import json
import os
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

REGISTRY_PATH = Path(os.environ.get("REGISTRY", REPO_ROOT / "registry.yml"))
SERVICES_JSON = os.environ.get("SERVICES_JSON")

if SERVICES_JSON and Path(SERVICES_JSON).exists():
    with open(SERVICES_JSON) as f:
        actual_services = json.load(f)
else:
    print(
        "[compare-registry] SERVICES_JSON not set or file missing; "
        "comparing against an empty service snapshot.\n"
        "Set SERVICES_JSON=/path/to/services.json to enable filesystem comparison.",
        file=sys.stderr,
    )
    actual_services = {}

if not REGISTRY_PATH.exists():
    print(f"Registry file not found: {REGISTRY_PATH}", file=sys.stderr)
    sys.exit(1)

with open(REGISTRY_PATH) as f:
    registry = yaml.safe_load(f)

# Compare
print("=" * 80)
print("REGISTRY VERIFICATION REPORT")
print("=" * 80)

registered_services = set(registry['services'].keys())
actual_service_names = set()

for host, services in actual_services.items():
    actual_service_names.update(services.keys())

# Services in registry but not in filesystem
print("\n[1] Services in REGISTRY but NOT FOUND in filesystem:")
not_found = registered_services - actual_service_names
if not_found:
    for svc in sorted(not_found):
        reg_info = registry['services'][svc]
        print(f"  - {svc} (host: {reg_info.get('current_host', 'unknown')})")
else:
    print("  None")

# Services in filesystem but not in registry
print("\n[2] Services in FILESYSTEM but NOT in REGISTRY:")
missing = actual_service_names - registered_services
if missing:
    for svc in sorted(missing):
        for host, services in actual_services.items():
            if svc in services:
                print(f"  - {svc} (found on {host}, port {services[svc]['port']})")
else:
    print("  None")

# Port mismatches
print("\n[3] PORT MISMATCHES:")
mismatches = []
for svc_name, svc_data in registry['services'].items():
    current_host = svc_data.get('current_host')
    if current_host in actual_services:
        if svc_name in actual_services[current_host]:
            actual_port = actual_services[current_host][svc_name]['port']
            reg_port = svc_data.get('port')

            # For docker services, check docker_compose for port
            if not reg_port and svc_data.get('deployment_type') == 'docker':
                # Port might be in docker-compose, not explicitly in registry
                print(f"  - {svc_name}: registry has NO explicit port, actual={actual_port}")
                mismatches.append((svc_name, None, actual_port))
            elif reg_port and int(reg_port) != int(actual_port):
                print(f"  - {svc_name}: registry={reg_port}, actual={actual_port}")
                mismatches.append((svc_name, reg_port, actual_port))

if not mismatches and '  -' not in open(__file__).read().split('[3]')[1].split('[4]')[0]:
    print("  None")

print("\n[4] SUMMARY:")
print(f"  Total services in registry: {len(registered_services)}")
print(f"  Total services in filesystem: {len(actual_service_names)}")
print(f"  Port mismatches: {len(mismatches)}")
print()
