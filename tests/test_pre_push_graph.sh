#!/bin/bash

# test_pre_push_graph.sh — the warn-only graph status check in hooks/pre-push.
#
# The graph is optional: these scenarios run with code intelligence set to
# code-review-graph; scenario 0 shows the default (none) reports nothing.
#
# Scenarios:
#   0. Code intelligence none (the default) — no graph warning
#   1. Tier 0 — exempt (no graph warning)
#   2. Tier 1 supported (Go) missing graph — warning, exit 0
#   3. Tier 1 supported (Go) fresh graph — no warning
#   4. Weak stack (Laravel) with exception — no graph warning
#   5. Non-intellisense repo — no graph warning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# The graph only applies when the team chose it as code intelligence.
export INTELLISENSE_CODE_INTEL=code-review-graph

# ============================================================================
# Test helpers (mirroring test_pre_push_tiers.sh patterns)
# ============================================================================

assert_exit_code() {
  local expected="$1" actual="$2" message="${3:-exit code $expected}"
  ((++TESTS_RUN))
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected: $expected"
    echo -e "    Actual:   $actual"
    ((++TESTS_FAILED))
  fi
}

assert_grep_match() {
  local pattern="$1" text="$2" message="${3:-pattern should match}"
  ((++TESTS_RUN))
  if echo "$text" | grep -q "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern: $pattern"
    echo -e "    Text head: ${text:0:200}"
    ((++TESTS_FAILED))
  fi
}

assert_grep_no_match() {
  local pattern="$1" text="$2" message="${3:-pattern should not match}"
  ((++TESTS_RUN))
  if ! echo "$text" | grep -q "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern leaked: $pattern"
    ((++TESTS_FAILED))
  fi
}

# Build a minimal git repo with proper origin/main tracking that the hook
# expects. Returns 0 on success.
setup_test_repo() {
  local tmpdir="$1"
  git -C "$tmpdir" init --initial-branch=main >/dev/null 2>&1
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "Test User"
  git -C "$tmpdir" remote add origin https://github.com/fork/repo.git
  git -C "$tmpdir" remote add upstream https://github.com/upstream/repo.git
  git -C "$tmpdir" commit --allow-empty -m "init" >/dev/null 2>&1
  mkdir -p "$tmpdir/.git/refs/remotes/origin"
  git -C "$tmpdir" rev-parse HEAD > "$tmpdir/.git/refs/remotes/origin/main"
  echo "ref: refs/remotes/origin/main" > "$tmpdir/.git/refs/remotes/origin/HEAD"
}

# Mark a repo as intellisense-managed via .intellisense/MANAGED (no CLAUDE.md edit needed).
mark_intellisense_managed() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/.intellisense"
  echo "INTELLISENSE-MANAGED" > "$tmpdir/.intellisense/MANAGED"
}

# Write a minimal manifest.json with the stack key (what setup-repos.sh writes).
write_manifest_stack() {
  local tmpdir="$1" stack="$2"
  mkdir -p "$tmpdir/.intellisense"
  cat > "$tmpdir/.intellisense/manifest.json" <<JSON
{"intellisense_manifest_version": "1", "stack": "$stack", "components": []}
JSON
}

# Create a Tier 1 file (a code file no rule matches: the policy's default_tier, 1) and commit it with its
# evidence.
make_tier1_change() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/internal/tool"
  cat > "$tmpdir/internal/tool/tool.go" <<EOF
package tool

func Run() {}
EOF
  git -C "$tmpdir" add "internal/tool/tool.go"
  git -C "$tmpdir" commit -m "feat: add tool

Beads: intellisense-test
Change Contract: scope=add tool, files_affected=1, estimated_lines=3, confidence=0.9, risk=low" >/dev/null 2>&1
}

# Create a Tier 0 file (docs only) and commit it.
make_tier0_change() {
  local tmpdir="$1"
  cat > "$tmpdir/README.md" <<EOF
# Test Repo
Documentation update.
EOF
  git -C "$tmpdir" add README.md
  git -C "$tmpdir" commit -m "docs: update readme" >/dev/null 2>&1
}

