#!/bin/bash
# validate-fork-setup.sh — Phase 1 diagnostic for fork workflow enforcement
# Read-only validation of fork configuration and hooks path resolution
# Usage: ./scripts/validate-fork-setup.sh [--check|--strict|--repair-hint]
#
# Modes:
#   --check       (default) Exit 0; report PASS/WARN/FAIL status
#   --strict      Exit 1 on FAIL; exit 0 on PASS
#   --repair-hint Exit 0; print literal templates (never infer, never mutate)

set -o pipefail

# Color constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
MODE="check"
REPO_PATH="."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse mode flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --strict)
      MODE="strict"
      shift
      ;;
    --repair-hint)
      MODE="repair-hint"
      shift
      ;;
    *)
      REPO_PATH="$1"
      shift
      ;;
  esac
done

# Source shared hooks library
source "$SCRIPT_DIR/lib/hooks.sh"

# Initialize status tracking
CHECKS_PASSED=0
CHECKS_WARNED=0
CHECKS_FAILED=0

print_status() {
  local status="$1"
  local message="$2"
  case "$status" in
    PASS)
      echo -e "${GREEN}✓${NC} $message"
      ((CHECKS_PASSED++))
      ;;
    WARN)
      echo -e "${YELLOW}⚠${NC} $message"
      ((CHECKS_WARNED++))
      ;;
    FAIL)
      echo -e "${RED}✗${NC} $message"
      ((CHECKS_FAILED++))
      ;;
  esac
}

# ===================================================================
# VALIDATION: Fork Configuration
# ===================================================================

validate_fork_config() {
  echo -e "${BLUE}Fork Configuration Checks:${NC}"
  echo ""

  # Check 1: Git repo validation
  if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    print_status "FAIL" "Not a git repository: $REPO_PATH"
    return 1
  fi
  print_status "PASS" "Repository is valid git repo"

  # Check 2: Upstream remote exists
  UPSTREAM_URL=$(git -C "$REPO_PATH" remote get-url upstream 2>/dev/null || echo "")
  if [ -z "$UPSTREAM_URL" ]; then
    print_status "WARN" "No 'upstream' remote configured (fork workflow may not be set up)"
    return 0
  fi
  print_status "PASS" "Upstream remote configured: $UPSTREAM_URL"

  # Check 3: Origin remote exists and differs from upstream
  ORIGIN_URL=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || echo "")
  if [ -z "$ORIGIN_URL" ]; then
    print_status "FAIL" "No 'origin' remote configured"
    return 1
  fi
  print_status "PASS" "Origin remote configured: $ORIGIN_URL"

  # Check 4: Origin != Upstream (fork misconfiguration check)
  if [ "$ORIGIN_URL" = "$UPSTREAM_URL" ]; then
    print_status "FAIL" "origin == upstream (misconfigured fork; origin should point to personal fork)"
    if [ "$MODE" = "repair-hint" ]; then
      echo ""
      echo "Template to fix:"
      echo "  git remote set-url origin git@github.com:<your-username>/repo.git"
      echo "  git push origin <branch-name>"
    fi
    return 1
  fi
  print_status "PASS" "origin != upstream (fork correctly configured)"

  return 0
}

# ===================================================================
# VALIDATION: Hook Path Resolution
# ===================================================================

validate_hooks_path() {
  echo ""
  echo -e "${BLUE}Hooks Path Resolution Checks:${NC}"
  echo ""

  # Check 1: Can resolve hooks directory
  HOOKS_DIR=$(resolve_hooks_dir "$REPO_PATH" 2>/dev/null) || {
    print_status "FAIL" "Unable to resolve hooks directory"
    return 1
  }
  print_status "PASS" "Hooks directory resolved: $HOOKS_DIR"

  # Check 2: Can resolve pre-push hook path
  PRE_PUSH_PATH=$(resolve_pre_push_hook_path "$REPO_PATH" 2>/dev/null) || {
    print_status "FAIL" "Unable to resolve pre-push hook path"
    return 1
  }
  print_status "PASS" "Pre-push hook path resolved: $PRE_PUSH_PATH"

  # Check 3: Check for core.hooksPath configuration
  HOOKS_PATH_CONFIG=$(git -C "$REPO_PATH" config core.hooksPath 2>/dev/null || echo "")
  if [ -n "$HOOKS_PATH_CONFIG" ]; then
    print_status "PASS" "core.hooksPath configured: $HOOKS_PATH_CONFIG"
  else
    print_status "PASS" "core.hooksPath not configured (using default .git/hooks)"
  fi

  # Check 4: Verify resolved path is inside repo or configured location
  if [[ "$PRE_PUSH_PATH" == "$REPO_PATH"* ]] || [[ "$PRE_PUSH_PATH" == /* ]]; then
    print_status "PASS" "Hook path is valid (absolute or inside repo)"
  else
    print_status "WARN" "Hook path may be outside repo (but is valid)"
  fi

  return 0
}

# ===================================================================
# SUMMARY AND EXIT
# ===================================================================

print_summary() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$CHECKS_FAILED" -eq 0 ]; then
    if [ "$CHECKS_WARNED" -eq 0 ]; then
      echo -e "${GREEN}✓ PASS${NC}: Fork setup is valid. You can push safely."
    else
      echo -e "${YELLOW}⚠ WARN${NC}: Fork setup has warnings. Review and fix before pushing."
    fi
  else
    echo -e "${RED}✗ FAIL${NC}: Fork setup is misconfigured. Fix required before pushing."
  fi

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "Summary:"
  echo "  Passed: $CHECKS_PASSED"
  echo "  Warned: $CHECKS_WARNED"
  echo "  Failed: $CHECKS_FAILED"
  echo ""
}

# ===================================================================
# MAIN
# ===================================================================

validate_fork_config
FORK_STATUS=$?

validate_hooks_path
HOOKS_STATUS=$?

print_summary

# Exit based on mode
case "$MODE" in
  check)
    # --check always exits 0, just reports status
    exit 0
    ;;
  strict)
    # --strict exits 1 if any failures, 0 if all pass
    if [ "$CHECKS_FAILED" -gt 0 ]; then
      exit 1
    fi
    exit 0
    ;;
  repair-hint)
    # --repair-hint always exits 0, templates printed in-line
    exit 0
    ;;
esac
