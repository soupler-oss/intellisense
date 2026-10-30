#!/bin/bash

# test_restore.sh — Automated tests for restore.sh
# Tests cover: restore after fresh install, backup restoration, non-interactive flags, symlink handling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Setup test environment
INTELLISENSE_SETUP_ROOT="$SCRIPT_DIR/.."
RESTORE_SCRIPT="$INTELLISENSE_SETUP_ROOT/restore.sh"

# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: restore.sh${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Test 1: Restore after fresh install removes intellisense-managed symlinks
test_restore_fresh_install() {
  echo -e "${CYAN}Test 1: Restore after fresh install removes intellisense symlinks${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local INTELLISENSE_HOME="$FAKE_HOME/.intellisense"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$INTELLISENSE_HOME/rules"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"

  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Simulate setup.sh creating symlinks
  mkdir -p "$FAKE_HOME/.claude/rules"
  mkdir -p "$FAKE_HOME/.claude"
  ln -s "$FAKE_INTELLISENSE_SETUP/rules/baseline" "$FAKE_HOME/.claude/rules/baseline"
  ln -s "$FAKE_INTELLISENSE_SETUP/skills" "$FAKE_HOME/.claude/skills"
  ln -s "$FAKE_INTELLISENSE_SETUP/agents" "$FAKE_HOME/.claude/agents"

  # Create config.json so restore knows the INTELLISENSE_SETUP path
  cat > "$FAKE_HOME/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$FAKE_INTELLISENSE_SETUP"
}
EOF

  # Verify symlinks exist
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "symlinks exist before restore"

  # Run restore with --non-interactive --yes
  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    2>/dev/null || true

  # DEBUG: Print what actually exists after restore
  echo -e "  ${DIM}[DEBUG] Files in $FAKE_HOME/.claude/:${NC}"
  ls -la "$FAKE_HOME/.claude/" 2>/dev/null | tail -n +4 | sed 's/^/    /'
  if [ -d "$FAKE_HOME/.claude/rules" ]; then
    echo -e "  ${DIM}[DEBUG] Contents of $FAKE_HOME/.claude/rules/:${NC}"
    ls -la "$FAKE_HOME/.claude/rules/" 2>/dev/null | tail -n +4 | sed 's/^/    /'
  fi

  # Verify symlinks removed
  assert_file_missing "$FAKE_HOME/.claude/rules/baseline" "rules/baseline symlink removed"
  assert_file_missing "$FAKE_HOME/.claude/config.json" "config.json removed"

  rm -rf "$TMPDIR"
}

# Test 2: Restore after replacing pre-existing content restores backups
test_restore_with_backup() {
  echo -e "${CYAN}Test 2: Restore restores from backups${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"

  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Simulate pre-existing content that was backed up
  mkdir -p "$FAKE_HOME/.claude/rules/baseline.bak-20260424120000"
  cat > "$FAKE_HOME/.claude/rules/baseline.bak-20260424120000/my-rule.md" << 'EOF'
# My Custom Rule
Original content
EOF

  # Create symlink pointing to INTELLISENSE_SETUP
  mkdir -p "$FAKE_HOME/.claude/rules"
  ln -s "$FAKE_INTELLISENSE_SETUP/rules/baseline" "$FAKE_HOME/.claude/rules/baseline"

  # Create config.json
  cat > "$FAKE_HOME/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$FAKE_INTELLISENSE_SETUP"
}
EOF

  # Run restore
  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    2>/dev/null || true

  # Verify symlink removed and backup restored
  assert_file_missing "$FAKE_HOME/.claude/rules/baseline" "symlink removed after restore"
  assert_file_exists "$FAKE_HOME/.claude/rules/baseline/my-rule.md" "backup restored"

  rm -rf "$TMPDIR"
}

# Test 3: Restore with --dry-run shows what would happen
test_restore_dry_run() {
  echo -e "${CYAN}Test 3: Restore with --dry-run shows changes without applying${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"

  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Create symlinks
  mkdir -p "$FAKE_HOME/.claude/rules"
  mkdir -p "$FAKE_HOME/.claude"
  ln -s "$FAKE_INTELLISENSE_SETUP/rules/baseline" "$FAKE_HOME/.claude/rules/baseline"
  ln -s "$FAKE_INTELLISENSE_SETUP/skills" "$FAKE_HOME/.claude/skills"

  # Create config.json
  cat > "$FAKE_HOME/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$FAKE_INTELLISENSE_SETUP"
}
EOF

  # Run restore with --dry-run
  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    --dry-run \
    2>/dev/null || true

  # Verify symlinks still exist (not actually removed)
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "symlinks unchanged after dry-run"
  assert_file_exists "$FAKE_HOME/.claude/config.json" "config.json still exists after dry-run"

  rm -rf "$TMPDIR"
}

