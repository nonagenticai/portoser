#!/usr/bin/env bash
# Portoser Template Commands - FOXTROT-6
# Integration of template system with main CLI

set -euo pipefail

# Source the template engine
# shellcheck source=lib/templates.sh
source "$(dirname "${BASH_SOURCE[0]}")/templates.sh"

# Template command dispatcher
cmd_template() {
    local subcommand="${1:-help}"
    shift || true

    case "$subcommand" in
        list)
            cmd_template_list "$@"
            ;;
        show)
            cmd_template_show "$@"
            ;;
        use)
            cmd_template_use "$@"
            ;;
        create)
            cmd_template_create "$@"
            ;;
        validate)
            cmd_template_validate "$@"
            ;;
        export)
            cmd_template_export "$@"
            ;;
        import)
            cmd_template_import "$@"
            ;;
        status)
            cmd_template_status "$@"
            ;;
        help|--help|-h)
            template_help
            ;;
        *)
            echo "Error: Unknown template command '$subcommand'" >&2
            template_help
            return 1
            ;;
    esac
}

# List available templates
cmd_template_list() {
    local category="all"
    local format="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --category|-c)
                shift
                category="$1"
                ;;
            --json)
                format="json"
                ;;
            --help|-h)
                cat << 'EOF'
Usage: portoser template list [OPTIONS]

List all available templates.

Options:
  --category, -c CATEGORY   Filter by category (backend, frontend, database, infrastructure, plugin)
  --json                    Output as JSON
  --help, -h               Show this help message

Examples:
  portoser template list
  portoser template list --category backend
  portoser template list --category frontend --json
EOF
                return 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                return 1
                ;;
        esac
        shift
    done

    # Initialize template engine
    template_engine_init

    # List templates
    if template_list "$category" "$format"; then
        return 0
    else
        return 1
    fi
}

# Show template details
cmd_template_show() {
    if [ $# -lt 2 ]; then
        cat << 'EOF'
Usage: portoser template show <template-name>

Show details for a specific template.

Arguments:
  <template-name>  Name of the template to display

Example:
  portoser template show fastapi-rest
EOF
        return 1
    fi

    local template_name="$2"

    # Initialize template engine
    template_engine_init

    # Show template
    if template_show "$template_name"; then
        return 0
    else
        return 1
    fi
}

# Use a template to create a new service
cmd_template_use() {
    if [ $# -lt 3 ]; then
        cat << 'EOF'
Usage: portoser template use <template-name> <output-directory> [--var KEY=VALUE]...

Create a new service from a template.

Arguments:
  <template-name>      Name of the template to use
  <output-directory>   Where to create the new service

Options:
  --var KEY=VALUE      Set a template variable (can be used multiple times)
  --interactive, -i    Prompt for all variables
  --help, -h          Show this help message

Examples:
  portoser template use fastapi-rest ./my-api --var APP_NAME=my-api --var PORT=8989
  portoser template use react-spa ./my-ui --interactive
EOF
        return 1
    fi

    local template_name="$2"
    local output_dir="$3"
    shift 3

    # `variables` is consumed by name (nameref) by template_render below.
    # shellcheck disable=SC2034 # passed by name to template_render
    declare -A variables

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --var)
                shift
                local key_value="$1"
                local key="${key_value%=*}"
                local value="${key_value#*=}"
                # shellcheck disable=SC2034 # consumed by template_render via nameref
                variables["$key"]="$value"
                ;;
            --interactive|-i)
                # Interactive prompting was advertised in --help but never wired
                # up. Accept the flag silently to avoid breaking callers that
                # pass it; remove this branch once help text is corrected.
                ;;
            --help|-h)
                cmd_template_use
                return 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                return 1
                ;;
        esac
        shift
    done

    # Initialize template engine
    template_engine_init

    # Render template
    if template_render "$template_name" "$output_dir" variables; then
        echo ""
        echo "Success! Service created in: $output_dir"
        echo ""
        echo "Next steps:"
        echo "  1. Review the created files"
        echo "  2. Add to your registry if needed"
        echo "  3. Deploy using: portoser deploy <MACHINE> <SERVICE>"
        return 0
    else
        return 1
    fi
}

