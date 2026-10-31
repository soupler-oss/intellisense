#!/bin/bash
#
# test_pre_push_per_commit_task.sh — per-commit task-trailer enforcement
#
# Every Tier 1+ commit carries its OWN task trailer (any key in the policy's
# evidence.task_trailers: Task, Refs, …): one commit's trailer never
# satisfies the gate for the other commits in the push range. The trailer check
# itself is the engine's gate (`intellisense gate`), which the hook calls.
#
# Test matrix (mirrors the acceptance criteria):
#   (a) Commit A on Tier 0 path has a task trailer; commit B on Tier 1 path
#       (setup.sh) lacks a task trailer → push BLOCKED, error names commit B's SHA
#       and the Tier 1 path it touched.
#   (b) Commit on Tier 0 path (README.md) with no a task trailer → push PASSES.
#   (c) Commit on Tier 1 path (setup.sh) whose Intellisense-Metadata declares
#       `tier=0` → push BLOCKED with metadata/path tier-mismatch message.
#   (d) Commit on Tier 1 path with a task trailer but Intellisense-Metadata missing
#       required fields → enforced mode BLOCKS; pilot mode WARNS-only
#       (pinning existing the metadata check behavior so the new per-commit logic does
#       not regress it).
#   (e) 2-parent merge commit on Tier 0 paths with no a task trailer → push
#       PASSES (defensive: real merge commits are common locally; do
#       not over-block).
#
# Server-side synthetic merge commits (refs/pull/N/merge) are out of scope
# for the local pre-push hook — the CI PR check that
# inspects refs/pull/N/head and skips the synthetic merge node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# ─── Local asserts (mirroring test_pre_push_tiers.sh style) ─────────────────
assert_grep_match() {
  local pattern="$1" text="$2" message="${3:-pattern should match}"
  ((++TESTS_RUN))
  if echo "$text" | grep -qE "$pattern"; then
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
  if ! echo "$text" | grep -qE "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Pattern unexpectedly matched: $pattern"
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
    echo -e "  ${RED}✗${NC} $message (got $actual)"
    ((++TESTS_FAILED))
  fi
}

# Minimal repo: origin/main set to initial commit, fork-style remotes.
setup_test_repo() {
  local d="$1"
  git -C "$d" init --initial-branch=main >/dev/null 2>&1
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test User"
  git -C "$d" remote add origin https://github.com/fork/repo.git
  git -C "$d" remote add upstream https://github.com/upstream/repo.git
  git -C "$d" commit --allow-empty -m "init" >/dev/null 2>&1
  mkdir -p "$d/.git/refs/remotes/origin"
  git -C "$d" rev-parse HEAD > "$d/.git/refs/remotes/origin/main"
  echo "ref: refs/remotes/origin/main" > "$d/.git/refs/remotes/origin/HEAD"
}

run_hook() {
  local d="$1"
  local exit_code= out
  ( cd "$d" && bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1 ) \
    > /tmp/hook_out.$$ || exit_code=$?
  exit_code=${exit_code:-0}
  out=$(cat /tmp/hook_out.$$)
  rm -f /tmp/hook_out.$$
  printf '%s\n' "$out"
  return "$exit_code"
}

echo -e "${BLUE}Per-commit task trailer enforcement${NC}"
echo ""

# ─── Test (a): commit A has task trailer, commit B (Tier 1) does not → BLOCK ─────
echo "Test (a): free-ride blocked — Tier 1 commit without its own a task trailer"

T_A=$(mktemp -d)
setup_test_repo "$T_A"

# Commit 1: README change with task trailer
echo "first" > "$T_A/README.md"
git -C "$T_A" add README.md
git -C "$T_A" commit -m "docs: tweak readme

Task: PROJ-1" >/dev/null 2>&1

# Commit 2: setup.sh edit, NO task trailer
echo "echo minor edit" >> "$T_A/setup.sh"
git -C "$T_A" add setup.sh
git -C "$T_A" commit -m "chore: tweak setup (intentionally lacks task trailer)" >/dev/null 2>&1

COMMIT_B_SHA=$(git -C "$T_A" rev-parse HEAD)
HOOK_EXIT=
OUT=$(run_hook "$T_A") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "1" "$HOOK_EXIT" "push blocked (exit 1)"
assert_grep_match "${COMMIT_B_SHA:0:7}" "$OUT" "error cites commit B's SHA"
assert_grep_match "setup\.sh" "$OUT" "error names the Tier 1 path that triggered enforcement"
assert_grep_match "has no task trailer" "$OUT" "error explains the missing task trailer"

rm -rf "$T_A"
echo ""

# ─── Test (b): Tier 0 docs commit without a task trailer → PASS ────────────────────
echo "Test (b): Tier 0 docs commit without a task trailer passes"

T_B=$(mktemp -d)
setup_test_repo "$T_B"

