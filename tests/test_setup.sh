#!/bin/bash

# test_setup.sh — Automated tests for setup.sh
# Tests cover: fresh install, re-run idempotency, pre-existing backups, non-interactive mode, rollback safety
#
# ──────────────────────────────────────────────────────────────────────────────
# Expected console noise: "Step 17: Install code-review-graph MCP" appears
# multiple times in this suite's stdout. This is INTENTIONAL and CORRECT.
#
# With the graph chosen (HARD-FAIL at global level), every invocation of setup.sh
# MUST verify code-review-graph==2.3.2 is installed. There is no skip flag and
# no test-mode bypass — adding one would create silent drift across the org
# and break the rule that a chosen graph is pinned exactly.
#
# When CRG is already installed (the normal case on developer machines), the
# step completes in <1s with "✓ already installed at required version" — it
# is NOT re-installing on each invocation, only re-verifying.
#
# If you see CRG install FAILURES (not verifications), that is a real bug; the
# suite will hard-fail at test_helpers via require_code_review_graph_or_fail.
# Pure noise from successful verification is expected and not a regression.
# ──────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Setup test environment
INTELLISENSE_SETUP_ROOT="$SCRIPT_DIR/.."
SETUP_SCRIPT="$INTELLISENSE_SETUP_ROOT/setup.sh"

# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: setup.sh${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Test helper: extract the `auto-detect stack` block from setup.sh into a
# sourceable shim, then invoke it against a fixture path. Lets us assert
# detection behavior without re-running the full setup flow.
#
# The block lives between markers "BEGIN: stack-detection" and
# "END: stack-detection" in setup.sh. If either marker disappears or the
# block changes shape, the extraction errors loudly — preventing silent test
# drift if someone refactors detection.
_run_stack_detection_against() {
  local REPO_PATH="$1"
  local TMP_SHIM
  TMP_SHIM=$(mktemp)

  awk '/# BEGIN: stack-detection/,/# END: stack-detection/' "$SETUP_SCRIPT" \
    > "$TMP_SHIM"

  if ! grep -q "BEGIN: stack-detection" "$TMP_SHIM"; then
    echo "ERR: stack-detection markers not found in setup.sh" >&2
    rm -f "$TMP_SHIM"
    echo "MARKER_MISSING"
    return
  fi

  REPO_PATH="$REPO_PATH" STACK="unknown" bash -c "
    REPO_PATH='$REPO_PATH'
    STACK='unknown'
    source '$TMP_SHIM'
    echo \"\$STACK\"
  " 2>/dev/null | tail -1

  rm -f "$TMP_SHIM"
}

# Test S1: manual stack prompt advertises node + react (in sync with auto-detect
# and with setup-repos.sh validator).
# Pre-fix bug: prompt offered only "go/php/angular/python" — a user whose repo
# wasn't auto-detected (e.g. NestJS monorepo) had no path to choose node/react
# manually, even though setup-repos.sh would accept them and templates exist.
test_manual_prompt_includes_node_react() {
  echo -e "${CYAN}Test S1: manual stack prompt advertises node and react${NC}"

  if grep -qE 'Enter stack \(go/php/angular/python/node/react\)' "$SETUP_SCRIPT"; then
    echo -e "  ${GREEN}✓${NC} prompt text includes node and react"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} prompt text missing node/react (regression)"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  # Validation arm must accept the new values.
  if grep -qE 'go\|php\|angular\|python\|node\|react\)' "$SETUP_SCRIPT"; then
    echo -e "  ${GREEN}✓${NC} validation arm accepts node|react"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} validation arm does not accept node|react"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))
}

# Test S2: stack-detection helper block is delimited by markers (enforces that
# refactors keep the extraction shim usable for tests).
test_stack_detection_markers_present() {
  echo -e "${CYAN}Test S2: stack-detection block has BEGIN/END markers${NC}"

  if grep -q "# BEGIN: stack-detection" "$SETUP_SCRIPT" \
     && grep -q "# END: stack-detection" "$SETUP_SCRIPT"; then
    echo -e "  ${GREEN}✓${NC} markers present"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} markers missing — tests below will fail extraction"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))
}

