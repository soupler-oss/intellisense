#!/bin/bash

# test_pre_push_tiers.sh — Regression tests for hook tier-based enforcement
#
# Tests:
# 1. Tier 2 file (rules/baseline/security.md) blocks push with TIER 2 message
# 2. Safe file (README.md) allows push (exit 0)
# 3. Same-URL origin/upstream detection: suggests fix, does NOT mutate origin URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Assert grep match (new helper for this test)
assert_grep_match() {
  local pattern="$1"
  local text="$2"
  local message="${3:-pattern should match}"
  ((++TESTS_RUN))

  if echo "$text" | grep -q "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern: $pattern"
    echo -e "    Text (first 200 chars): ${text:0:200}"
    ((++TESTS_FAILED))
  fi
}

# Assert grep does NOT match
assert_grep_no_match() {
  local pattern="$1"
  local text="$2"
  local message="${3:-pattern should not match}"
  ((++TESTS_RUN))

  if ! echo "$text" | grep -q "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern should not appear: $pattern"
    ((++TESTS_FAILED))
  fi
}

# Assert exit code
assert_exit_code() {
  local expected_code="$1"
  local actual_code="$2"
  local message="${3:-exit code should be $expected_code}"
  ((++TESTS_RUN))

  if [ "$expected_code" = "$actual_code" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected exit code: $expected_code"
    echo -e "    Actual exit code: $actual_code"
    ((++TESTS_FAILED))
  fi
}

# Create minimal git repo with proper tracking (hook requires origin/main to exist)
setup_test_repo() {
  local tmpdir="$1"

  git -C "$tmpdir" init --initial-branch=main >/dev/null 2>&1
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "Test User"
  git -C "$tmpdir" remote add origin https://github.com/fork/repo.git
  git -C "$tmpdir" remote add upstream https://github.com/upstream/repo.git

  # Create initial commit
  git -C "$tmpdir" commit --allow-empty -m "init" >/dev/null 2>&1

  # Create a fake origin/main tracking branch (hook requires this to exist)
  # We do this by creating the .git/refs/remotes/origin/main file directly
  mkdir -p "$tmpdir/.git/refs/remotes/origin"
  git -C "$tmpdir" rev-parse HEAD > "$tmpdir/.git/refs/remotes/origin/main"

  # Set up refs/remotes/origin/HEAD to point to main (so hook detects it as default branch)
  echo "ref: refs/remotes/origin/main" > "$tmpdir/.git/refs/remotes/origin/HEAD"
}

echo -e "${BLUE}intellisense Pre-Push Hook Tier-Based Enforcement Tests${NC}"
echo ""

# ============================================================================
# TEST 1: Tier 2 file blocks push
# ============================================================================
echo "Test 1: Tier 2 file (internal/auth/session.go: auth/identity) blocks push"

TEST1_DIR=$(mktemp -d)

setup_test_repo "$TEST1_DIR"

# Create a Tier 2 file: auth code is Tier 2 under every policy's defaults.
mkdir -p "$TEST1_DIR/internal/auth"
cat > "$TEST1_DIR/internal/auth/session.go" << 'EOF'
package auth
EOF

# Create a second commit that modifies the security.md file
git -C "$TEST1_DIR" add internal/auth/session.go
git -C "$TEST1_DIR" commit -m "add session handling" >/dev/null 2>&1

# Invoke hook: this should block because it's a Tier 2 file
ORIGINAL_DIR=$(pwd)
cd "$TEST1_DIR"
HOOK_EXIT=
HOOK_OUTPUT=$(bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1) || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
cd "$ORIGINAL_DIR"

assert_exit_code "1" "$HOOK_EXIT" "Tier 2 push should fail (exit code 1)"
assert_grep_match "Tier 2" "$HOOK_OUTPUT" "Output should mention Tier 2 check"
assert_grep_match "BLOCKED" "$HOOK_OUTPUT" "Output should contain BLOCKED message"

rm -rf "$TEST1_DIR"

echo ""

# ============================================================================
# TEST 2: Safe file allows push
# ============================================================================
echo "Test 2: Safe file (README.md) allows push"

TEST2_DIR=$(mktemp -d)

setup_test_repo "$TEST2_DIR"

# Create a safe file (README.md)
cat > "$TEST2_DIR/README.md" << 'EOF'
# My Repo
Safe documentation...
EOF

# Create a second commit that modifies README.md
git -C "$TEST2_DIR" add README.md
git -C "$TEST2_DIR" commit -m "update readme" >/dev/null 2>&1

# Invoke hook: this should pass because README.md is not a Tier 2 file
ORIGINAL_DIR=$(pwd)
cd "$TEST2_DIR"
HOOK_EXIT=
HOOK_OUTPUT=$(bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1) || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
cd "$ORIGINAL_DIR"

assert_exit_code "0" "$HOOK_EXIT" "Safe file push should succeed (exit code 0)"
assert_grep_no_match "BLOCKED" "$HOOK_OUTPUT" "Output should NOT contain BLOCKED message"

rm -rf "$TEST2_DIR"

echo ""

# ============================================================================
# TEST 3: Same-URL detection triggers suggestion, NO remote mutation
# ============================================================================
echo "Test 3: Same-URL detection — suggests fix, does NOT mutate origin URL"

TEST3_DIR=$(mktemp -d)

setup_test_repo "$TEST3_DIR"

# Set up: origin and upstream both point to same URL (misconfigured fork)
SAME_URL="https://github.com/upstream/repo.git"
git -C "$TEST3_DIR" remote set-url origin "$SAME_URL"
git -C "$TEST3_DIR" remote set-url upstream "$SAME_URL"

# Capture original origin URL
ORIG_ORIGIN=$(git -C "$TEST3_DIR" remote get-url origin)

# Create a safe file and commit
cat > "$TEST3_DIR/README.md" << 'EOF'
# Test
EOF
git -C "$TEST3_DIR" add README.md
git -C "$TEST3_DIR" commit -m "test" >/dev/null 2>&1

# Invoke hook with same URL (use the normalized URL that git returns)
ORIGIN_URL=$(git -C "$TEST3_DIR" remote get-url origin)
ORIGINAL_DIR=$(pwd)
cd "$TEST3_DIR"
HOOK_EXIT=
HOOK_OUTPUT=$(bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin "$ORIGIN_URL" 2>&1) || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
cd "$ORIGINAL_DIR"

# Capture origin URL after hook execution
AFTER_ORIGIN=$(git -C "$TEST3_DIR" remote get-url origin)

assert_grep_match "git remote set-url origin" "$HOOK_OUTPUT" "Output should suggest git remote set-url"
assert_eq "$ORIG_ORIGIN" "$AFTER_ORIGIN" "Origin URL must remain unchanged (no mutation)"

rm -rf "$TEST3_DIR"

echo ""

# ============================================================================
# BRANCH FRESHNESS SYNC GATE — mandatory pre-push backstop (plan v7)
# Hermetic: local bare remotes only. Freshness re-enabled per-invocation
# (helpers.sh disables it by default). Diverged fixture: work is ahead by 1
# (Tier 0 README.md so tier checks stay clean) and behind upstream/main by 1.
# ============================================================================
echo ""
echo -e "${BLUE}Branch freshness sync gate (pre-push backstop)${NC}"

SYNC_LIB="$INTELLISENSE_SETUP_DIR/scripts/lib/sync-ref.sh"

# pp_setup_behind <basedir> — distinct local bare origin + upstream; work
# diverged: behind upstream/main by 1, ahead by 1 (README.md).
pp_setup_behind() {
    local d="$1"
    git init -q --bare "$d/origin.git"; git init -q --bare "$d/upstream.git"
    git init -q -b main "$d/work"
    git -C "$d/work" config user.email t@t; git -C "$d/work" config user.name t
    printf 'base\n' >"$d/work/a.txt"
    git -C "$d/work" add a.txt; git -C "$d/work" commit -qm U1
    git -C "$d/work" remote add origin "$d/origin.git"
    git -C "$d/work" remote add upstream "$d/upstream.git"
    git -C "$d/work" push -q origin main; git -C "$d/work" push -q upstream main
    git -C "$d/work" checkout -q -b adv
    printf 'theirs\n' >>"$d/work/a.txt"; git -C "$d/work" commit -qam U2
    git -C "$d/work" push -q upstream adv:main
    git -C "$d/work" checkout -q main
    printf '# notes\n' >"$d/work/README.md"
    git -C "$d/work" add README.md; git -C "$d/work" commit -qm "W local"
    git -C "$d/work" fetch -q origin; git -C "$d/work" fetch -q upstream
    git -C "$d/work" remote set-head origin main >/dev/null 2>&1
    git -C "$d/work" remote set-head upstream main >/dev/null 2>&1
    mkdir -p "$d/work/.intellisense/session"
}

# pp_run <dir> <settings_file> — run the hook with freshness ENABLED.
pp_run() {
    ( cd "$1/work" && INTELLISENSE_SKIP_SYNC_CHECK=0 INTELLISENSE_GATE_MODE=pilot \
        INTELLISENSE_SETTINGS_FILE="$2" INTELLISENSE_SYNC_REF_LIB="$SYNC_LIB" \
        bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin "$1/origin.git" ) >/tmp/pp_out 2>/tmp/pp_err
    echo $?
}

PPW=$(mktemp -d)
printf '{"intellisense":{"sync_enforcement":"warn"}}\n'     >"$PPW/warn.json"
printf '{"intellisense":{"sync_enforcement":"enforced"}}\n' >"$PPW/enf.json"

# PP-1: warn + inferred + behind → allow (exit 0), stderr names behind.
D1=$(mktemp -d); pp_setup_behind "$D1"
ec=$(pp_run "$D1" "$PPW/warn.json")
assert_exit_code 0 "$ec" "pre-push warn+behind allows the push"
assert_grep_match "commit(s) behind upstream/main" "$(cat /tmp/pp_err)" "pre-push warn names the behind count"
rm -rf "$D1"

# PP-2: enforced + explicit manifest + behind → BLOCK (exit 1).
D2=$(mktemp -d); pp_setup_behind "$D2"
printf '{"integration_ref":"upstream/main"}\n' >"$D2/work/.intellisense/manifest.json"
ec=$(pp_run "$D2" "$PPW/enf.json")
assert_exit_code 1 "$ec" "pre-push enforced+explicit+behind blocks"
assert_grep_match "BLOCKED" "$(cat /tmp/pp_err)" "pre-push block emits BLOCKED"
rm -rf "$D2"

# PP-3: enforced + malformed explicit manifest → CONFIG ERROR block (I7).
D3=$(mktemp -d); pp_setup_behind "$D3"
printf '{"integration_ref":"upstream/x@{0}"}\n' >"$D3/work/.intellisense/manifest.json"
ec=$(pp_run "$D3" "$PPW/enf.json")
assert_exit_code 1 "$ec" "pre-push enforced+config_error blocks"
assert_grep_match "integration_ref is invalid" "$(cat /tmp/pp_err)" "config-error message (not infra)"
rm -rf "$D3"

# PP-4 (RR-I1): enforced + explicit + behind but INFRA failure (bogus remote
# url) → FAIL-OPEN: warn + ALLOW (exit 0), never block.
D4=$(mktemp -d); pp_setup_behind "$D4"
printf '{"integration_ref":"upstream/main"}\n' >"$D4/work/.intellisense/manifest.json"
git -C "$D4/work" remote set-url upstream "$D4/missing-bogus.git"
ec=$(pp_run "$D4" "$PPW/enf.json")
assert_exit_code 0 "$ec" "RR-I1: pre-push fails OPEN on infra failure (allows)"
assert_grep_match "fail-open" "$(cat /tmp/pp_err)" "RR-I1: fail-open warning emitted"
rm -rf "$D4"

# PP-5 (RR-I6): dirty tree + behind block → remediation has the stash line.
D5=$(mktemp -d); pp_setup_behind "$D5"
printf '{"integration_ref":"upstream/main"}\n' >"$D5/work/.intellisense/manifest.json"
printf 'uncommitted\n' >>"$D5/work/a.txt"   # make the tree dirty
ec=$(pp_run "$D5" "$PPW/enf.json")
assert_exit_code 1 "$ec" "RR-I6: dirty+behind still blocks"
assert_grep_match "commit or stash manually first" "$(cat /tmp/pp_err)" "RR-I6: dirty-tree remediation line present"
rm -rf "$D5"

# PP-6 (RR-I8 + RR-I4): cached session-marker ref is a DISCOVERY shortcut only.
# Cache an EXPLICIT upstream/main; resolve would otherwise be inferred. With
# enforce_on_inferred=false, inferred would NOT block — but the cached explicit
# confidence promotes it to a block, proving the cache is consulted. The block
# message still names "behind 1", proving a fresh fetch+count happened (I8).
D6=$(mktemp -d); pp_setup_behind "$D6"
SID6=sess6
printf '%s' "$SID6" >"$D6/work/.intellisense/session/current-session-id"
printf '{"status":"fresh","ts":%s,"target":"upstream/main","confidence":"explicit"}\n' "$(date +%s)" \
    >"$D6/work/.intellisense/session/${SID6}.sync-freshness-checked"
ec=$(pp_run "$D6" "$PPW/enf.json")   # NO manifest → resolve=inferred; cache→explicit
assert_exit_code 1 "$ec" "RR-I8: cached explicit ref promotes inferred to a block"
assert_grep_match "commit(s) behind upstream/main" "$(cat /tmp/pp_err)" "RR-I8: cache is discovery-only — behind still computed from fresh fetch"
rm -rf "$D6"

# PP-7 (RR-I4 parity): the remote/branch the hook resolves matches the shared
# lib's direct resolution for the same fixture (guards pre-edit/pre-push drift).
D7=$(mktemp -d); pp_setup_behind "$D7"
LIB_REF=$( . "$SYNC_LIB"; rec=$(sync_resolve_integration_ref "$D7/work" 0); printf '%s/%s' "$(sync_rec_remote "$rec")" "$(sync_rec_branch "$rec")" )
pp_run "$D7" "$PPW/warn.json" >/dev/null
HOOK_REF=$(grep -oE 'behind [^ .]+' /tmp/pp_err | head -1 | awk '{print $2}')
assert_eq "$LIB_REF" "$HOOK_REF" "RR-I4: hook-resolved ref matches shared-lib resolution ($LIB_REF)"
rm -rf "$D7"

rm -rf "$PPW"

# ============================================================================
# Summary
# ============================================================================
print_test_summary
