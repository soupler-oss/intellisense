#!/bin/bash
# tests/test_source_guard.sh — regression harness for the setup.sh source-guard.
#
# Bug: running `source setup.sh` / `. setup.sh` on Linux closed the user's
# terminal. setup.sh uses `set -e` and has hard `exit 1` guards; when sourced,
# those aborts run in the caller's interactive shell and terminate it.
#
# Fix: a source-guard at the top of setup.sh detects sourcing and bails with
# `return` (non-zero) instead of letting `exit`/`set -e` kill the parent shell.
#
# Verifies:
#   S1 Sourcing setup.sh in a subshell returns NON-ZERO (guard fired) rather
#      than running the full setup flow.
#   S2 The sourcing parent shell SURVIVES — execution continues past the
#      `source` line (the terminal would not close).
#   S3 The guard prints the corrective "must be executed, not sourced" message.
#   S4 Direct execution still reaches the real script body (guard does NOT fire
#      on `./setup.sh` / `bash setup.sh`).

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$INTELLISENSE_SETUP/setup.sh"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

case_pass() { echo "  ✓ $1"; echo "P" >> "$RESULTS"; }
case_fail() { echo "  ✗ $1: $2"; echo "F" >> "$RESULTS"; }

# ─────────────────────────────────────────────────────────────────────
# S1 + S2: source the script inside a subshell. If the guard works, control
# returns to the subshell (it survives) and we observe a non-zero rc from the
# sourced script. We capture both the post-source rc and a survival sentinel.
# Without the fix, `source` would abort the subshell via exit/set -e and the
# sentinel would never print.
out="$(bash -c '
  source "'"$SETUP"'" >/dev/null 2>&1
  rc=$?
  echo "SURVIVED rc=$rc"
' 2>/dev/null || true)"

if echo "$out" | grep -q '^SURVIVED '; then
  case_pass "S2 parent-shell-survives-sourcing"
else
  case_fail "S2" "sourcing setup.sh aborted the parent shell (no survival sentinel)"
  echo "    captured: ${out:-<empty>}"
fi

src_rc="$(echo "$out" | sed -n 's/^SURVIVED rc=//p')"
if [ -n "$src_rc" ] && [ "$src_rc" -ne 0 ]; then
  case_pass "S1 sourcing-returns-nonzero"
else
  case_fail "S1" "expected non-zero return from sourced setup.sh, got '${src_rc:-<none>}'"
fi

# ─────────────────────────────────────────────────────────────────────
# S3: the guard must tell the user how to run it correctly.
msg="$(bash -c 'source "'"$SETUP"'" 2>&1 || true')"
if echo "$msg" | grep -qi 'must be executed, not sourced'; then
  case_pass "S3 guard-prints-corrective-message"
else
  case_fail "S3" "guard did not print the 'must be executed, not sourced' message"
  echo "    captured: ${msg:-<empty>}"
fi

# ─────────────────────────────────────────────────────────────────────
# S4: direct execution must NOT trip the guard. We run with --help-style early
# args via a stubbed HOME so the real flow can't touch the developer's machine,
# and assert the guard message is absent. We use --dry-run --non-interactive
# and an isolated HOME; we only care that the guard branch did not fire.
ISO_HOME="$(mktemp -d)"
exec_out="$(HOME="$ISO_HOME" bash "$SETUP" --dry-run --non-interactive --skip-repo-setup 2>&1 || true)"
rm -rf "$ISO_HOME" 2>/dev/null || true
if echo "$exec_out" | grep -qi 'must be executed, not sourced'; then
  case_fail "S4" "guard incorrectly fired on direct execution"
  echo "    captured (head): $(echo "$exec_out" | head -3)"
else
  case_pass "S4 direct-execution-does-not-trip-guard"
fi

# ─────────────────────────────────────────────────────────────────────
PASS=$(grep -c '^P$' "$RESULTS" || true)
FAIL=$(grep -c '^F$' "$RESULTS" || true)
echo "─────────────────────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