echo "# docs change" > "$T_B/README.md"
git -C "$T_B" add README.md
git -C "$T_B" commit -m "docs: harmless update" >/dev/null 2>&1

HOOK_EXIT=
OUT=$(run_hook "$T_B") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "0" "$HOOK_EXIT" "Tier 0 commit passes without a task trailer"
assert_grep_no_match "BLOCKED" "$OUT" "no BLOCKED message"

rm -rf "$T_B"
echo ""

# ─── Test (c): metadata says tier 0 but path is tier 1 → BLOCK ─────────────
echo "Test (c): Intellisense-Metadata declares tier 0 but path is Tier 1 → blocked"

T_C=$(mktemp -d)
setup_test_repo "$T_C"

echo "echo tier-misdeclared edit" >> "$T_C/setup.sh"
git -C "$T_C" add setup.sh
git -C "$T_C" commit -m "chore: tweak setup with misdeclared metadata

Task: PROJ-2
Intellisense-Metadata: {\"v\":1,\"author_type\":\"claude_with_intellisense\",\"commit_kind\":\"single\",\"stamping_source\":\"local_hook\",\"classification_state\":\"ok\",\"tier\":0,\"mode\":\"bug_fix\",\"session\":\"s1\",\"version\":\"1.0.0\",\"tokens\":{\"input\":1,\"output\":1,\"cache_creation\":0,\"cache_read\":0,\"total\":2}}" >/dev/null 2>&1

HOOK_EXIT=
OUT=$(run_hook "$T_C") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "1" "$HOOK_EXIT" "push blocked when metadata-tier < path-tier"
assert_grep_match "tier" "$OUT" "error message mentions tier"
assert_grep_match "(mismatch|declared|path)" "$OUT" "error explains the mismatch"

rm -rf "$T_C"
echo ""

# ─── Test (d): Intellisense-Metadata missing required fields ─────
echo "Test (d): Intellisense-Metadata missing required field"

T_D=$(mktemp -d)
setup_test_repo "$T_D"

echo "# d-test edit" > "$T_D/README.md"
git -C "$T_D" add README.md
# Metadata missing `version` and the tokens sub-fields
git -C "$T_D" commit -m "docs: d-test

Intellisense-Metadata: {\"v\":1,\"author_type\":\"claude_with_intellisense\",\"commit_kind\":\"single\",\"stamping_source\":\"local_hook\",\"classification_state\":\"ok\",\"tier\":0,\"mode\":\"bug_fix\",\"session\":\"s1\"}" >/dev/null 2>&1

# Pilot mode: warn-only, exit 0
HOOK_EXIT=
OUT=$(INTELLISENSE_GATE_MODE=pilot run_hook "$T_D") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "0" "$HOOK_EXIT" "pilot mode: missing fields warn-only"
assert_grep_match "(pilot|missing)" "$OUT" "pilot warning printed"

# Enforced mode: must block
HOOK_EXIT=
OUT=$(INTELLISENSE_GATE_MODE=enforced run_hook "$T_D") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "1" "$HOOK_EXIT" "enforced mode: missing fields blocked"
assert_grep_match "(BLOCKED|missing)" "$OUT" "enforced block message printed"

rm -rf "$T_D"
echo ""

# ─── Test (e): 2-parent merge commit on Tier 0 paths → PASS ───────────────
echo "Test (e): real 2-parent merge commit on Tier 0 paths passes"

T_E=$(mktemp -d)
setup_test_repo "$T_E"

# Branch off, make a Tier 0 change, switch back, merge --no-ff
git -C "$T_E" checkout -b feature-e >/dev/null 2>&1
echo "feature line" > "$T_E/README.md"
git -C "$T_E" add README.md
git -C "$T_E" commit -m "docs: feature change" >/dev/null 2>&1
git -C "$T_E" checkout main >/dev/null 2>&1
git -C "$T_E" merge --no-ff feature-e -m "merge: feature-e into main" >/dev/null 2>&1

# Should pass (Tier 0, defensive merge handling)
HOOK_EXIT=
OUT=$(run_hook "$T_E") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "0" "$HOOK_EXIT" "Tier 0 merge commit does not block"
assert_grep_no_match "BLOCKED" "$OUT" "no BLOCKED message on merge commit"

rm -rf "$T_E"
echo ""

# ─── Test (f): degraded install (effective-tier lib unresolvable) still blocks ─
echo "Test (f): degraded install (no effective-tier.sh) — setup.sh + no task trailer still blocked"

T_F=$(mktemp -d)
setup_test_repo "$T_F"

# Setup.sh edit with NO task trailer
echo "echo degraded-install probe" >> "$T_F/setup.sh"
git -C "$T_F" add setup.sh
git -C "$T_F" commit -m "chore: tweak setup (no task trailer — degraded-install probe)" >/dev/null 2>&1

# The hook also looks for the engine in the standard install folders (Homebrew, /usr/local/bin). On a machine with
# intellisense installed there, a missing engine cannot be simulated, so the "engine is missing" message checks are
# skipped; CI, which has no installed engine, runs them. The BLOCK itself is asserted either way.
ENGINE_INSTALLED=""
for _d in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
  [ -x "$_d/intellisense" ] && ENGINE_INSTALLED="$_d/intellisense"
done
assert_engine_missing_message() {
  if [ -n "$ENGINE_INSTALLED" ]; then
    echo "  SKIP: $2 — intellisense is installed at $ENGINE_INSTALLED, so a missing engine cannot be simulated here"
    return
  fi
  assert_grep_match "engine is not installed" "$1" "$2"
}

# Run the hook with the library deliberately unreachable:
# - INTELLISENSE_SETUP_PATH points to nowhere
# - HOME points to an empty dir (no ~/.claude/config.json to fall back to)
# If the engine lookup failed open, the per-commit task-trailer check would
# pass silently. With the fix, it must still BLOCK.
FAKE_HOME=$(mktemp -d)
HOOK_EXIT=
OUT=$(
  cd "$T_F" && \
  env -i \
    PATH="$PATH" \
    HOME="$FAKE_HOME" \
    INTELLISENSE_SETUP_PATH="/no/such/dir" \
    bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1
) || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "1" "$HOOK_EXIT" "degraded install: setup.sh without task trailer still BLOCKED (no fail-open)"
# Degraded now means "the engine cannot be found": the hook fails closed and names the fix.
assert_engine_missing_message "$OUT" "error says the engine is missing (fail-closed)"
if [ -z "$ENGINE_INSTALLED" ]; then
  assert_grep_match "intellisense live install" "$OUT" "error names the install command"
fi
# Sanity: confirm we actually degraded the env (library would have logged otherwise).
# This assertion guards against the test silently re-resolving via $HOME — if it
# stops being a meaningful degradation, the test is no longer probing what it claims.
assert_grep_no_match "✅ contract validated" "$OUT" "library-dependent validators did not silently run"

rm -rf "$T_F" "$FAKE_HOME"
echo ""

# ─── Tests (g)/(h): hooks/ path-policy gap — pre-push itself is Tier 1 ─────
# hooks/pre-push is itself a Tier 1 path: editing it without a task trailer must
# be blocked, with or without the Live-mode libraries installed.
echo "Test (g): hooks/pre-push commit without task trailer → BLOCKED (normal install)"

T_G=$(mktemp -d)
setup_test_repo "$T_G"

mkdir -p "$T_G/hooks"
cat > "$T_G/hooks/pre-push" <<'PREPUSH'
#!/usr/bin/env bash
# placeholder hook for the test
exit 0
PREPUSH
git -C "$T_G" add hooks/pre-push
git -C "$T_G" commit -m "chore: tweak hooks/pre-push (no task trailer — gap probe)" >/dev/null 2>&1
COMMIT_G_SHA=$(git -C "$T_G" rev-parse HEAD)

HOOK_EXIT=
OUT=$(run_hook "$T_G") || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "1" "$HOOK_EXIT" "hooks/pre-push commit without task trailer is BLOCKED"
assert_grep_match "${COMMIT_G_SHA:0:7}" "$OUT" "error cites the commit SHA"
assert_grep_match "hooks/pre-push" "$OUT" "error names hooks/pre-push as the Tier 1 path"
assert_grep_match "has no task trailer" "$OUT" "error explains the missing task trailer"

rm -rf "$T_G"
echo ""

echo "Test (h): hooks/pre-push commit without task trailer → BLOCKED (degraded install — no effective-tier.sh)"

T_H=$(mktemp -d)
setup_test_repo "$T_H"

mkdir -p "$T_H/hooks"
echo "#!/usr/bin/env bash" > "$T_H/hooks/pre-push"
echo "exit 0" >> "$T_H/hooks/pre-push"
git -C "$T_H" add hooks/pre-push
git -C "$T_H" commit -m "chore: tweak hooks/pre-push (no task trailer — degraded-install + hooks/ probe)" >/dev/null 2>&1

FAKE_HOME=$(mktemp -d)
HOOK_EXIT=
OUT=$(
  cd "$T_H" && \
  env -i \
    PATH="$PATH" \
    HOME="$FAKE_HOME" \
    INTELLISENSE_SETUP_PATH="/no/such/dir" \
    bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git 2>&1
) || HOOK_EXIT=$?
HOOK_EXIT=${HOOK_EXIT:-0}

assert_exit_code "1" "$HOOK_EXIT" "degraded install: hooks/pre-push without task trailer still BLOCKED"
assert_engine_missing_message "$OUT" "degraded install: error says the engine is missing (fail-closed)"

rm -rf "$T_H" "$FAKE_HOME"
echo ""

print_test_summary "Per-commit task trailer enforcement"