# Write a stale graph-status.json (built_at_utc explicitly older than HEAD,
# readiness=ready). Used to exercise the staleness branch of graph_warn_if_needed.
write_stale_graph_status() {
  local tmpdir="$1" stack="$2" support="$3"
  mkdir -p "$tmpdir/.intellisense"
  # Far in the past: 2020-01-01. HEAD commit's timestamp will be `now`,
  # and the hook compares `built_at_utc < HEAD commit ts` to detect staleness.
  local stale_ts="2020-01-01T00:00:00Z"
  cat > "$tmpdir/.intellisense/graph-status.json" <<JSON
{
  "stack": "$stack",
  "stack_support": "$support",
  "nodes": 100,
  "built_at_utc": "$stale_ts",
  "upstream_last_updated": null,
  "build_exit_code": 0,
  "readiness": "ready",
  "build_time_ms": 200,
  "min_nodes_threshold": 50,
  "min_nodes_override": null,
  "advisory": null
}
JSON
}

# Write a fresh graph-status.json (built_at_utc = now-ish; readiness=ready).
write_fresh_graph_status() {
  local tmpdir="$1" stack="$2" support="$3"
  mkdir -p "$tmpdir/.intellisense"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$tmpdir/.intellisense/graph-status.json" <<JSON
{
  "stack": "$stack",
  "stack_support": "$support",
  "nodes": 100,
  "built_at_utc": "$now",
  "upstream_last_updated": null,
  "build_exit_code": 0,
  "readiness": "ready",
  "build_time_ms": 200,
  "min_nodes_threshold": 50,
  "min_nodes_override": null,
  "advisory": null
}
JSON
}

# Write an exception JSON (committed; signals opt-out).
write_graph_exception() {
  local tmpdir="$1" stack="$2" reason="${3:-unsupported-stack}"
  mkdir -p "$tmpdir/.intellisense"
  cat > "$tmpdir/.intellisense/graph-exception.json" <<JSON
{
  "reason": "$reason",
  "stack": "$stack",
  "owner": "test@intellisense",
  "expires": "2099-12-31",
  "notes": "test fixture"
}
JSON
}

# Run the pre-push hook against a repo and capture both output and exit code.
# Sets HOOK_OUTPUT and HOOK_EXIT.
run_hook() {
  local repo="$1"
  local original_dir
  original_dir="$(pwd)"
  cd "$repo"
  HOOK_EXIT=
  HOOK_OUTPUT=$(bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1) || HOOK_EXIT=$?
  HOOK_EXIT=${HOOK_EXIT:-0}
  cd "$original_dir"
}

