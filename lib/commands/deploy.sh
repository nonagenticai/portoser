#!/usr/bin/env bash
################################################################################
# Deploy Command Module
#
# Handles intelligent deployment of services to target machines.
# Automatically detects current locations and handles migrations.
#
# Usage: portoser deploy MACHINE SERVICE [SERVICE...] [OPTIONS]
################################################################################

set -euo pipefail

# Deploy command handler (registry-aware, natural syntax)
cmd_deploy() {
    if [ $# -eq 0 ]; then
        deploy_help
        exit 1
    fi

    # Check for flags
    local dry_run=0
    local auto_heal="--auto-heal"
    local args=()

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                dry_run=1
                ;;
            --no-auto-heal)
                auto_heal=""
                ;;
            --json-output)
                export JSON_OUTPUT_MODE=1
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done

    # Parse deployment arguments
    local deployment_plan
    if ! deployment_plan=$(parse_deploy_args "${args[@]}"); then
        exit 1
    fi

    # Convert to array
    local deployments=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            deployments+=("$line")
        fi
    done <<< "$deployment_plan"

    if [ ${#deployments[@]} -eq 0 ]; then
        print_color "$RED" "Error: No valid deployments found"
        exit 1
    fi

    # Dry run mode
    if [ $dry_run -eq 1 ]; then
        for deployment in "${deployments[@]}"; do
            local service="${deployment%%:*}"
            local target="${deployment##*:}"
            intelligent_deploy_dryrun "$service" "$target"
            echo ""
        done
        exit 0
    fi

    # Show deployment plan
    show_deployment_plan "${deployments[@]}"

    echo ""
    print_color "$BLUE" "Starting intelligent deployments..."
    if [ -n "$auto_heal" ]; then
        print_color "$GREEN" "✓ Auto-healing enabled - problems will be fixed automatically"
    else
        print_color "$YELLOW" "⚠ Auto-healing disabled"
    fi
    echo ""

    # Execute deployments with intelligence
    local failed=0
    for deployment in "${deployments[@]}"; do
        local service="${deployment%%:*}"
        local target="${deployment##*:}"

        if ! intelligent_deploy_service "$service" "$target" "$auto_heal"; then
            failed=$((failed + 1))
        fi
        echo ""
        echo "================================================================"
        echo ""
    done

    # Summary
    echo ""
    if [ $failed -eq 0 ]; then
        print_color "$GREEN" "==========================================="
        print_color "$GREEN" "✓ ALL DEPLOYMENTS COMPLETED SUCCESSFULLY"
        print_color "$GREEN" "==========================================="
    else
        print_color "$RED" "==========================================="
        print_color "$RED" "✗ $failed DEPLOYMENT(S) FAILED"
        print_color "$RED" "==========================================="
        exit 1
    fi
}

# Help function for deploy command
deploy_help() {
    cat <<EOF
Usage: portoser deploy MACHINE SERVICE [SERVICE...] [OPTIONS]

Deploy services to target machines with intelligent resource management.

Options:
  --dry-run        Show what would happen without executing
  --no-auto-heal   Disable automatic problem fixing
  --json-output    Output structured JSON instead of colored text

Examples:
  portoser deploy host-a myservice requirements
  portoser deploy host-a myservice requirements host-b mlx_inference
  portoser deploy host-a requirements --dry-run
  portoser deploy host-a myservice --no-auto-heal

This will deploy myservice and requirements to host-a, and mlx_inference to host-b.
Portoser automatically detects current locations and handles migrations.
Auto-healing is enabled by default.

EOF
}

################################################################################
# End of deploy.sh
################################################################################
