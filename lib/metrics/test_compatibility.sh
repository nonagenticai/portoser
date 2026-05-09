#!/usr/bin/env bash
set -euo pipefail

# Cross-Platform Compatibility Test
# Tests metric collection on the current platform

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/platform/detector.sh"
source "$SCRIPT_DIR/lib/metrics/collector.sh"
source "$SCRIPT_DIR/lib/metrics/docker_stats.sh"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test result counters
TESTS_PASSED=0
TESTS_FAILED=0

# Print test header
print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Cross-Platform Metrics Test${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
}

# Print test result
print_result() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"

    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [ "$result" = "FAIL" ]; then
        echo -e "${RED}✗${NC} $test_name"
        if [ -n "$message" ]; then
            echo -e "  ${RED}$message${NC}"
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif [ "$result" = "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $test_name"
        if [ -n "$message" ]; then
            echo -e "  ${YELLOW}$message${NC}"
        fi
    else
        echo -e "  $test_name: $message"
    fi
}

# Test platform detection
test_platform_detection() {
    echo -e "${BLUE}Testing Platform Detection...${NC}"

    local platform
    platform=$(detect_platform)

    if [ -n "$platform" ] && [ "$platform" != "unknown" ]; then
        print_result "Platform Detection" "PASS" "Detected: $platform"
    else
        print_result "Platform Detection" "FAIL" "Could not detect platform"
    fi

    local distro
    distro=$(detect_linux_distro)
    print_result "Distribution Detection" "INFO" "Detected: $distro"

    local cpu_count
    cpu_count=$(get_cpu_count)
    print_result "CPU Count Detection" "INFO" "CPUs: $cpu_count"

    local total_memory
    total_memory=$(get_total_memory_bytes)
    local total_memory_gb
    total_memory_gb=$(echo "scale=2; $total_memory / 1024 / 1024 / 1024" | bc)
    print_result "Memory Detection" "INFO" "Total: ${total_memory_gb}GB"

    echo ""
}

# Test available commands
test_available_commands() {
    echo -e "${BLUE}Testing Available Commands...${NC}"

    # Essential commands
    if has_command docker; then
        print_result "Docker" "PASS"
    else
        print_result "Docker" "WARN" "Not available (optional)"
    fi

    if has_command top; then
        print_result "top" "PASS"
    else
        print_result "top" "FAIL" "Required for CPU monitoring"
    fi

    if has_command ps; then
        print_result "ps" "PASS"
    else
        print_result "ps" "FAIL" "Required for process monitoring"
    fi

    if has_command df; then
        print_result "df" "PASS"
    else
        print_result "df" "FAIL" "Required for disk monitoring"
    fi

    # Platform-specific commands
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            if has_command vm_stat; then
                print_result "vm_stat" "PASS"
            else
                print_result "vm_stat" "WARN" "Fallback will be used"
            fi

            if has_command netstat; then
                print_result "netstat" "PASS"
            else
                print_result "netstat" "WARN" "Network I/O may be limited"
            fi
            ;;
        linux)
            if has_command free; then
                print_result "free" "PASS"
            else
                print_result "free" "WARN" "Using /proc/meminfo fallback"
            fi

            if [ -f /proc/meminfo ]; then
                print_result "/proc/meminfo" "PASS"
            else
                print_result "/proc/meminfo" "FAIL" "Required on Linux"
            fi

            if [ -f /proc/stat ]; then
                print_result "/proc/stat" "PASS"
            else
                print_result "/proc/stat" "WARN" "CPU monitoring may be limited"
            fi

            if [ -f /proc/net/dev ]; then
                print_result "/proc/net/dev" "PASS"
            else
                print_result "/proc/net/dev" "WARN" "Network I/O may be limited"
            fi
            ;;
    esac

    echo ""
}

# Test CPU metrics
test_cpu_metrics() {
    echo -e "${BLUE}Testing CPU Metrics Collection...${NC}"

    local cpu_usage
    cpu_usage=$(get_cpu_usage)

    if [ -n "$cpu_usage" ]; then
        print_result "CPU Usage Collection" "PASS" "Current: ${cpu_usage}%"
    else
        print_result "CPU Usage Collection" "FAIL" "Could not collect CPU metrics"
    fi

    echo ""
}