# Test S3: auto-detect at repo root — go.
test_detect_root_go() {
  echo -e "${CYAN}Test S3: auto-detect — root go.mod → go${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  touch "$TMPREPO/go.mod"
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "go" "$RESULT" "root go.mod detected as go"
  rm -rf "$TMPREPO"
}

# Test S4: auto-detect at repo root — python.
test_detect_root_python() {
  echo -e "${CYAN}Test S4: auto-detect — root pyproject.toml → python${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  touch "$TMPREPO/pyproject.toml"
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "python" "$RESULT" "root pyproject.toml detected as python"
  rm -rf "$TMPREPO"
}

# Test S5: auto-detect at repo root — node (NestJS).
test_detect_root_node_nestjs() {
  echo -e "${CYAN}Test S5: auto-detect — root NestJS package.json → node${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  cat > "$TMPREPO/package.json" << 'EOF'
{"name":"x","dependencies":{"@nestjs/core":"^10"}}
EOF
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "node" "$RESULT" "root NestJS package.json detected as node"
  rm -rf "$TMPREPO"
}

# Test S6: auto-detect at repo root — react.
test_detect_root_react() {
  echo -e "${CYAN}Test S6: auto-detect — root React package.json → react${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  cat > "$TMPREPO/package.json" << 'EOF'
{"name":"x","dependencies":{"react":"^18","react-dom":"^18"}}
EOF
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "react" "$RESULT" "root React package.json detected as react"
  rm -rf "$TMPREPO"
}

# Test S7: monorepo fallback — single nested package.json detects through one
# subdirectory. Regression for example/api-service layout (NestJS in subdir).
test_detect_monorepo_single_nested() {
  echo -e "${CYAN}Test S7: monorepo — single nested NestJS subdir → node${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  mkdir -p "$TMPREPO/wave-api"
  cat > "$TMPREPO/wave-api/package.json" << 'EOF'
{"name":"x","dependencies":{"@nestjs/core":"^10"}}
EOF
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "node" "$RESULT" "monorepo with single nested NestJS subdir detected as node"
  rm -rf "$TMPREPO"
}

# Test S8: monorepo fallback — single nested go.mod.
test_detect_monorepo_single_nested_go() {
  echo -e "${CYAN}Test S8: monorepo — single nested go.mod → go${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  mkdir -p "$TMPREPO/services/api"
  # Place under a one-level subdir (services/, which itself contains api/);
  # depth-1 scan should find go.mod at $TMPREPO/services/ if present, not
  # two levels deep. Use one-level layout to match the implemented contract.
  mkdir -p "$TMPREPO/api"
  touch "$TMPREPO/api/go.mod"
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "go" "$RESULT" "monorepo with single nested go.mod detected as go"
  rm -rf "$TMPREPO"
}

# Test S9: monorepo fallback — polyglot stays "unknown" (refuses to guess).
# Two subdirs with different stacks → detection must NOT silently pick one.
test_detect_monorepo_polyglot_stays_unknown() {
  echo -e "${CYAN}Test S9: monorepo — polyglot (node + go) stays unknown${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  mkdir -p "$TMPREPO/api" "$TMPREPO/worker"
  cat > "$TMPREPO/api/package.json" << 'EOF'
{"dependencies":{"@nestjs/core":"^10"}}
EOF
  touch "$TMPREPO/worker/go.mod"
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "unknown" "$RESULT" "polyglot monorepo refuses to guess"
  rm -rf "$TMPREPO"
}

