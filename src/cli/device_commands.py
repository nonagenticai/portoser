#!/usr/bin/env python3
"""
Portoser Device Onboarding CLI Commands
Handles device registration, token generation, and device management
"""

import os
import sys
import json
import secrets
import hashlib
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List

# Configuration
PORTOSER_ROOT = Path(__file__).parent.parent.parent
REGISTRY_FILE = PORTOSER_ROOT / "registry.yml"
TOKENS_FILE = PORTOSER_ROOT / ".device_tokens.json"
DEVICES_FILE = PORTOSER_ROOT / ".devices.json"


class Colors:
    """ANSI color codes for terminal output"""
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    RED = "\033[31m"
    CYAN = "\033[36m"


def print_color(text: str, color: str = Colors.RESET):
    """Print colored text to terminal"""
    print(f"{color}{text}{Colors.RESET}")


def load_json_file(filepath: Path) -> Dict:
    """Load JSON file or return empty dict"""
    if filepath.exists():
        with open(filepath, 'r') as f:
            return json.load(f)
    return {}


def save_json_file(filepath: Path, data: Dict):
    """Save data to JSON file"""
    filepath.parent.mkdir(parents=True, exist_ok=True)
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)


def generate_token() -> str:
    """Generate a secure bootstrap token"""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """Create SHA256 hash of token for storage"""
    return hashlib.sha256(token.encode()).hexdigest()


def cmd_onboard_generate_token(args: List[str]):
    """Generate a bootstrap token for device onboarding"""

    # Parse arguments
    expires_hours = 24
    description = ""

    i = 0
    while i < len(args):
        if args[i] == "--expires" and i + 1 < len(args):
            expires_hours = int(args[i + 1])
            i += 2
        elif args[i] == "--description" and i + 1 < len(args):
            description = args[i + 1]
            i += 2
        else:
            i += 1

    # Generate token
    token = generate_token()
    token_hash = hash_token(token)
    expires_at = (datetime.now() + timedelta(hours=expires_hours)).isoformat()

    # Load existing tokens
    tokens_data = load_json_file(TOKENS_FILE)
    if "tokens" not in tokens_data:
        tokens_data["tokens"] = []

    # Store token metadata
    token_entry = {
        "hash": token_hash,
        "created_at": datetime.now().isoformat(),
        "expires_at": expires_at,
        "description": description,
        "used": False
    }
    tokens_data["tokens"].append(token_entry)
    save_json_file(TOKENS_FILE, tokens_data)

    # Display token and instructions
    print_color("\n" + "="*60, Colors.BOLD)
    print_color("  Bootstrap Token Generated", Colors.BOLD + Colors.GREEN)
    print_color("="*60 + "\n", Colors.BOLD)

    print_color(f"Token: {Colors.BOLD}{token}{Colors.RESET}")
    print_color(f"Expires: {expires_at}", Colors.CYAN)
    if description:
        print_color(f"Description: {description}", Colors.CYAN)

    print_color("\n" + "-"*60, Colors.YELLOW)
    print_color("  Onboarding Instructions", Colors.BOLD + Colors.YELLOW)
    print_color("-"*60, Colors.YELLOW)

    # Get controller URL from environment or default
    controller_url = os.environ.get("PORTOSER_CONTROLLER_URL", "https://portoser.example.com")

    onboard_command = f"""
# On the device to be onboarded, run:

curl -fsSL {controller_url}/onboard.sh | bash -s -- \\
  --token {token} \\
  --controller {controller_url}

# Or download and inspect first:
curl -fsSL {controller_url}/onboard.sh -o onboard.sh
chmod +x onboard.sh
./onboard.sh --token {token} --controller {controller_url}
"""

    print_color(onboard_command, Colors.CYAN)
    print_color("-"*60 + "\n", Colors.YELLOW)

    print_color(f"Token stored at: {TOKENS_FILE}", Colors.BLUE)
    print_color(f"Token will expire in {expires_hours} hours\n", Colors.RED)


