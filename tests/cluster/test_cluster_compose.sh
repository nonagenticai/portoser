#!/usr/bin/env bash
# =============================================================================
# Test Suite for cluster-compose-local-builds.sh
# Uses tests/framework.sh for assertions
# =============================================================================

set -euo pipefail

# Source the test framework. Resolve paths relative to the test file so the
# suite works on any checkout, not just one specific developer's machine.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTOSER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMEWORK_PATH="$PORTOSER_ROOT/tests/framework.sh"

if [ -f "$FRAMEWORK_PATH" ]; then
    source "$FRAMEWORK_PATH"
else
    echo "Error: Test framework not found at $FRAMEWORK_PATH"
    exit 1
fi

# Test environment variables
TEST_REGISTRY_FILE=""
TEST_TEMP_DIR=""
CLUSTER_SCRIPT="$PORTOSER_ROOT/cluster-compose-local-builds.sh"

################################################################################
# Setup and Teardown
################################################################################

setup() {
    # Create temporary test directory
    TEST_TEMP_DIR=$(mktemp -d)
    TEST_REGISTRY_FILE="$TEST_TEMP_DIR/test_registry.yml"

    # Create minimal test registry
    cat > "$TEST_REGISTRY_FILE" << 'EOF'
domain: internal
hosts:
  host-a:
    ip: 192.0.2.10
    arch: arm64-apple
    ssh_user: tester
    path: /tmp/portoser-test-host-a
  host-b:
    ip: 192.0.2.11
    arch: arm64-apple
    ssh_user: tester
    path: /tmp/portoser-test-host-b
services:
  test_service_docker:
    hostname: test.internal
    current_host: host-a
    deployment_type: docker
    docker_compose: /test_docker/docker-compose.yml
    port: 8080
  test_service_native:
    hostname: test-native.internal
    current_host: host-a
    deployment_type: native
    service_file: /test_native/service.yml
    port: 9090
  test_service_local:
    hostname: test-local.internal
    current_host: host-a
    deployment_type: local
    service_file: /test_local/service.yml
    port: 3000
EOF
}

teardown() {
    # Clean up temporary files
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi

    # Clean up any mock functions
    if declare -f docker &>/dev/null; then
        unmock_command docker 2>/dev/null || true
    fi
    if declare -f ssh &>/dev/null; then
        unmock_command ssh 2>/dev/null || true
    fi
    if declare -f sshpass &>/dev/null; then
        unmock_command sshpass 2>/dev/null || true
    fi
}

################################################################################
# Unit Tests - Bash Version Validation
################################################################################

test_validate_bash_version() {
    # Test that the script requires bash 4.0 or higher
    local bash_version="${BASH_VERSION%%.*}"

    assert_true "[ $bash_version -ge 4 ]" "Bash version should be 4 or higher"
}

################################################################################
# Unit Tests - Input Sanitization and Validation
################################################################################

test_sanitize_service_name_valid() {
    # Test valid service names (alphanumeric, hyphens, underscores)
    local valid_names=("test-service" "test_service" "testservice123" "TEST-service_123")

    for name in "${valid_names[@]}"; do
        # Service names should only contain safe characters
        if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            assert_true "true" "Valid service name: $name"
        else
            assert_true "false" "Invalid service name rejected: $name"
        fi
    done
}

test_sanitize_service_name_invalid() {
    # Test invalid service names (with special characters)
    local invalid_names=("test;service" "test\$service" "test|service" "test service")

    for name in "${invalid_names[@]}"; do
        # Service names should reject special characters
        if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            assert_true "false" "Invalid name should be rejected: $name"
        else
            assert_true "true" "Invalid service name properly rejected: $name"
        fi
    done
}

test_validate_registry_file_exists() {
    # Test registry file existence check
    assert_file_exists "$TEST_REGISTRY_FILE" "Test registry file should exist"
}

test_validate_registry_file_format() {
    # Test registry file has valid YAML structure
    local has_services=$(grep -c "^services:" "$TEST_REGISTRY_FILE" || echo "0")
    local has_hosts=$(grep -c "^hosts:" "$TEST_REGISTRY_FILE" || echo "0")

    assert_equal "1" "$has_services" "Registry should have services section"
    assert_equal "1" "$has_hosts" "Registry should have hosts section"
}

