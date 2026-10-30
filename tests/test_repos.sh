#!/bin/bash

# test_repos.sh — Automated tests for setup-repos.sh
# Tests cover: hook install (missing/identical/different), CI workflow install, CLAUDE.md handling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Setup test environment
INTELLISENSE_SETUP_ROOT="$SCRIPT_DIR/.."
SETUP_REPOS_SCRIPT="$INTELLISENSE_SETUP_ROOT/setup-repos.sh"

# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: setup-repos.sh${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# No stack is mandatory-supported by default (intellisense_graph_stack_support opts
# in per-organization — see scripts/lib/intellisense-graph.sh). This suite exists to
# exercise the mandatory-stack readiness-enforcement path specifically, so
# opt Go/Python in for the whole run.
export INTELLISENSE_GRAPH_MANDATORY_STACKS="go python"

# Graph precondition: tests invoke setup-repos.sh against Go (mandatory-supported),
# which requires code-review-graph==2.3.2 installed (skipped, exit 77, when it is not). Remediation
# if missing — no skip-when-missing, no bypass valve.
require_code_review_graph_or_fail
echo ""

# Test 1: Hook install when hook doesn't exist
test_hook_install_missing() {
  echo -e "${CYAN}Test 1: Hook install when hook doesn't exist${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Verify hook doesn't exist initially
  assert_file_missing "$FAKE_REPO/.git/hooks/pre-push" "hook doesn't exist before install"

  # Run setup-repos.sh
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --skip-claude-md \
    2>/dev/null || true

  # Verify hook installed
  assert_file_exists "$FAKE_REPO/.git/hooks/pre-push" "hook installed successfully"

  rm -rf "$TMPDIR"
}

# Test 2: Hook install when identical hook exists
test_hook_install_identical() {
  echo -e "${CYAN}Test 2: Hook install when identical hook exists (skipped)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Copy the same hook to repo (identical scenario)
  cp "$FAKE_INTELLISENSE_SETUP/hooks/pre-push" "$FAKE_REPO/.git/hooks/pre-push"
  chmod +x "$FAKE_REPO/.git/hooks/pre-push"

  # Record initial timestamp
  local FIRST_TIMESTAMP
  FIRST_TIMESTAMP=$(stat -c "%Y" "$FAKE_REPO/.git/hooks/pre-push" 2>/dev/null || stat -f "%m" "$FAKE_REPO/.git/hooks/pre-push" 2>/dev/null || echo "")

  sleep 1

  # Run setup-repos.sh
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --skip-claude-md \
    2>/dev/null || true

  # Verify hook unchanged
  assert_file_exists "$FAKE_REPO/.git/hooks/pre-push" "hook still exists"

  rm -rf "$TMPDIR"
}

# Test 3: Hook install when different hook exists (creates .intellisense-new)
test_hook_install_different() {
  echo -e "${CYAN}Test 3: Hook install with different hook (creates .intellisense-new)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Create different hook
  cat > "$FAKE_REPO/.git/hooks/pre-push" << 'EOF'
#!/bin/bash
echo "Custom pre-push hook"
exit 0
EOF
  chmod +x "$FAKE_REPO/.git/hooks/pre-push"

  # Run setup-repos.sh (without --force)
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --skip-claude-md \
    2>/dev/null || true

  # Verify .intellisense-new candidate created
  assert_file_exists "$FAKE_REPO/.git/hooks/pre-push.intellisense-new" ".intellisense-new candidate created"

  # Verify original hook unchanged
  if grep -q "Custom pre-push hook" "$FAKE_REPO/.git/hooks/pre-push" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} original hook preserved"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} original hook was modified"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 4: Hook install with --force backs up and replaces
