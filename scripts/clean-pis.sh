#!/usr/bin/env bash
# clean-pis.sh - Clean Pis to keep only runtime essentials
#
# Keeps:  docker-compose.yml, .env, data/, certs/, volumes/
# Removes: source code, .venv, node_modules, build artifacts, .git
#
# Usage:
#   ./clean-pis.sh              # Clean all Pis
#   ./clean-pis.sh pi1          # Clean only pi1
#   ./clean-pis.sh pi1 pi3      # Clean pi1 and pi3
#   ./clean-pis.sh --dry-run    # Show what would be deleted without deleting

set -euo pipefail

# SSH password for the pi accounts. Leave empty (the default) to use
# key-based auth, which is what production deployments should use. Override
# via env (PI_PASSWORD) only when you genuinely need password auth.
PASSWORD="${PI_PASSWORD:-}"
DRY_RUN=false

# Parse arguments
if [ $# -eq 0 ]; then
    PI_LIST=(1 2 3 4)
elif [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    PI_LIST=(1 2 3 4)
else
    PI_LIST=()
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            DRY_RUN=true
        elif [[ "$arg" =~ ^pi([1-4])$ ]]; then
            PI_LIST+=("${BASH_REMATCH[1]}")
        else
            echo "Error: Invalid argument '$arg'. Use: pi1, pi2, pi3, pi4, or --dry-run"
            exit 1
        fi
    done
fi

echo "========================================"
echo "Pi Cleanup Script"
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "MODE: DRY RUN (no files will be deleted)"
else
    echo "MODE: LIVE (files will be deleted)"
fi
echo "Target Pis: $(printf 'pi%s ' "${PI_LIST[@]}")"
echo ""

# Files/directories to KEEP (essentials for running containers).
# This list is documentation: the script enumerates what to DELETE below
# and leaves everything else alone. Kept to make the keep-list reviewable.
# shellcheck disable=SC2034 # documentation-only enumeration
KEEP_PATTERNS=(
    "docker-compose*.yml"
    ".env"
    ".env.*"
    "data"
    "certs"
    "volumes"
    "config"  # Some apps keep runtime config here
)

# Files/directories to DELETE (not needed for runtime)
DELETE_PATTERNS=(
    ".venv"
    "venv"
    "node_modules"
    ".git"
    "__pycache__"
    ".pytest_cache"
    ".mypy_cache"
    "*.pyc"
    ".DS_Store"
    "dist"
    "build"
    ".next"
    "coverage"
    ".coverage"
    "htmlcov"
    "*.egg-info"
    "src"
    "tests"
    "scripts"
    "alembic"
    "*.py"
    "*.ts"
    "*.tsx"
    "*.js"
    "*.jsx"
    "package.json"
    "package-lock.json"
    "pyproject.toml"
    "uv.lock"
    "poetry.lock"
    "Dockerfile"
    "Dockerfile.*"
    ".dockerignore"
    "README.md"
    "*.log"
)

clean_pi() {
    local pi_num=$1
    local pi_name="pi${pi_num}"
    local ssh_host="${pi_name}@${pi_name}.local"
    # Base path on the remote: prefer ${PI_BASE_PATH} (e.g. "portoser") so
    # this isn't hard-coded to one operator's home-directory layout.
    local base_path="/home/${pi_name}/${PI_BASE_PATH:-portoser}"

    echo "----------------------------------------"
    echo "Cleaning ${pi_name}"
    echo "----------------------------------------"

    # Test connection
    echo -n "Testing connection... "
    if ! sshpass -p "$PASSWORD" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$ssh_host" "echo OK" >/dev/null 2>&1; then
        echo "✗ Failed - Skipping ${pi_name}"
        return 1
    fi
    echo "✓ Connected"

    # Get list of service directories
    echo "Getting service directories..."
    local services
    services=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" \
        "ls -1 $base_path 2>/dev/null" || echo "")

    if [ -z "$services" ]; then
        echo "No services found in $base_path"
        return 0
    fi

    echo "Services found:"
    # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
    echo "$services" | sed 's/^/  - /'
    echo ""

    # For each service, show what will be deleted
    for service in $services; do
        echo "  Analyzing $service..."
        local service_path="$base_path/$service"

        # Get size before
        local size_before
        size_before=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" \
            "du -sh $service_path 2>/dev/null | cut -f1" || echo "unknown")

        # Build find command to locate deletable items
        local find_cmd="find $service_path -maxdepth 2 \("
        local first=true
        for pattern in "${DELETE_PATTERNS[@]}"; do
            if [ "$first" = true ]; then
                find_cmd+=" -name '$pattern'"
                first=false
            else
                find_cmd+=" -o -name '$pattern'"
            fi
        done
        find_cmd+=" \) 2>/dev/null"

        # List what will be deleted
        local items
        items=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" "$find_cmd" || echo "")

        if [ -n "$items" ]; then
            echo "    Will delete:"
            echo "$items" | sed "s|${service_path}/||" | sed 's/^/      ✗ /'

            if [ "$DRY_RUN" = false ]; then
                # Delete the items
                sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" \
                    "cd $service_path && rm -rf ${DELETE_PATTERNS[*]}" 2>/dev/null || true

                # Get size after
                local size_after
                size_after=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" \
                    "du -sh $service_path 2>/dev/null | cut -f1" || echo "unknown")

                echo "    Before: $size_before → After: $size_after"
            fi
        else
            echo "    Nothing to delete"
        fi
        echo ""
    done

    # Show final summary
    if [ "$DRY_RUN" = false ]; then
        echo "  Final size:"
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new "$ssh_host" \
            "du -sh $base_path/* 2>/dev/null | sort -h" | sed 's/^/    /'
    fi

    echo "✓ ${pi_name} cleaned"
    echo ""
}

# Clean each Pi
for pi_num in "${PI_LIST[@]}"; do
    clean_pi "$pi_num" || echo "Warning: Failed to clean pi${pi_num}"
done

echo "========================================"
echo "Cleanup Complete"
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "This was a DRY RUN. No files were deleted."
    echo "Run without --dry-run to actually delete files."
fi
echo ""
echo "Pis are now ready to run containers!"
echo "Next steps:"
echo "  1. Build images on a builder host"
echo "  2. Push to registry or save/load to Pis"
echo "  3. Run docker-compose up on each Pi"
