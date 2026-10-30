#!/bin/bash

# test_validate_intellisense_trailers_pr.sh — tests for the PR validator
#
# Layer 3 of the Intellisense-Metadata coverage plan: scripts/validate-intellisense-trailers-pr.sh
# is the server-side validator invoked by the GitHub Action on every PR. It
# walks `base_sha..head_sha`, extracts Intellisense-Metadata trailers via
# `git interpret-trailers --parse`, validates the JSON schema (matching the pre-push
# enum at hooks/pre-push:418), honors `.intellisense/exception-allowlist.yaml`, and
# exits 0/1 to drive the GitHub status check.
#
# Test isolation: each test creates a /tmp throwaway repo with base + head
# branches, then invokes the validator with explicit --base / --head SHAs.
# No network calls; no gh CLI dependency.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

VALIDATOR="$INTELLISENSE_SETUP_DIR/scripts/validate-intellisense-trailers-pr.sh"

# Local assertions (mirror the pre-push test pattern)
assert_grep_match() {
  local pattern="$1" text="$2" message="${3:-pattern should match}"
  ((++TESTS_RUN))
  if echo "$text" | grep -q -e "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern: $pattern"
    echo -e "    Text (first 300 chars): ${text:0:300}"
    ((++TESTS_FAILED))
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" message="${3:-exit code should be $expected}"
  ((++TESTS_RUN))
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message (expected $expected, got $actual)"
    ((++TESTS_FAILED))
  fi
}

# ----------------------------------------------------------------------------
# Test fixture: hermetic /tmp repo with base + head branches
# ----------------------------------------------------------------------------

# setup_pr_repo <dir>
#   Initializes a git repo with an initial commit on `main` that becomes
#   the test's base_sha. Returns nothing; caller adds commits + reads SHAs.
setup_pr_repo() {
  local dir="$1"
  git -C "$dir" init --initial-branch=main >/dev/null 2>&1
  git -C "$dir" config user.email "dev@example.com"
  git -C "$dir" config user.name  "Dev User"
  git -C "$dir" commit --allow-empty -m "init" >/dev/null 2>&1
}