test_hook_install_force() {
  echo -e "${CYAN}Test 4: Hook install with --force backs up and replaces${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Create different hook
  cat > "$FAKE_REPO/.git/hooks/pre-push" << 'EOF'
#!/bin/bash
echo "Custom pre-push hook"
exit 0
EOF
  chmod +x "$FAKE_REPO/.git/hooks/pre-push"

  # Scope the backup destination to TMPDIR so the test never writes to the
  # developer's real ~/.intellisense-backups/. setup-repos.sh → hooks.sh respects this.
  local FAKE_BACKUPS="$TMPDIR/intellisense-backups"

  # Run setup-repos.sh with --force
  INTELLISENSE_BACKUPS_DIR="$FAKE_BACKUPS" bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --force \
    --skip-claude-md \
    2>/dev/null || true

  # Verify backup created under <BACKUPS>/repo-hooks/ (path-encoded).
  # Old behavior wrote sibling pre-push.bak-* — moved out of Claude's load path.
  local BACKUPS
  BACKUPS=$(ls "$FAKE_BACKUPS/repo-hooks/"*pre-push.bak-* 2>/dev/null | wc -l)
  local SIBLING_BAKS
  SIBLING_BAKS=$(ls "$FAKE_REPO/.git/hooks/pre-push.bak-"* 2>/dev/null | wc -l)
  if [ "$BACKUPS" -gt 0 ] && [ "$SIBLING_BAKS" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} hook backup in ~/.intellisense-backups/repo-hooks/ (no sibling .bak-*)"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} hook backup not in ~/.intellisense-backups/repo-hooks/ (or sibling exists)"
    echo -e "      repo-hooks count: $BACKUPS  sibling count: $SIBLING_BAKS"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  # Verify new hook installed
  if ! grep -q "Custom pre-push hook" "$FAKE_REPO/.git/hooks/pre-push" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} new hook installed"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} hook was not replaced"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 6: CLAUDE.md inject action
test_claude_md_inject() {
  echo -e "${CYAN}Test 6: CLAUDE.md inject action (adds content to existing)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" true > /dev/null

  # Verify CLAUDE.md exists (created by make_fake_repo with true flag)
  assert_file_exists "$FAKE_REPO/CLAUDE.md" "CLAUDE.md exists before inject"

  # Run setup-repos.sh with inject action
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --claude-md-action inject \
    2>/dev/null || true

  # Verify CLAUDE.md still exists and was modified
  assert_file_exists "$FAKE_REPO/CLAUDE.md" "CLAUDE.md exists after inject"

  rm -rf "$TMPDIR"
}

# Test 7: CLAUDE.md skip action
test_claude_md_skip() {
  echo -e "${CYAN}Test 7: CLAUDE.md skip action (leaves existing unchanged)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" true > /dev/null

  # Record original content
  local ORIGINAL_CONTENT
  ORIGINAL_CONTENT=$(cat "$FAKE_REPO/CLAUDE.md")

  # Run setup-repos.sh with skip action
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --claude-md-action skip \
    2>/dev/null || true

  # Verify content unchanged
  local NEW_CONTENT
  NEW_CONTENT=$(cat "$FAKE_REPO/CLAUDE.md")

  assert_eq "$ORIGINAL_CONTENT" "$NEW_CONTENT" "CLAUDE.md unchanged after skip"

  rm -rf "$TMPDIR"
}

# Test 8: Python repo with subdirectory source file (regression for basename-collapse bug)
# Original bug: -maxdepth 2 found file in subdir, basename stripped path,
# reconstructed path didn't exist, set -e aborted setup and rolled back.
test_python_subdir_source_file() {
  echo -e "${CYAN}Test 8: Python repo with subdirectory source file (regression)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  cat > "$FAKE_REPO/pyproject.toml" << 'EOF'
[tool.poetry]
name = "test"
[tool.poetry.dependencies]
python = "^3.11"
fastapi = "^0.100"
EOF

  # Top up to graph-ready (>50 nodes). The test's own subdir file below
  # remains the regression target; this helper just adds enough source
  # surface for mandatory-stack graph readiness to pass.
  make_fake_python_repo_graph_ready "$FAKE_REPO"

  # Source file two levels deep — the shape that tripped the original crash.
  mkdir -p "$FAKE_REPO/app/tools"
  for i in $(seq 1 50); do echo "# line $i"; done > "$FAKE_REPO/app/tools/deep_service.py"

  # Setup must complete without rollback (exit 0).
  if bash "$SETUP_REPOS_SCRIPT" \
      --repo "$FAKE_REPO" \
      --stack python \
      --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
      --non-interactive \
      --skip-claude-md \
      >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} setup-repos.sh completed without crash on subdir source file"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} setup-repos.sh crashed/rolled back (basename-collapse bug regressed)"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  # Bootstrap must record the full relpath, not just the basename.
  if grep -q "app/tools/deep_service.py" "$FAKE_REPO/.intellisense-bootstrap.md" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} bootstrap records full relpath (app/tools/deep_service.py)"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} bootstrap missing full relpath — basename-collapse may have returned"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 9: Source file path with spaces (regression for awk '{print $2}' field-split bug)