# Test S10: monorepo fallback — common non-source dirs (node_modules, vendor,
# dist, .git) ignored. node_modules ALWAYS contains package.json files.
test_detect_monorepo_skips_noise_dirs() {
  echo -e "${CYAN}Test S10: monorepo — node_modules/vendor/dist ignored${NC}"
  local TMPREPO; TMPREPO=$(mktemp -d)
  mkdir -p "$TMPREPO/node_modules/lodash" "$TMPREPO/vendor/foo" "$TMPREPO/dist"
  cat > "$TMPREPO/node_modules/lodash/package.json" << 'EOF'
{"name":"lodash","dependencies":{"react":"^18"}}
EOF
  cat > "$TMPREPO/vendor/foo/package.json" << 'EOF'
{"dependencies":{"@nestjs/core":"^10"}}
EOF
  local RESULT; RESULT=$(_run_stack_detection_against "$TMPREPO")
  assert_eq "unknown" "$RESULT" "noise dirs ignored — no false positive"
  rm -rf "$TMPREPO"
}

# Test 1: Fresh install creates symlinks and config
test_fresh_install() {
  echo -e "${CYAN}Test 1: Fresh install creates symlinks and config${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"

  # Create minimal INTELLISENSE_SETUP structure
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Run setup.sh in non-interactive mode with minimal config
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    2>/dev/null || true

  # Verify symlinks created
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "rules/baseline symlink created"
  assert_symlink_points_to "$FAKE_HOME/.claude/skills" "$FAKE_INTELLISENSE_SETUP/skills" "skills symlink created"
  assert_file_exists "$FAKE_HOME/.claude/config.json" "config.json created"

  # Verify pre-existing content not wiped
  touch "$FAKE_HOME/.claude/MEMORY.md"
  assert_file_exists "$FAKE_HOME/.claude/MEMORY.md" "pre-existing MEMORY.md preserved"

  rm -rf "$TMPDIR"
}

# Test 2: Re-run on existing install skips already-created items
test_rerun_idempotency() {
  echo -e "${CYAN}Test 2: Re-run on existing install skips correctly${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # First run
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    2>/dev/null || true

  # Record first symlink timestamp
  local FIRST_TIMESTAMP
  FIRST_TIMESTAMP=$(stat -c "%Y" "$FAKE_HOME/.claude/rules/baseline" 2>/dev/null || stat -f "%m" "$FAKE_HOME/.claude/rules/baseline" 2>/dev/null || echo "")

  sleep 1

  # Second run
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    2>/dev/null || true

  # Verify symlinks still point correctly and config exists
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "symlink unchanged on re-run"
  assert_file_exists "$FAKE_HOME/.claude/config.json" "config.json still exists"

  rm -rf "$TMPDIR"
}

# Test 3: Pre-existing real directory at symlink destination gets backed up
test_preexisting_directory_backup() {
  echo -e "${CYAN}Test 3: Pre-existing real directory backed up, symlink installed${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Create pre-existing real directory at symlink destination
  mkdir -p "$FAKE_HOME/.claude/rules/baseline"
  touch "$FAKE_HOME/.claude/rules/baseline/my-custom-rule.md"

  # Run setup.sh
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    2>/dev/null || true

  # Verify symlink created
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "symlink installed over pre-existing directory"

  # Verify backup exists in ~/.intellisense-backups/ (NOT as a sibling — that path
  # was inside Claude Code's auto-load surface and bloated the system prompt).
  local BACKUPS
  BACKUPS=$(ls "$FAKE_HOME/.intellisense-backups/baseline.bak-"* 2>/dev/null | wc -l)
  local SIBLING_BAKS
  SIBLING_BAKS=$(ls -d "$FAKE_HOME/.claude/rules/baseline.bak-"* 2>/dev/null | wc -l)
  if [ "$BACKUPS" -gt 0 ] && [ "$SIBLING_BAKS" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} backup created in ~/.intellisense-backups/ (no sibling .bak-*)"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} backup not in ~/.intellisense-backups/ (or sibling .bak-* still exists)"
    echo -e "      ~/.intellisense-backups count: $BACKUPS  sibling count: $SIBLING_BAKS"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 4: Non-interactive mode completes without blocking
test_noninteractive_no_blocking() {
  echo -e "${CYAN}Test 4: Non-interactive mode completes without blocking${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Run with timeout — should complete without blocking
  local EXIT_CODE=0
  timeout 10s bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    </dev/null \
    >/dev/null 2>&1 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -eq 124 ]; then
    echo -e "  ${RED}✗${NC} non-interactive mode blocked (timeout)"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} non-interactive mode completed without blocking"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 5: Rollback on failure removes only run-created items
