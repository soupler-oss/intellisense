#!/bin/bash
# tests/test_backup_location.sh — where intellisense writes and reads its backups.
#
# Verifies:
#   S1 setup.sh's create_symlink_safe writes backups to ~/.intellisense-backups/, not as
#      a sibling of $DST (which would land inside Claude Code's auto-load path).
#   S2 scripts/lib/hooks.sh's install_hook_safe writes hook backups to
#      ~/.intellisense-backups/repo-hooks/ with path-encoded names.
#   S3 restore.sh restores from a backup in ~/.intellisense-backups/.
#
# Every scenario runs with HOME=$(mktemp -d) so the developer's real ~/.claude
# and ~/.claude-intellisense are never touched.

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

case_pass() { echo "  ✓ $1"; echo "P" >> "$RESULTS"; }
case_fail() { echo "  ✗ $1: $2"; echo "F" >> "$RESULTS"; }

# Pull a single bash function definition out of a file. Brace-matched across
# multiple lines so we can source individual functions without running the
# script's main flow.
extract_func() {
  local file="$1" name="$2"
  awk -v fn="$name" '
    !in_fn && $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" {
      in_fn = 1
      depth = gsub(/\{/, "{") - gsub(/\}/, "}")
      print
      next
    }
    in_fn {
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth <= 0) exit
    }
  ' "$file"
}

make_fixture() {
  ISO_HOME="$(mktemp -d)"
  ISO_BACKUPS="$ISO_HOME/.intellisense-backups"
  export HOME="$ISO_HOME"
  export INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS"
}

cleanup_fixture() {
  rm -rf "$ISO_HOME" 2>/dev/null || true
}

# Color stubs used by sourced functions.
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; NC=""

# ─────────────────────────────────────────────────────────────────────
# S1: create_symlink_safe writes backups to ~/.intellisense-backups/
# ─────────────────────────────────────────────────────────────────────
make_fixture
CREATED_SYMLINKS=()
BACKED_UP_ITEMS=()
status_line() { :; }
S1_FUNC="$(extract_func "$INTELLISENSE_SETUP/setup.sh" create_symlink_safe)"
if [ -z "$S1_FUNC" ]; then
  case_fail "S1" "could not extract create_symlink_safe from setup.sh"
else
  eval "$S1_FUNC"
  mkdir -p "$ISO_HOME/.claude/skills/realdir"
  echo "marker-content" > "$ISO_HOME/.claude/skills/realdir/file.txt"
  DST="$ISO_HOME/.claude/skills"
  SRC="$INTELLISENSE_SETUP/skills"
  create_symlink_safe "$SRC" "$DST" "test-skills" >/dev/null 2>&1 || true

  sibling_bak="$(ls -d "${DST}.bak-"* 2>/dev/null || true)"
  new_bak="$(ls -d "$ISO_BACKUPS/skills.bak-"* 2>/dev/null | head -1 || true)"

  if [ -L "$DST" ] && [ -z "$sibling_bak" ] && [ -n "$new_bak" ] \
     && [ -f "$new_bak/realdir/file.txt" ]; then
    case_pass "S1 setup.sh-backup-lands-in-intellisense-backups"
  else
    case_fail "S1" "expected symlink + backup under $ISO_BACKUPS, no sibling .bak-*"
    echo "    DST is symlink: $([ -L "$DST" ] && echo yes || echo no)"
    echo "    Sibling bak:    ${sibling_bak:-<none>}"
    echo "    New bak:        ${new_bak:-<none>}"
  fi
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# S2: install_hook_safe writes hook backups to ~/.intellisense-backups/repo-hooks/
# ─────────────────────────────────────────────────────────────────────
make_fixture
# shellcheck disable=SC1091
source "$INTELLISENSE_SETUP/scripts/lib/hooks.sh"
mkdir -p "$ISO_HOME/repo/.git/hooks"
printf '#!/bin/bash\necho new\n' > "$ISO_HOME/src.sh"
printf '#!/bin/bash\necho old\n' > "$ISO_HOME/repo/.git/hooks/pre-push"
install_hook_safe "$ISO_HOME/src.sh" "$ISO_HOME/repo/.git/hooks/pre-push" "test-hook" "true" >/dev/null 2>&1 || true

repo_hook_bak="$(ls "$ISO_BACKUPS/repo-hooks/"*.bak-* 2>/dev/null | head -1 || true)"
sibling_hook_bak="$(ls "$ISO_HOME/repo/.git/hooks/pre-push.bak-"* 2>/dev/null || true)"