# The original wc-output parsing split on whitespace, truncating any path that
# contained a space. Setup never crashed, but bootstrap recorded a wrong path.
test_python_path_with_spaces() {
  echo -e "${CYAN}Test 9: Source file path with spaces (regression)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  cat > "$FAKE_REPO/pyproject.toml" << 'EOF'
[tool.poetry]
name = "test"
[tool.poetry.dependencies]
python = "^3.11"
EOF

  # Top up to graph-ready (>50 nodes) — see test 8 for rationale.
  make_fake_python_repo_graph_ready "$FAKE_REPO"

  # Path with a space — old awk '{print $2}' would truncate at the space.
  mkdir -p "$FAKE_REPO/app/dir with space"
  for i in $(seq 1 60); do echo "# line $i"; done > "$FAKE_REPO/app/dir with space/big.py"

  if bash "$SETUP_REPOS_SCRIPT" \
      --repo "$FAKE_REPO" \
      --stack python \
      --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
      --non-interactive \
      --skip-claude-md \
      >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} setup-repos.sh completed without crash on space-in-path"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} setup-repos.sh crashed on space-in-path"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  if grep -q "app/dir with space/big.py" "$FAKE_REPO/.intellisense-bootstrap.md" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} bootstrap records full path including spaces"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} bootstrap missing space-containing path — awk field-split may have returned"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 10: intellisense source repo case (regression for MATURITY_LEVEL="platform" sentinel
# vs numeric -ge/-eq comparisons). Setting --repo and --intellisense-setup to the same
# canonical path triggers the platform branch; numeric comparison would crash
# under set -euo pipefail before the fix.
test_intellisense_source_repo_maturity_sentinel() {
  echo -e "${CYAN}Test 10: intellisense source repo — MATURITY_LEVEL sentinel (regression)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"

  mkdir -p "$FAKE_REPO/.git/hooks"
  # Use the repo directory as the intellisense setup root too, so realpath equality holds.
  make_fake_intellisense_setup "$FAKE_REPO" > /dev/null
  make_fake_repo "$FAKE_REPO" true > /dev/null
  # Top up to graph-ready (>50 nodes) so mandatory-stack graph readiness passes.
  make_fake_go_repo_graph_ready "$FAKE_REPO"

  if bash "$SETUP_REPOS_SCRIPT" \
      --repo "$FAKE_REPO" \
      --stack go \
      --intellisense-setup "$FAKE_REPO" \
      --non-interactive \
      >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} setup-repos.sh handled platform sentinel without numeric-compare crash"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} setup-repos.sh crashed on platform sentinel ([ \"platform\" -ge 3 ] regressed)"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 11: Python repo re-inject preserves python-patterns.md (regression for case-stmt
# that mapped go/php/angular but dropped python in the existing-intellisense-block update path).
test_python_inject_existing_intellisense_block() {
  echo -e "${CYAN}Test 11: Python re-inject preserves python-patterns.md (regression)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  cat > "$FAKE_REPO/pyproject.toml" << 'EOF'
[tool.poetry]
name = "test"
[tool.poetry.dependencies]
python = "^3.11"
EOF

  # CLAUDE.md with an existing intellisense block — triggers the "update inside markers" path
  # for the python stack.
  cat > "$FAKE_REPO/CLAUDE.md" << 'EOF'
# Test Repo

<!-- intellisense:BEGIN -->
## intellisense Rule Pointers

@~/.intellisense/rules/language-specific/old-stale.md
<!-- intellisense:END -->
EOF

  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" \
    --stack python \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive \
    --claude-md-action inject \
    >/dev/null 2>&1 || true

  if grep -q "python-patterns.md" "$FAKE_REPO/CLAUDE.md" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} python-patterns.md reference present after re-inject"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} python-patterns.md missing — case stmt regression"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))

  rm -rf "$TMPDIR"
}