# Test 4: Restore --non-interactive without --yes cancels
test_restore_noninteractive_no_yes() {
  echo -e "${CYAN}Test 4: Restore --non-interactive without --yes cancels${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"

  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Create symlinks
  mkdir -p "$FAKE_HOME/.claude/rules"
  mkdir -p "$FAKE_HOME/.claude"
  ln -s "$FAKE_INTELLISENSE_SETUP/rules/baseline" "$FAKE_HOME/.claude/rules/baseline"

  # Create config.json
  cat > "$FAKE_HOME/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$FAKE_INTELLISENSE_SETUP"
}
EOF

  # Run restore --non-interactive WITHOUT --yes
  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    </dev/null \
    2>/dev/null || true

  # Verify symlinks still exist (restore was cancelled)
  assert_symlink_points_to "$FAKE_HOME/.claude/rules/baseline" "$FAKE_INTELLISENSE_SETUP/rules/baseline" "symlinks unchanged when restore cancelled"

  rm -rf "$TMPDIR"
}

# Test 5: Restore skips non-intellisense symlinks
test_restore_skip_non_intellisense_symlinks() {
  echo -e "${CYAN}Test 5: Restore skips non-intellisense symlinks${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local EXTERNAL_DIR="$TMPDIR/external"

  mkdir -p "$FAKE_HOME/.claude"
  mkdir -p "$FAKE_INTELLISENSE_SETUP"
  mkdir -p "$EXTERNAL_DIR"

  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null

  # Create intellisense-managed symlink
  mkdir -p "$FAKE_HOME/.claude/rules"
  mkdir -p "$FAKE_HOME/.claude"
  ln -s "$FAKE_INTELLISENSE_SETUP/rules/baseline" "$FAKE_HOME/.claude/rules/baseline"

  # Create non-intellisense symlink (points outside INTELLISENSE_SETUP)
  mkdir -p "$FAKE_HOME/.claude"
  ln -s "$EXTERNAL_DIR/external-rules" "$FAKE_HOME/.claude/external-skills"

  # Create config.json
  cat > "$FAKE_HOME/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$FAKE_INTELLISENSE_SETUP"
}
EOF

  # Run restore
  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    2>/dev/null || true

  # Verify intellisense symlink removed but non-intellisense symlink unchanged
  assert_file_missing "$FAKE_HOME/.claude/rules/baseline" "intellisense symlink removed"
  assert_symlink_points_to "$FAKE_HOME/.claude/external-skills" "$EXTERNAL_DIR/external-rules" "non-intellisense symlink preserved"

  rm -rf "$TMPDIR"
}

# Helper: stand up a fake repos-manifest.json + per-repo .intellisense/manifest.json
# fixture under $FAKE_HOME/.claude/. Returns nothing; populates the repos.
#
# Args:
#   $1 = FAKE_HOME (parent of .claude/)
#   $2 = REPOS_BASE (parent dir for the fake repos)
#   $3 = FAKE_INTELLISENSE_SETUP (passed through into config.json)
make_fake_repos_manifest() {
  local fake_home="$1"
  local repos_base="$2"
  local fake_setup="$3"

  mkdir -p \
    "$repos_base/r-with-original/.intellisense/.backup" \
    "$repos_base/r-with-original/knowledge-base" \
    "$repos_base/r-no-original/.intellisense" \
    "$repos_base/r-no-original/knowledge-base"

  echo "INTELLISENSE-INSTALLED CLAUDE.md" > "$repos_base/r-with-original/CLAUDE.md"
  echo "DEV ORIGINAL pre-intellisense"    > "$repos_base/r-with-original/.intellisense/.backup/CLAUDE.md.original"
  echo "kb-with-original"           > "$repos_base/r-with-original/knowledge-base/00.md"
  echo "INTELLISENSE-INSTALLED CLAUDE.md" > "$repos_base/r-no-original/CLAUDE.md"
  echo "kb-no-original"             > "$repos_base/r-no-original/knowledge-base/00.md"

  cat > "$repos_base/r-with-original/.intellisense/manifest.json" << 'EOF'
{"intellisense_manifest_version":"1","stack":"go","components":["claude-md","knowledge-base"]}
EOF
  cat > "$repos_base/r-no-original/.intellisense/manifest.json" << 'EOF'
{"intellisense_manifest_version":"1","stack":"go","components":["claude-md","knowledge-base"]}
EOF

  # Match setup.sh's actual format: `"path": "..."` with a space after the colon
  cat > "$fake_home/.claude/repos-manifest.json" << EOF
{
  "base_path": "$repos_base",
  "repos": [
    { "path": "$repos_base/r-with-original", "stack": "go" },
    { "path": "$repos_base/r-no-original",   "stack": "go" }
  ]
}
EOF

  cat > "$fake_home/.claude/config.json" << EOF
{
  "intellisense_setup_path": "$fake_setup"
}
EOF
}