# Create a new template
cmd_template_create() {
    if [ $# -lt 1 ]; then
        cat << 'EOF'
Usage: portoser template create <template-name> [--category CATEGORY] [--description DESC]

Create a new template scaffold.

Arguments:
  <template-name>   Name of the template (e.g., my-custom-api)

Options:
  --category CATEGORY   Template category (backend, frontend, database, infrastructure, plugin)
  --description DESC    Template description
  --help, -h           Show this help message

Examples:
  portoser template create my-api --category backend --description "Custom API service"
EOF
        return 1
    fi

    local template_name="$1"
    shift

    local category="backend"
    local description="Custom template"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --category)
                shift
                if [ $# -gt 0 ]; then
                    category="$1"
                    shift
                else
                    echo "Error: --category requires a value" >&2
                    return 1
                fi
                ;;
            --description)
                shift
                if [ $# -gt 0 ]; then
                    description="$1"
                    shift
                else
                    echo "Error: --description requires a value" >&2
                    return 1
                fi
                ;;
            --help|-h)
                cmd_template_create
                return 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                return 1
                ;;
        esac
    done

    # Initialize template engine
    template_engine_init

    local template_path="${TEMPLATE_HOME}/${template_name}"

    if [ -d "$template_path" ]; then
        echo "Error: Template already exists at $template_path" >&2
        return 1
    fi

    # Create template directory structure
    mkdir -p "$template_path"

    # Create template.yml
    cat > "${template_path}/template.yml" << EOF
name: ${template_name}
version: "0.1.0"
description: "${description}"
author: "$(whoami)"
category: "${category}"
tags: []

# Dependencies required to run this template
requires:
  - service: docker
    min_version: "20.10"

# Template variables that can be customized
variables:
  APP_NAME:
    type: string
    default: "${template_name}"
    description: "Application name"
    required: false

# Files that will be created from this template
files:
  - Dockerfile
  - docker-compose.yml
  - .env.example

# Services defined by this template
services:
  main:
    type: docker
    description: "Main application service"
    port: "8989"
    healthcheck: /health
    depends_on: []

# Template metadata
metadata:
  difficulty: beginner
  estimated_time: "5 minutes"
  use_cases: [microservice, api, web-app]
EOF

    # Create sample files
    cat > "${template_path}/Dockerfile" << 'EOF'
FROM alpine:latest

WORKDIR /app

# Add your application here
COPY . .

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8989/health || exit 1

CMD ["sh", "-c", "echo 'Template needs implementation'"]
EOF

    cat > "${template_path}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  main:
    build: .
    container_name: "{{ APP_NAME }}"
    ports:
      - "8989:8989"
    environment:
      - APP_NAME={{ APP_NAME }}
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8989/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    restart: unless-stopped
EOF

    cat > "${template_path}/.env.example" << 'EOF'
# Application Configuration
APP_NAME=my-application
DEBUG=false
LOG_LEVEL=info
EOF

    echo "Success! Template created at: $template_path"
    echo ""
    echo "Next steps:"
    echo "  1. Edit template.yml to configure your template"
    echo "  2. Add or modify files in the template directory"
    echo "  3. Use template variables with {{ VAR_NAME }} syntax"
    echo "  4. Register template with: portoser template validate $template_name"
    echo "  5. List templates with: portoser template list"

    return 0
}

# Validate a template
cmd_template_validate() {
    if [ $# -lt 2 ]; then
        cat << 'EOF'
Usage: portoser template validate <template-name>

Validate a template and register it if valid.

Arguments:
  <template-name>  Name of the template to validate

Example:
  portoser template validate my-custom-api
EOF
        return 1
    fi

    local template_name="$2"

    # Initialize template engine
    template_engine_init

    local template_path="${TEMPLATE_HOME}/${template_name}"
    local template_file="${template_path}/template.yml"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template file not found at $template_file" >&2
        return 1
    fi

    # Validate metadata
    if template_validate_metadata "$template_file"; then
        # Register the template
        if template_register "$template_name"; then
            echo "Template is valid and registered successfully"
            return 0
        else
            return 1
        fi
    else
        echo "Template validation failed" >&2
        return 1
    fi
}

# Export a template
cmd_template_export() {
    if [ $# -lt 2 ]; then
        cat << 'EOF'
Usage: portoser template export <template-name> [--output OUTPUT_DIR]

Export a template as a tarball for distribution.

Arguments:
  <template-name>  Name of the template to export

Options:
  --output, -o DIR  Output directory (default: current directory)
  --help, -h       Show this help message

Examples:
  portoser template export fastapi-rest
  portoser template export fastapi-rest --output /tmp/templates
EOF
        return 1
    fi

    local template_name="$2"
    shift 2

    local output_dir="."

    while [ $# -gt 0 ]; do
        case "$1" in
            --output|-o)
                shift
                output_dir="$1"
                ;;
            --help|-h)
                cmd_template_export
                return 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                return 1
                ;;
        esac
        shift
    done

    # Initialize template engine
    template_engine_init

    if template_export "$template_name" "$output_dir"; then
        return 0
    else
        return 1
    fi
}

# Import a template
cmd_template_import() {
    if [ $# -lt 2 ]; then
        cat << 'EOF'
Usage: portoser template import <template-file>

Import a template from a tarball.

Arguments:
  <template-file>  Path to the template tarball (.tar.gz)

Example:
  portoser template import fastapi-rest.tar.gz
EOF
        return 1
    fi

    local import_file="$2"

    # Initialize template engine
    template_engine_init

    if template_import "$import_file"; then
        return 0
    else
        return 1
    fi
}

# Show template engine status
cmd_template_status() {
    # Initialize template engine
    template_engine_init

    template_status

    return 0
}

# Help text
template_help() {
    cat << 'EOF'
Usage: portoser template [COMMAND] [OPTIONS]

Manage project templates for rapid service deployment.

Commands:
  list                    List all available templates
  show <name>             Show template details
  use <name> <output>     Create a new service from a template
  create <name>           Create a new template
  validate <name>         Validate and register a template
  export <name>           Export template as tarball
  import <file>           Import template from tarball
  status                  Show template engine status
  help                    Show this help message

Examples:
  portoser template list
  portoser template list --category backend
  portoser template show fastapi-rest
  portoser template use fastapi-rest ./my-api --var APP_NAME=my-api
  portoser template create my-custom-api --category backend

For more help on a specific command:
  portoser template <command> --help
EOF
}

# Export command for use in main CLI
export -f cmd_template
export -f cmd_template_list
export -f cmd_template_show
export -f cmd_template_use
export -f cmd_template_create
export -f cmd_template_validate
export -f cmd_template_export
export -f cmd_template_import
export -f cmd_template_status
