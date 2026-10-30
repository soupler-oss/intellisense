#!/bin/bash

# test_intellisense_paths.sh — Unit tests for scripts/lib/intellisense-paths.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

INTELLISENSE_SETUP_ROOT="$SCRIPT_DIR/.."
# Source the unit under test
source "$INTELLISENSE_SETUP_ROOT/scripts/lib/intellisense-paths.sh"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: scripts/lib/intellisense-paths.sh${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# H1 — intellisense_state_path returns deterministic pathss.
test_h1_state_path_deterministic() {
  echo -e "${CYAN}H1: intellisense_state_path returns deterministic paths${NC}"
  local repo="/fake/repo"
  assert_eq "/fake/repo/.intellisense/version"                       "$(intellisense_state_path "$repo" version)"                   "version path"
  assert_eq "/fake/repo/.intellisense/manifest.json"                 "$(intellisense_state_path "$repo" manifest)"                  "manifest path"
  assert_eq "/fake/repo/.intellisense/local.json"                    "$(intellisense_state_path "$repo" local)"                     "local path"
  assert_eq "/fake/repo/.intellisense/stubs-status.json"             "$(intellisense_state_path "$repo" stubs-status)"              "stubs-status path"
  assert_eq "/fake/repo/.intellisense/kb-status.md"                  "$(intellisense_state_path "$repo" kb-status)"                 "kb-status path"
  assert_eq "/fake/repo/.intellisense/existing-knowledge-report.md"  "$(intellisense_state_path "$repo" existing-knowledge-report)" "existing-knowledge-report path"
}

# H2 — intellisense_state_path does NOT create .intellisense/ (pure-read invariant).
test_h2_read_does_not_create_dir() {
  echo -e "${CYAN}H2: intellisense_state_path does NOT create .intellisense/${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  # Call the resolver for several keys.
  intellisense_state_path "$TMPDIR" version >/dev/null
  intellisense_state_path "$TMPDIR" manifest >/dev/null
  intellisense_state_path "$TMPDIR" local >/dev/null
  if [ -d "$TMPDIR/.intellisense" ]; then
    echo -e "  ${RED}✗${NC} reader created .intellisense/ (pure-read invariant violated)"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} reader did not create .intellisense/"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))
  rm -rf "$TMPDIR"
}

# H3 — ensure_intellisense_state_dir creates .intellisense/.
test_h3_ensure_creates_dir() {
  echo -e "${CYAN}H3: ensure_intellisense_state_dir creates .intellisense/${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  ensure_intellisense_state_dir "$TMPDIR"
  if [ -d "$TMPDIR/.intellisense" ]; then
    echo -e "  ${GREEN}✓${NC} ensure_intellisense_state_dir created .intellisense/"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} ensure_intellisense_state_dir failed to create .intellisense/"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))
  # Idempotent on second call.
  ensure_intellisense_state_dir "$TMPDIR"
  if [ -d "$TMPDIR/.intellisense" ]; then
    echo -e "  ${GREEN}✓${NC} ensure_intellisense_state_dir is idempotent"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} idempotent call broke the directory"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))
  rm -rf "$TMPDIR"
}

# H4 — intellisense_state_dir echoes path but does NOT create.
test_h4_state_dir_pure() {
  echo -e "${CYAN}H4: intellisense_state_dir echoes path but does NOT create${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  local got
  got=$(intellisense_state_dir "$TMPDIR")
  assert_eq "$TMPDIR/.intellisense" "$got" "intellisense_state_dir echoes correct path"
  if [ -d "$TMPDIR/.intellisense" ]; then
    echo -e "  ${RED}✗${NC} intellisense_state_dir created the directory (should be pure)"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} intellisense_state_dir did not create the directory"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))
  rm -rf "$TMPDIR"
}

# ─────────────────────────────────────────────────────────────
test_h1_state_path_deterministic
test_h2_read_does_not_create_dir
test_h3_ensure_creates_dir
test_h4_state_dir_pure

print_test_summary