# Test memory metrics
test_memory_metrics() {
    echo -e "${BLUE}Testing Memory Metrics Collection...${NC}"

    local memory_usage
    memory_usage=$(get_memory_usage)

    local used
    used=$(echo "$memory_usage" | cut -d' ' -f1)
    local total
    total=$(echo "$memory_usage" | cut -d' ' -f2)

    if [ -n "$used" ] && [ -n "$total" ] && [ "$total" != "0" ]; then
        print_result "Memory Usage Collection" "PASS" "Used: ${used}MB / Total: ${total}MB"
    else
        print_result "Memory Usage Collection" "FAIL" "Could not collect memory metrics"
    fi

    echo ""
}

# Test disk metrics
test_disk_metrics() {
    echo -e "${BLUE}Testing Disk Metrics Collection...${NC}"

    local disk_usage
    disk_usage=$(get_disk_usage /)

    local used
    used=$(echo "$disk_usage" | cut -d' ' -f1)
    local total
    total=$(echo "$disk_usage" | cut -d' ' -f2)

    if [ -n "$used" ] && [ -n "$total" ] && [ "$total" != "0" ]; then
        print_result "Disk Usage Collection" "PASS" "Used: ${used}GB / Total: ${total}GB"
    else
        print_result "Disk Usage Collection" "FAIL" "Could not collect disk metrics"
    fi

    echo ""
}

# Test network metrics
test_network_metrics() {
    echo -e "${BLUE}Testing Network I/O Collection...${NC}"

    local network_io
    network_io=$(get_network_io)

    local received
    received=$(echo "$network_io" | cut -d' ' -f1)
    local transmitted
    transmitted=$(echo "$network_io" | cut -d' ' -f2)

    if [ -n "$received" ] && [ -n "$transmitted" ]; then
        local received_mb
        received_mb=$(echo "scale=2; $received / 1024 / 1024" | bc)
        local transmitted_mb
        transmitted_mb=$(echo "scale=2; $transmitted / 1024 / 1024" | bc)
        print_result "Network I/O Collection" "PASS" "RX: ${received_mb}MB / TX: ${transmitted_mb}MB"
    else
        print_result "Network I/O Collection" "WARN" "Limited network metrics available"
    fi

    echo ""
}

# Test Docker stats
test_docker_stats() {
    echo -e "${BLUE}Testing Docker Stats Collection...${NC}"

    if ! has_command docker; then
        print_result "Docker Stats" "WARN" "Docker not available - skipping"
        echo ""
        return
    fi

    if ! docker info >/dev/null 2>&1; then
        print_result "Docker Stats" "WARN" "Docker daemon not running - skipping"
        echo ""
        return
    fi

    # Count running containers
    local container_count
    container_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')

    if [ "$container_count" -gt 0 ]; then
        print_result "Running Containers" "INFO" "Count: $container_count"

        # Try to collect stats
        local stats
        stats=$(get_docker_stats 2>/dev/null)

        if [ -n "$stats" ]; then
            print_result "Docker Stats Collection" "PASS"
        else
            print_result "Docker Stats Collection" "FAIL" "Could not collect container stats"
        fi
    else
        print_result "Docker Stats" "INFO" "No containers running"
    fi

    echo ""
}

# Test system metrics JSON
test_system_metrics_json() {
    echo -e "${BLUE}Testing System Metrics JSON Output...${NC}"

    local json
    json=$(get_system_metrics_json)

    if [ -n "$json" ]; then
        # Basic validation - check if it contains expected fields
        if echo "$json" | grep -q '"cpu_percent"' && \
           echo "$json" | grep -q '"memory"' && \
           echo "$json" | grep -q '"disk"'; then
            print_result "System Metrics JSON" "PASS"
            echo -e "${BLUE}Sample Output:${NC}"
            echo "$json" | head -15
        else
            print_result "System Metrics JSON" "FAIL" "JSON missing expected fields"
        fi
    else
        print_result "System Metrics JSON" "FAIL" "Could not generate JSON"
    fi

    echo ""
}

# Print summary
print_summary() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
    echo -e "${RED}Failed:${NC} $TESTS_FAILED"
    echo ""

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}All critical tests passed!${NC}"
        echo -e "${GREEN}Metrics collection is fully functional on this platform.${NC}"
        return 0
    else
        echo -e "${YELLOW}Some tests failed.${NC}"
        echo -e "${YELLOW}Check the output above for details.${NC}"
        return 1
    fi
}

# Main test execution
main() {
    print_header
    test_platform_detection
    test_available_commands
    test_cpu_metrics
    test_memory_metrics
    test_disk_metrics
    test_network_metrics
    test_docker_stats
    test_system_metrics_json
    print_summary
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
fi