# ============================================================================
# Test runner
# ============================================================================

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  pre-push warn-only graph status tests"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ----------------------------------------------------------------------------
# Test 0: code intelligence none (the default) — no graph warning at all
# ----------------------------------------------------------------------------
echo "Test 0: code intelligence none → no graph warning (graph is optional)"
TEST0_DIR=$(mktemp -d -t intellisense-pp0.XXXX)
setup_test_repo "$TEST0_DIR"
mark_intellisense_managed "$TEST0_DIR"
write_manifest_stack "$TEST0_DIR" "go"
make_tier1_change "$TEST0_DIR"
INTELLISENSE_CODE_INTEL=none run_hook "$TEST0_DIR"
assert_exit_code "0" "$HOOK_EXIT" "code intelligence none: push succeeds"
assert_grep_no_match "graph" "$HOOK_OUTPUT" "code intelligence none: nothing about graphs"
rm -rf "$TEST0_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 1: Tier 0 (docs-only) — exempt; no graph warning
# ----------------------------------------------------------------------------
echo "Test 1: Tier 0 (docs-only) is exempt from graph warning"
TEST1_DIR=$(mktemp -d -t intellisense-pp1.XXXX)
setup_test_repo "$TEST1_DIR"
mark_intellisense_managed "$TEST1_DIR"
write_manifest_stack "$TEST1_DIR" "go"
make_tier0_change "$TEST1_DIR"
run_hook "$TEST1_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Tier 0 push succeeds (exit 0)"
assert_grep_no_match "intellisense graph not ready" "$HOOK_OUTPUT" "Tier 0: no graph-not-ready warning"
assert_grep_no_match "graph is stale" "$HOOK_OUTPUT" "Tier 0: no stale-graph warning"
rm -rf "$TEST1_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 2: Tier 1 supported (Go) missing graph — warns, exit 0
# ----------------------------------------------------------------------------
echo "Test 2: Tier 1 Go (mandatory-supported) missing graph → warning, exit 0"
TEST2_DIR=$(mktemp -d -t intellisense-pp2.XXXX)
setup_test_repo "$TEST2_DIR"
mark_intellisense_managed "$TEST2_DIR"
write_manifest_stack "$TEST2_DIR" "go"
make_tier1_change "$TEST2_DIR"
# NO graph-status.json written
run_hook "$TEST2_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Tier 1 supported missing graph: push succeeds (warn-only)"
assert_grep_match "Tier 1 checks passed" "$HOOK_OUTPUT" "Tier 1 artifact gates pass"
assert_grep_match "intellisense graph not ready" "$HOOK_OUTPUT" "Tier 1 supported: graph-not-ready warning emitted (hooks/pre-push:635)"
assert_grep_match "graph-bootstrap.sh" "$HOOK_OUTPUT" "Warning includes the bootstrap command"
assert_grep_no_match "BLOCKED" "$HOOK_OUTPUT" "Tier 1 push not blocked by graph absence (warn-only by default)"
rm -rf "$TEST2_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 3: Tier 1 supported (Go) fresh graph — no warning
# ----------------------------------------------------------------------------
echo "Test 3: Tier 1 Go (mandatory-supported) fresh graph → no warning"
TEST3_DIR=$(mktemp -d -t intellisense-pp3.XXXX)
setup_test_repo "$TEST3_DIR"
mark_intellisense_managed "$TEST3_DIR"
write_manifest_stack "$TEST3_DIR" "go"
make_tier1_change "$TEST3_DIR"
write_fresh_graph_status "$TEST3_DIR" "go" "mandatory-supported"
run_hook "$TEST3_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Tier 1 supported fresh graph: push succeeds"
assert_grep_match "Tier 1 checks passed" "$HOOK_OUTPUT" "Tier 1 artifact gates pass"
assert_grep_no_match "intellisense graph not ready" "$HOOK_OUTPUT" "Fresh graph: no graph-not-ready warning"
assert_grep_no_match "graph is stale" "$HOOK_OUTPUT" "Fresh graph: no stale-graph warning"
rm -rf "$TEST3_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 4: Weak stack (Laravel) WITH exception — no graph warning
# ----------------------------------------------------------------------------
echo "Test 4: Weak stack with .intellisense/graph-exception.json → no graph warning"
TEST4_DIR=$(mktemp -d -t intellisense-pp4.XXXX)
setup_test_repo "$TEST4_DIR"
mark_intellisense_managed "$TEST4_DIR"
write_manifest_stack "$TEST4_DIR" "laravel"
write_graph_exception "$TEST4_DIR" "laravel" "opt-out"
make_tier1_change "$TEST4_DIR"
run_hook "$TEST4_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Weak stack with exception: push succeeds"
assert_grep_match "Tier 1 checks passed" "$HOOK_OUTPUT" "Tier 1 artifact gates pass"
assert_grep_no_match "intellisense graph not ready" "$HOOK_OUTPUT" "Exception present: no graph-not-ready warning"
assert_grep_no_match "graph is stale" "$HOOK_OUTPUT" "Exception present: no stale-graph warning"
rm -rf "$TEST4_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 5: Non-intellisense repo (no marker, no .intellisense/) — no graph warning
# ----------------------------------------------------------------------------
echo "Test 5: Non-intellisense repo (no marker) → no graph warning"
TEST5_DIR=$(mktemp -d -t intellisense-pp5.XXXX)
setup_test_repo "$TEST5_DIR"
# Deliberately NO mark_intellisense_managed, NO manifest, NO .intellisense/ at all
make_tier1_change "$TEST5_DIR"
run_hook "$TEST5_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Non-intellisense repo Tier 1: push succeeds"
assert_grep_match "Tier 1 checks passed" "$HOOK_OUTPUT" "Tier 1 artifact gates pass on non-intellisense repo too"
assert_grep_no_match "intellisense graph not ready" "$HOOK_OUTPUT" "Non-intellisense: no graph-not-ready warning"
assert_grep_no_match "graph is stale" "$HOOK_OUTPUT" "Non-intellisense: no stale-graph warning"
rm -rf "$TEST5_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 6: Tier 1 supported (Go) STALE graph — warns, exit 0, does not block
#
# Positive-case staleness: graph-status.json exists with readiness=ready but
# built_at_utc predates the HEAD commit. Confirms the hook's staleness branch
# fires (the test_3 case asserts only the absence of this warning on a fresh
# graph; without this positive case, the staleness path was never positively
# exercised).
# ----------------------------------------------------------------------------
echo "Test 6: Tier 1 Go (mandatory-supported) STALE graph → stale-graph warning, exit 0"
TEST6_DIR=$(mktemp -d -t intellisense-pp6.XXXX)
setup_test_repo "$TEST6_DIR"
mark_intellisense_managed "$TEST6_DIR"
write_manifest_stack "$TEST6_DIR" "go"
write_stale_graph_status "$TEST6_DIR" "go" "mandatory-supported"
make_tier1_change "$TEST6_DIR"
run_hook "$TEST6_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Tier 1 stale graph: push still succeeds (warn-only)"
assert_grep_match "Tier 1 checks passed" "$HOOK_OUTPUT" "Tier 1 artifact gates pass"
assert_grep_match "graph is stale" "$HOOK_OUTPUT" "Stale graph: stale-graph warning emitted"
assert_grep_match "graph-bootstrap.sh" "$HOOK_OUTPUT" "Stale-graph warning includes bootstrap command"
assert_grep_no_match "BLOCKED" "$HOOK_OUTPUT" "Tier 1 push not blocked by stale graph (warn-only by default)"
assert_grep_no_match "intellisense graph not ready" "$HOOK_OUTPUT" "Stale graph: no graph-not-ready warning (graph exists)"
rm -rf "$TEST6_DIR"
echo ""

