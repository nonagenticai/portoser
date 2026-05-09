#!/usr/bin/env bash
# repos.sh - Repository library for batch git operations
#
# Provides functions for discovering and managing multiple git repositories
# across a services directory. Supports local and remote operations with
# dry-run mode and colorized output.
#
# Environment Requirements:
#   SERVICES_ROOT - Root directory containing git repositories
#
# Usage:
#   source repos.sh
#   find_all_repos
#   commit_all_repos "Commit message" true false

set -euo pipefail

# Source shared utilities (use local variable to avoid overwriting global SCRIPT_DIR)
_REPOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
source "${_REPOS_LIB_DIR}/utils.sh"

# Default SERVICES_ROOT if not set
SERVICES_ROOT="${SERVICES_ROOT:-.}"

# Global arrays to track repository operations
declare -a FOUND_REPOS=()
declare -a SUCCESS_REPOS=()
declare -a SKIPPED_REPOS=()
declare -a ERROR_REPOS=()

# Counters for operations
SUCCESS_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

# ============================================================================
# find_all_repos() - Find all git repositories under SERVICES_ROOT
# ============================================================================
# Searches for git repositories and populates FOUND_REPOS array
# Arguments: None
# Returns: 0 on success
# ============================================================================
find_all_repos() {
    local root="${1:-.}"
    local search_depth="${2:-3}"

    FOUND_REPOS=()

    if [ ! -d "$root" ]; then
        print_color "$RED" "Error: SERVICES_ROOT directory not found: $root"
        return 1
    fi

    print_color "$BLUE" "Scanning for git repositories in: $root"

    # Find all .git directories up to specified depth
    while IFS= read -r -d '' git_dir; do
        local repo_dir
        repo_dir=$(dirname "$git_dir")
        FOUND_REPOS+=("$repo_dir")
    done < <(find "$root" -maxdepth "$search_depth" -type d -name ".git" -print0 2>/dev/null)

    if [ ${#FOUND_REPOS[@]} -eq 0 ]; then
        print_color "$YELLOW" "No git repositories found in $root"
        return 0
    fi

    print_color "$GREEN" "Found ${#FOUND_REPOS[@]} repositories"
    return 0
}

# ============================================================================
# get_repo_status(repo) - Get git status for a repository
# ============================================================================
# Retrieves the current git status of a repository
# Arguments:
#   repo - Path to the repository
# Returns: 0 if repository has no changes, 1 if it has changes
# Output: Repository status information
# ============================================================================
get_repo_status() {
    local repo="$1"

    if [ ! -d "$repo/.git" ]; then
        print_color "$RED" "Error: Not a git repository: $repo"
        return 1
    fi

    # Verify repo path is safe before changing directory
    if ! cd "$repo" 2>/dev/null; then
        print_color "$RED" "Error: Cannot access repository directory: $repo"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain 2>/dev/null)

    if [ -z "$status_output" ]; then
        return 0  # No changes
    else
        return 1  # Has changes
    fi
}

# ============================================================================
# commit_repo(repo, message, dry_run) - Commit changes to a repository
# ============================================================================
# Stages all changes and creates a commit in the specified repository
# Arguments:
#   repo     - Path to the repository
#   message  - Commit message
#   dry_run  - If "true", show what would be done without making changes
# Returns: 0 on success, 1 on failure
# ============================================================================
commit_repo() {
    local repo="$1"
    local message="$2"
    local dry_run="${3:-false}"

    local repo_name
    repo_name=$(basename "$repo")

    if [ ! -d "$repo/.git" ]; then
        print_color "$RED" "Error: Not a git repository: $repo"
        ERROR_REPOS+=("$repo_name: Not a git repository")
        ((ERROR_COUNT++))
        return 1
    fi

    if ! cd "$repo" 2>/dev/null; then
        print_color "$RED" "Error: Cannot access repository directory: $repo"
        ERROR_REPOS+=("$repo_name: Cannot access directory")
        ((ERROR_COUNT++))
        return 1
    fi

    # Check for changes
    local status_output
    status_output=$(git status --porcelain 2>/dev/null)

    if [ -z "$status_output" ]; then
        print_color "$YELLOW" "  ⊘ No changes to commit"
        SKIPPED_REPOS+=("$repo_name (no changes)")
        ((SKIP_COUNT++))
        return 0
    fi

    # Show changes
    print_color "$YELLOW" "  Changes found:"
    if ! git status --short | sed 's/^/    /'; then
        print_color "$RED" "ERROR: Failed to display git status"
        ERROR_REPOS+=("$repo_name: Failed to display status")
        ((ERROR_COUNT++))
        return 1
    fi

    if [ "$dry_run" = "true" ]; then
        print_color "$YELLOW" "  [DRY RUN] Would commit with message: '$message'"
        SKIPPED_REPOS+=("$repo_name (dry-run)")
        ((SKIP_COUNT++))
        return 0
    fi

    # Stage changes
    if ! git add -A; then
        print_color "$RED" "  ✗ Failed to stage changes"
        ERROR_REPOS+=("$repo_name: Failed to stage changes")
        ((ERROR_COUNT++))
        return 1
    fi

    # Create commit
    if ! git commit -m "$message" 2>/dev/null; then
        print_color "$RED" "  ✗ Failed to create commit"
        ERROR_REPOS+=("$repo_name: Failed to commit")
        ((ERROR_COUNT++))
        return 1
    fi

    print_color "$GREEN" "  ✓ Successfully committed"
    return 0
}

# ============================================================================
# push_repo(repo, dry_run) - Push changes to remote repository
# ============================================================================
# Pushes committed changes to the remote repository
# Arguments:
#   repo    - Path to the repository
#   dry_run - If "true", show what would be done without making changes
# Returns: 0 on success, 1 on failure
# ============================================================================
push_repo() {
    local repo="$1"
    local dry_run="${2:-false}"

    local repo_name
    repo_name=$(basename "$repo")

    if [ ! -d "$repo/.git" ]; then
        print_color "$RED" "Error: Not a git repository: $repo"
        ERROR_REPOS+=("$repo_name: Not a git repository")
        ((ERROR_COUNT++))
        return 1
    fi

    if ! cd "$repo" 2>/dev/null; then
        print_color "$RED" "Error: Cannot access repository directory: $repo"
        ERROR_REPOS+=("$repo_name: Cannot access directory")
        ((ERROR_COUNT++))
        return 1
    fi

    if [ "$dry_run" = "true" ]; then
        print_color "$YELLOW" "  [DRY RUN] Would push to remote"
        return 0
    fi

    if ! git push 2>/dev/null; then
        print_color "$RED" "  ✗ Failed to push to remote"
        print_color "$YELLOW" "  ⚠ You may need to pull and merge first"
        ERROR_REPOS+=("$repo_name: Failed to push (may need to pull first)")
        ((ERROR_COUNT++))
        return 1
    fi

    print_color "$GREEN" "  ✓ Successfully pushed"
    return 0
}

# ============================================================================
# commit_all_repos(message, push, dry_run) - Batch commit/push operations
# ============================================================================
# Processes multiple repositories with optional push to remote
# Arguments:
#   message - Commit message to use for all repositories
#   push    - If "true", also push changes to remote (default: true)
#   dry_run - If "true", show what would be done (default: false)
# Returns: 0 on success, 1 if any repository fails
# ============================================================================
commit_all_repos() {
    local message="$1"
    local push="${2:-true}"
    local dry_run="${3:-false}"

    # Reset counters and arrays
    SUCCESS_REPOS=()
    SKIPPED_REPOS=()
    ERROR_REPOS=()
    SUCCESS_COUNT=0
    SKIP_COUNT=0
    ERROR_COUNT=0

    if [ -z "$message" ]; then
        print_color "$RED" "Error: Commit message is required"
        return 1
    fi

    print_color "$BLUE" "======================================"
    print_color "$BLUE" "Starting batch commit operation"
    print_color "$BLUE" "Message: $message"
    print_color "$BLUE" "Push to remote: $push"
    if [ "$dry_run" = "true" ]; then
        print_color "$YELLOW" "DRY RUN MODE - No changes will be made"
    fi
    print_color "$BLUE" "======================================"
    echo ""

    # If no repos found, search for them
    if [ ${#FOUND_REPOS[@]} -eq 0 ]; then
        find_all_repos "$SERVICES_ROOT" || return 1
    fi

    # Process each repository
    for repo in "${FOUND_REPOS[@]}"; do
        local repo_name
        repo_name=$(basename "$repo")

        print_color "$BLUE" "Processing: $repo_name ($repo)"

        # Commit changes
        if ! commit_repo "$repo" "$message" "$dry_run"; then
            # Error already recorded in commit_repo
            continue
        fi

        # Push if requested and not dry-run
        if [ "$push" = "true" ] && [ "$dry_run" = "false" ]; then
            if ! push_repo "$repo" "$dry_run"; then
                # Error already recorded in push_repo
                continue
            fi
        fi

        # Record success only if we get here
        SUCCESS_REPOS+=("$repo_name")
        ((SUCCESS_COUNT++))
    done

    # Print summary
    print_summary

    # Return error code if any failures occurred
    if [ $ERROR_COUNT -gt 0 ]; then
        return 1
    fi

    return 0
}

# ============================================================================
# show_repos_status() - Display status of all repositories
# ============================================================================
# Shows the current git status for all found repositories
# Arguments: None
# Returns: 0 on success
# ============================================================================
show_repos_status() {
    print_color "$BLUE" "======================================"
    print_color "$BLUE" "Repository Status Report"
    print_color "$BLUE" "======================================"
    echo ""

    # If no repos found, search for them
    if [ ${#FOUND_REPOS[@]} -eq 0 ]; then
        find_all_repos "$SERVICES_ROOT" || return 1
    fi

    if [ ${#FOUND_REPOS[@]} -eq 0 ]; then
        print_color "$YELLOW" "No repositories found"
        return 0
    fi

    local repos_with_changes=0
    local repos_clean=0

    for repo in "${FOUND_REPOS[@]}"; do
        local repo_name
        repo_name=$(basename "$repo")

        if [ ! -d "$repo/.git" ]; then
            print_color "$RED" "✗ $repo_name - Not a git repository"
            continue
        fi

        if ! cd "$repo" 2>/dev/null; then
            print_color "$RED" "✗ $repo_name - Cannot access directory"
            continue
        fi

        # Get status
        local status_output
        status_output=$(git status --porcelain 2>/dev/null)

        local branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

        if [ -z "$status_output" ]; then
            print_color "$GREEN" "✓ $repo_name ($branch) - Clean"
            ((repos_clean++))
        else
            print_color "$YELLOW" "⚠ $repo_name ($branch) - Has changes:"
            # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
            echo "$status_output" | sed 's/^/    /'
            ((repos_with_changes++))
        fi
        echo ""
    done

    # Print summary
    echo ""
    print_color "$BLUE" "======================================"
    print_color "$BLUE" "Summary"
    print_color "$BLUE" "======================================"
    print_color "$GREEN" "Clean repositories: $repos_clean"
    print_color "$YELLOW" "Repositories with changes: $repos_with_changes"
    print_color "$BLUE" "Total repositories: $((repos_clean + repos_with_changes))"

    return 0
}

# ============================================================================
# print_summary() - Print operation summary
# ============================================================================
# Internal function to print a summary of operations performed
# ============================================================================
print_summary() {
    echo ""
    print_color "$BLUE" "======================================"
    print_color "$BLUE" "Summary"
    print_color "$BLUE" "======================================"
    print_color "$GREEN" "Successfully processed: $SUCCESS_COUNT"
    print_color "$YELLOW" "Skipped: $SKIP_COUNT"
    print_color "$RED" "Errors: $ERROR_COUNT"
    echo ""

    if [ ${#SUCCESS_REPOS[@]} -gt 0 ]; then
        print_color "$GREEN" "Successful repositories:"
        for repo in "${SUCCESS_REPOS[@]}"; do
            print_color "$GREEN" "  ✓ $repo"
        done
        echo ""
    fi

    if [ ${#SKIPPED_REPOS[@]} -gt 0 ]; then
        print_color "$YELLOW" "Skipped repositories:"
        for repo in "${SKIPPED_REPOS[@]}"; do
            print_color "$YELLOW" "  ⊘ $repo"
        done
        echo ""
    fi

    if [ ${#ERROR_REPOS[@]} -gt 0 ]; then
        print_color "$RED" "Failed repositories:"
        for repo in "${ERROR_REPOS[@]}"; do
            print_color "$RED" "  ✗ $repo"
        done
        echo ""
    fi

    print_color "$BLUE" "Total processed: $((SUCCESS_COUNT + SKIP_COUNT + ERROR_COUNT))"
}

# ============================================================================
# Helper functions
# ============================================================================

# get_all_repos() - Return array of all found repositories
get_all_repos() {
    printf "%s\n" "${FOUND_REPOS[@]}"
}

# get_repo_count() - Return the total number of found repositories
get_repo_count() {
    echo "${#FOUND_REPOS[@]}"
}

# reset_repos() - Clear all repository arrays and counters
reset_repos() {
    FOUND_REPOS=()
    SUCCESS_REPOS=()
    SKIPPED_REPOS=()
    ERROR_REPOS=()
    SUCCESS_COUNT=0
    SKIP_COUNT=0
    ERROR_COUNT=0
}

# ============================================================================
# Export functions for use in other scripts
# ============================================================================
export -f find_all_repos
export -f get_repo_status
export -f commit_repo
export -f push_repo
export -f commit_all_repos
export -f show_repos_status
export -f get_all_repos
export -f get_repo_count
export -f reset_repos
export -f print_color
