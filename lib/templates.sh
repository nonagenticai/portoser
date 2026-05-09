#!/usr/bin/env bash
# Portoser Template Engine - FOXTROT-1
# YAML-based template management system with variable substitution
# Supports template inheritance, composition, and comprehensive validation

# Guard against multiple sourcing
[[ -n "${_TEMPLATES_SH_LOADED:-}" ]] && return 0
readonly _TEMPLATES_SH_LOADED=1

set -euo pipefail

# Color codes (only declare if not already set)
if [ -z "${TEMPLATE_RED:-}" ]; then
    readonly TEMPLATE_RED='\033[0;31m'
    readonly TEMPLATE_GREEN='\033[0;32m'
    readonly TEMPLATE_YELLOW='\033[1;33m'
    readonly TEMPLATE_BLUE='\033[0;34m'
    readonly TEMPLATE_NC='\033[0m'
fi

# Template engine configuration
readonly TEMPLATE_HOME="${TEMPLATE_HOME:-$(dirname "${BASH_SOURCE[0]}")/../templates}"
readonly TEMPLATE_CACHE_DIR="${TEMPLATE_CACHE_DIR:-./.template-cache}"
readonly TEMPLATE_REGISTRY="${TEMPLATE_REGISTRY:-${TEMPLATE_HOME}/registry.yml}"

# LOADED_TEMPLATES guards against recursive includes; TEMPLATE_CACHE memoizes
# parsed yq lookups. Both must be associative — the previous indexed-array
# declaration silently coerced string keys to 0 (so the cache held one entry
# instead of one per key).
declare -gA LOADED_TEMPLATES=()
declare -gA TEMPLATE_CACHE=()

# Initialize template engine
template_engine_init() {
    mkdir -p "$TEMPLATE_CACHE_DIR"

    # Create registry if it doesn't exist
    if [ ! -f "$TEMPLATE_REGISTRY" ]; then
        cat > "$TEMPLATE_REGISTRY" << 'REGISTRY_EOF'
# Portoser Template Registry
# Automatically managed by template engine

categories:
  backend:
    description: "Backend/API services"
    count: 0
  frontend:
    description: "Frontend/UI applications"
    count: 0
  database:
    description: "Database services"
    count: 0
  infrastructure:
    description: "Infrastructure and platform services"
    count: 0
  plugin:
    description: "Portoser plugins and extensions"
    count: 0

templates: {}
REGISTRY_EOF
    fi

    if [ "$DEBUG" = "1" ]; then
        echo "[TEMPLATE] Engine initialized: $TEMPLATE_HOME" >&2
    fi
}

# Log template operations
template_log() {
    local level="$1"
    shift
    local message="$*"

    case "$level" in
        ERROR)
            echo -e "${TEMPLATE_RED}[TEMPLATE ERROR]${TEMPLATE_NC} $message" >&2
            ;;
        WARN)
            echo -e "${TEMPLATE_YELLOW}[TEMPLATE WARN]${TEMPLATE_NC} $message" >&2
            ;;
        INFO)
            echo -e "${TEMPLATE_BLUE}[TEMPLATE INFO]${TEMPLATE_NC} $message" >&2
            ;;
        SUCCESS)
            echo -e "${TEMPLATE_GREEN}[TEMPLATE OK]${TEMPLATE_NC} $message" >&2
            ;;
        *)
            echo "[TEMPLATE] $message" >&2
            ;;
    esac
}

