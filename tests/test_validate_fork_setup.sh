#!/bin/bash
# test_validate_fork_setup.sh — Test suite for fork setup validation (11 scenarios)
# 7 fork configuration scenarios + 4 hooksPath resolution scenarios

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="$INTELLISENSE_DIR/scripts/validate-fork-setup.sh"

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temporary test repos
TEMP_DIR="/tmp/test_validate_fork_setup_$$"
mkdir -p "$TEMP_DIR"

# Cleanup on exit
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Helper: Create a test git repo with configured remotes
create_test_repo() {
  local repo_path="$1"
  local origin_url="$2"
  local upstream_url="$3"

  mkdir -p "$repo_path"
  cd "$repo_path" || return 1
  git init -q

  if [ -n "$origin_url" ]; then
    git remote add origin "$origin_url"
  fi
  if [ -n "$upstream_url" ]; then
    git remote add upstream "$upstream_url"
  fi

  cd - > /dev/null
}

# Helper: Run validation and capture output/exit code
run_validation() {
  local repo_path="$1"
  local mode="$2"

  "$VALIDATE_SCRIPT" "$repo_path" "$mode" 2>&1
  return $?
}

# Helper: Assert exit code
assert_exit() {
  local test_name="$1"
  local expected_exit="$2"
  local actual_exit="$3"

  ((TESTS_RUN++))
  if [ "$expected_exit" -eq "$actual_exit" ]; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name (exit $actual_exit)"
    ((TESTS_PASSED++))
    return 0
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name (expected exit $expected_exit, got $actual_exit)"
    ((TESTS_FAILED++))
    return 1
  fi
}

# Helper: Assert output contains string
assert_contains() {
  local test_name="$1"
  local output="$2"
  local expected_string="$3"

  ((TESTS_RUN++))
  if echo "$output" | grep -q "$expected_string"; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    ((TESTS_PASSED++))
    return 0
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name (expected to find: $expected_string)"
    echo "Output: $output"
    ((TESTS_FAILED++))
    return 1
  fi
}

# Helper: Assert output does NOT contain string
assert_not_contains() {
  local test_name="$1"
  local output="$2"
  local unexpected_string="$3"

  ((TESTS_RUN++))
  if ! echo "$output" | grep -q "$unexpected_string"; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    ((TESTS_PASSED++))
    return 0
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name (should not contain: $unexpected_string)"
    echo "Output: $output"
    ((TESTS_FAILED++))
    return 1
  fi
}

echo -e "${BLUE}Fork Configuration Tests (7 scenarios)${NC}"
echo ""

# ===================================================================
# Scenario 1: origin == upstream (misconfigured fork)
# ===================================================================
echo "Test 1: origin == upstream misconfiguration"
test_repo1="$TEMP_DIR/test1"
create_test_repo "$test_repo1" "git@github.com:org/repo.git" "git@github.com:org/repo.git"

output=$(run_validation "$test_repo1" "--strict" 2>&1)
exit_code=$?
assert_exit "Fork misconfiguration detected in --strict mode" 1 $exit_code
assert_contains "Fork misconfiguration output" "$output" "origin == upstream"
echo ""

# ===================================================================
# Scenario 2: Correct fork configuration
# ===================================================================
echo "Test 2: Correct fork configuration (origin != upstream)"
test_repo2="$TEMP_DIR/test2"
create_test_repo "$test_repo2" "git@github.com:user/repo.git" "git@github.com:org/repo.git"

output=$(run_validation "$test_repo2" "--check" 2>&1)
exit_code=$?
assert_exit "Correct fork setup in --check mode" 0 $exit_code
assert_contains "Correct fork output" "$output" "origin != upstream"
assert_contains "Correct fork output" "$output" "PASS"
echo ""

# ===================================================================
# Scenario 3: Missing upstream remote (warn only)
# ===================================================================
echo "Test 3: Missing upstream remote (should warn, not fail)"
test_repo3="$TEMP_DIR/test3"
create_test_repo "$test_repo3" "git@github.com:user/repo.git" ""

output=$(run_validation "$test_repo3" "--check" 2>&1)
exit_code=$?
assert_exit "Missing upstream in --check mode" 0 $exit_code
assert_contains "Missing upstream output" "$output" "No 'upstream' remote"
assert_contains "Missing upstream output" "$output" "WARN"
echo ""

# ===================================================================
# Scenario 4: SSH remote URL
# ===================================================================
echo "Test 4: SSH remote URLs"
test_repo4="$TEMP_DIR/test4"
create_test_repo "$test_repo4" "git@github.com:user/repo.git" "git@github.com:org/repo.git"

output=$(run_validation "$test_repo4" "--check" 2>&1)
exit_code=$?
assert_exit "SSH remotes in --check mode" 0 $exit_code
assert_contains "SSH remotes output" "$output" "git@github.com:user/repo.git"
echo ""