# Test 6: Non-interactive --yes does NOT delete per-repo CLAUDE.md / knowledge-base/
# (safety default — repo artifacts only deleted when an interactive developer
# explicitly says yes to the per-repo prompt).
test_restore_noninteractive_preserves_repo_artifacts() {
  echo -e "${CYAN}Test 6: Non-interactive --yes preserves per-repo CLAUDE.md and knowledge-base/${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local REPOS_BASE="$TMPDIR/repos"

  mkdir -p "$FAKE_HOME/.claude" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repos_manifest "$FAKE_HOME" "$REPOS_BASE" "$FAKE_INTELLISENSE_SETUP"

  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    2>/dev/null || true

  assert_file_exists "$REPOS_BASE/r-with-original/CLAUDE.md" "r-with-original CLAUDE.md preserved (non-interactive)"
  assert_file_exists "$REPOS_BASE/r-with-original/knowledge-base/00.md" "r-with-original knowledge-base preserved"
  assert_file_exists "$REPOS_BASE/r-no-original/CLAUDE.md" "r-no-original CLAUDE.md preserved"
  assert_file_exists "$REPOS_BASE/r-no-original/knowledge-base/00.md" "r-no-original knowledge-base preserved"

  rm -rf "$TMPDIR"
}

# Test 7: Per-repo cleanup loop actually runs after repos-manifest.json is removed.
# Regression test for the bug where repos-manifest.json was deleted before the
# per-repo loop tried to read it, silently no-op'ing the entire block.
test_restore_per_repo_cleanup_runs() {
  echo -e "${CYAN}Test 7: Per-repo .intellisense/manifest.json is removed (regression: snapshot before delete)${NC}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local REPOS_BASE="$TMPDIR/repos"

  mkdir -p "$FAKE_HOME/.claude" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repos_manifest "$FAKE_HOME" "$REPOS_BASE" "$FAKE_INTELLISENSE_SETUP"

  HOME="$FAKE_HOME" bash "$RESTORE_SCRIPT" \
    --non-interactive \
    --yes \
    2>/dev/null || true

  assert_file_missing "$REPOS_BASE/r-with-original/.intellisense/manifest.json" "r-with-original .intellisense/manifest.json cleaned up"
  assert_file_missing "$REPOS_BASE/r-no-original/.intellisense/manifest.json"   "r-no-original .intellisense/manifest.json cleaned up"

  rm -rf "$TMPDIR"
}

# Test 8: Interactive yes restores CLAUDE.md from .backup when present
# and deletes knowledge-base/. Skipped if `expect` is not installed (CI safety).
test_restore_interactive_yes_deletes_repo_artifacts() {
  echo -e "${CYAN}Test 8: Interactive yes restores CLAUDE.md from the kept original, deletes knowledge-base/${NC}"

  if ! command -v expect >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⊘${NC} skipped: expect not installed (interactive prompt cannot be driven)"
    return 0
  fi

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local FAKE_HOME="$TMPDIR/home"
  local FAKE_INTELLISENSE_SETUP="$TMPDIR/intellisense_setup"
  local REPOS_BASE="$TMPDIR/repos"

  mkdir -p "$FAKE_HOME/.claude" "$FAKE_INTELLISENSE_SETUP"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" > /dev/null
  make_fake_repos_manifest "$FAKE_HOME" "$REPOS_BASE" "$FAKE_INTELLISENSE_SETUP"

  # expect script: answer "yes" to every prompt (top-level + each per-repo)
  cat > "$TMPDIR/run.exp" << EOF
#!/usr/bin/expect -f
set timeout 30
set env(HOME) "$FAKE_HOME"
spawn bash $RESTORE_SCRIPT
expect "Proceed? (yes/no)"
send "yes\r"
expect {
  "Delete these? (yes/no)" { send "yes\r"; exp_continue }
  "Restore Complete" { }
  timeout { exit 2 }
  eof { }
}
expect eof
EOF
  chmod +x "$TMPDIR/run.exp"
  expect "$TMPDIR/run.exp" >/dev/null 2>&1 || true

  # r-with-original: CLAUDE.md should be restored to the pre-intellisense original content
  assert_file_exists "$REPOS_BASE/r-with-original/CLAUDE.md" "r-with-original CLAUDE.md still present (restored)"
  if [ -f "$REPOS_BASE/r-with-original/CLAUDE.md" ]; then
    local content
    content=$(cat "$REPOS_BASE/r-with-original/CLAUDE.md")
    assert_eq "DEV ORIGINAL pre-intellisense" "$content" "r-with-original CLAUDE.md content matches the kept original"
  fi
  assert_file_missing "$REPOS_BASE/r-with-original/knowledge-base/00.md" "r-with-original knowledge-base deleted"

  # r-no-original: no .backup → CLAUDE.md is deleted outright
  assert_file_missing "$REPOS_BASE/r-no-original/CLAUDE.md" "r-no-original CLAUDE.md deleted (no original kept)"
  assert_file_missing "$REPOS_BASE/r-no-original/knowledge-base/00.md" "r-no-original knowledge-base deleted"

  rm -rf "$TMPDIR"
}

# ─────────────────────────────────────────────────────────────
test_restore_fresh_install
test_restore_with_backup
test_restore_dry_run
test_restore_noninteractive_no_yes
test_restore_skip_non_intellisense_symlinks
test_restore_noninteractive_preserves_repo_artifacts
test_restore_per_repo_cleanup_runs
test_restore_interactive_yes_deletes_repo_artifacts

print_test_summary
