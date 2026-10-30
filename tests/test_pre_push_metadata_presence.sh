#!/bin/bash

# test_pre_push_metadata_presence.sh — TDD RED tests
#
# Layer 2 of the intellisense metadata coverage plan: pre-push enforces presence of
# the Intellisense-Metadata trailer on every commit at Tier 1+.
#
# These tests are written BEFORE the implementation (TDD RED). They describe
# the validate_metadata_presence function's contract
# acceptance criteria:
#
#   - Reads pushed refs from stdin tuples (NOT a hardcoded git rev-list range),
#   - Uses `git interpret-trailers --parse` for enforcement (NOT grep)
#   - Honors .intellisense/exception-allowlist.yaml with governance: expired entries
#     fail, missing reason fails, self-approval blocked, max expiry 90 days
#   - Ships in warn mode behind intellisense.gate_mode for 2 weeks before flipping
#     to enforced
#
#
# Expected state at commit time: ALL tests fail (RED). validate_metadata_presence
# does not exist in hooks/pre-push yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

HOOK="$INTELLISENSE_SETUP_DIR/hooks/pre-push"

# ----------------------------------------------------------------------------
# Local assertions (mirror pattern from test_pre_push_tiers.sh)
# ----------------------------------------------------------------------------

assert_grep_match() {
  local pattern="$1" text="$2" message="${3:-pattern should match}"
  ((++TESTS_RUN))
  if echo "$text" | grep -q "$pattern"; then
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
# Test fixture: hermetic /tmp repo with controlled commits and remotes
# ----------------------------------------------------------------------------

# setup_metadata_repo <dir> <gate_mode>
#   Creates a /tmp throwaway repo with:
#     - origin + upstream remotes (fork workflow)
#     - main branch + fake origin/main tracking ref
#     - .claude/settings.json with intellisense.gate_mode = <gate_mode> (pilot | enforced)
#     - one initial commit (no trailers — used as the remote baseline)
#   Returns: nothing; modifies <dir> in place.
setup_metadata_repo() {
  local dir="$1" gate_mode="${2:-pilot}"
  git -C "$dir" init --initial-branch=main >/dev/null 2>&1
  git -C "$dir" config user.email "dev@example.com"
  git -C "$dir" config user.name  "Dev User"
  git -C "$dir" remote add origin   https://github.com/fork/repo.git
  git -C "$dir" remote add upstream https://github.com/upstream/repo.git
  git -C "$dir" commit --allow-empty -m "init" >/dev/null 2>&1

  mkdir -p "$dir/.git/refs/remotes/origin"
  git -C "$dir" rev-parse HEAD > "$dir/.git/refs/remotes/origin/main"
  echo "ref: refs/remotes/origin/main" > "$dir/.git/refs/remotes/origin/HEAD"

  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<EOF
{
  "intellisense": {
    "gate_mode": "$gate_mode",
    "audit_chain_enforcement": "warn"
  }
}
EOF
}

# add_tier1_commit <dir> <subject> <trailers...>
#   Creates a commit that touches a Tier 1 path (rules/operational/) so the
#   hook's tier classification fires. Each remaining arg is a trailer line
#   appended after a blank line (interpret-trailers compatible).
add_tier1_commit() {
  local dir="$1" subject="$2"; shift 2
  mkdir -p "$dir/rules/operational"
  echo "tier1 change for: $subject" >> "$dir/rules/operational/probe.md"
  git -C "$dir" add rules/operational/probe.md

  local msg="$subject"
  if [ $# -gt 0 ]; then
    msg="$msg"$'\n\n'
    local first=1
    for t in "$@"; do
      if [ "$first" = 1 ]; then msg="${msg}${t}"; first=0
      else msg="${msg}"$'\n'"${t}"; fi
    done
  fi
  git -C "$dir" commit -m "$msg" >/dev/null 2>&1
}

# run_hook_with_stdin <dir> <stdin_tuples>
#   Invokes the pre-push hook with the given stdin and captures exit + output.
#   Sets INTELLISENSE_GATE_MODE from <dir>/.claude/settings.json (hook reads $HOME's
#   settings.json by default; tests can't pollute $HOME, so use the env-var
#   override per hooks/pre-push:337).
#   Writes HOOK_EXIT and HOOK_OUTPUT to the caller's scope (no return value).
run_hook_with_stdin() {
  local dir="$1" stdin="$2"
  local orig gate
  orig=$(pwd)
  gate="pilot"
  if [ -f "$dir/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
    gate="$(jq -r '.intellisense.gate_mode // "pilot"' "$dir/.claude/settings.json" 2>/dev/null)"
    [ -z "$gate" ] && gate="pilot"
  fi
  cd "$dir"
  HOOK_EXIT=
  HOOK_OUTPUT=$(INTELLISENSE_GATE_MODE="$gate" printf '%s\n' "$stdin" | INTELLISENSE_GATE_MODE="$gate" bash "$HOOK" origin https://github.com/fork/repo.git 2>&1) || HOOK_EXIT=$?
  HOOK_EXIT=${HOOK_EXIT:-0}
  cd "$orig"
}

# Standard JSON for a Claude-direct commit (matches the prepare-commit-msg emission shape)
# Minimal valid v=2 trailer. Uses author_type=no_session_signal which is in
# the simple enum arm (merge|squash|no_session_signal) — needs only the four
# baseline fields (v, author_type, commit_kind, stamping_source). Other
# enum values (claude_with_intellisense, bot, github_ui, ...) require additional
# fields per hooks/pre-push:418-458 that we don't want to assemble in tests.
VALID_METADATA_JSON='{"v":1,"author_type":"no_session_signal","commit_kind":"feat","stamping_source":"prepare-commit-msg"}'

echo -e "${BLUE}intellisense pre-push validate_metadata_presence Tests${NC}"
echo -e "${YELLOW}TDD RED phase — all tests expected to FAIL until validate_metadata_presence ships.${NC}"
echo ""

# ============================================================================
# GROUP 1: Stdin tuple parsing
# Acceptance: "Reads pushed refs from stdin (<local_ref> <local_sha>
# <remote_ref> <remote_sha>), NOT a hardcoded range"
# ============================================================================

# --- T1: new branch push (remote_sha = 0000...) -----------------------------
echo "T1: new branch push — remote_sha=0000... derives range from origin/main"
T1=$(mktemp -d); setup_metadata_repo "$T1" enforced
add_tier1_commit "$T1" "feat: new feature" "Beads: intellisense-test" "Intellisense-Metadata: $VALID_METADATA_JSON"
NEW_SHA=$(git -C "$T1" rev-parse HEAD)
STDIN="refs/heads/feat-new $NEW_SHA refs/heads/feat-new 0000000000000000000000000000000000000000"
run_hook_with_stdin "$T1" "$STDIN"
assert_exit_code "0" "$HOOK_EXIT" "T1: new branch with valid metadata trailer should pass"
rm -rf "$T1"; echo ""

# --- T2: deleted ref (local_sha = 0000...) — skip entirely ------------------
echo "T2: deleted ref — local_sha=0000... is skipped (no commits to validate)"
T2=$(mktemp -d); setup_metadata_repo "$T2" enforced
STDIN="(delete) 0000000000000000000000000000000000000000 refs/heads/feat-gone $(git -C "$T2" rev-parse HEAD)"
run_hook_with_stdin "$T2" "$STDIN"
assert_exit_code "0" "$HOOK_EXIT" "T2: deleted ref must not block (no range to validate)"
rm -rf "$T2"; echo ""

# --- T3: multi-branch push — every ref validated independently --------------
echo "T3: multi-branch push — each ref tuple gets validated"
T3=$(mktemp -d); setup_metadata_repo "$T3" enforced
add_tier1_commit "$T3" "feat A: valid" "Beads: intellisense-test" "Intellisense-Metadata: $VALID_METADATA_JSON"
SHA_A=$(git -C "$T3" rev-parse HEAD)
git -C "$T3" checkout -b feat-b main >/dev/null 2>&1
add_tier1_commit "$T3" "feat B: MISSING metadata" "Beads: intellisense-test"   # no Intellisense-Metadata
SHA_B=$(git -C "$T3" rev-parse HEAD)
STDIN="refs/heads/main $SHA_A refs/heads/main $(git -C "$T3" rev-parse origin/main)
refs/heads/feat-b $SHA_B refs/heads/feat-b 0000000000000000000000000000000000000000"
run_hook_with_stdin "$T3" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T3: multi-branch with one missing-metadata branch must block"
assert_grep_match "Intellisense-Metadata" "$HOOK_OUTPUT" "T3: failure message must name the missing trailer"
rm -rf "$T3"; echo ""

# ============================================================================
# GROUP 2: Trailer detection via git interpret-trailers
# Acceptance: "Uses git interpret-trailers --parse + schema-validate JSON;
# rejects malformed JSON; rejects unknown author_type"
# ============================================================================

# --- T4: missing Intellisense-Metadata in PILOT mode → warn but pass ----------------
echo "T4: missing Intellisense-Metadata in pilot mode — warn, do not block"
T4=$(mktemp -d); setup_metadata_repo "$T4" pilot
add_tier1_commit "$T4" "feat: missing metadata" "Beads: intellisense-test"
SHA=$(git -C "$T4" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T4" rev-parse origin/main)"
run_hook_with_stdin "$T4" "$STDIN"
assert_exit_code "0" "$HOOK_EXIT" "T4: pilot mode must not block missing metadata"
assert_grep_match "Intellisense-Metadata" "$HOOK_OUTPUT" "T4: pilot mode must emit warning naming the trailer"
rm -rf "$T4"; echo ""

# --- T5: missing Intellisense-Metadata in ENFORCED mode → block ---------------------
echo "T5: missing Intellisense-Metadata in enforced mode — block"
T5=$(mktemp -d); setup_metadata_repo "$T5" enforced
add_tier1_commit "$T5" "feat: missing metadata" "Beads: intellisense-test"
SHA=$(git -C "$T5" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T5" rev-parse origin/main)"
run_hook_with_stdin "$T5" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T5: enforced mode must block missing metadata"
assert_grep_match "BLOCKED" "$HOOK_OUTPUT" "T5: enforced mode must say BLOCKED"
rm -rf "$T5"; echo ""

# --- T6: malformed JSON in Intellisense-Metadata trailer → block --------------------
echo "T6: malformed JSON in Intellisense-Metadata — block (cannot parse)"
T6=$(mktemp -d); setup_metadata_repo "$T6" enforced
add_tier1_commit "$T6" "feat: malformed json" "Beads: intellisense-test" "Intellisense-Metadata: {not valid json"
SHA=$(git -C "$T6" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T6" rev-parse origin/main)"
run_hook_with_stdin "$T6" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T6: malformed JSON must block"
assert_grep_match "malformed\|invalid JSON\|parse" "$HOOK_OUTPUT" "T6: error message must name the JSON parse failure"
rm -rf "$T6"; echo ""

# --- T7: unknown author_type enum → block -----------------------------------
echo "T7: unknown author_type value — block (schema rejects)"
T7=$(mktemp -d); setup_metadata_repo "$T7" enforced
BAD='{"v":1,"author_type":"sentient-toaster","claude_version":"4.7","session_id":"t"}'
add_tier1_commit "$T7" "feat: unknown enum" "Beads: intellisense-test" "Intellisense-Metadata: $BAD"
SHA=$(git -C "$T7" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T7" rev-parse origin/main)"
run_hook_with_stdin "$T7" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T7: unknown author_type must block"
assert_grep_match "author_type" "$HOOK_OUTPUT" "T7: error message must name the rejected field"
rm -rf "$T7"; echo ""

# --- T8: duplicate Intellisense-Metadata trailers → block ---------------------------
echo "T8: duplicate Intellisense-Metadata trailers — block (ambiguous)"
T8=$(mktemp -d); setup_metadata_repo "$T8" enforced
add_tier1_commit "$T8" "feat: dup trailers" "Beads: intellisense-test" \
  "Intellisense-Metadata: $VALID_METADATA_JSON" "Intellisense-Metadata: $VALID_METADATA_JSON"
SHA=$(git -C "$T8" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T8" rev-parse origin/main)"
run_hook_with_stdin "$T8" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T8: duplicate Intellisense-Metadata trailers must block"
rm -rf "$T8"; echo ""

# --- T9: reordered trailers (Beads BEFORE Intellisense-Metadata) → accept -----------
echo "T9: reordered trailers — order doesn't matter; both must accept"
T9=$(mktemp -d); setup_metadata_repo "$T9" enforced
add_tier1_commit "$T9" "feat: reordered" "Intellisense-Metadata: $VALID_METADATA_JSON" "Beads: intellisense-test"
SHA=$(git -C "$T9" rev-parse HEAD)
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T9" rev-parse origin/main)"
run_hook_with_stdin "$T9" "$STDIN"
assert_exit_code "0" "$HOOK_EXIT" "T9: trailer order must not affect acceptance"
rm -rf "$T9"; echo ""

# ============================================================================
# GROUP 3: Allowlist governance (.intellisense/exception-allowlist.yaml)
# Acceptance: "expired entries hard-fail; entries without reason fail;
# self-approval blocked (commit author cannot be sole approver);
# max expiry 90 days"
# ============================================================================

# --- T10: valid allowlist entry → bypass enforcement ------------------------
echo "T10: valid allowlist entry — bypasses missing-metadata block"
T10=$(mktemp -d); setup_metadata_repo "$T10" enforced
add_tier1_commit "$T10" "feat: commit without metadata" "Beads: intellisense-test"
SHA=$(git -C "$T10" rev-parse HEAD)
mkdir -p "$T10/.intellisense"
FUTURE_DATE=$(date -u -v+30d '+%Y-%m-%d' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%d')
cat > "$T10/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $SHA
  reason: "Commit made before intellisense was installed — backfill"
  expiry: "$FUTURE_DATE"
  added_by: "different-approver@example.com"
EOF
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T10" rev-parse origin/main)"
run_hook_with_stdin "$T10" "$STDIN"
assert_exit_code "0" "$HOOK_EXIT" "T10: valid allowlist entry must permit push"
rm -rf "$T10"; echo ""

# --- T11: expired allowlist entry → block -----------------------------------
echo "T11: expired allowlist entry — hard-fail"
T11=$(mktemp -d); setup_metadata_repo "$T11" enforced
add_tier1_commit "$T11" "feat: stale exception" "Beads: intellisense-test"
SHA=$(git -C "$T11" rev-parse HEAD)
mkdir -p "$T11/.intellisense"
PAST_DATE=$(date -u -v-1d '+%Y-%m-%d' 2>/dev/null || date -u -d '-1 day' '+%Y-%m-%d')
cat > "$T11/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $SHA
  reason: "Was valid; now expired"
  expiry: "$PAST_DATE"
  added_by: "approver@example.com"
EOF
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T11" rev-parse origin/main)"
run_hook_with_stdin "$T11" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T11: expired allowlist entry must hard-fail"
assert_grep_match "expir" "$HOOK_OUTPUT" "T11: error message must mention expiry"
rm -rf "$T11"; echo ""

# --- T12: self-approval blocked (commit author == allowlist added_by) -------
echo "T12: self-approval blocked — commit author cannot also be approver"
T12=$(mktemp -d); setup_metadata_repo "$T12" enforced
add_tier1_commit "$T12" "feat: self-approval attempt" "Beads: intellisense-test"
SHA=$(git -C "$T12" rev-parse HEAD)
mkdir -p "$T12/.intellisense"
FUTURE_DATE=$(date -u -v+30d '+%Y-%m-%d' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%d')
cat > "$T12/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $SHA
  reason: "self approving"
  expiry: "$FUTURE_DATE"
  added_by: "dev@example.com"
EOF
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T12" rev-parse origin/main)"
run_hook_with_stdin "$T12" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T12: self-approval must be blocked"
assert_grep_match "self.approv\|same author" "$HOOK_OUTPUT" "T12: error must name self-approval"
rm -rf "$T12"; echo ""

# --- T13: missing reason in allowlist entry → block -------------------------
echo "T13: allowlist entry without reason — block (governance)"
T13=$(mktemp -d); setup_metadata_repo "$T13" enforced
add_tier1_commit "$T13" "feat: no-reason allowlist" "Beads: intellisense-test"
SHA=$(git -C "$T13" rev-parse HEAD)
mkdir -p "$T13/.intellisense"
FUTURE_DATE=$(date -u -v+30d '+%Y-%m-%d' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%d')
cat > "$T13/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $SHA
  expiry: "$FUTURE_DATE"
  added_by: "approver@example.com"
EOF
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T13" rev-parse origin/main)"
run_hook_with_stdin "$T13" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T13: allowlist entry without reason must block"
assert_grep_match "reason" "$HOOK_OUTPUT" "T13: error must mention missing reason"
rm -rf "$T13"; echo ""

# --- T14: allowlist entry with >90d expiry → block --------------------------
echo "T14: allowlist entry with expiry >90 days — block (governance cap)"
T14=$(mktemp -d); setup_metadata_repo "$T14" enforced
add_tier1_commit "$T14" "feat: over-long expiry" "Beads: intellisense-test"
SHA=$(git -C "$T14" rev-parse HEAD)
mkdir -p "$T14/.intellisense"
FAR_FUTURE=$(date -u -v+200d '+%Y-%m-%d' 2>/dev/null || date -u -d '+200 days' '+%Y-%m-%d')
cat > "$T14/.intellisense/exception-allowlist.yaml" <<EOF
- sha: $SHA
  reason: "Trying to slip a 200-day exception past the gate"
  expiry: "$FAR_FUTURE"
  added_by: "approver@example.com"
EOF
STDIN="refs/heads/main $SHA refs/heads/main $(git -C "$T14" rev-parse origin/main)"
run_hook_with_stdin "$T14" "$STDIN"
assert_exit_code "1" "$HOOK_EXIT" "T14: allowlist expiry >90d must block"
assert_grep_match "90" "$HOOK_OUTPUT" "T14: error must reference the 90-day cap"
rm -rf "$T14"; echo ""

# ============================================================================
# GROUP 4: Edge cases — STUBBED (TDD scaffolding; bodies in next session)
# Acceptance items deferred to GREEN phase:
#   - stacked branches (feat-B off feat-A, both pushed)
#   - detached HEAD push
#   - shallow clone push
#   - mirror push
#   - force-push rewrite (re-validates ALL commits in new range)
#   - git rebase -i (reword)
#   - git rebase --autosquash + --fixup
#   - git rebase --rebase-merges
# Each will follow the setup_metadata_repo + run_hook_with_stdin pattern.
# Tracked in the acceptance criteria §"Empirical test matrix" and
# §"Git rewrite workflow test matrix".
# ============================================================================
echo "T15+: edge-case matrix stubs — see the acceptance criteria above"
echo "      (stacked / detached HEAD / shallow / mirror / force-push / rebase variants)"
echo "      Stubs intentionally not asserting yet — fill in once T1-T14 are GREEN."
echo ""

# ============================================================================
# Summary
# ============================================================================
print_test_summary
