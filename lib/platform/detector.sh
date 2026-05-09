#!/usr/bin/env bash
set -euo pipefail

# Platform Detection Library
# Detects OS type, distribution, and available commands for cross-platform compatibility

# Detect the platform (macOS, Linux, or unknown)
detect_platform() {
    local uname_output
    uname_output=$(uname -s 2>/dev/null)

    case "$uname_output" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        FreeBSD*|OpenBSD*|NetBSD*)
            echo "bsd"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Detect Linux distribution
detect_linux_distro() {
    local platform
    platform=$(detect_platform)

    if [ "$platform" != "linux" ]; then
        echo "not_linux"
        return 0
    fi

    # Try /etc/os-release first (most modern distributions)
    if [ -f /etc/os-release ]; then
        local distro_id
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

        case "$distro_id" in
            ubuntu|debian|mint|pop)
                echo "ubuntu"
                ;;
            centos|rhel|fedora|rocky|alma)
                echo "centos"
                ;;
            alpine)
                echo "alpine"
                ;;
            arch|manjaro)
                echo "arch"
                ;;
            suse|opensuse*)
                echo "suse"
                ;;
            *)
                echo "$distro_id"
                ;;
        esac
        return 0
    fi

    # Fallback to checking specific files
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/centos-release ]; then
        echo "centos"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    elif [ -f /etc/debian_version ]; then
        echo "ubuntu"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# Check if a command exists
has_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Get platform-specific total memory in bytes
get_total_memory_bytes() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # macOS: use sysctl
            if has_command sysctl; then
                sysctl -n hw.memsize 2>/dev/null || echo "0"
            else
                echo "0"
            fi
            ;;
        linux)
            # Linux: use /proc/meminfo
            if [ -f /proc/meminfo ]; then
                awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0"
            else
                echo "0"
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Get platform-specific CPU count
get_cpu_count() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            if has_command sysctl; then
                sysctl -n hw.ncpu 2>/dev/null || echo "1"
            else
                echo "1"
            fi
            ;;
        linux)
            if has_command nproc; then
                nproc 2>/dev/null || echo "1"
            elif [ -f /proc/cpuinfo ]; then
                grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1"
            else
                echo "1"
            fi
            ;;
        *)
            echo "1"
            ;;
    esac
}

# Detect available metric collection tools
detect_available_tools() {
    local tools=""

    # Docker
    if has_command docker; then
        tools="${tools}docker,"
    fi

    # System monitoring tools
    if has_command top; then
        tools="${tools}top,"
    fi

    if has_command ps; then
        tools="${tools}ps,"
    fi

    if has_command df; then
        tools="${tools}df,"
    fi

    # Platform-specific tools
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            if has_command vm_stat; then
                tools="${tools}vm_stat,"
            fi
            if has_command netstat; then
                tools="${tools}netstat,"
            fi
            ;;
        linux)
            if has_command free; then
                tools="${tools}free,"
            fi
            if [ -f /proc/meminfo ]; then
                tools="${tools}proc,"
            fi
            if has_command ifstat; then
                tools="${tools}ifstat,"
            fi
            ;;
    esac

    # Remove trailing comma
    echo "${tools%,}"
}

# Get platform information as JSON
get_platform_info_json() {
    local platform distro tools cpu_count total_memory

    platform=$(detect_platform)
    distro=$(detect_linux_distro)
    tools=$(detect_available_tools)
    cpu_count=$(get_cpu_count)
    total_memory=$(get_total_memory_bytes)

    cat <<EOF
{
  "platform": "$platform",
  "distro": "$distro",
  "cpu_count": $cpu_count,
  "total_memory_bytes": $total_memory,
  "available_tools": ["${tools//,/\",\"}"]
}
EOF
}

# Export platform variables for use in other scripts
export_platform_vars() {
    PORTOSER_PLATFORM=$(detect_platform)
    PORTOSER_DISTRO=$(detect_linux_distro)
    PORTOSER_CPU_COUNT=$(get_cpu_count)
    PORTOSER_TOTAL_MEMORY=$(get_total_memory_bytes)
    PORTOSER_HAS_DOCKER=$(has_command docker && echo "1" || echo "0")
    PORTOSER_HAS_FREE=$(has_command free && echo "1" || echo "0")
    PORTOSER_HAS_VM_STAT=$(has_command vm_stat && echo "1" || echo "0")
    export PORTOSER_PLATFORM PORTOSER_DISTRO PORTOSER_CPU_COUNT \
           PORTOSER_TOTAL_MEMORY PORTOSER_HAS_DOCKER PORTOSER_HAS_FREE \
           PORTOSER_HAS_VM_STAT
}