if [ -n "$repo_hook_bak" ] && [ -z "$sibling_hook_bak" ]; then
  case_pass "S2 hooks.sh-backup-lands-in-repo-hooks"
else
  case_fail "S2" "expected backup under $ISO_BACKUPS/repo-hooks/, none or sibling found"
  echo "    repo-hooks bak:  ${repo_hook_bak:-<none>}"
  echo "    sibling bak:     ${sibling_hook_bak:-<none>}"
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# S3: restore.sh restores from a backup at the new location
# ─────────────────────────────────────────────────────────────────────
make_fixture
mkdir -p "$ISO_HOME/.claude/rules"
ln -sf "$INTELLISENSE_SETUP/rules/baseline" "$ISO_HOME/.claude/rules/baseline"
mkdir -p "$ISO_BACKUPS/baseline.bak-20200101000000"
echo "new-location-original" > "$ISO_BACKUPS/baseline.bak-20200101000000/marker.txt"
# config.json points restore.sh at the right INTELLISENSE_SETUP_DIR.
mkdir -p "$ISO_HOME/.claude"
cat > "$ISO_HOME/.claude/config.json" <<EOF
{ "intellisense_setup_path": "$INTELLISENSE_SETUP" }
EOF
HOME="$ISO_HOME" INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS" \
  bash "$INTELLISENSE_SETUP/restore.sh" --non-interactive --yes >/dev/null 2>&1 || true

if [ -d "$ISO_HOME/.claude/rules/baseline" ] \
   && [ ! -L "$ISO_HOME/.claude/rules/baseline" ] \
   && [ "$(cat "$ISO_HOME/.claude/rules/baseline/marker.txt" 2>/dev/null)" = "new-location-original" ]; then
  case_pass "S3 restore-from-new-location"
else
  case_fail "S3" "restore did not move backup from $ISO_BACKUPS back to original path"
  ls -la "$ISO_HOME/.claude/rules/" 2>&1 | sed 's/^/    /'
  ls -la "$ISO_BACKUPS" 2>&1 | sed 's/^/    /'
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# Helper: build an isolated $HOME with a complete fake INTELLISENSE_SETUP and
# pre-installed critical symlinks. Returns 0 if HOME is fully prepped to
# trigger setup.sh's version-skip path (when ~/.claude/.intellisense-version matches).
# ─────────────────────────────────────────────────────────────────────
build_full_fake_home() {
  # shellcheck disable=SC1091
  source "$INTELLISENSE_SETUP/tests/helpers.sh" >/dev/null 2>&1 || true

  FAKE_INTELLISENSE_SETUP="$ISO_HOME/fake_intellisense_setup"
  make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" >/dev/null

  CLAUDE_HOME_T="$ISO_HOME/.claude"
  SHIP_T="$ISO_HOME/.intellisense"
  mkdir -p "$CLAUDE_HOME_T/rules" "$SHIP_T/rules"

  ln -sf "$FAKE_INTELLISENSE_SETUP/rules/baseline"           "$CLAUDE_HOME_T/rules/baseline"
  ln -sf "$FAKE_INTELLISENSE_SETUP/skills"                   "$CLAUDE_HOME_T/skills"
  ln -sf "$FAKE_INTELLISENSE_SETUP/agents"                   "$CLAUDE_HOME_T/agents"
  ln -sf "$FAKE_INTELLISENSE_SETUP/templates"                "$CLAUDE_HOME_T/templates"
  ln -sf "$FAKE_INTELLISENSE_SETUP/infrastructure"           "$CLAUDE_HOME_T/infrastructure"
  ln -sf "$FAKE_INTELLISENSE_SETUP/infrastructure/service-map.md" "$CLAUDE_HOME_T/service-map.md"
  ln -sf "$FAKE_INTELLISENSE_SETUP/rules/language-specific"  "$SHIP_T/rules/language-specific"
  ln -sf "$FAKE_INTELLISENSE_SETUP/rules/operational"        "$SHIP_T/rules/operational"
}

# ─────────────────────────────────────────────────────────────────────
# S7: end-to-end version-match — NO new bak created
#     because all symlinks are healthy and SKIP_TO_VALIDATION=true.
# ─────────────────────────────────────────────────────────────────────
make_fixture
build_full_fake_home

# Version-match: write .intellisense-version exactly equal to fake VERSION
echo "INTELLISENSE_VERSION=1.0-test" > "$ISO_HOME/.claude/.intellisense-version"

