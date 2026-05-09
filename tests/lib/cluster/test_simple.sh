#!/usr/bin/env bash
# Simple integration test for all libraries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"

echo "Testing library imports..."

# Test sourcing each library
for lib in buildx build deploy sync health discovery; do
    echo -n "  Sourcing lib/cluster/${lib}.sh... "
    if source "${LIB_DIR}/${lib}.sh" 2>/dev/null; then
        echo "✓"
    else
        echo "✗ FAILED"
        exit 1
    fi
done

echo ""
echo "Testing basic functions..."

# Test buildx
source "${LIB_DIR}/buildx.sh"
echo -n "  get_buildx_builder_name... "
result=$(get_buildx_builder_name)
[[ "$result" == "portoser-builder" ]] && echo "✓" || { echo "✗"; exit 1; }

# Test sync
source "${LIB_DIR}/sync.sh"
echo -n "  get_sync_excludes... "
result=$(get_sync_excludes | wc -l)
[[ $result -gt 5 ]] && echo "✓" || { echo "✗"; exit 1; }

echo ""
echo "All basic tests passed!"
exit 0
