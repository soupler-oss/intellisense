#!/bin/bash
# tests/test-intellisense-scripts.sh
# Comprehensive test suite for intellisense scripts

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_DIR="/tmp/intellisense-test-$$"
INTELLISENSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Skip Claude-CLI extractions inside generate-kb-stubs.sh during this test
# suite (test mode). Without this, setup-repos.sh blocks for minutes per
# fixture waiting on Claude. The KB-stub population is exercised separately
# in dedicated tests; this suite focuses on setup-repos.sh modes.
export INTELLISENSE_SKIP_KB_EXTRACT=1

# No stack is mandatory-supported by default (intellisense_graph_stack_support opts
# in per-organization — see scripts/lib/intellisense-graph.sh). This suite exists to
# exercise the mandatory-stack readiness-enforcement path specifically, so
# opt Go in for the whole run.
export INTELLISENSE_GRAPH_MANDATORY_STACKS="go python"

# Graph precondition: setup-repos.sh invocations against mandatory-supported
# stacks (Go, when opted in) require code-review-graph==2.3.2; skipped (exit 77) unless installed, or a hard fail with
# INTELLISENSE_REQUIRE_OPTIONAL_TOOLS=1, if
# missing — no skip-when-missing, no bypass valve.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
require_code_review_graph_or_fail
echo ""

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

test_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((++TESTS_PASSED))
}

test_fail() {
  echo -e "${RED}✗${NC} $1"
  ((++TESTS_FAILED))
}

# test_skip — third outcome category. Used when a precondition makes a test
# meaningless to run (e.g. CRG can't multiprocess in this environment). Does
# NOT count as pass or fail; surfaces in summary so the operator can decide
# whether the env should support it.
test_skip() {
  echo -e "${YELLOW}⊘${NC} SKIP: $1"
  ((++TESTS_SKIPPED))
}

test_section() {
  echo ""
  echo -e "${YELLOW}>>> $1${NC}"
}

# Run setup-repos.sh capturing exit + output. Replaces the silent
# `setup-repos.sh ... > /dev/null 2>&1 || true` pattern that hid the real
# cause of failures and made downstream assertions misreport (e.g. the
# "intellisense version file not found" red herring when graph-bootstrap failed
# upstream and setup-repos.sh exited before writing .intellisense/version).
#
# On non-zero exit, prints the last 25 lines of setup-repos.sh's combined
# stdout+stderr so the failing CI run names the real reason. Always returns
# 0 (test_fail is called by the caller) so set -e doesn't kill the suite.
#
# Sets:
#   LAST_SETUP_REPOS_EXIT   — exit code
#   LAST_SETUP_REPOS_OUTPUT — combined stdout+stderr (last 25 lines)
run_setup_repos() {
  local out exit_code
  set +e
  out=$(bash "$INTELLISENSE_ROOT/setup-repos.sh" "$@" 2>&1)
  exit_code=$?
  set -e
  LAST_SETUP_REPOS_EXIT=$exit_code
  LAST_SETUP_REPOS_OUTPUT=$(echo "$out" | tail -25)
  if [[ $exit_code -ne 0 ]]; then
    echo -e "  ${RED}⚠ setup-repos.sh exit=$exit_code${NC} — args: $*"
    echo "    last 25 lines of setup-repos.sh output:"
    echo "$LAST_SETUP_REPOS_OUTPUT" | sed 's/^/    | /'
  fi
  return 0
}

# ============================================================================
# Test Suite
# ============================================================================

test_section "1. Syntax Checks (bash -n)"