# ----------------------------------------------------------------------------
# Test 7 (Impact Discovery): contract.json with empty
# impact_analysis surfaces the warn-only message at push time, exit 0.
#
# Confirms the end-to-end chain: validator → pre-push → dev stderr. The
# unit test for the validator's warning lives in test_contract_layer1.sh
# Case 9a; this case is the integration check that the warning actually
# reaches the developer through the push hook.
# ----------------------------------------------------------------------------
echo "Test 7: empty impact_analysis warns via pre-push, exit 0"
TEST7_DIR=$(mktemp -d -t intellisense-pp7.XXXX)
setup_test_repo "$TEST7_DIR"
mark_intellisense_managed "$TEST7_DIR"
write_manifest_stack "$TEST7_DIR" "go"
write_fresh_graph_status "$TEST7_DIR" "go" "mandatory-supported"
make_tier1_change "$TEST7_DIR"
# Pre-push resolves the validator via $repo_root/scripts/validate-contract-schema.sh
# first. Copy the in-tree validator so this integration check actually runs it
# (mirroring test_contract_layer1.sh's setup_throwaway_repo).
mkdir -p "$TEST7_DIR/scripts"
cp "$INTELLISENSE_SETUP_DIR/scripts/validate-contract-schema.sh" "$TEST7_DIR/scripts/validate-contract-schema.sh"
chmod +x "$TEST7_DIR/scripts/validate-contract-schema.sh"
# Also copy the schema.json so the validator can read required-fields from it.
mkdir -p "$TEST7_DIR/skills/contract"
cp "$INTELLISENSE_SETUP_DIR/skills/contract/schema.json" "$TEST7_DIR/skills/contract/schema.json"
# Seed a contract.json for branch "main" with empty impact_analysis but
# otherwise valid (mirrors write_valid_contract from test_contract_layer1.sh).
mkdir -p "$TEST7_DIR/.intellisense/session"
mkdir -p "$(dirname "$TEST7_DIR/.intellisense/contracts/main.md")"; { echo ---; cat <<JSON
{
  "branch": "main",
  "mode": "full_feature",
  "requirement": "Test 7 fixture — empty impact_analysis triggers warning",
  "files_affected": ["internal/tool/tool.go"],
  "estimated_lines": 2,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert commit",
  "test_strategy": "see test_pre_push_graph.sh Test 7",
  "session_id": "test7-fixture",
  "prompt_hash": "test7hash",
  "classification_id": "cls_test7_fixture",
  "state": "approved",
  "impact_analysis": ""
}
JSON
echo ---; } >"$TEST7_DIR/.intellisense/contracts/main.md"
run_hook "$TEST7_DIR"
assert_exit_code "0" "$HOOK_EXIT" "Empty impact_analysis: push still succeeds (warn-only)"
assert_grep_match "impact-discovery" "$HOOK_OUTPUT" "Warn-only message reaches dev via pre-push"
assert_grep_match "impact_analysis is empty" "$HOOK_OUTPUT" "Warning explains the cause"
assert_grep_no_match "BLOCKED" "$HOOK_OUTPUT" "Push not blocked by missing impact_analysis"
rm -rf "$TEST7_DIR"
echo ""

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
print_test_summary
exit $?