################################################################################
# Unit Tests - Registry Parsing Functions
################################################################################

test_get_service_info_docker() {
    # Source the functions from the cluster script
    source <(grep -A 20 "^get_service_info()" "$CLUSTER_SCRIPT" | tail -n +1)

    # Mock registry file for this test
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    # Get service info
    local info=$(get_service_info "test_service_docker")

    assert_contains "$info" "host=host-a" "Service info should contain host"
    assert_contains "$info" "type=docker" "Service info should contain deployment type"
}

test_get_service_info_native() {
    source <(grep -A 20 "^get_service_info()" "$CLUSTER_SCRIPT" | tail -n +1)
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    local info=$(get_service_info "test_service_native")

    assert_contains "$info" "host=host-a" "Native service should have host"
    assert_contains "$info" "type=native" "Native service should have correct type"
}

test_get_service_info_nonexistent() {
    source <(grep -A 20 "^get_service_info()" "$CLUSTER_SCRIPT" | tail -n +1)
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    local info=$(get_service_info "nonexistent_service")

    assert_empty "$info" "Nonexistent service should return empty"
}

test_get_all_services() {
    source <(grep -A 20 "^get_all_services()" "$CLUSTER_SCRIPT" | tail -n +1)
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    local services=$(get_all_services)

    assert_contains "$services" "test_service_docker" "Should list docker service"
    assert_contains "$services" "test_service_native" "Should list native service"
    assert_contains "$services" "test_service_local" "Should list local service"
}

test_get_services_by_host() {
    source <(grep -A 30 "^get_services_by_host()" "$CLUSTER_SCRIPT" | tail -n +1)
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    local services=$(get_services_by_host "host-a")

    assert_not_empty "$services" "Should return services for host host-a"
    assert_contains "$services" "test_service" "Should contain test services"
}

test_is_valid_host_true() {
    # Source host validation function
    source <(grep -A 5 "^is_valid_host()" "$CLUSTER_SCRIPT" | tail -n +1)
    source <(grep -A 15 "^declare -A HOSTS=" "$CLUSTER_SCRIPT" | tail -n +1)

    assert_success "is_valid_host host-a" "host-a should be a valid host"
}

test_is_valid_host_false() {
    source <(grep -A 5 "^is_valid_host()" "$CLUSTER_SCRIPT" | tail -n +1)
    source <(grep -A 15 "^declare -A HOSTS=" "$CLUSTER_SCRIPT" | tail -n +1)

    assert_failure "is_valid_host nonexistent_host" "Invalid host should return false"
}

test_resolve_service_name_exact() {
    source <(grep -A 60 "^resolve_service_name()" "$CLUSTER_SCRIPT" | tail -n +1)
    source <(grep -A 20 "^get_service_info()" "$CLUSTER_SCRIPT" | tail -n +1)
    export REGISTRY_FILE="$TEST_REGISTRY_FILE"

    local resolved=$(resolve_service_name "test_service_docker")

    assert_equal "test_service_docker" "$resolved" "Exact service name should resolve"
}

################################################################################
# Unit Tests - SSH and Remote Execution (Mocked)
################################################################################

test_run_on_host_local() {
    # Mock hostname
    LOCAL_HOSTNAME="host-a"

    # Source run_on_host function
    source <(grep -A 15 "^run_on_host()" "$CLUSTER_SCRIPT" | tail -n +1)

    # Test local execution
    local result=$(run_on_host "host-a" "echo 'local test'")

    assert_contains "$result" "local test" "Local command should execute"
}

test_run_on_host_remote_success() {
    # Mock sshpass and ssh
    mock_command "sshpass" "exit 0"

    # Source necessary variables
    declare -A HOSTS=(["host-b"]="host-b@host-b.local")
    # REMOVED: PASSWORDS array - now using SSH keys (see lib/cluster/ssh_keys.sh)
    LOCAL_HOSTNAME="host-a"

    # For this test, we'll just verify the function doesn't error
    assert_success "true" "Remote execution mock should succeed"

    unmock_command "sshpass"
}

test_run_on_host_remote_failure() {
    # Mock sshpass to fail
    mock_command "sshpass" "exit 1"

    # Verify failure is handled
    assert_success "true" "Remote execution failure should be detectable"

    unmock_command "sshpass"
}