def cmd_device_list(args: List[str]):
    """List all registered devices"""

    devices_data = load_json_file(DEVICES_FILE)
    devices = devices_data.get("devices", [])

    if not devices:
        print_color("No devices registered yet.", Colors.YELLOW)
        return

    print_color("\n" + "="*80, Colors.BOLD)
    print_color("  Registered Devices", Colors.BOLD + Colors.GREEN)
    print_color("="*80 + "\n", Colors.BOLD)

    # Table header
    header = f"{'HOSTNAME':<20} {'STATUS':<12} {'IP ADDRESS':<15} {'REGISTERED':<20}"
    print_color(header, Colors.BOLD + Colors.CYAN)
    print_color("-"*80, Colors.CYAN)

    # Sort by registration date (newest first)
    devices_sorted = sorted(devices, key=lambda d: d.get("registered_at", ""), reverse=True)

    for device in devices_sorted:
        hostname = device.get("hostname", "unknown")[:19]
        status = device.get("status", "unknown")[:11]
        ip_address = device.get("ip_address", "N/A")[:14]
        registered_at = device.get("registered_at", "N/A")[:19]

        # Color status
        status_color = Colors.GREEN if status == "online" else Colors.RED if status == "offline" else Colors.YELLOW
        status_display = f"{status_color}{status}{Colors.RESET}"

        row = f"{hostname:<20} {status_display:<12} {ip_address:<15} {registered_at:<20}"
        print(row)

    print_color("\n" + f"Total devices: {len(devices)}\n", Colors.BLUE)


def cmd_device_status(args: List[str]):
    """Show detailed status for a specific device"""

    if not args:
        print_color("Error: hostname required", Colors.RED)
        print_color("Usage: portoser device status <hostname>", Colors.YELLOW)
        sys.exit(1)

    hostname = args[0]

    devices_data = load_json_file(DEVICES_FILE)
    devices = devices_data.get("devices", [])

    # Find device
    device = None
    for d in devices:
        if d.get("hostname") == hostname:
            device = d
            break

    if not device:
        print_color(f"Error: Device '{hostname}' not found", Colors.RED)
        sys.exit(1)

    # Display device details
    print_color("\n" + "="*60, Colors.BOLD)
    print_color(f"  Device: {hostname}", Colors.BOLD + Colors.GREEN)
    print_color("="*60 + "\n", Colors.BOLD)

    # Basic info
    print_color("Basic Information:", Colors.BOLD + Colors.CYAN)
    print(f"  Hostname:        {device.get('hostname', 'N/A')}")
    print(f"  IP Address:      {device.get('ip_address', 'N/A')}")
    print(f"  Status:          {device.get('status', 'N/A')}")
    print(f"  Registered:      {device.get('registered_at', 'N/A')}")
    print(f"  Last Seen:       {device.get('last_seen', 'N/A')}")

    # System info
    if "system_info" in device:
        print_color("\nSystem Information:", Colors.BOLD + Colors.CYAN)
        sys_info = device["system_info"]
        print(f"  OS:              {sys_info.get('os', 'N/A')}")
        print(f"  Kernel:          {sys_info.get('kernel', 'N/A')}")
        print(f"  Architecture:    {sys_info.get('arch', 'N/A')}")
        print(f"  CPU Cores:       {sys_info.get('cpu_cores', 'N/A')}")
        print(f"  Memory:          {sys_info.get('memory', 'N/A')}")

    # Services
    if "services" in device:
        print_color("\nRunning Services:", Colors.BOLD + Colors.CYAN)
        services = device["services"]
        if services:
            for svc in services:
                print(f"  - {svc.get('name', 'unknown')} ({svc.get('status', 'unknown')})")
        else:
            print("  No services deployed")

    print()

    # Try to ping device
    print_color("Connection Test:", Colors.BOLD + Colors.CYAN)
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2", device.get("ip_address", "")],
            capture_output=True,
            timeout=3
        )
        if result.returncode == 0:
            print_color("  Status: REACHABLE", Colors.GREEN)
        else:
            print_color("  Status: UNREACHABLE", Colors.RED)
    except Exception as e:
        print_color(f"  Status: ERROR ({str(e)})", Colors.RED)

    print()


def main():
    """Main entry point for device commands"""

    if len(sys.argv) < 2:
        print_color("Usage: portoser onboard|device <subcommand> [args]", Colors.YELLOW)
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:] if len(sys.argv) > 2 else []

    if command == "onboard":
        if not args or args[0] == "generate-token":
            cmd_onboard_generate_token(args[1:] if len(args) > 1 else [])
        else:
            print_color(f"Unknown onboard subcommand: {args[0]}", Colors.RED)
            sys.exit(1)

    elif command == "device":
        if not args:
            print_color("Usage: portoser device list|status <hostname>", Colors.YELLOW)
            sys.exit(1)

        subcommand = args[0]
        sub_args = args[1:] if len(args) > 1 else []

        if subcommand == "list":
            cmd_device_list(sub_args)
        elif subcommand == "status":
            cmd_device_status(sub_args)
        else:
            print_color(f"Unknown device subcommand: {subcommand}", Colors.RED)
            sys.exit(1)

    else:
        print_color(f"Unknown command: {command}", Colors.RED)
        sys.exit(1)


if __name__ == "__main__":
    main()