# ===================================================================
# Scenario 5: HTTPS remote URLs
# ===================================================================
echo "Test 5: HTTPS remote URLs"
test_repo5="$TEMP_DIR/test5"
create_test_repo "$test_repo5" "https://github.com/user/repo.git" "https://github.com/org/repo.git"

output=$(run_validation "$test_repo5" "--check" 2>&1)
exit_code=$?
assert_exit "HTTPS remotes in --check mode" 0 $exit_code
assert_contains "HTTPS remotes output" "$output" "Origin remote configured"
echo ""

# ===================================================================
# Scenario 6: --repair-hint mode (templates only)
# ===================================================================
echo "Test 6: --repair-hint mode prints templates only"
test_repo6="$TEMP_DIR/test6"
create_test_repo "$test_repo6" "git@github.com:org/repo.git" "git@github.com:org/repo.git"

output=$(run_validation "$test_repo6" "--repair-hint" 2>&1)
exit_code=$?
assert_exit "--repair-hint mode always exits 0" 0 $exit_code
assert_contains "--repair-hint output" "$output" "git remote set-url origin"
assert_contains "--repair-hint output" "$output" "<your-username>"
assert_not_contains "--repair-hint output" "$output" "Never auto-infer"
echo ""

# ===================================================================
# Scenario 7: --strict mode behavior (pass case)
# ===================================================================
echo "Test 7: --strict mode exits 0 on PASS"
test_repo7="$TEMP_DIR/test7"
create_test_repo "$test_repo7" "git@github.com:alice/repo.git" "git@github.com:org/repo.git"

output=$(run_validation "$test_repo7" "--strict" 2>&1)
exit_code=$?
assert_exit "--strict mode passes correct config" 0 $exit_code
assert_contains "--strict PASS output" "$output" "PASS"
echo ""

echo -e "${BLUE}Hooks Path Resolution Tests (4 scenarios)${NC}"
echo ""

# ===================================================================
# Scenario 8: Default hooks path (.git/hooks)
# ===================================================================
echo "Test 8: Default hooks path (no core.hooksPath set)"
test_repo8="$TEMP_DIR/test8"
create_test_repo "$test_repo8" "git@github.com:user/repo.git" "git@github.com:org/repo.git"
cd "$test_repo8" && git config --unset core.hooksPath 2>/dev/null || true && cd - > /dev/null

output=$(run_validation "$test_repo8" "--check" 2>&1)
exit_code=$?
assert_exit "Default hooks path in --check" 0 $exit_code
assert_contains "Default hooks output" "$output" "core.hooksPath not configured"
assert_contains "Default hooks output" "$output" ".git/hooks"
echo ""

# ===================================================================
# Scenario 9: Relative core.hooksPath (.beads/hooks)
# ===================================================================
echo "Test 9: Relative core.hooksPath (.beads/hooks)"
test_repo9="$TEMP_DIR/test9"
create_test_repo "$test_repo9" "git@github.com:user/repo.git" "git@github.com:org/repo.git"
cd "$test_repo9" && git config core.hooksPath .beads/hooks && cd - > /dev/null

output=$(run_validation "$test_repo9" "--check" 2>&1)
exit_code=$?
assert_exit "Relative hooksPath in --check" 0 $exit_code
assert_contains "Relative hooksPath output" "$output" "core.hooksPath configured"
assert_contains "Relative hooksPath output" "$output" ".beads/hooks"
echo ""

# ===================================================================
# Scenario 10: Absolute core.hooksPath
# ===================================================================
echo "Test 10: Absolute core.hooksPath"
test_repo10="$TEMP_DIR/test10"
create_test_repo "$test_repo10" "git@github.com:user/repo.git" "git@github.com:org/repo.git"
absolute_hooks="/tmp/shared-hooks"
cd "$test_repo10" && git config core.hooksPath "$absolute_hooks" && cd - > /dev/null

output=$(run_validation "$test_repo10" "--check" 2>&1)
exit_code=$?
assert_exit "Absolute hooksPath in --check" 0 $exit_code
assert_contains "Absolute hooksPath output" "$output" "core.hooksPath configured"
echo ""

# ===================================================================
# Scenario 11: Not a git repository (should fail)
# ===================================================================
echo "Test 11: Not a git repository"
test_repo11="$TEMP_DIR/test11"
mkdir -p "$test_repo11"

output=$(run_validation "$test_repo11" "--strict" 2>&1)
exit_code=$?
assert_exit "Not a git repo in --strict mode" 1 $exit_code
assert_contains "Not a git repo output" "$output" "Not a git repository"
echo ""

# ===================================================================
# Summary
# ===================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$TESTS_FAILED" -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed${NC}"
  exit 0
else
  echo -e "${RED}✗ Some tests failed${NC}"
  exit 1
fi