for script in scripts/*.sh; do
  if bash -n "$script" 2>/dev/null; then
    test_pass "Syntax: $(basename $script)"
  else
    test_fail "Syntax: $(basename $script)"
  fi
done

# ============================================================================

test_section "2. Maturity Detection Tests"

mkdir -p "$TEST_DIR/level0" "$TEST_DIR/level1" "$TEST_DIR/level3"

cd "$TEST_DIR/level0"
git init > /dev/null 2>&1

cd "$TEST_DIR/level1"
git init > /dev/null 2>&1
echo "# Test CLAUDE.md" > CLAUDE.md

cd "$TEST_DIR/level3"
git init > /dev/null 2>&1
echo "# Test CLAUDE.md" > CLAUDE.md
mkdir -p .claude/agents .claude/skills knowledge-base
echo "test" > .claude/agents/test-agent.md
echo "test" > .claude/skills/test-skill.md
echo "# System Context" > knowledge-base/00-system-context.md

cd "$TEST_DIR/level0"
LEVEL=$(bash "$INTELLISENSE_ROOT/scripts/intellisense-health.sh" --format maturity --json . 2>/dev/null | grep -oE '"maturity_level": *[0-9]+' | grep -oE '[0-9]+' || true)
[[ "$LEVEL" == "0" ]] && test_pass "Level 0 detection" || test_fail "Level 0 detection"

cd "$TEST_DIR/level1"
LEVEL=$(bash "$INTELLISENSE_ROOT/scripts/intellisense-health.sh" --format maturity --json . 2>/dev/null | grep -oE '"maturity_level": *[0-9]+' | grep -oE '[0-9]+' || true)
[[ "$LEVEL" == "1" ]] && test_pass "Level 1 detection" || test_fail "Level 1 detection"

cd "$TEST_DIR/level3"
LEVEL=$(bash "$INTELLISENSE_ROOT/scripts/intellisense-health.sh" --format maturity --json . 2>/dev/null | grep -oE '"maturity_level": *[0-9]+' | grep -oE '[0-9]+' || true)
[[ "$LEVEL" == "3" ]] && test_pass "Level 3 detection" || test_fail "Level 3 detection"

# ============================================================================

test_section "3. Scorecard Tests"

cd "$TEST_DIR/level1"
OUTPUT=$(bash "$INTELLISENSE_ROOT/scripts/intellisense-health.sh" --format score . 2>/dev/null || true)

if echo "$OUTPUT" | grep -q "Governance"; then
  test_pass "Scorecard: Governance section"
else
  test_fail "Scorecard: Governance section"
fi

# ============================================================================

# Section 4 (Governance Validator Tests) removed — scripts/validate-claude-governance.sh
# was deleted in commit da1bebd ("consolidate validation scripts into unified
# validate-intellisense-content.sh"). Governance validation is now part of
# scripts/validate-intellisense-content.sh, exercised by Section 1 syntax check above
# and by the standalone validator run in pre-push and CI.

test_section "5. Knowledge-Base Init Tests"

cd "$TEST_DIR"
mkdir -p kb-test && cd kb-test
bash "$INTELLISENSE_ROOT/scripts/intellisense-init-knowledge-base.sh" > /dev/null 2>&1 || true

if [[ -f "knowledge-base/README.md" ]]; then
  test_pass "KB init: README.md created"
else
  test_fail "KB init: README.md not created"
fi

if [[ -f "knowledge-base/project-context.md" ]]; then
  test_pass "KB init: project-context.md created"
else
  test_fail "KB init: project-context.md not created"
fi

# ============================================================================

test_section "6. setup-repos.sh inject Mode Tests"

# Sections 6, 7, 9 exercise stack-agnostic setup-repos.sh behaviors
# (CLAUDE.md write, idempotency, adopt-mode protocol extraction). They do
# NOT verify Go-specific code paths. Using --stack php (weak — graph
# soft-fails per scripts/lib/intellisense-graph.sh:55) makes them deterministic
# across environments where CRG multiprocessing fails (sandboxed CI,
# containers without /dev/shm, etc.). Real Go-stack + graph
# bootstrap is covered separately by the "Go graph bootstrap
# integration" section near the bottom — auto-skipped when CRG can't
# build in this environment.
cd "$TEST_DIR"
mkdir -p inject-test && cd inject-test
git init > /dev/null 2>&1
echo "# Test CLAUDE.md" > CLAUDE.md

run_setup_repos --repo . --stack php --claude-md-action inject --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "inject mode (php): setup-repos.sh failed (exit=$LAST_SETUP_REPOS_EXIT) — see output above; downstream assertions skipped"
else
  INTELLISENSE_COUNT=$(grep -c "intellisense Rule Pointers" CLAUDE.md 2>/dev/null || true)
  [[ "$INTELLISENSE_COUNT" == "1" ]] && test_pass "inject mode: Creates intellisense Rule Pointers section" || test_fail "inject mode: intellisense Rule Pointers section not found (found $INTELLISENSE_COUNT)"

  LOADED_COUNT=$(grep -c "@~/.intellisense/rules/language-specific" CLAUDE.md 2>/dev/null || true)
  [[ "$LOADED_COUNT" -ge 1 ]] && test_pass "inject mode: Writes @-include for language-specific rule" || test_fail "inject mode: @-include for language-specific rule not written"
fi

# ============================================================================

test_section "7. setup-repos.sh inject Mode Idempotency Tests"

cd "$TEST_DIR/inject-test"
run_setup_repos --repo . --stack php --claude-md-action inject --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "inject mode idempotent (php): setup-repos.sh failed on re-run (exit=$LAST_SETUP_REPOS_EXIT) — see output above"
else
  INTELLISENSE_COUNT=$(grep -c "intellisense Rule Pointers" CLAUDE.md 2>/dev/null || true)
  [[ "$INTELLISENSE_COUNT" == "1" ]] && test_pass "inject mode idempotent: Re-run doesn't duplicate intellisense Rule Pointers" || test_fail "inject mode idempotent: Found $INTELLISENSE_COUNT intellisense Rule Pointers sections (should be 1)"
fi

# ============================================================================

test_section "8. setup-repos.sh replace Mode Tests"

cd "$TEST_DIR"
mkdir -p replace-test && cd replace-test
git init > /dev/null 2>&1
echo "# Existing CLAUDE.md" > CLAUDE.md

run_setup_repos --repo . --stack php --claude-md-action replace --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "replace mode (php): setup-repos.sh failed (exit=$LAST_SETUP_REPOS_EXIT) — see output above; downstream assertions skipped"
else
  [[ -f "CLAUDE.md" ]] && test_pass "replace mode: Creates CLAUDE.md" || test_fail "replace mode: CLAUDE.md not created"

  INTELLISENSE_COUNT=$(grep -c "intellisense Rule Pointers" CLAUDE.md 2>/dev/null || true)
  [[ "$INTELLISENSE_COUNT" -ge 1 ]] && test_pass "replace mode: CLAUDE.md has intellisense Rule Pointers section" || test_fail "replace mode: intellisense Rule Pointers section not found"
fi

# ============================================================================

test_section "9. setup-repos.sh adopt Mode Tests"

cd "$TEST_DIR"
mkdir -p adopt-test && cd adopt-test
git init > /dev/null 2>&1

cat > CLAUDE.md << 'CLAUDEEOF'
# Existing Service CLAUDE.md

## Architecture
This is the service architecture.

## Execution Mode
This should be extracted.

## Domain Terms
- Term 1: Definition
CLAUDEEOF
# Adopt mode is stack-agnostic — it extracts protocol sections from the
# existing CLAUDE.md regardless of language. Using --stack php (weak)
# avoids the CRG multiprocessing dependency that broke fresh-clone runs.
run_setup_repos --repo . --stack php --claude-md-action adopt --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "adopt mode (php): setup-repos.sh failed (exit=$LAST_SETUP_REPOS_EXIT) — see output above; downstream assertions skipped"
else
  # Adopt mode now preserves the original at .intellisense/.backup/CLAUDE.md.original
  # (write-once) instead of the historical CLAUDE.md.backup-<ts> pattern that
  # polluted git status. See setup-repos.sh:245-247 for rationale.
  # `find` is used (not `ls`) because a non-matching glob under `set -euo pipefail`
  # kills the test script before test_fail can run.
  BACKUP_COUNT=$(find .intellisense/.backup -maxdepth 1 -name 'CLAUDE.md.original' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [[ "$BACKUP_COUNT" -gt 0 ]] && test_pass "adopt mode: Preserves original CLAUDE.md at .intellisense/.backup/" || test_fail "adopt mode: Original CLAUDE.md not preserved at .intellisense/.backup/CLAUDE.md.original"

  [[ -f "migration-review.md" ]] && test_pass "adopt mode: Creates migration-review.md" || test_fail "adopt mode: migration-review.md not created"

  INTELLISENSE_COUNT=$(grep -c "REPO_CONTEXT:BEGIN" CLAUDE.md 2>/dev/null || true)
  [[ "$INTELLISENSE_COUNT" -ge 1 ]] && test_pass "adopt mode: Rewrites CLAUDE.md with REPO_CONTEXT:BEGIN" || test_fail "adopt mode: REPO_CONTEXT:BEGIN not found in rewritten CLAUDE.md"
fi

# ============================================================================

test_section "10. knowledge-base/ Directory Structure Tests"

cd "$TEST_DIR"
mkdir -p kb-struct-test && cd kb-struct-test
git init > /dev/null 2>&1

run_setup_repos --repo . --stack angular --claude-md-action inject --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "kb-struct (angular): setup-repos.sh failed (exit=$LAST_SETUP_REPOS_EXIT) — see output above; downstream assertions skipped"
else
  [[ -d "knowledge-base" ]] && test_pass "Fresh repo: knowledge-base/ created as primary" || test_fail "Fresh repo: knowledge-base/ not created"
fi

# ============================================================================

test_section "11. Existing docs/ Preservation Tests"

cd "$TEST_DIR"
mkdir -p docs-existing-test && cd docs-existing-test
git init > /dev/null 2>&1
mkdir -p docs
echo "# Project docs" > docs/project.md
# This test exercises ONLY docs/ preservation + version-file writing — it does
# NOT test Go-specific behavior. PHP is classified `weak` (per
# scripts/lib/intellisense-graph.sh:55), so graph-bootstrap failures are soft and
# setup-repos.sh proceeds to write .intellisense/version regardless of CRG parser
# quirks. Using --stack php here makes the test deterministic across fresh
# clones; Go-path coverage is exercised in sections 6, 7, 9.
run_setup_repos --repo . --stack php --claude-md-action inject --non-interactive

if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
  test_fail "docs preservation (php): setup-repos.sh failed (exit=$LAST_SETUP_REPOS_EXIT) — see output above; downstream assertions skipped"
else
  [[ -d "docs" ]] && test_pass "Existing docs/ preserved (not deleted)" || test_fail "Existing docs/ was deleted"

  [[ -d "knowledge-base" ]] && test_pass "knowledge-base/ created alongside existing docs/" || test_fail "knowledge-base/ not created with existing docs/"

  [[ ! -d "docs" ]] || [[ -f "docs/project.md" && ! -f "docs/kb-status.md" ]] && test_pass "intellisense did not create docs/ directory (only user-owned docs/ preserved)" || test_fail "intellisense created docs/ — should not happen"

  [[ -f ".intellisense/version" ]] && test_pass "intellisense version file written (.intellisense/version)" || test_fail "intellisense version file not found"
fi

# ============================================================================

# Sections 12 and 13 (Governance Validator: Domain Headings / Ignores intellisense Markers)
# removed — scripts/validate-claude-governance.sh was deleted in commit da1bebd.
# Governance validation now lives in scripts/validate-intellisense-content.sh.

# ─────────────────────────────────────────────────────────────────────────────
# Go graph bootstrap integration (auto-skips if CRG can't build).
# ─────────────────────────────────────────────────────────────────────────────
# This is the EXPLICIT integration test that exercises the real graph
# mandatory-supported code path: setup-repos.sh --stack go invokes
# graph-bootstrap.sh, which runs `code-review-graph build` with the CRG
# multiprocessing pipeline.
#
# CRG's pipeline forks workers that touch /dev/shm and POSIX semaphores.
# Sandboxed environments (some CI runners, restricted containers,
# Docker without --shm-size, etc.) raise PermissionError and the build
# exits non-zero with no usable graph. In those environments the integration
# CANNOT succeed regardless of fixture quality — that is an environmental
# limit on graph enforcement, not a test bug.
#
# This section probes CRG with a tiny build in /tmp first; on probe failure
# it test_skip's with the probe's stderr displayed so the operator can see
# whether the gap is fixable (missing /dev/shm, wrong Python, etc.) or
# fundamental to the sandbox. On probe success it runs the integration.
#
# Override: INTELLISENSE_SKIP_GRAPH_INTEGRATION=1 forces skip (e.g. for fast
# CI runs that exercise integration separately).
test_section "12. Go graph bootstrap integration (auto-skip on CRG failure)"

graph_probe() {
  local probe_dir
  probe_dir=$(mktemp -d)
  make_fake_go_repo_graph_ready "$probe_dir" >/dev/null 2>&1
  local probe_out probe_rc
  set +e
  probe_out=$(cd "$probe_dir" && code-review-graph build 2>&1)
  probe_rc=$?
  set -e
  GRAPH_PROBE_OUTPUT=$(echo "$probe_out" | tail -10)
  rm -rf "$probe_dir"
  return $probe_rc
}

if [[ "${INTELLISENSE_SKIP_GRAPH_INTEGRATION:-0}" = "1" ]]; then
  test_skip "Go graph integration: INTELLISENSE_SKIP_GRAPH_INTEGRATION=1 set explicitly"
elif ! graph_probe; then
  test_skip "Go graph integration: CRG build probe failed in this environment — see captured output below"
  echo "    last 10 lines of CRG probe output:"
  echo "$GRAPH_PROBE_OUTPUT" | sed 's/^/    | /'
  echo "    (graph enforcement still applies; this environment cannot exercise it.)"
else
  # Probe succeeded — run the real integration: setup-repos.sh on Go fixture.
  cd "$TEST_DIR"
  mkdir -p graph-integration && cd graph-integration
  git init > /dev/null 2>&1
  echo "# Test CLAUDE.md" > CLAUDE.md
  make_fake_go_repo_graph_ready "$PWD"

  run_setup_repos --repo . --stack go --claude-md-action inject --non-interactive

  if [[ "$LAST_SETUP_REPOS_EXIT" -ne 0 ]]; then
    test_fail "Go graph integration: setup-repos.sh exit=$LAST_SETUP_REPOS_EXIT — CRG probe succeeded but setup-repos failed; investigate"
  else
    [[ -f ".intellisense/graph-status.json" ]] && test_pass "graph-status.json written" || test_fail "graph-status.json missing"
    if [[ -f ".intellisense/graph-status.json" ]]; then
      READINESS=$(grep -oE '"readiness"[[:space:]]*:[[:space:]]*"[^"]*"' .intellisense/graph-status.json | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
      [[ "$READINESS" = "ready" ]] && test_pass "graph readiness=ready" || test_fail "graph readiness='$READINESS' (expected 'ready')"
    fi
    [[ -f ".intellisense/version" ]] && test_pass ".intellisense/version written after successful graph bootstrap" || test_fail ".intellisense/version missing after successful graph bootstrap"
  fi
fi

# ============================================================================

test_section "14. Template: No Eager Language-Specific Rule Imports"

for template in "$INTELLISENSE_ROOT"/templates/CLAUDE.md.*.template; do
  if grep -q '@.*language-specific' "$template"; then
    test_fail "Template $(basename $template): Has eager @language-specific imports"
  else
    test_pass "Template $(basename $(basename $template .template)): No eager @language-specific imports"
  fi
done

# ============================================================================

test_section "15. Template: project-context.md Only Auto-Load"

UNWANTED_LOADS=0
for template in "$INTELLISENSE_ROOT"/templates/CLAUDE.md.*.template; do
  # Count @knowledge-base/ imports (excluding 00-system-context)
  KB_IMPORTS=$(grep '@knowledge-base/' "$template" | grep -v '00-system-context' | wc -l || true)
  [[ $KB_IMPORTS -gt 0 ]] && ((++UNWANTED_LOADS)) || true
done

if [[ $UNWANTED_LOADS -eq 0 ]]; then
  test_pass "Templates: 00-system-context.md is only @knowledge-base auto-load"
else
  test_fail "Templates: Found $UNWANTED_LOADS templates with non-00-system-context @knowledge-base imports"
fi

# ============================================================================

test_section "17. Template Structural Tests (All 3 Templates)"

TEMPLATES=("templates/CLAUDE.md.go.template" "templates/CLAUDE.md.php.template" "templates/CLAUDE.md.angular.template")
for template in "${TEMPLATES[@]}"; do
  template_file="$INTELLISENSE_ROOT/$template"

  if [ ! -f "$template_file" ]; then
    test_fail "Template structural: $template does not exist"
    continue
  fi

  # Test 17.1: Protocol provenance statement
  if grep -q 'governed by intellisense global rules' "$template_file"; then
    test_pass "Template structural: $template has protocol provenance"
  else
    test_fail "Template structural: $template missing protocol provenance"
  fi

  # Test 17.2: On-demand loading rule
  if grep -q '\*\*Loading rule\*\*' "$template_file"; then
    test_pass "Template structural: $template has on-demand loading rule"
  else
    test_fail "Template structural: $template missing on-demand loading rule"
  fi

  # Test 17.3: Risk Escalation Files section
  if grep -q '## Risk Escalation Files' "$template_file"; then
    test_pass "Template structural: $template has Risk Escalation Files section"
  else
    test_fail "Template structural: $template missing Risk Escalation Files section"
  fi

  # Test 17.4: Response Style section
  if grep -q '## Response Style' "$template_file"; then
    test_pass "Template structural: $template has Response Style section"
  else
    test_fail "Template structural: $template missing Response Style section"
  fi

  # Test 17.5: MCP Tools section
  if grep -q '## MCP Tools' "$template_file"; then
    test_pass "Template structural: $template has MCP Tools section"
  else
    test_fail "Template structural: $template missing MCP Tools section"
  fi

  # Test 17.6: Only one @knowledge-base/00-system-context, no other @ imports
  context_count=$(grep -c '@knowledge-base/00-system-context' "$template_file" 2>/dev/null || true)
  other_count=$(grep '@knowledge-base/' "$template_file" 2>/dev/null | grep -vc '00-system-context' || true)

  if [[ "$context_count" -eq 1 && "$other_count" -eq 0 ]]; then
    test_pass "Template structural: $template has only @00-system-context import"
  else
    test_fail "Template structural: $template has improper @ imports (context=$context_count, other=$other_count)"
  fi
done

# ============================================================================

test_section "18. Rule Precedence Tests"

# Test 18.1: Mode-specific file limit overrides generic limit
if grep -q 'mode-keyed and BLOCKING\|do not borrow.*15-file' "$INTELLISENSE_ROOT/rules/operational/development-workflow.md"; then
  test_pass "Rule precedence: Mode-specific file limit rule present"
else
  test_fail "Rule precedence: Mode-specific file limit rule missing"
fi

# Test 18.2: Security is CRITICAL baseline
if grep -q 'priority: CRITICAL' "$INTELLISENSE_ROOT/rules/baseline/security.md"; then
  test_pass "Rule precedence: Security is CRITICAL priority"
else
  test_fail "Rule precedence: Security priority not marked CRITICAL"
fi

# Test 18.3: bug_fix scope limit (≤3 files)
if grep -q '`bug_fix`.*≤3 files\|4th file touched' "$INTELLISENSE_ROOT/rules/operational/development-workflow.md"; then
  test_pass "Rule precedence: bug_fix 3-file maximum rule present"
else
  test_fail "Rule precedence: bug_fix 3-file maximum rule missing"
fi

# ============================================================================

test_section "16. Summary"
echo "Passed:  $TESTS_PASSED"
echo "Failed:  $TESTS_FAILED"
echo "Skipped: $TESTS_SKIPPED"

if [[ $TESTS_FAILED -eq 0 ]]; then
  if [[ $TESTS_SKIPPED -gt 0 ]]; then
    echo -e "${GREEN}All tests passed${NC} (${YELLOW}$TESTS_SKIPPED skipped — see SKIP lines for env limits${NC})"
  else
    echo -e "${GREEN}All tests passed!${NC}"
  fi
  exit 0
else
  echo -e "${RED}Some tests failed.${NC}"
  exit 1
fi