HOME="$ISO_HOME" INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS" \
  bash "$INTELLISENSE_SETUP/setup.sh" --non-interactive --skip-repo-setup \
  --intellisense-setup "$FAKE_INTELLISENSE_SETUP" >/dev/null 2>&1 || true

# Assertions
new_bak_count=$(find "$ISO_BACKUPS" -maxdepth 1 -type d -name '*.bak-*' 2>/dev/null | wc -l | tr -d ' ')

if [ "$new_bak_count" -eq 0 ]; then
  case_pass "S7 version-match-creates-no-new-bak"
else
  case_fail "S7" "version-match path did not behave as expected"
  echo "    new top-level baks count: $new_bak_count"
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# S8: end-to-end version-mismatch — a real dir at $CLAUDE_HOME/skills
#     triggers a NEW bak in ~/.intellisense-backups/.
# ─────────────────────────────────────────────────────────────────────
make_fixture
FAKE_INTELLISENSE_SETUP="$ISO_HOME/fake_intellisense_setup"
# shellcheck disable=SC1091
source "$INTELLISENSE_SETUP/tests/helpers.sh" >/dev/null 2>&1 || true
make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" >/dev/null

CLAUDE_HOME_T="$ISO_HOME/.claude"
mkdir -p "$CLAUDE_HOME_T"

# Version-mismatch: stale .intellisense-version triggers full re-setup
echo "INTELLISENSE_VERSION=0.0.0-stale" > "$CLAUDE_HOME_T/.intellisense-version"

# Real DIR (not symlink) at one of the install targets — triggers backup logic
mkdir -p "$CLAUDE_HOME_T/skills/preexisting"
echo "user-content" > "$CLAUDE_HOME_T/skills/preexisting/file.txt"

HOME="$ISO_HOME" INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS" \
  bash "$INTELLISENSE_SETUP/setup.sh" --non-interactive --skip-repo-setup \
  --intellisense-setup "$FAKE_INTELLISENSE_SETUP" >/dev/null 2>&1 || true

# Assertions
new_skills_bak=$(ls -d "$ISO_BACKUPS/skills.bak-"* 2>/dev/null | head -1 || true)
sibling_bak=$(ls -d "$CLAUDE_HOME_T/skills.bak-"* 2>/dev/null || true)

if [ -L "$CLAUDE_HOME_T/skills" ] \
   && [ -n "$new_skills_bak" ] \
   && [ -f "$new_skills_bak/preexisting/file.txt" ] \
   && [ -z "$sibling_bak" ]; then
  case_pass "S8 version-mismatch-creates-new-bak-correctly"
else
  case_fail "S8" "version-mismatch end-to-end behaviour incorrect"
  echo "    skills is symlink:  $([ -L "$CLAUDE_HOME_T/skills" ] && echo yes || echo no)"
  echo "    new skills.bak-*:   ${new_skills_bak:-<none>}"
  echo "    sibling .bak-*:     ${sibling_bak:-<none>}"
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# S9: intellisense owns ~/.claude/CLAUDE.md — regenerate-on-run backs up the
#     prior file to $HOME/.intellisense-backups/CLAUDE.bak-<ts> with no .md
#     extension, and writes a fresh file.
# ─────────────────────────────────────────────────────────────────────
make_fixture
FAKE_INTELLISENSE_SETUP="$ISO_HOME/fake_intellisense_setup"
# shellcheck disable=SC1091
source "$INTELLISENSE_SETUP/tests/helpers.sh" >/dev/null 2>&1 || true
make_fake_intellisense_setup "$FAKE_INTELLISENSE_SETUP" >/dev/null

CLAUDE_HOME_T="$ISO_HOME/.claude"
mkdir -p "$CLAUDE_HOME_T"

# Stale .intellisense-version → version-mismatch path → full re-setup (Step 10 runs).
echo "INTELLISENSE_VERSION=0.0.0-stale" > "$CLAUDE_HOME_T/.intellisense-version"

# Pre-existing CLAUDE.md the developer has edited (or that drifted on disk).
S9_SENTINEL="intellisense-S9-SENTINEL-${RANDOM}"
printf '%s\n' "$S9_SENTINEL" > "$CLAUDE_HOME_T/CLAUDE.md"

HOME="$ISO_HOME" INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS" \
  bash "$INTELLISENSE_SETUP/setup.sh" --non-interactive --skip-repo-setup \
  --intellisense-setup "$FAKE_INTELLISENSE_SETUP" >/dev/null 2>&1 || true

