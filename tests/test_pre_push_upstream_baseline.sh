#!/bin/bash
#
# test_pre_push_upstream_baseline.sh — scan-range baseline correctness
#
# The pre-push hook computed its scan range against the
# FORK's origin/<default> branch. When the fork's master is stale but the
# feature branch has synced commits from upstream/master (mandatory fork
# hygiene), those already-reviewed upstream commits fell inside the range and
# tripped Tier 2 (financial/auth/migration) — a false-positive block.
#
# Fix (option B): a single RANGE_BASE that prefers upstream/<default> when the
# upstream remote-tracking ref exists, else falls back to origin/<default>
# (today's behaviour). Fail-safe: never scans a NARROWER set than today when
# upstream is unresolved, so a developer's OWN Tier 2 change is never hidden.
#
# Test matrix:
#   T1 (RED->GREEN): fork/origin stale at C0, upstream ahead at C2 (contains
#       payment/charge.go), branch = C2 + one benign NOTES.md commit.
#       upstream/<default> baseline => only NOTES.md in range => PUSH PASSES.
#   T2 (no false negative): same stale/ahead setup, but the developer's OWN
#       commit adds account/refund.go => still Tier 2 => PUSH BLOCKED.
#   T3 (fail-safe): no upstream remote-tracking ref => falls back to origin
#       baseline => payment/charge.go back in range => PUSH BLOCKED (no silent
#       pass when upstream is unknown).
#   T4 (consumer parity): in the T1 scenario the per-commit Beads loop must NOT
#       demand a Beads: trailer on the upstream commit the developer didn't author.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# ─── Local asserts ──────────────────────────────────────────────────────────
assert_exit_code() {
  local expected="$1" actual="$2" message="${3:-exit code}"
  ((++TESTS_RUN))
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $message (exit $actual)"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected exit: $expected"
    echo -e "    Actual exit:   $actual"
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

# ─── Fixture: stale fork (origin@C0) + ahead upstream (upstream@C2) ──────────
# Builds linear history C0(README) -> C1(payment/charge.go) -> C2(README++),
# sets origin/main=C0 (stale) and upstream/main=C2 (ahead). HEAD is left at C2;
# the caller adds the developer's own commit(s) on top.
mk_base() {
  local d="$1"
  git -C "$d" init -q --initial-branch=main 2>/dev/null || git -C "$d" init -q
  git -C "$d" config user.email t@e.com
  git -C "$d" config user.name "Repro Tester"
  git -C "$d" config commit.gpgsign false
  git -C "$d" remote add origin   https://github.com/fork/repo.git
  git -C "$d" remote add upstream https://github.com/upstream/repo.git

  echo "# proj" > "$d/README.md"
  git -C "$d" add README.md && git -C "$d" commit -q -m "C0 init"
  local c0; c0=$(git -C "$d" rev-parse HEAD)

  mkdir -p "$d/payment"
  echo "package payment" > "$d/payment/charge.go"
  git -C "$d" add payment/charge.go && git -C "$d" commit -q -m "C1 upstream payment (already reviewed)"

  echo "upstream change" >> "$d/README.md"
  git -C "$d" add README.md && git -C "$d" commit -q -m "C2 upstream work"
  local c2; c2=$(git -C "$d" rev-parse HEAD)

  mkdir -p "$d/.git/refs/remotes/origin" "$d/.git/refs/remotes/upstream"
  echo "$c0" > "$d/.git/refs/remotes/origin/main"        # fork master STALE at C0
  echo "ref: refs/remotes/origin/main" > "$d/.git/refs/remotes/origin/HEAD"
  echo "$c2" > "$d/.git/refs/remotes/upstream/main"       # upstream master AHEAD at C2
}

run_hook() {
  local d="$1"
  ( cd "$d" \
      && INTELLISENSE_SETUP_PATH="$INTELLISENSE_SETUP_DIR" \
         bash "$INTELLISENSE_SETUP_DIR/hooks/pre-push" origin https://github.com/fork/repo.git \
         < /dev/null 2>&1 )
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ─── T1: benign commit synced over upstream financial file → PASSES ─────────
echo "T1: branch synced onto upstream (has payment/), only benign NOTES.md added → push PASSES"
T1="$TMP_ROOT/t1"; mkdir -p "$T1"; mk_base "$T1"
echo "my notes" > "$T1/NOTES.md"
git -C "$T1" add NOTES.md && git -C "$T1" commit -q -m "C_new my benign docs change"
HOOK_EXIT=; OUT=$(run_hook "$T1") || HOOK_EXIT=$?; HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "0" "$HOOK_EXIT" "upstream-baseline: synced upstream financial file is not re-scanned"

# ─── T4: per-commit Beads parity (uses T1's output) ─────────────────────────
echo "T4: per-commit Beads check does not flag the upstream commit"
assert_grep_no_match "C1 upstream payment" "$OUT" "no Beads: demand on upstream commit C1"
assert_grep_no_match "Beads: trailer missing" "$OUT" "no per-commit Beads block for upstream-authored work"

# ─── T2: developer's OWN Tier 2 change still BLOCKS (no false negative) ──────
echo "T2: developer's own commit touches account/ → still BLOCKED"
T2="$TMP_ROOT/t2"; mkdir -p "$T2"; mk_base "$T2"
mkdir -p "$T2/account"
echo "package account" > "$T2/account/refund.go"
git -C "$T2" add account/refund.go && git -C "$T2" commit -q -m "C_new my own account change (no Beads)"
HOOK_EXIT=; OUT=$(run_hook "$T2") || HOOK_EXIT=$?; HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "1" "$HOOK_EXIT" "own Tier 2 change is still caught (fail-safe holds)"

# ─── T3: no upstream remote → fall back to origin baseline → BLOCKS ─────────
echo "T3: no upstream remote-tracking ref → falls back to origin baseline → BLOCKED"
T3="$TMP_ROOT/t3"; mkdir -p "$T3"; mk_base "$T3"
rm -f "$T3/.git/refs/remotes/upstream/main"
git -C "$T3" remote remove upstream 2>/dev/null || true
echo "my notes" > "$T3/NOTES.md"
git -C "$T3" add NOTES.md && git -C "$T3" commit -q -m "C_new benign (no upstream remote)"
HOOK_EXIT=; OUT=$(run_hook "$T3") || HOOK_EXIT=$?; HOOK_EXIT=${HOOK_EXIT:-0}
assert_exit_code "1" "$HOOK_EXIT" "no-upstream behaves exactly as today (origin baseline)"

print_test_summary