# add_commit <dir> <subject> <trailer...>
#   Commits a small change with the given message + trailers.
#   Caller can read the resulting SHA via `git -C <dir> rev-parse HEAD`.
add_commit() {
  local dir="$1" subject="$2"; shift 2
  # Each call edits a unique file to ensure commits aren't empty.
  local n
  n="$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 0)"
  echo "$subject" >> "$dir/changes-${n}.txt"
  git -C "$dir" add "changes-${n}.txt"
  local msg="$subject"
  if [ $# -gt 0 ]; then
    msg="$msg"$'\n\n'
    local first=1 t
    for t in "$@"; do
      if [ "$first" = 1 ]; then msg="${msg}${t}"; first=0
      else msg="${msg}"$'\n'"${t}"; fi
    done
  fi
  git -C "$dir" commit -m "$msg" >/dev/null 2>&1
}

# run_validator <dir> <base_sha> <head_sha> [extra args...]
#   Invokes the validator and captures SCRIPT_EXIT + SCRIPT_OUTPUT.
run_validator() {
  local dir="$1" base="$2" head="$3"; shift 3
  SCRIPT_EXIT=
  SCRIPT_OUTPUT=$(cd "$dir" && bash "$VALIDATOR" --base "$base" --head "$head" "$@" 2>&1) || SCRIPT_EXIT=$?
  SCRIPT_EXIT=${SCRIPT_EXIT:-0}
}

# Minimal valid v=2 Intellisense-Metadata JSON (no_session_signal needs only the baseline fields)
VALID_TRAILER_JSON='{"v":1,"author_type":"no_session_signal","commit_kind":"feat","stamping_source":"prepare-commit-msg"}'

echo -e "${BLUE}validate-intellisense-trailers-pr.sh Tests${NC}"
echo ""

# ============================================================================
# T1: all commits have valid Intellisense-Metadata → exit 0
# ============================================================================
echo "T1: range with all-valid trailers passes"
T1=$(mktemp -d); setup_pr_repo "$T1"
BASE=$(git -C "$T1" rev-parse HEAD)
add_commit "$T1" "feat A" "Beads: t-1" "Intellisense-Metadata: $VALID_TRAILER_JSON"
add_commit "$T1" "feat B" "Beads: t-2" "Intellisense-Metadata: $VALID_TRAILER_JSON"
HEAD_SHA=$(git -C "$T1" rev-parse HEAD)
run_validator "$T1" "$BASE" "$HEAD_SHA"
assert_exit_code "0" "$SCRIPT_EXIT" "T1: all-valid PR exits 0"
rm -rf "$T1"; echo ""

# ============================================================================
# T2: one commit missing Intellisense-Metadata → exit 1, names the bad SHA
# ============================================================================
echo "T2: range with one missing-trailer commit fails"
T2=$(mktemp -d); setup_pr_repo "$T2"
BASE=$(git -C "$T2" rev-parse HEAD)
add_commit "$T2" "feat A" "Beads: t-1" "Intellisense-Metadata: $VALID_TRAILER_JSON"
add_commit "$T2" "feat B (NO METADATA)" "Beads: t-2"
BAD_SHA=$(git -C "$T2" rev-parse HEAD)
HEAD_SHA=$BAD_SHA
run_validator "$T2" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T2: missing-trailer fails"
assert_grep_match "Intellisense-Metadata\|missing\|trailer" "$SCRIPT_OUTPUT" "T2: error names what's missing"
assert_grep_match "${BAD_SHA:0:7}" "$SCRIPT_OUTPUT" "T2: error names the bad SHA"
rm -rf "$T2"; echo ""

# ============================================================================
# T3: malformed JSON in Intellisense-Metadata → exit 1 with parse error
# ============================================================================
echo "T3: malformed JSON in trailer fails"
T3=$(mktemp -d); setup_pr_repo "$T3"
BASE=$(git -C "$T3" rev-parse HEAD)
add_commit "$T3" "feat malformed" "Beads: t-3" "Intellisense-Metadata: {not valid json"
HEAD_SHA=$(git -C "$T3" rev-parse HEAD)
run_validator "$T3" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T3: malformed JSON fails"
assert_grep_match "malformed\|invalid JSON\|parse" "$SCRIPT_OUTPUT" "T3: error names parse failure"
rm -rf "$T3"; echo ""

# ============================================================================
# T4: unknown author_type → exit 1
# ============================================================================
echo "T4: unknown author_type fails"
T4=$(mktemp -d); setup_pr_repo "$T4"
BASE=$(git -C "$T4" rev-parse HEAD)
BAD='{"v":1,"author_type":"sentient-toaster","commit_kind":"feat","stamping_source":"x"}'
add_commit "$T4" "feat unknown enum" "Beads: t-4" "Intellisense-Metadata: $BAD"
HEAD_SHA=$(git -C "$T4" rev-parse HEAD)
run_validator "$T4" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T4: unknown author_type fails"
assert_grep_match "author_type" "$SCRIPT_OUTPUT" "T4: error names the rejected field"
rm -rf "$T4"; echo ""

# ============================================================================
# T5: duplicate Intellisense-Metadata trailers → exit 1
# ============================================================================
echo "T5: duplicate Intellisense-Metadata trailers fail"
T5=$(mktemp -d); setup_pr_repo "$T5"
BASE=$(git -C "$T5" rev-parse HEAD)
add_commit "$T5" "feat dup" "Beads: t-5" \
  "Intellisense-Metadata: $VALID_TRAILER_JSON" "Intellisense-Metadata: $VALID_TRAILER_JSON"
HEAD_SHA=$(git -C "$T5" rev-parse HEAD)
run_validator "$T5" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T5: duplicate trailers fail"
assert_grep_match "duplicate\|2.*Intellisense-Metadata\|ambiguous" "$SCRIPT_OUTPUT" "T5: error names duplicate"
rm -rf "$T5"; echo ""

# ============================================================================
# T6: range with multiple commits, only one missing, names the bad one
# ============================================================================
echo "T6: multi-commit range names which commit is bad"
T6=$(mktemp -d); setup_pr_repo "$T6"
BASE=$(git -C "$T6" rev-parse HEAD)
add_commit "$T6" "feat A (valid)" "Beads: t-6a" "Intellisense-Metadata: $VALID_TRAILER_JSON"
add_commit "$T6" "feat B (NO METADATA)" "Beads: t-6b"
BAD_SHA=$(git -C "$T6" rev-parse HEAD)
add_commit "$T6" "feat C (valid)" "Beads: t-6c" "Intellisense-Metadata: $VALID_TRAILER_JSON"
HEAD_SHA=$(git -C "$T6" rev-parse HEAD)
run_validator "$T6" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T6: multi-commit one-bad fails"
assert_grep_match "${BAD_SHA:0:7}" "$SCRIPT_OUTPUT" "T6: error specifically names the bad SHA"
rm -rf "$T6"; echo ""

# ============================================================================
# T7: missing trailer + allowlist entry → exit 0 (bypass)
# ============================================================================
echo "T7: missing trailer + valid allowlist entry passes"
T7=$(mktemp -d); setup_pr_repo "$T7"
BASE=$(git -C "$T7" rev-parse HEAD)
add_commit "$T7" "feat: commit without metadata" "Beads: t-7"
HEAD_SHA=$(git -C "$T7" rev-parse HEAD)
mkdir -p "$T7/.intellisense"
FUTURE=$(date -u -v+30d '+%Y-%m-%d' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%d')
cat > "$T7/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $HEAD_SHA
  reason: "Commit made before intellisense was installed"
  expiry: "$FUTURE"
  added_by: "different-approver@example.com"
EOF
run_validator "$T7" "$BASE" "$HEAD_SHA"
assert_exit_code "0" "$SCRIPT_EXIT" "T7: valid allowlist bypass works"
rm -rf "$T7"; echo ""

# ============================================================================
# T8: allowlist governance — expired entry → exit 1
# ============================================================================
echo "T8: allowlist with expired entry fails"
T8=$(mktemp -d); setup_pr_repo "$T8"
BASE=$(git -C "$T8" rev-parse HEAD)
add_commit "$T8" "feat stale" "Beads: t-8"
HEAD_SHA=$(git -C "$T8" rev-parse HEAD)
mkdir -p "$T8/.intellisense"
PAST=$(date -u -v-1d '+%Y-%m-%d' 2>/dev/null || date -u -d '-1 day' '+%Y-%m-%d')
cat > "$T8/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $HEAD_SHA
  reason: "Was OK; now expired"
  expiry: "$PAST"
  added_by: "approver@example.com"
EOF
run_validator "$T8" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T8: expired allowlist fails"
assert_grep_match "expir" "$SCRIPT_OUTPUT" "T8: error mentions expiry"
rm -rf "$T8"; echo ""

# ============================================================================
# T9: empty range (base == head) → exit 0 (no-op)
# ============================================================================
echo "T9: empty range exits 0"
T9=$(mktemp -d); setup_pr_repo "$T9"
HEAD_SHA=$(git -C "$T9" rev-parse HEAD)
run_validator "$T9" "$HEAD_SHA" "$HEAD_SHA"
assert_exit_code "0" "$SCRIPT_EXIT" "T9: base==head is no-op"
rm -rf "$T9"; echo ""

# ============================================================================
# T10: --help prints usage
# ============================================================================
echo "T10: --help prints usage"
T10=$(mktemp -d); setup_pr_repo "$T10"
SCRIPT_EXIT=
SCRIPT_OUTPUT=$(cd "$T10" && bash "$VALIDATOR" --help 2>&1) || SCRIPT_EXIT=$?
SCRIPT_EXIT=${SCRIPT_EXIT:-0}
assert_exit_code "0" "$SCRIPT_EXIT" "T10: --help exits 0"
assert_grep_match "Usage\|usage:" "$SCRIPT_OUTPUT" "T10: prints Usage"
assert_grep_match "base\|head" "$SCRIPT_OUTPUT" "T10: documents --base/--head args"
rm -rf "$T10"; echo ""

# ============================================================================
# T11: claude_inline WITHOUT tokens → exit 0 (tokens not required)
# ============================================================================
echo "T11: claude_inline (no tokens) passes"
T11=$(mktemp -d); setup_pr_repo "$T11"
BASE=$(git -C "$T11" rev-parse HEAD)
INLINE_T0='{"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s-1","version":"1.0.0"}'
add_commit "$T11" "feat inline" "Beads: t-11" "Intellisense-Metadata: $INLINE_T0" "Co-Authored-By: Claude <noreply@anthropic.com>"
HEAD_SHA=$(git -C "$T11" rev-parse HEAD)
run_validator "$T11" "$BASE" "$HEAD_SHA"
assert_exit_code "0" "$SCRIPT_EXIT" "T11: claude_inline without tokens passes"
rm -rf "$T11"; echo ""

# ============================================================================
# T12: claude_inline carrying a tokens field → exit 1 (fail-closed)
# ============================================================================
echo "T12: claude_inline WITH tokens is rejected"
T12=$(mktemp -d); setup_pr_repo "$T12"
BASE=$(git -C "$T12" rev-parse HEAD)
INLINE_TOK='{"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s-1","version":"1.0.0","tokens":{"input":1,"output":1,"cache_creation":0,"cache_read":0,"total":2}}'
add_commit "$T12" "feat inline w/ tokens" "Beads: t-12" "Intellisense-Metadata: $INLINE_TOK"
HEAD_SHA=$(git -C "$T12" rev-parse HEAD)
run_validator "$T12" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T12: claude_inline with tokens fails"
assert_grep_match "token" "$SCRIPT_OUTPUT" "T12: error names the tokens violation"
rm -rf "$T12"; echo ""

# ============================================================================
# T13: claude_inline missing a required field (session) → exit 1
# ============================================================================
echo "T13: claude_inline missing session is rejected"
T13=$(mktemp -d); setup_pr_repo "$T13"
BASE=$(git -C "$T13" rev-parse HEAD)
INLINE_NOSESS='{"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","version":"1.0.0"}'
add_commit "$T13" "feat inline no session" "Beads: t-13" "Intellisense-Metadata: $INLINE_NOSESS"
HEAD_SHA=$(git -C "$T13" rev-parse HEAD)
run_validator "$T13" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T13: claude_inline missing session fails"
rm -rf "$T13"; echo ""

# ============================================================================
# T14: INLINE TIER GUARD — declared tier < commit path tier → exit 1
#   Commit touches scripts/*, which implies tier>=1, but trailer declares tier 0.
# ============================================================================
echo "T14: claude_inline under-stamped tier (scripts/* commit declared Tier 0) is rejected"
T14=$(mktemp -d); setup_pr_repo "$T14"
BASE=$(git -C "$T14" rev-parse HEAD)
mkdir -p "$T14/scripts"
echo "echo hi" > "$T14/scripts/thing.sh"
git -C "$T14" add scripts/thing.sh
git -C "$T14" commit -m "feat: touch scripts

Beads: t-14
Intellisense-Metadata: $INLINE_T0" >/dev/null 2>&1
HEAD_SHA=$(git -C "$T14" rev-parse HEAD)
run_validator "$T14" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T14: under-stamped inline tier fails"
assert_grep_match "tier" "$SCRIPT_OUTPUT" "T14: error names the tier under-statement"
rm -rf "$T14"; echo ""

# ============================================================================
# T15 (regression): claude_with_intellisense + classification_state=ok + NO
#   tokens → STILL exit 1. Proves we did NOT relax the hook-stamped token rule.
# ============================================================================
echo "T15: claude_with_intellisense ok-state without tokens still blocks (regression guard)"
T15=$(mktemp -d); setup_pr_repo "$T15"
BASE=$(git -C "$T15" rev-parse HEAD)
WITH_INTELLISENSE_NOTOK='{"v":1,"author_type":"claude_with_intellisense","commit_kind":"single","stamping_source":"local_hook","classification_state":"ok","tier":1,"mode":"bug_fix","session":"s-1","version":"1.0.0","skills":[],"rules_expected":[],"agents":[]}'
add_commit "$T15" "feat hook no tokens" "Beads: t-15" "Intellisense-Metadata: $WITH_INTELLISENSE_NOTOK"
HEAD_SHA=$(git -C "$T15" rev-parse HEAD)
run_validator "$T15" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T15: claude_with_intellisense ok+no-tokens still blocks"
rm -rf "$T15"; echo ""

# ============================================================================
# T16: claude_inline source fields are value-checked
#   commit_kind must be "single" and stamping_source must be "agent_inline".
# ============================================================================
echo "T16: claude_inline with wrong commit_kind/stamping_source is rejected"
T16=$(mktemp -d); setup_pr_repo "$T16"
BASE=$(git -C "$T16" rev-parse HEAD)
INLINE_BADSRC='{"v":1,"author_type":"claude_inline","commit_kind":"merge","stamping_source":"local_hook","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}'
add_commit "$T16" "feat inline bad source" "Beads: t-16" "Intellisense-Metadata: $INLINE_BADSRC"
HEAD_SHA=$(git -C "$T16" rev-parse HEAD)
run_validator "$T16" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T16: wrong commit_kind/stamping_source fails"
assert_grep_match "commit_kind\|stamping_source" "$SCRIPT_OUTPUT" "T16: error names the bad source field"
rm -rf "$T16"; echo ""

# ============================================================================
# T17: inline tier guard honors the policy floor
#   .intellisense/manifest.json policy_minimum_tier=1 + declared inline Tier 0 → block,
#   even when the changed path itself implies Tier 0.
# ============================================================================
echo "T17: claude_inline below policy floor (manifest minimum tier 1, declared 0) is rejected"
T17=$(mktemp -d); setup_pr_repo "$T17"
mkdir -p "$T17/.intellisense"
echo '{"policy_minimum_tier":1}' > "$T17/.intellisense/manifest.json"
git -C "$T17" add .intellisense/manifest.json
git -C "$T17" commit -q -m "chore: manifest" >/dev/null 2>&1
# Capture BASE AFTER the manifest commit so only the inline commit is in range.
BASE=$(git -C "$T17" rev-parse HEAD)
add_commit "$T17" "docs: normal file" "Beads: t-17" "Intellisense-Metadata: $INLINE_T0"
HEAD_SHA=$(git -C "$T17" rev-parse HEAD)
run_validator "$T17" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T17: inline tier below policy floor fails"
assert_grep_match "tier\|policy" "$SCRIPT_OUTPUT" "T17: error names tier/policy floor"
rm -rf "$T17"; echo ""

# ============================================================================
# T18: co-author guard is FAIL-CLOSED — blocks.
#   A claude_inline commit lacking Co-Authored-By: Claude must NOT validate
#   (a human commit can't be attributed as intellisense+Claude; stderr-warn alone would
#   not stop analytics, which ingests git data not validator stderr).
# ============================================================================
echo "T18: claude_inline WITHOUT Co-Authored-By is BLOCKED (fail-closed §3.7)"
T18=$(mktemp -d); setup_pr_repo "$T18"
BASE=$(git -C "$T18" rev-parse HEAD)
add_commit "$T18" "feat inline no coauthor" "Beads: t-18" "Intellisense-Metadata: $INLINE_T0"
HEAD_SHA=$(git -C "$T18" rev-parse HEAD)
run_validator "$T18" "$BASE" "$HEAD_SHA"
assert_exit_code "1" "$SCRIPT_EXIT" "T18: missing co-author BLOCKS (fail-closed)"
assert_grep_match "[Cc]o-[Aa]uthor" "$SCRIPT_OUTPUT" "T18: error names the missing co-author evidence"
rm -rf "$T18"; echo ""

print_test_summary
