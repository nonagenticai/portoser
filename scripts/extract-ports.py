#!/usr/bin/env python3
# ==============================================================================
# Extract Ports - Python-based Service Port Extraction
# ==============================================================================
# Purpose: Parse docker-compose.yml and service.yml files to extract port
#          configurations using proper YAML parsing.
#
# Usage:
#     python3 extract-ports.py [SCAN_DIR] [--host-key NAME]
#
#     SCAN_DIR    Directory containing one sub-directory per service.
#                 Defaults to $SCAN_DIR or, if unset, the parent of the
#                 portoser repo root (i.e. the directory holding the repo).
#     --host-key  Key under which results are reported in the output JSON
#                 (defaults to $HOST_KEY or "local").
#
# Output: JSON to stdout, e.g. { "local": { "service/sub": {...}, ... } }
#
# Dependencies: pyyaml (pip install pyyaml)
#
# To produce a cluster-wide snapshot, run this script on every host (e.g.
# `ssh host-x python3 -` < extract-ports.py) and merge the resulting
# dictionaries into a single JSON object keyed by host.
# ==============================================================================

import argparse
import json
import os
import sys
from pathlib import Path

import yaml

def extract_docker_ports(compose_file):
    """Extract ports from docker-compose.yml"""
    try:
        with open(compose_file) as f:
            data = yaml.safe_load(f)

        ports = {}
        if not data or 'services' not in data:
            return ports

        for service_name, service_config in data.get('services', {}).items():
            if 'ports' in service_config:
                for port_mapping in service_config['ports']:
                    if isinstance(port_mapping, str):
                        # Format: "8080:80" or "127.0.0.1:8080:80"
                        parts = port_mapping.split(':')
                        if len(parts) >= 2:
                            # Get the external port (could be second or first element)
                            ext_port = parts[-2] if len(parts) == 3 else parts[0]
                            ports[service_name] = ext_port
                            break
                    elif isinstance(port_mapping, int):
                        ports[service_name] = str(port_mapping)
                        break
        return ports
    except Exception as e:
        return {}

def extract_service_port(service_file):
    """Extract port from service.yml"""
    try:
        with open(service_file) as f:
            data = yaml.safe_load(f)
        return data.get('port', None)
    except:
        return None

def scan_host(host_path, ssh_prefix=None):
    """Scan a host for services"""
    services = {}

    if ssh_prefix:
        # For remote hosts, we'll need to handle this differently
        # For now, skip complex remote scanning
        return services

    movies_dir = Path(host_path)
    if not movies_dir.exists():
        return services

    for item in movies_dir.iterdir():
        if not item.is_dir():
            continue

        service_name = item.name
        if service_name in ['TV', 'node_modules', 'logs', 'scripts', 'presentations_markdown',
                           'actions-runner', 'frontend', 'certs', 'planka-cleanup',
                           'server-certs', 'postgres-ssl-setup', 'docker-compose-templates']:
            continue

        docker_compose = item / 'docker-compose.yml'
        service_yml = item / 'service.yml'

        if docker_compose.exists():
            ports = extract_docker_ports(docker_compose)
            for svc, port in ports.items():
                services[f"{service_name}/{svc}"] = {
                    'type': 'docker',
                    'port': port,
                    'path': str(docker_compose)
                }

        if service_yml.exists():
            port = extract_service_port(service_yml)
            if port:
                services[service_name] = {
                    'type': 'native/local',
                    'port': str(port),
                    'path': str(service_yml)
                }

    return services

def main():
    repo_root = Path(__file__).resolve().parent.parent
    default_scan = os.environ.get("SCAN_DIR") or str(repo_root.parent)

    parser = argparse.ArgumentParser(description="Extract service ports from docker-compose/service.yml files.")
    parser.add_argument("scan_dir", nargs="?", default=default_scan,
                        help="Directory containing service sub-directories (default: parent of portoser repo)")
    parser.add_argument("--host-key", default=os.environ.get("HOST_KEY", "local"),
                        help="Key used in the output JSON to label this host (default: 'local')")
    args = parser.parse_args()

    services = scan_host(args.scan_dir)
    json.dump({args.host_key: services}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