test_rollback_safety() {
  echo -e "${CYAN}Test 5: Rollback on failure preserves pre-existing content${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Create pre-existing content that should survive rollback
  mkdir -p "$FAKE_HOME/.claude/teams"
  touch "$FAKE_HOME/.claude/teams/my-team.json"
  touch "$FAKE_HOME/.claude/MEMORY.md"

  # Run setup.sh with --dry-run to verify it doesn't delete existing content
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --dry-run \
    --skip-repo-setup \
    2>/dev/null || true

  # Verify pre-existing content still present after dry-run
  assert_file_exists "$FAKE_HOME/.claude/teams/my-team.json" "teams/ directory preserved"
  assert_file_exists "$FAKE_HOME/.claude/MEMORY.md" "MEMORY.md preserved"

  rm -rf "$TMPDIR"
}

# Test 6: Re-run validation reports intellisense symlinks as healthy (regression).
# Pre-fix bug: INTELLISENSE_HOME was set inside Steps 1-13 only. On a version-match
# re-run those steps were skipped, leaving INTELLISENSE_HOME unset. Step 14's
# verification then checked "/rules/language-specific" (empty prefix) and printed
# [FAILED] even though the symlinks were healthy.
test_rerun_validation_intellisense_symlinks() {
  echo -e "${CYAN}Test 6: Re-run validation reports intellisense symlinks as healthy${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # First run: fresh install creates all symlinks, including intellisense ones,
  # and writes ~/.claude/.intellisense-version so the second run takes the skip-path.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  # Sanity: the intellisense symlinks must actually exist before the regression
  # check is meaningful.
  if [ -L "$FAKE_HOME/.intellisense/rules/language-specific" ] \
     && [ -L "$FAKE_HOME/.intellisense/rules/operational" ]; then
    echo -e "  ${GREEN}✓${NC} intellisense symlinks created on first run"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} intellisense symlinks not created — test setup invalid"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
    rm -rf "$TMPDIR"
    return
  fi
  ((TESTS_RUN++))

  # Second run: version matches → Steps 1-13 skipped → Step 14 must still
  # resolve $INTELLISENSE_HOME correctly.
  local SECOND_OUTPUT
  SECOND_OUTPUT=$(HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    2>&1 || true)

  if echo "$SECOND_OUTPUT" | grep -qE '\[FAILED\].*\.intellisense/rules/(language-specific|operational)'; then
    echo -e "  ${RED}✗${NC} re-run reports [FAILED] for healthy intellisense symlinks (regression)"
    ((TESTS_FAILED++))
  else
    echo -e "  ${GREEN}✓${NC} re-run reports intellisense symlinks as healthy"
    ((TESTS_PASSED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 7: Step 16.5 anchors .beads/hooks/pre-push to INTELLISENSE_SETUP, not caller CWD.
# Pre-fix bug: relative ".beads/hooks" path leaked the hook copy into whatever
# directory setup.sh was invoked from when called by absolute path.
test_beads_hook_anchored_to_intellisense_setup() {
  echo -e "${CYAN}Test 7: .beads/hooks anchored to INTELLISENSE_SETUP, not caller CWD${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local CALLER_CWD="$TMPDIR/caller_cwd"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  mkdir -p "$CALLER_CWD"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Invoke setup.sh from a CWD that is NOT INTELLISENSE_SETUP. Pre-fix this would drop
  # the hook into "$CALLER_CWD/.beads/hooks/pre-push".
  ( cd "$CALLER_CWD" && \
      HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
        --non-interactive \
        --skip-repo-setup \
        --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
        >/dev/null 2>&1 ) || true

  if [ -f "$CALLER_CWD/.beads/hooks/pre-push" ]; then
    echo -e "  ${RED}✗${NC} hook leaked into caller CWD (relative-path regression)"
    ((TESTS_FAILED++))
  elif [ -f "$FAKE_INTELLISENSE_SETUP/.beads/hooks/pre-push" ]; then
    echo -e "  ${GREEN}✓${NC} hook correctly anchored to INTELLISENSE_SETUP"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} hook not found in either location"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 8: ~/.claude/CLAUDE.md regenerated on re-run when missing.
# intellisense owns the file; missing/corrupted CLAUDE.md must
# self-heal on the next setup.sh run, even on the version-match fast path.
test_global_claude_md_regenerated_when_missing() {
  echo -e "${CYAN}Test 8: ~/.claude/CLAUDE.md regenerated on re-run when missing${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # First run: fresh install creates CLAUDE.md and writes .intellisense-version.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  assert_file_exists "$FAKE_HOME/.claude/CLAUDE.md" "fresh install creates CLAUDE.md"

  # Developer (accidentally) deletes the file.
  rm -f "$FAKE_HOME/.claude/CLAUDE.md"
  assert_file_missing "$FAKE_HOME/.claude/CLAUDE.md" "deletion confirmed"

  # Second run: version matches → version-match path. Today this skips Step 10
  # and CLAUDE.md stays missing. After the gc5 change, the regenerate function
  # runs unconditionally and the file is restored.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  assert_file_exists "$FAKE_HOME/.claude/CLAUDE.md" "re-run regenerates missing CLAUDE.md"

  if [ -f "$FAKE_HOME/.claude/CLAUDE.md" ] \
     && grep -q "intellisense Managed" "$FAKE_HOME/.claude/CLAUDE.md"; then
    echo -e "  ${GREEN}✓${NC} regenerated CLAUDE.md has intellisense managed header"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} regenerated CLAUDE.md missing intellisense managed header"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 9: existing CLAUDE.md is backed up (no .md extension), fresh one written.
# Verifies that intellisense ownership replaces drifted content and that the prior copy
# is preserved under $HOME/.intellisense-backups/ outside Claude Code's auto-load path.
test_global_claude_md_backed_up_then_regenerated() {
  echo -e "${CYAN}Test 9: existing CLAUDE.md backed up to CLAUDE.bak-<ts>, fresh written${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local SENTINEL="INTELLISENSE-TEST-SENTINEL-9-$$"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # First run installs CLAUDE.md, version, symlinks.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  # Developer "edits" the file (or it drifts on disk somehow).
  echo "$SENTINEL" >> "$FAKE_HOME/.claude/CLAUDE.md"

  # Second run: should back up the sentinel-bearing file and regenerate.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  # Assertion 1: backup file exists at the new location with CLAUDE.bak-<ts> naming.
  local BACKUP_FILE
  BACKUP_FILE=$(ls -1 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-"* 2>/dev/null | head -1)
  if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo -e "  ${GREEN}✓${NC} backup created at ~/.intellisense-backups/CLAUDE.bak-<ts>"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} no backup file at ~/.intellisense-backups/CLAUDE.bak-*"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  # Assertion 2: backup must NOT have .md extension (so $HOME/**/*.md globs miss it).
  local MD_BACKUPS
  MD_BACKUPS=$(ls -1 "$FAKE_HOME/.intellisense-backups/"CLAUDE*.md.* \
            "$FAKE_HOME/.intellisense-backups/"CLAUDE.md.bak-* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$MD_BACKUPS" = "0" ]; then
    echo -e "  ${GREEN}✓${NC} backup filename has no .md extension"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} backup filename leaks .md extension ($MD_BACKUPS matches)"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  # Assertion 3: backup contains the sentinel from the pre-replacement file.
  if [ -n "$BACKUP_FILE" ] && grep -q "$SENTINEL" "$BACKUP_FILE" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} backup preserves pre-replacement content (sentinel found)"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} backup does not contain sentinel"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  # Assertion 4: regenerated CLAUDE.md does NOT carry the sentinel (it is fresh).
  if [ -f "$FAKE_HOME/.claude/CLAUDE.md" ] \
     && ! grep -q "$SENTINEL" "$FAKE_HOME/.claude/CLAUDE.md"; then
    echo -e "  ${GREEN}✓${NC} regenerated CLAUDE.md is fresh (sentinel absent)"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} regenerated CLAUDE.md still contains sentinel (not regenerated)"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# Test 10: backup retention capped at 3 — oldest CLAUDE.bak-<ts> files pruned.
# Prevents $HOME/.intellisense-backups/ from growing unbounded across many setup runs.
test_global_claude_md_backup_retention_3() {
  echo -e "${CYAN}Test 10: CLAUDE.md backup retention capped at 3 (oldest pruned)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_HOME/.intellisense-backups"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # First run installs CLAUDE.md and writes .intellisense-version (version-match path
  # active on the second run).
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  # Pre-seed 4 backups with explicit old mtimes so `ls -1t` reliably orders
  # them oldest-last regardless of filesystem timestamp granularity.
  local TS
  for TS in 20200101000000 20200102000000 20200103000000 20200104000000; do
    echo "pre-seeded-$TS" > "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-$TS"
  done
  touch -t 202001010000 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200101000000"
  touch -t 202001020000 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200102000000"
  touch -t 202001030000 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200103000000"
  touch -t 202001040000 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200104000000"

  # Mutate CLAUDE.md so the next run produces a fresh backup (5 total before prune).
  echo "rotation-trigger" >> "$FAKE_HOME/.claude/CLAUDE.md"

  # Re-run setup. After regen: 5 backups briefly, prune cuts to 3 newest by mtime.
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" \
    --non-interactive \
    --skip-repo-setup \
    --intellisense-setup "$FAKE_INTELLISENSE_SETUP" \
    >/dev/null 2>&1 || true

  local FINAL_COUNT
  FINAL_COUNT=$(ls -1 "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-"* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$FINAL_COUNT" = "3" ]; then
    echo -e "  ${GREEN}✓${NC} exactly 3 CLAUDE.bak-* files retained after prune"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} expected 3 backups, got $FINAL_COUNT"
    ls -la "$FAKE_HOME/.intellisense-backups/" 2>&1 | sed 's/^/      /'
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  # The two oldest pre-seeded ones must be the casualties.
  if [ ! -f "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200101000000" ] \
     && [ ! -f "$FAKE_HOME/.intellisense-backups/CLAUDE.bak-20200102000000" ]; then
    echo -e "  ${GREEN}✓${NC} two oldest pre-seeded backups pruned"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} oldest pre-seeded backups still present"
    ((TESTS_FAILED++))
  fi
  ((TESTS_RUN++))

  rm -rf "$TMPDIR"
}

# ─────────────────────────────────────────────────────────────
test_manual_prompt_includes_node_react
test_stack_detection_markers_present
test_detect_root_go
test_detect_root_python
test_detect_root_node_nestjs
test_detect_root_react
test_detect_monorepo_single_nested
test_detect_monorepo_single_nested_go
test_detect_monorepo_polyglot_stays_unknown
test_detect_monorepo_skips_noise_dirs
test_fresh_install
test_rerun_idempotency
test_preexisting_directory_backup
test_noninteractive_no_blocking
test_rollback_safety
test_rerun_validation_intellisense_symlinks
test_beads_hook_anchored_to_intellisense_setup
test_global_claude_md_regenerated_when_missing
test_global_claude_md_backed_up_then_regenerated
test_global_claude_md_backup_retention_3

print_test_summary