# Validate template YAML structure
template_validate_metadata() {
    local template_file="$1"
    local errors=()

    if [ ! -f "$template_file" ]; then
        template_log ERROR "Template file not found: $template_file"
        return 1
    fi

    # Parse YAML and validate required fields
    local name version description category

    name=$(yq eval '.name' "$template_file" 2>/dev/null || echo "")
    version=$(yq eval '.version' "$template_file" 2>/dev/null || echo "")
    description=$(yq eval '.description' "$template_file" 2>/dev/null || echo "")
    category=$(yq eval '.category' "$template_file" 2>/dev/null || echo "")

    # Validate required fields
    if [ -z "$name" ]; then
        errors+=("Missing required field: 'name'")
    fi

    if [ -z "$version" ]; then
        errors+=("Missing required field: 'version'")
    elif ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        errors+=("Invalid semantic version format: '$version' (expected: MAJOR.MINOR.PATCH)")
    fi

    if [ -z "$description" ]; then
        errors+=("Missing required field: 'description'")
    fi

    if [ -z "$category" ]; then
        errors+=("Missing required field: 'category'")
    else
        case "$category" in
            backend|frontend|database|infrastructure|plugin)
                ;;
            *)
                errors+=("Invalid category '$category' (must be: backend, frontend, database, infrastructure, or plugin)")
                ;;
        esac
    fi

    # Report errors
    if [ ${#errors[@]} -gt 0 ]; then
        template_log ERROR "Template validation failed: $template_file"
        for error in "${errors[@]}"; do
            echo "  - $error" >&2
        done
        return 1
    fi

    return 0
}

# Parse template YAML and return field value
template_get_field() {
    local template_file="$1"
    local field_path="$2"
    local default="${3:-}"

    local cache_key="${template_file}:${field_path}"

    # Check cache first
    if [[ -v TEMPLATE_CACHE["$cache_key"] ]]; then
        echo "${TEMPLATE_CACHE[$cache_key]}"
        return 0
    fi

    # Parse using yq
    local value
    value=$(yq eval "$field_path" "$template_file" 2>/dev/null || echo "$default")

    # Cache the result
    TEMPLATE_CACHE["$cache_key"]="$value"

    echo "$value"
}

# Substitute variables in content using {{ VAR_NAME }} syntax
template_substitute_variables() {
    local content="$1"
    local -n var_array=$2

    local result="$content"

    for var_name in "${!var_array[@]}"; do
        local var_value="${var_array[$var_name]}"
        # Escape special regex characters in value
        var_value=$(printf '%s\n' "$var_value" | sed -e 's/[\/&]/\\&/g')
        # shellcheck disable=SC2001  # regex with \s* literal-zero-or-more whitespace; not a parameter-expansion case
        result=$(echo "$result" | sed "s|{{\\s*${var_name}\\s*}}|${var_value}|g")
    done

    echo "$result"
}

# Load and parse template configuration
template_load() {
    local template_name="$1"
    local template_path="${TEMPLATE_HOME}/${template_name}"
    local template_file="${template_path}/template.yml"

    # Check for circular dependencies
    if [[ -v LOADED_TEMPLATES["$template_name"] ]]; then
        template_log ERROR "Circular template dependency detected: $template_name"
        return 1
    fi

    if [ ! -f "$template_file" ]; then
        template_log ERROR "Template not found: $template_name"
        template_log ERROR "Expected path: $template_file"
        return 1
    fi

    # Mark as loaded
    LOADED_TEMPLATES["$template_name"]=1

    # Validate metadata
    if ! template_validate_metadata "$template_file"; then
        return 1
    fi

    # Output template data as associative array assignment
    cat "$template_file"

    return 0
}

# List all available templates
template_list() {
    local category="${1:-all}"
    local format="${2:-text}"

    if [ ! -d "$TEMPLATE_HOME" ]; then
        template_log ERROR "Template directory not found: $TEMPLATE_HOME"
        return 1
    fi

    local templates=()
    local json_output=""

    # Find all template.yml files
    while IFS= read -r template_file; do
        local template_dir
        template_dir=$(dirname "$template_file")
        local template_rel_path="${template_dir#"$TEMPLATE_HOME"/}"

        # Skip if in wrong category
        if [ "$category" != "all" ]; then
            local tmpl_category
            tmpl_category=$(yq eval '.category' "$template_file" 2>/dev/null || echo "")
            if [ "$tmpl_category" != "$category" ]; then
                continue
            fi
        fi

        # Parse template metadata
        local name version description tmpl_category author
        name=$(yq eval '.name' "$template_file" 2>/dev/null || echo "")
        version=$(yq eval '.version' "$template_file" 2>/dev/null || echo "")
        description=$(yq eval '.description' "$template_file" 2>/dev/null || echo "")
        tmpl_category=$(yq eval '.category' "$template_file" 2>/dev/null || echo "")
        author=$(yq eval '.author' "$template_file" 2>/dev/null || echo "Unknown")

        if [ "$format" = "json" ]; then
            json_output+=$(cat <<EOF
{
  "name": "$name",
  "version": "$version",
  "category": "$tmpl_category",
  "description": "$description",
  "author": "$author",
  "path": "$template_rel_path"
}
EOF
)
            json_output+=$'\n,'
        else
            templates+=("${name:--}|${version:--}|${tmpl_category:--}|${description:--}")
        fi
    done < <(find "$TEMPLATE_HOME" -name "template.yml" -type f 2>/dev/null | sort)

    if [ "$format" = "json" ]; then
        # Output as JSON array
        if [ -n "$json_output" ]; then
            json_output="${json_output%,}"  # Remove trailing comma
        fi
        echo "[${json_output}]"
    else
        # Output as formatted table
        if [ ${#templates[@]} -eq 0 ]; then
            template_log WARN "No templates found"
            return 1
        fi

        printf "%-30s | %-10s | %-20s | %s\n" "Name" "Version" "Category" "Description"
        printf "%-30s | %-10s | %-20s | %s\n" "$(printf '=%.0s' {1..28})" "$(printf '=%.0s' {1..8})" "$(printf '=%.0s' {1..18})" "$(printf '=%.0s' {1..40})"

        for tmpl in "${templates[@]}"; do
            IFS='|' read -r name version category desc <<< "$tmpl"
            printf "%-30s | %-10s | %-20s | %.40s\n" "$name" "$version" "$category" "$desc"
        done
    fi

    return 0
}

# Display template details
template_show() {
    local template_name="$1"
    local template_path="${TEMPLATE_HOME}/${template_name}"
    local template_file="${template_path}/template.yml"

    if [ ! -f "$template_file" ]; then
        template_log ERROR "Template not found: $template_name"
        return 1
    fi

    # Display template information
    local name version description category author
    name=$(yq eval '.name' "$template_file")
    version=$(yq eval '.version' "$template_file")
    description=$(yq eval '.description' "$template_file")
    category=$(yq eval '.category' "$template_file")
    author=$(yq eval '.author' "$template_file" || echo "Unknown")

    echo "Template: $name"
    echo "Version: $version"
    echo "Category: $category"
    echo "Author: $author"
    echo "Description: $description"
    echo ""

    # Show variables if present
    local var_count
    var_count=$(yq eval '.variables | length' "$template_file" 2>/dev/null || echo 0)
    if [ "$var_count" -gt 0 ]; then
        echo "Variables:"
        yq eval '.variables | to_entries | .[] | "  " + .key + ": " + .value.description' "$template_file"
        echo ""
    fi

    # Show files
    local file_count
    file_count=$(yq eval '.files | length' "$template_file" 2>/dev/null || echo 0)
    if [ "$file_count" -gt 0 ]; then
        echo "Files:"
        yq eval '.files | .[] | "  - " + .' "$template_file"
        echo ""
    fi

    # Show services
    local service_count
    service_count=$(yq eval '.services | length' "$template_file" 2>/dev/null || echo 0)
    if [ "$service_count" -gt 0 ]; then
        echo "Services:"
        yq eval '.services | to_entries | .[] | "  " + .key + ": " + .value.type' "$template_file"
    fi

    return 0
}

# Validate all required variables are provided
template_validate_variables() {
    local template_file="$1"
    local -n provided_vars=$2
    local errors=()

    # Get required variables from template
    local var_list
    var_list=$(yq eval '.variables | keys | .[]' "$template_file" 2>/dev/null || true)

    while IFS= read -r var_name; do
        [ -z "$var_name" ] && continue

        # Check if variable is required
        local is_required
        is_required=$(yq eval ".variables.${var_name}.required" "$template_file" 2>/dev/null || echo "false")

        if [ "$is_required" = "true" ]; then
            if [ -z "${provided_vars[$var_name]:-}" ]; then
                errors+=("Required variable missing: $var_name")
            fi
        fi
    done <<< "$var_list"

    if [ ${#errors[@]} -gt 0 ]; then
        template_log ERROR "Variable validation failed"
        for error in "${errors[@]}"; do
            echo "  - $error" >&2
        done
        return 1
    fi

    return 0
}

# Render template with variables
template_render() {
    local template_name="$1"
    local output_dir="$2"
    # shellcheck disable=SC2034 # nameref consumed by template_validate_variables / template_substitute_variables (passed by name)
    local -n template_vars=$3

    local template_path="${TEMPLATE_HOME}/${template_name}"
    local template_file="${template_path}/template.yml"

    if [ ! -f "$template_file" ]; then
        template_log ERROR "Template not found: $template_name"
        return 1
    fi

    # Validate variables
    if ! template_validate_variables "$template_file" template_vars; then
        return 1
    fi

    # Create output directory
    mkdir -p "$output_dir"

    # Get list of files to copy
    local files
    files=$(yq eval '.files | .[]' "$template_file" 2>/dev/null || true)

    local file_count=0
    while IFS= read -r file_path; do
        [ -z "$file_path" ] && continue

        local src_file="${template_path}/${file_path}"
        local dest_file
        dest_file="${output_dir}/$(basename "$file_path")"

        # Handle template files (.tpl extension)
        if [ "${file_path%.tpl}" != "$file_path" ]; then
            # This is a template file - substitute variables
            if [ -f "$src_file" ]; then
                local content
                content=$(<"$src_file")
                content=$(template_substitute_variables "$content" template_vars)
                echo "$content" > "$dest_file"
            fi
        else
            # Regular file - just copy
            if [ -f "$src_file" ]; then
                cp "$src_file" "$dest_file"
            fi
        fi

        file_count=$((file_count + 1))
    done <<< "$files"

    template_log SUCCESS "Rendered template '$template_name' with $file_count files to $output_dir"
    return 0
}

# Register template in registry
template_register() {
    local template_name="$1"
    local template_path="${TEMPLATE_HOME}/${template_name}"
    local template_file="${template_path}/template.yml"

    if [ ! -f "$template_file" ]; then
        template_log ERROR "Template file not found: $template_file"
        return 1
    fi

    # Validate metadata
    if ! template_validate_metadata "$template_file"; then
        return 1
    fi

    # Get template metadata
    local name version description category
    name=$(yq eval '.name' "$template_file")
    version=$(yq eval '.version' "$template_file")
    description=$(yq eval '.description' "$template_file")
    category=$(yq eval '.category' "$template_file")

    # Update registry
    yq eval ".templates.\"$name\" = {
        \"version\": \"$version\",
        \"category\": \"$category\",
        \"description\": \"$description\",
        \"path\": \"$template_name\",
        \"registered\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"
    }" -i "$TEMPLATE_REGISTRY"

    template_log SUCCESS "Registered template: $name v$version"
    return 0
}

# Export template as tarball
template_export() {
    local template_name="$1"
    local export_path="${2:-.}"

    local template_path="${TEMPLATE_HOME}/${template_name}"

    if [ ! -d "$template_path" ]; then
        template_log ERROR "Template directory not found: $template_path"
        return 1
    fi

    local export_file="${export_path}/${template_name}.tar.gz"

    tar -czf "$export_file" -C "$TEMPLATE_HOME" "$template_name"

    template_log SUCCESS "Exported template to: $export_file"
    return 0
}

# Import template from tarball
template_import() {
    local import_file="$1"

    if [ ! -f "$import_file" ]; then
        template_log ERROR "Import file not found: $import_file"
        return 1
    fi

    # Extract to templates directory
    tar -xzf "$import_file" -C "$TEMPLATE_HOME"

    # Extract template name from tarball
    local template_name
    template_name=$(tar -tzf "$import_file" | head -n 1 | cut -d'/' -f1)

    # Register the imported template
    if ! template_register "$template_name"; then
        return 1
    fi

    template_log SUCCESS "Imported template: $template_name"
    return 0
}

# Clear template cache
template_cache_clear() {
    rm -rf "$TEMPLATE_CACHE_DIR"
    mkdir -p "$TEMPLATE_CACHE_DIR"
    TEMPLATE_CACHE=()
    template_log SUCCESS "Template cache cleared"
    return 0
}

# Get template status and statistics
template_status() {
    echo "Portoser Template Engine Status"
    echo "================================"
    echo ""
    echo "Template Home: $TEMPLATE_HOME"
    echo "Template Registry: $TEMPLATE_REGISTRY"
    echo "Cache Directory: $TEMPLATE_CACHE_DIR"
    echo ""

    # Count templates
    local total=0
    declare -A categories

    while IFS= read -r template_file; do
        local category
        category=$(yq eval '.category' "$template_file" 2>/dev/null || echo "unknown")
        categories["$category"]=$((${categories["$category"]:-0} + 1))
        total=$((total + 1))
    done < <(find "$TEMPLATE_HOME" -name "template.yml" -type f 2>/dev/null)

    echo "Total Templates: $total"
    echo ""
    echo "By Category:"
    for cat in backend frontend database infrastructure plugin; do
        echo "  $cat: ${categories[$cat]:-0}"
    done

    return 0
}

# Export function for use in other scripts
export -f template_engine_init
export -f template_load
export -f template_list
export -f template_show
export -f template_validate_metadata
export -f template_validate_variables
export -f template_render
export -f template_register
export -f template_export
export -f template_import
export -f template_substitute_variables
export -f template_log
export -f template_status