s9_bak="$(ls -1 "$ISO_BACKUPS/CLAUDE.bak-"* 2>/dev/null | head -1 || true)"
# Anti-glob: any .md-suffixed backup (under either location) is a regression.
s9_md_leaks="$(ls -1 "$ISO_BACKUPS/CLAUDE.md.bak-"* 2>/dev/null; \
               ls -1 "$ISO_BACKUPS/CLAUDE.md."* 2>/dev/null; \
               ls -1 "$CLAUDE_HOME_T/CLAUDE.md.bak-"* 2>/dev/null) "

if [ -n "$s9_bak" ] \
   && [ -f "$CLAUDE_HOME_T/CLAUDE.md" ] \
   && grep -q "$S9_SENTINEL" "$s9_bak" \
   && ! grep -q "$S9_SENTINEL" "$CLAUDE_HOME_T/CLAUDE.md" \
   && grep -q "intellisense Managed" "$CLAUDE_HOME_T/CLAUDE.md" \
   && [ -z "${s9_md_leaks// /}" ]; then
  case_pass "S9 claude-md-backup-naming-and-regeneration"
else
  case_fail "S9" "expected backup at CLAUDE.bak-<ts> (no .md) + fresh regenerated CLAUDE.md"
  echo "    backup file:        ${s9_bak:-<none>}"
  echo "    sentinel in backup: $([ -n "$s9_bak" ] && grep -q "$S9_SENTINEL" "$s9_bak" && echo yes || echo no)"
  echo "    sentinel in fresh:  $(grep -q "$S9_SENTINEL" "$CLAUDE_HOME_T/CLAUDE.md" 2>/dev/null && echo yes || echo no)"
  echo "    .md-leaked paths:   ${s9_md_leaks:-<none>}"
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
# S10: restore.sh treats ~/.claude/CLAUDE.md as intellisense-owned —
#      restores oldest CLAUDE.bak-<ts> (pre-intellisense original recovery) and
#      removes the intellisense-installed copy. Mirrors S3 for symlinks.
# ─────────────────────────────────────────────────────────────────────
make_fixture
CLAUDE_HOME_T="$ISO_HOME/.claude"
mkdir -p "$CLAUDE_HOME_T"

# Current intellisense-installed CLAUDE.md (what setup.sh would write today).
cat > "$CLAUDE_HOME_T/CLAUDE.md" <<'EOF'
<!-- intellisense Managed — installed by setup.sh -->
# Global Developer CLAUDE.md
intellisense Version: 1.0-test
EOF

# Pre-intellisense original lives in $INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-<oldest-ts>.
# restore.sh's list_backups_for picks the OLDEST as the pre-intellisense original.
mkdir -p "$ISO_BACKUPS"
echo "pre-intellisense-developer-content" > "$ISO_BACKUPS/CLAUDE.bak-20200101000000"
# A newer backup from a previous setup run that should NOT be restored.
echo "intermediate-rotation" > "$ISO_BACKUPS/CLAUDE.bak-20250101000000"

# config.json points restore.sh at the right INTELLISENSE_SETUP_DIR.
cat > "$CLAUDE_HOME_T/config.json" <<EOF
{ "intellisense_setup_path": "$INTELLISENSE_SETUP" }
EOF

HOME="$ISO_HOME" INTELLISENSE_BACKUPS_DIR="$ISO_BACKUPS" \
  bash "$INTELLISENSE_SETUP/restore.sh" --non-interactive --yes >/dev/null 2>&1 || true

# After restore: the oldest .bak content should be back at ~/.claude/CLAUDE.md.
# All CLAUDE.bak-* should be cleaned up (consumed by the restore).
s10_content="$(cat "$CLAUDE_HOME_T/CLAUDE.md" 2>/dev/null || true)"
s10_remaining_baks="$(ls -1 "$ISO_BACKUPS/CLAUDE.bak-"* 2>/dev/null | wc -l | tr -d ' ')"

if [ "$s10_content" = "pre-intellisense-developer-content" ] \
   && [ "$s10_remaining_baks" = "0" ]; then
  case_pass "S10 restore-claude-md-from-oldest-backup"
else
  case_fail "S10" "restore.sh did not flip CLAUDE.md to intellisense-owned semantics"
  echo "    ~/.claude/CLAUDE.md content: $s10_content"
  echo "    leftover CLAUDE.bak-* count: $s10_remaining_baks"
  ls -la "$ISO_BACKUPS/" 2>&1 | sed 's/^/      /'
fi
cleanup_fixture

# ─────────────────────────────────────────────────────────────────────
PASS=$(grep -c '^P$' "$RESULTS" || true)
FAIL=$(grep -c '^F$' "$RESULTS" || true)
echo "─────────────────────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