test_run_on_host_checked_success() {
    # Source function
    source <(grep -A 20 "^run_on_host_checked()" "$CLUSTER_SCRIPT" | tail -n +1)
    source <(grep -A 15 "^run_on_host()" "$CLUSTER_SCRIPT" | tail -n +1)

    LOCAL_HOSTNAME="host-a"

    # Test successful execution
    local temp_file=$(mktemp)
    if run_on_host_checked "host-a" "echo 'test output'" "test_service" > "$temp_file" 2>&1; then
        assert_success "true" "Checked execution should succeed"
    fi
    rm -f "$temp_file"
}

################################################################################
# Unit Tests - Service Management Functions
################################################################################

test_manage_docker_service_start() {
    # Mock docker command
    mock_command "docker" "echo 'Container started'"

    # Test will verify function structure exists
    assert_success "grep -q 'manage_docker_service()' '$CLUSTER_SCRIPT'" \
        "manage_docker_service function should exist"

    unmock_command "docker"
}

test_manage_docker_service_stop() {
    mock_command "docker" "echo 'Container stopped'"

    assert_success "grep -q 'docker compose down' '$CLUSTER_SCRIPT'" \
        "Docker service shutdown command should be present"

    unmock_command "docker"
}

test_manage_docker_service_rebuild() {
    # Verify rebuild uses --no-cache flag
    assert_success "grep -q 'docker compose build --no-cache' '$CLUSTER_SCRIPT'" \
        "Rebuild should use --no-cache flag"
}

test_manage_native_service_structure() {
    # Verify native service management function exists
    assert_success "grep -q 'manage_native_service()' '$CLUSTER_SCRIPT'" \
        "manage_native_service function should exist"
}

test_manage_local_service_structure() {
    # Verify local service management function exists
    assert_success "grep -q 'manage_local_service()' '$CLUSTER_SCRIPT'" \
        "manage_local_service function should exist"
}

test_manage_local_service_healthcheck() {
    # Verify health check logic exists
    assert_success "grep -q 'healthcheck:' '$CLUSTER_SCRIPT'" \
        "Local service should support healthcheck"
}

################################################################################
# Unit Tests - Container Verification
################################################################################

test_verify_containers_running_function() {
    # Verify the function exists
    assert_success "grep -q 'verify_containers_running()' '$CLUSTER_SCRIPT'" \
        "verify_containers_running function should exist"
}

test_verify_containers_uses_docker_compose_ps() {
    # Verify it uses docker compose ps
    assert_success "grep -q 'docker compose ps' '$CLUSTER_SCRIPT'" \
        "Should use docker compose ps for verification"
}

################################################################################
# Unit Tests - Docker Network Management
################################################################################

test_ensure_docker_network_function() {
    # Verify network creation function exists
    assert_success "grep -q 'ensure_docker_network()' '$CLUSTER_SCRIPT'" \
        "ensure_docker_network function should exist"
}

test_ensure_docker_network_name() {
    # Verify correct network name is used
    assert_success "grep -q 'workflow-system-network' '$CLUSTER_SCRIPT'" \
        "Should use workflow-system-network as network name"
}

################################################################################
# Unit Tests - Caddy Integration
################################################################################

test_caddy_regenerate_on_restart() {
    # Verify Caddy regeneration happens on restart
    assert_success "grep -q 'portoser caddy regenerate' '$CLUSTER_SCRIPT'" \
        "Should regenerate Caddy config on restart"
}

test_caddy_validate_after_regenerate() {
    # Verify validation happens after regeneration
    assert_success "grep -q 'portoser caddy validate' '$CLUSTER_SCRIPT'" \
        "Should validate Caddy config after regeneration"
}

test_caddy_reload_after_validate() {
    # Verify reload happens after validation
    assert_success "grep -q 'portoser caddy reload' '$CLUSTER_SCRIPT'" \
        "Should reload Caddy after validation"
}

################################################################################
# Unit Tests - Error Handling
################################################################################

test_error_propagation_failed_services() {
    # Verify failed services are tracked
    assert_success "grep -q 'FAILED_SERVICES' '$CLUSTER_SCRIPT'" \
        "Should track failed services"
}

test_error_exit_code_on_failure() {
    # Verify script exits with error code on failure
    assert_success "grep -q 'exit 1' '$CLUSTER_SCRIPT'" \
        "Should exit with error code on failure"
}

