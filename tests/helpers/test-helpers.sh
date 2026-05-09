#!/bin/bash
# Helper functions for Portoser testing

# Color definitions
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# Assert functions
assert_equals() {
  local expected=$1
  local actual=$2
  local message=${3:-"Assertion failed"}

  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}[PASS]${NC} $message"
    return 0
  else
    echo -e "${RED}[FAIL]${NC} $message"
    echo "  Expected: $expected"
    echo "  Actual: $actual"
    return 1
  fi
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local message=${3:-"Assertion failed"}

  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "${GREEN}[PASS]${NC} $message"
    return 0
  else
    echo -e "${RED}[FAIL]${NC} $message"
    echo "  Expected to contain: $needle"
    echo "  Actual: $haystack"
    return 1
  fi
}

assert_true() {
  local condition=$1
  local message=${2:-"Assertion failed"}

  if $condition; then
    echo -e "${GREEN}[PASS]${NC} $message"
    return 0
  else
    echo -e "${RED}[FAIL]${NC} $message"
    return 1
  fi
}

assert_file_exists() {
  local file=$1
  local message=${2:-"File should exist: $file"}

  if [[ -f "$file" ]]; then
    echo -e "${GREEN}[PASS]${NC} $message"
    return 0
  else
    echo -e "${RED}[FAIL]${NC} $message"
    return 1
  fi
}

assert_command_success() {
  local command=$1
  local message=${2:-"Command should succeed"}

  if eval "$command" &>/dev/null; then
    echo -e "${GREEN}[PASS]${NC} $message"
    return 0
  else
    echo -e "${RED}[FAIL]${NC} $message"
    return 1
  fi
}

# Retry helper
retry() {
  local max_attempts=$1
  local delay=$2
  shift 2
  local command="$@"
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    if eval "$command"; then
      return 0
    fi
    echo "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
  done

  echo "Command failed after $max_attempts attempts"
  return 1
}

# Wait for condition
wait_for() {
  local timeout=$1
  local interval=$2
  shift 2
  local condition="$@"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if eval "$condition"; then
      return 0
    fi
    sleep "$interval"
    ((elapsed += interval))
  done

  echo "Timeout waiting for condition: $condition"
  return 1
}

# Logging helpers
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

# Test execution helpers
run_test() {
  local test_name=$1
  local test_function=$2

  echo ""
  echo "========================================="
  echo "Running: $test_name"
  echo "========================================="

  if $test_function; then
    log_success "Test passed: $test_name"
    return 0
  else
    log_error "Test failed: $test_name"
    return 1
  fi
}
