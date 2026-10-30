#!/bin/bash

# test_apply_merge_policy.sh — tests for the merge-method policy
#
# Layer 4 of the Intellisense-Metadata coverage plan: scripts/apply-merge-policy.sh
# is the per-repo backfill that disables squash + plain-merge and enforces
# rebase-only via `gh api PATCH /repos/{owner}/{repo}`.
#
# Acceptance criteria covered :
#   - Idempotent re-runs
#   - --dry-run prints planned changes without API calls
#   - .intellisense/manifest.json: merge_policy_override is honored (skip + log)
#   - --restore-defaults reverts (re-enables squash + merge_commit)
#   - Missing gh CLI surfaces clearly
#   - Helpful --help / usage output
#
# Test isolation: each test creates a /tmp throwaway repo + a stub `gh`
# binary on PATH that records its invocations to a per-test calls.log file.
# This means tests assert against the CALL SHAPE without touching real GitHub.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SCRIPT="$INTELLISENSE_SETUP_DIR/scripts/apply-merge-policy.sh"

# ----------------------------------------------------------------------------
# Local assertions (mirror pattern from test_pre_push_metadata_presence.sh)
# ----------------------------------------------------------------------------

assert_grep_match() {
  local pattern="$1" text="$2" message="${3:-pattern should match}"
  ((++TESTS_RUN))
  # `-e --` disambiguates patterns starting with `-` (e.g. `--dry-run`)
  # so grep doesn't misread them as its own flags.
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

assert_grep_no_match() {
  local pattern="$1" text="$2" message="${3:-pattern should not match}"
  ((++TESTS_RUN))
  if ! echo "$text" | grep -q -e "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern should NOT appear: $pattern"
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
# Test fixture: stub `gh` binary + isolated PATH
# ----------------------------------------------------------------------------

# setup_fake_gh <stubs_dir> [<response_json>]
#   Creates a `gh` shell stub in <stubs_dir> that:
#     - Records every invocation (argv + stdin) to $stubs_dir/calls.log
#     - Returns <response_json> on stdout (default: "{}")
#     - Always exits 0 unless GH_STUB_EXIT is set in env
#   Caller is expected to prefix <stubs_dir> on PATH before invoking the script.
setup_fake_gh() {
  local stubs_dir="$1"
  local response="${2:-}"
  [ -z "$response" ] && response='{}'
  mkdir -p "$stubs_dir"
  cat > "$stubs_dir/gh" <<EOF
#!/bin/bash
# Stub recording all invocations to calls.log.
STDIN=""
if [ ! -t 0 ]; then
  STDIN="\$(cat 2>/dev/null || true)"
fi
echo "ARGV: \$*" >> "$stubs_dir/calls.log"
if [ -n "\$STDIN" ]; then
  echo "STDIN: \$STDIN" >> "$stubs_dir/calls.log"
fi
echo "---" >> "$stubs_dir/calls.log"
# Configurable failure for error-path tests.
if [ -n "\${GH_STUB_EXIT:-}" ] && [ "\${GH_STUB_EXIT}" != "0" ]; then
  echo "stub error: exit code \${GH_STUB_EXIT}" >&2
  exit \${GH_STUB_EXIT}
fi
# Configurable response for read-call tests.
echo '${response}'
EOF
  chmod +x "$stubs_dir/gh"
}

# run_script <stubs_dir> <args...>
#   Invokes the script-under-test with the stub-gh on PATH.
#   Sets SCRIPT_EXIT and SCRIPT_OUTPUT in caller scope.
run_script() {
  local stubs_dir="$1"; shift
  SCRIPT_EXIT=
  SCRIPT_OUTPUT=$(PATH="$stubs_dir:$PATH" bash "$SCRIPT" "$@" 2>&1) || SCRIPT_EXIT=$?
  SCRIPT_EXIT=${SCRIPT_EXIT:-0}
}

echo -e "${BLUE}apply-merge-policy.sh Tests${NC}"
echo ""

# ============================================================================
# T1: --help / usage output
# ============================================================================
echo "T1: --help prints usage"
T1=$(mktemp -d); setup_fake_gh "$T1"
run_script "$T1" --help
assert_exit_code "0" "$SCRIPT_EXIT" "T1: --help exits 0"
assert_grep_match "Usage\|usage:" "$SCRIPT_OUTPUT" "T1: output contains usage line"
assert_grep_match "--dry-run" "$SCRIPT_OUTPUT" "T1: usage documents --dry-run"
assert_grep_match "--restore-defaults" "$SCRIPT_OUTPUT" "T1: usage documents --restore-defaults"
rm -rf "$T1"; echo ""

# ============================================================================
# T2: PATCH call shape — sends correct merge-method fields
# ============================================================================
echo "T2: applies rebase-only policy via gh api PATCH"
T2=$(mktemp -d); setup_fake_gh "$T2"
run_script "$T2" --repo example-org/test-repo
assert_exit_code "0" "$SCRIPT_EXIT" "T2: script exits 0 on success"
CALLS=$(cat "$T2/calls.log" 2>/dev/null || echo "")
assert_grep_match "PATCH.*\/repos\/example-org\/test-repo" "$CALLS" "T2: PATCH /repos/example-org/test-repo was called"
assert_grep_match "allow_squash_merge=false" "$CALLS" "T2: allow_squash_merge=false sent"
assert_grep_match "allow_merge_commit=false" "$CALLS" "T2: allow_merge_commit=false sent"
assert_grep_match "allow_rebase_merge=true" "$CALLS" "T2: allow_rebase_merge=true sent"
rm -rf "$T2"; echo ""

# ============================================================================
# T3: Idempotent — re-run on already-configured repo is a no-op (still safe)
# ============================================================================
echo "T3: re-run on already-configured repo is idempotent"
T3=$(mktemp -d)
# Stub gh to return the already-target-state on GET so the script can detect it
setup_fake_gh "$T3" '{"allow_squash_merge":false,"allow_merge_commit":false,"allow_rebase_merge":true}'
run_script "$T3" --repo example-org/already-set
assert_exit_code "0" "$SCRIPT_EXIT" "T3: idempotent re-run exits 0"
assert_grep_match "already\|no.change\|unchanged\|skip" "$SCRIPT_OUTPUT" "T3: output indicates no-op"
rm -rf "$T3"; echo ""

# ============================================================================
# T4: Opt-out honored via .intellisense/manifest.json: merge_policy_override
# ============================================================================
echo "T4: .intellisense/manifest.json merge_policy_override skips the PATCH"
T4=$(mktemp -d); setup_fake_gh "$T4"
# Caller invokes script with --manifest-dir pointing at a dir with an override manifest
mkdir -p "$T4/repo-with-override/.intellisense"
cat > "$T4/repo-with-override/.intellisense/manifest.json" <<EOF
{"policy_minimum_tier": 0, "merge_policy_override": "squash_with_metric_workaround"}
EOF
run_script "$T4" --repo example-org/some-repo --manifest-dir "$T4/repo-with-override"
assert_exit_code "0" "$SCRIPT_EXIT" "T4: opt-out repo still exits 0 (graceful skip)"
assert_grep_match "merge_policy_override\|opt.out\|skip" "$SCRIPT_OUTPUT" "T4: output explains why skipped"
CALLS=$(cat "$T4/calls.log" 2>/dev/null || echo "")
assert_grep_no_match "PATCH.*\/repos\/" "$CALLS" "T4: no PATCH call was made (opt-out honored)"
rm -rf "$T4"; echo ""

# ============================================================================
# T5: --dry-run prints plan, makes no API calls
# ============================================================================
echo "T5: --dry-run prints planned changes, makes no PATCH call"
T5=$(mktemp -d); setup_fake_gh "$T5"
run_script "$T5" --repo example-org/test-repo --dry-run
assert_exit_code "0" "$SCRIPT_EXIT" "T5: --dry-run exits 0"
assert_grep_match "dry.run\|would\|plan" "$SCRIPT_OUTPUT" "T5: output indicates dry-run intent"
CALLS=$(cat "$T5/calls.log" 2>/dev/null || echo "")
assert_grep_no_match "PATCH" "$CALLS" "T5: no PATCH call in dry-run"
rm -rf "$T5"; echo ""

# ============================================================================
# T6: gh api PATCH failure surfaces to operator (does NOT fail silently)
# ============================================================================
echo "T6: gh api failure produces clear error message + non-zero exit"
T6=$(mktemp -d); setup_fake_gh "$T6"
# Force the stub to fail
GH_STUB_EXIT=1 run_script "$T6" --repo example-org/will-fail
assert_exit_code "1" "$SCRIPT_EXIT" "T6: API failure surfaces non-zero exit"
assert_grep_match "fail\|error\|FAIL" "$SCRIPT_OUTPUT" "T6: error message names the failure"
rm -rf "$T6"; echo ""

# ============================================================================
# T7: --restore-defaults re-enables all three merge methods
# ============================================================================
echo "T7: --restore-defaults reverts merge methods to GitHub default"
T7=$(mktemp -d); setup_fake_gh "$T7"
run_script "$T7" --repo example-org/test-repo --restore-defaults
assert_exit_code "0" "$SCRIPT_EXIT" "T7: --restore-defaults exits 0"
CALLS=$(cat "$T7/calls.log" 2>/dev/null || echo "")
assert_grep_match "allow_squash_merge=true" "$CALLS" "T7: re-enables squash"
assert_grep_match "allow_merge_commit=true" "$CALLS" "T7: re-enables merge commits"
assert_grep_match "allow_rebase_merge=true" "$CALLS" "T7: keeps rebase enabled"
rm -rf "$T7"; echo ""

# ============================================================================
# T8: Missing gh CLI fails clearly (rather than mysteriously)
# ============================================================================
echo "T8: missing gh CLI on PATH produces clear error"
T8=$(mktemp -d)
# Path with ONLY system bins (so jq/grep/etc. still resolve) but NO gh.
# We achieve this by listing system bin dirs but omitting any dir that
# happens to contain a real `gh` (homebrew typically /opt/homebrew/bin).
SCRIPT_EXIT=
SCRIPT_OUTPUT=$(PATH="$T8:/usr/bin:/bin:/usr/sbin:/sbin" bash "$SCRIPT" --repo example-org/test-repo 2>&1) || SCRIPT_EXIT=$?
SCRIPT_EXIT=${SCRIPT_EXIT:-0}
assert_exit_code "1" "$SCRIPT_EXIT" "T8: missing gh exits non-zero"
assert_grep_match "gh\|GitHub CLI\|not found\|install" "$SCRIPT_OUTPUT" "T8: error names the missing dependency"
rm -rf "$T8"; echo ""

# ============================================================================
# T9: Multiple --repo flags accepted (apply to each in sequence)
# ============================================================================
echo "T9: multiple --repo flags apply to each"
T9=$(mktemp -d); setup_fake_gh "$T9"
run_script "$T9" --repo example-org/repo-a --repo example-org/repo-b
assert_exit_code "0" "$SCRIPT_EXIT" "T9: multi-repo invocation exits 0"
CALLS=$(cat "$T9/calls.log" 2>/dev/null || echo "")
assert_grep_match "\/repos\/example-org\/repo-a" "$CALLS" "T9: PATCH sent to repo-a"
assert_grep_match "\/repos\/example-org\/repo-b" "$CALLS" "T9: PATCH sent to repo-b"
rm -rf "$T9"; echo ""

print_test_summary