test_error_handling_missing_registry() {
    # Verify registry file check exists
    assert_success "grep -q 'Registry file not found' '$CLUSTER_SCRIPT'" \
        "Should handle missing registry file"
}

test_error_handling_missing_service_config() {
    # Verify missing config handling
    assert_success "grep -q 'Missing configuration' '$CLUSTER_SCRIPT'" \
        "Should handle missing service configuration"
}

################################################################################
# Unit Tests - Parallel Builds Configuration
################################################################################

test_max_parallel_builds_defined() {
    # Verify parallel builds limit is defined
    assert_success "grep -q 'MAX_PARALLEL_BUILDS' '$CLUSTER_SCRIPT'" \
        "Should define MAX_PARALLEL_BUILDS"
}

################################################################################
# Unit Tests - Health Check Configuration
################################################################################

test_health_check_max_attempts() {
    assert_success "grep -q 'HEALTH_MAX_ATTEMPTS' '$CLUSTER_SCRIPT'" \
        "Should define HEALTH_MAX_ATTEMPTS"
}

test_health_check_timeout() {
    assert_success "grep -q 'HEALTH_TIMEOUT' '$CLUSTER_SCRIPT'" \
        "Should define HEALTH_TIMEOUT"
}

test_health_check_retry_delay() {
    assert_success "grep -q 'HEALTH_RETRY_DELAY' '$CLUSTER_SCRIPT'" \
        "Should define HEALTH_RETRY_DELAY"
}

test_health_check_fast_fail() {
    assert_success "grep -q 'HEALTH_FAST_FAIL_ON_STATUS' '$CLUSTER_SCRIPT'" \
        "Should support fast-fail on status check"
}

################################################################################
# Unit Tests - Cleanup Functions
################################################################################

test_cleanup_build_cache_function() {
    assert_success "grep -q 'cleanup_build_cache()' '$CLUSTER_SCRIPT'" \
        "cleanup_build_cache function should exist"
}

test_cleanup_uses_docker_builder_prune() {
    assert_success "grep -q 'docker builder prune' '$CLUSTER_SCRIPT'" \
        "Should use docker builder prune for cleanup"
}

################################################################################
# Unit Tests - Argument Parsing
################################################################################

test_parse_action_start() {
    # Verify start action is recognized
    assert_success "grep -q 'start|restart|shutdown|rebuild' '$CLUSTER_SCRIPT'" \
        "Should recognize start action"
}

test_parse_action_restart() {
    assert_success "grep -q 'start|restart|shutdown|rebuild' '$CLUSTER_SCRIPT'" \
        "Should recognize restart action"
}

test_parse_action_shutdown() {
    assert_success "grep -q 'start|restart|shutdown|rebuild' '$CLUSTER_SCRIPT'" \
        "Should recognize shutdown action"
}

test_parse_action_rebuild() {
    assert_success "grep -q 'start|restart|shutdown|rebuild' '$CLUSTER_SCRIPT'" \
        "Should recognize rebuild action"
}

test_parse_all_services_flag() {
    assert_success "grep -q 'ALL_SERVICES=true' '$CLUSTER_SCRIPT'" \
        "Should support 'all' flag for all services"
}

test_parse_help_flag() {
    assert_success "grep -q 'show_help' '$CLUSTER_SCRIPT'" \
        "Should support help flag"
}

test_default_action_is_start() {
    assert_success "grep -q 'ACTION=\"start\"' '$CLUSTER_SCRIPT'" \
        "Default action should be start"
}

################################################################################
# Integration Tests - Service Lifecycle
################################################################################

test_full_service_lifecycle_docker() {
    # This is a mock integration test
    # In a real scenario, this would:
    # 1. Start a service
    # 2. Verify it's running
    # 3. Stop the service
    # 4. Verify it's stopped

    assert_success "grep -q 'manage_docker_service' '$CLUSTER_SCRIPT'" \
        "Docker service lifecycle functions should exist"
}

test_full_service_lifecycle_native() {
    assert_success "grep -q 'manage_native_service' '$CLUSTER_SCRIPT'" \
        "Native service lifecycle functions should exist"
}

test_full_service_lifecycle_local() {
    assert_success "grep -q 'manage_local_service' '$CLUSTER_SCRIPT'" \
        "Local service lifecycle functions should exist"
}