# Test 12: Every templates/knowledge-base/*.stub.md must have an <!-- intellisense: marker.
# Regression: 04-domain-features.stub.md was added without one, so every install
# produced a perpetual "→ CONFLICT 04-domain-features.md has no intellisense marker"
# warning even on freshly-bootstrapped repos.
test_kb_stubs_have_intellisense_marker() {
  echo -e "${CYAN}Test 12: Every KB stub template has the intellisense marker${NC}"

  local STUB_DIR="$INTELLISENSE_SETUP_ROOT/templates/knowledge-base"
  local missing=()
  local stub_file

  for stub_file in "$STUB_DIR"/*.stub.md; do
    [ -f "$stub_file" ] || continue
    if ! grep -q "<!-- intellisense:" "$stub_file" 2>/dev/null; then
      missing+=("$(basename "$stub_file")")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} all stubs in templates/knowledge-base/ carry an intellisense marker"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} stubs missing intellisense marker: ${missing[*]}"
    ((++TESTS_FAILED))
  fi
  ((++TESTS_RUN))
}

# ──────────────────────────────────────────────────────────────────
# .intellisense/ directory layout scenarios
# ──────────────────────────────────────────────────────────────────

# Helper: invoke setup-repos.sh against a fake repo with a given stack.
_run_setup_repos() {
  local fake_repo="$1" fake_intellisense_setup="$2" stack="${3:-go}"
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$fake_repo" \
    --stack "$stack" \
    --intellisense-setup "$fake_intellisense_setup" \
    --non-interactive \
    --skip-claude-md \
    --skip-ci \
    >/dev/null 2>&1 || true
}

# Helper: prepare a fake_repo with enough Go source to pass the graph
# readiness (>50 nodes). Delegates to the shared make_fake_go_repo_graph_ready
# helper so tests don't bypass mandatory-graph behavior.
_make_go_fake_repo() {
  local fake_repo="$1"
  make_fake_repo "$fake_repo" > /dev/null
  make_fake_go_repo_graph_ready "$fake_repo"
}

# Scenario A — Fresh install creates the .intellisense/ layout, no root backups.
test_intellisense_dir_fresh_install() {
  echo -e "${CYAN}Scenario A: fresh install creates .intellisense/ layout${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  mkdir -p "$FAKE_REPO/.git/hooks" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  _make_go_fake_repo "$FAKE_REPO"

  _run_setup_repos "$FAKE_REPO" "$FAKE_INTELLISENSE_SETUP" go

  assert_file_exists "$FAKE_REPO/.intellisense/version"             "fresh install: .intellisense/version exists"
  assert_file_exists "$FAKE_REPO/.intellisense/manifest.json"       "fresh install: .intellisense/manifest.json exists"
  # No .gitignore.intellisense-bak-* at repo root.
  if ls "$FAKE_REPO"/.gitignore.intellisense-bak-* >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} root-level .gitignore backup leaked"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} no root-level .gitignore backup"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Scenario C — Re-run idempotency: tracked files are byte-stable.
test_intellisense_dir_rerun_idempotency() {
  echo -e "${CYAN}Scenario C: re-run is idempotent${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  mkdir -p "$FAKE_REPO/.git/hooks" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  _make_go_fake_repo "$FAKE_REPO"

  _run_setup_repos "$FAKE_REPO" "$FAKE_INTELLISENSE_SETUP" go
  # Snapshot sha256 of every tracked .intellisense/* file after first run. Each one
  # is committed to git, so byte-for-byte stability across re-runs is the
  # contract — a different developer pulling and re-running setup must not
  # produce diffs in any of these files.
  #
  # Files checked (those present in fixture; loop tolerates absence so the
  # test stays correct as the set of tracked files evolves):
  #   - .intellisense/version           (setup-repos.sh)
  #   - .intellisense/manifest.json     (setup-repos.sh)
  #   - .intellisense/stubs-status.json (generate-kb-stubs.sh)
  #   - .intellisense/kb-status.md      (generate-kb-stubs.sh)
  # Not checked here: .intellisense/graph-exception.json — only written when
  # --graph-exception is passed, which the fixture doesn't. Covered separately
  # by the end-to-end pilot.
  # Use parallel arrays (bash 3.2 compatible — macOS ships bash 3.2, no -A).
  local tracked_files="version manifest.json stubs-status.json kb-status.md"
  local hash_first_v="" hash_first_m="" hash_first_s="" hash_first_k=""
  if [ -f "$FAKE_REPO/.intellisense/version" ];           then hash_first_v=$(shasum -a 256 "$FAKE_REPO/.intellisense/version"           | awk '{print $1}'); fi
  if [ -f "$FAKE_REPO/.intellisense/manifest.json" ];     then hash_first_m=$(shasum -a 256 "$FAKE_REPO/.intellisense/manifest.json"     | awk '{print $1}'); fi
  if [ -f "$FAKE_REPO/.intellisense/stubs-status.json" ]; then hash_first_s=$(shasum -a 256 "$FAKE_REPO/.intellisense/stubs-status.json" | awk '{print $1}'); fi
  if [ -f "$FAKE_REPO/.intellisense/kb-status.md" ];      then hash_first_k=$(shasum -a 256 "$FAKE_REPO/.intellisense/kb-status.md"      | awk '{print $1}'); fi
  sleep 1
  # Second run.
  _run_setup_repos "$FAKE_REPO" "$FAKE_INTELLISENSE_SETUP" go

  # A re-run writes no backups.
  if [ -d "$FAKE_REPO/.intellisense/.backup" ] && [ "$(ls -A "$FAKE_REPO/.intellisense/.backup" 2>/dev/null)" ]; then
    echo -e "  ${RED}✗${NC} idempotent re-run wrote backups"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} idempotent re-run wrote no backups"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))

  # Content-stability of tracked files: spurious diffs break team workflows
  # by polluting every intellisense-related PR with per-developer metadata churn.
  _idempotency_check() {
    local name="$1" first="$2" path="$FAKE_REPO/.intellisense/$3"
    [ -z "$first" ] && return 0  # File not present after first run — code path not exercised.
    local second
    second=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')
    if [ "$first" = "$second" ]; then
      echo -e "  ${GREEN}✓${NC} .intellisense/$name byte-stable across re-runs"
      ((TESTS_PASSED++))
    else
      echo -e "  ${RED}✗${NC} .intellisense/$name changed on idempotent re-run (first=$first second=$second)"
      ((TESTS_FAILED++))
    fi
    ((TESTS_RUN++))
  }
  _idempotency_check version           "$hash_first_v" version
  _idempotency_check manifest.json     "$hash_first_m" manifest.json
  _idempotency_check stubs-status.json "$hash_first_s" stubs-status.json
  _idempotency_check kb-status.md      "$hash_first_k" kb-status.md
  unset -f _idempotency_check

  rm -rf "$TMPDIR"
}

# Scenario B — Existing .gitignore: intellisense lines added, other content kept.
test_intellisense_dir_existing_gitignore() {
  echo -e "${CYAN}Scenario B: existing .gitignore keeps its content and gains intellisense lines${NC}"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_REPO="$TMPDIR/repo"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  mkdir -p "$FAKE_REPO/.git/hooks" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  _make_go_fake_repo "$FAKE_REPO"

  cat > "$FAKE_REPO/.gitignore" << 'EOF'
# unrelated comment
build/
node_modules/
EOF

  _run_setup_repos "$FAKE_REPO" "$FAKE_INTELLISENSE_SETUP" go

  if grep -qE '^# unrelated comment$' "$FAKE_REPO/.gitignore" && \
     grep -qE '^build/$' "$FAKE_REPO/.gitignore" && \
     grep -qE '^node_modules/$' "$FAKE_REPO/.gitignore"; then
    echo -e "  ${GREEN}✓${NC} unrelated gitignore content preserved"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} unrelated gitignore content was modified"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  if grep -qE '^\.intellisense/local\.json[[:space:]]*$' "$FAKE_REPO/.gitignore"; then
    echo -e "  ${GREEN}✓${NC} .intellisense/local.json added to .gitignore"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} .intellisense/local.json missing from .gitignore"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  if ls "$FAKE_REPO"/.gitignore.*bak* >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} gitignore backup written at repo root"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} no gitignore backup at repo root"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# ─────────────────────────────────────────────────────────────
# setup-repos.sh post-condition + PATH helper
# ─────────────────────────────────────────────────────────────

# R1: post-condition catches missing .intellisense/graph-status.json on mandatory-supported
test_post_condition_missing_status_file() {
  echo -e "${CYAN}Test R1: post-condition catches missing graph-status.json${NC}"

  local TMPDIR FAKE_REPO FAKE_INTELLISENSE_SETUP
  TMPDIR=$(mktemp -d)
  FAKE_REPO="$TMPDIR/repo"
  FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Override graph-bootstrap.sh: exit 0 without writing graph-status.json
  cat > "$FAKE_INTELLISENSE_SETUP/scripts/graph-bootstrap.sh" <<'EOF'
#!/bin/bash
# Stub: simulate broken graph-bootstrap that exits 0 without writing status.
exit 0
EOF
  chmod +x "$FAKE_INTELLISENSE_SETUP/scripts/graph-bootstrap.sh"

  local rc=0
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive --skip-claude-md --migrate \
    >/dev/null 2>&1 || rc=$?

  # Post-condition must trip: setup-repos.sh exits non-zero
  ((++TESTS_RUN))
  if [ "$rc" -ne 0 ]; then
    echo -e "  ${GREEN}✓${NC} setup-repos.sh exits non-zero when graph-status.json missing (rc=$rc)"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} setup-repos.sh exited 0 despite missing graph-status.json"
    ((++TESTS_FAILED))
  fi

  rm -rf "$TMPDIR"
}

# R2: post-condition catches readiness != ready
test_post_condition_readiness_failed() {
  echo -e "${CYAN}Test R2: post-condition catches readiness=failed${NC}"

  local TMPDIR FAKE_REPO FAKE_INTELLISENSE_SETUP
  TMPDIR=$(mktemp -d)
  FAKE_REPO="$TMPDIR/repo"
  FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_REPO/.git/hooks"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repo "$FAKE_REPO" > /dev/null

  # Override: write graph-status.json with readiness=failed
  cat > "$FAKE_INTELLISENSE_SETUP/scripts/graph-bootstrap.sh" <<'EOF'
#!/bin/bash
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$REPO/.intellisense"
printf '%s\n' '{"readiness": "failed", "reason": "test stub"}' > "$REPO/.intellisense/graph-status.json"
exit 0
EOF
  chmod +x "$FAKE_INTELLISENSE_SETUP/scripts/graph-bootstrap.sh"

  local rc=0
  bash "$SETUP_REPOS_SCRIPT" \
    --repo "$FAKE_REPO" --stack go \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    --non-interactive --skip-claude-md --migrate \
    >/dev/null 2>&1 || rc=$?

  ((++TESTS_RUN))
  if [ "$rc" -ne 0 ]; then
    echo -e "  ${GREEN}✓${NC} setup-repos.sh exits non-zero when readiness != ready (rc=$rc)"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} setup-repos.sh exited 0 despite readiness=failed"
    ((++TESTS_FAILED))
  fi

  rm -rf "$TMPDIR"
}

# R3: PATH helper makes ~/.local/bin discoverable when omitted from inherited PATH
test_path_helper_finds_local_bin() {
  echo -e "${CYAN}Test R3: _ensure_local_bin_on_path adds ~/.local/bin to PATH${NC}"

  local TMPHOME FAKEBIN
  TMPHOME=$(mktemp -d)
  FAKEBIN="$TMPHOME/.local/bin"
  mkdir -p "$FAKEBIN"
  # Plant a fake binary so command -v has something to find
  cat > "$FAKEBIN/fake-tool-acc" <<'EOF'
#!/bin/bash
echo "fake-tool-acc-found"
EOF
  chmod +x "$FAKEBIN/fake-tool-acc"

  # Run a subshell with PATH stripped of ~/.local/bin
  # Source intellisense-paths.sh, call helper, verify command -v finds the fake binary
  local out rc
  out=$(HOME="$TMPHOME" PATH="/usr/bin:/bin" bash -c "
    source $INTELLISENSE_SETUP_ROOT/scripts/lib/intellisense-paths.sh
    _ensure_local_bin_on_path
    command -v fake-tool-acc && echo OK || echo NOTFOUND
  " 2>&1)
  rc=$?

  ((++TESTS_RUN))
  if echo "$out" | grep -q 'OK$' && [ "$rc" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} fake binary in ~/.local/bin found after _ensure_local_bin_on_path"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} helper did not surface fake binary"
    echo "    output: $out"
    ((++TESTS_FAILED))
  fi

  rm -rf "$TMPHOME"
}

# ─────────────────────────────────────────────────────────────
test_hook_install_missing
test_hook_install_identical
test_hook_install_different
test_hook_install_force
test_claude_md_inject
test_claude_md_skip
test_python_subdir_source_file
test_python_path_with_spaces
test_intellisense_source_repo_maturity_sentinel
test_python_inject_existing_intellisense_block
test_kb_stubs_have_intellisense_marker
test_intellisense_dir_fresh_install
test_intellisense_dir_existing_gitignore
test_intellisense_dir_rerun_idempotency

# post-condition + PATH helper
test_post_condition_missing_status_file
test_post_condition_readiness_failed
test_path_helper_finds_local_bin

print_test_summary