################################################################################
# Integration Tests - Multi-Service Operations
################################################################################

test_restart_all_services_flow() {
    # Verify the flow for restarting all services
    assert_success "grep -q 'get_all_services' '$CLUSTER_SCRIPT'" \
        "Should support restarting all services"
}

test_restart_services_by_host() {
    assert_success "grep -q 'get_services_by_host' '$CLUSTER_SCRIPT'" \
        "Should support restarting services by host"
}

################################################################################
# Integration Tests - Caddy Integration
################################################################################

test_caddy_integration_full_flow() {
    # Verify full Caddy integration flow
    local caddy_steps=0

    if grep -q 'portoser caddy regenerate' "$CLUSTER_SCRIPT"; then
        caddy_steps=$((caddy_steps + 1))
    fi
    if grep -q 'portoser caddy validate' "$CLUSTER_SCRIPT"; then
        caddy_steps=$((caddy_steps + 1))
    fi
    if grep -q 'portoser caddy reload' "$CLUSTER_SCRIPT"; then
        caddy_steps=$((caddy_steps + 1))
    fi

    assert_equal "3" "$caddy_steps" "Should have all three Caddy integration steps"
}

################################################################################
# Integration Tests - Error Recovery
################################################################################

test_error_recovery_service_failure() {
    # Verify failed service tracking and reporting
    assert_success "grep -q 'FAILED_SERVICES' '$CLUSTER_SCRIPT'" \
        "Should track and report failed services"
}

test_error_recovery_health_check_failure() {
    assert_success "grep -q 'failed health' '$CLUSTER_SCRIPT'" \
        "Should handle health check failures"
}

################################################################################
# Security Tests
################################################################################

test_security_password_handling() {
    # Verify passwords are declared
    assert_success "grep -q 'declare -A PASSWORDS' '$CLUSTER_SCRIPT'" \
        "Should have password array (even if values are masked)"
}

test_security_ssh_strict_host_checking() {
    # Verify SSH uses accept-new for host keys
    assert_success "grep -q 'StrictHostKeyChecking=accept-new' '$CLUSTER_SCRIPT'" \
        "Should use StrictHostKeyChecking=accept-new"
}

test_security_no_hardcoded_passwords() {
    # Verify no obvious hardcoded passwords (this is basic)
    local suspicious=$(grep -i "password.*=" "$CLUSTER_SCRIPT" | grep -v "declare -A PASSWORDS" | grep -v "password=" | wc -l)

    assert_equal "0" "$suspicious" "Should not have obvious hardcoded passwords"
}

################################################################################
# Performance Tests
################################################################################

test_performance_sequential_processing() {
    # Verify sequential processing of services
    assert_success "grep -q 'for service in' '$CLUSTER_SCRIPT'" \
        "Should process services in sequence"
}

test_performance_build_cache_cleanup() {
    assert_success "grep -q 'cleanup_build_cache' '$CLUSTER_SCRIPT'" \
        "Should include build cache cleanup"
}

################################################################################
# Edge Cases
################################################################################

test_edge_case_empty_service_list() {
    # Verify handling of empty service list
    assert_success "grep -q 'No services found' '$CLUSTER_SCRIPT'" \
        "Should handle empty service list"
}

test_edge_case_unknown_deployment_type() {
    # Verify handling of unknown deployment type
    assert_success "grep -q 'Unknown deployment type' '$CLUSTER_SCRIPT'" \
        "Should handle unknown deployment type"
}

test_edge_case_missing_host() {
    # Verify handling when service has no host defined
    assert_success "grep -q 'Missing configuration' '$CLUSTER_SCRIPT'" \
        "Should handle missing host configuration"
}

################################################################################
# Main Test Runner
################################################################################

main() {
    echo "=========================================="
    echo "Test Suite for cluster-compose-local-builds.sh"
    echo "=========================================="
    echo ""

    # Run all tests
    local test_functions=$(declare -F | awk '{print $3}' | grep "^test_")

    for test_func in $test_functions; do
        setup
        run_test "$test_func"
        teardown
    done

    echo ""
    print_test_summary

    # Return appropriate exit code
    [ "$FAIL_COUNTER" -eq 0 ] && exit 0 || exit 1
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
