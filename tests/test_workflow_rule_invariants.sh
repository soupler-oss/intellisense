#!/bin/bash
# tests/test_workflow_rule_invariants.sh — Type C proof for the §6a manifest validator.
#
# §6a (plan F12/F12b): the gate-coverage check must be a MECHANIZED POSITIVE
# MANIFEST — assert that named safety invariants are PRESENT in the always-loaded
# development-workflow.md. It must NOT be a global "fail if a gate line lives in a
# coding file" scan (F12b: that false-positives on development-workflow-impl.md's
# legitimate Phase 2-6 gates).
#
# Verifies:
#   T0 the check script exists and is executable
#   T1 POSITIVE — the real development-workflow.md satisfies every invariant (exit 0)
#   T2 NEGATIVE — remove one invariant -> the check FAILS (exit 1)  [the guard works]
#   T3 NEGATIVE output names the missing invariant
#   T4 the check does NOT flag development-workflow-impl.md's coding-phase gates
#      (F12b: positive manifest is scoped to the always-loaded file only)

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$INTELLISENSE_SETUP/scripts/check-workflow-invariants.sh"
WF="$INTELLISENSE_SETUP/rules/operational/development-workflow.md"
IMPL="$INTELLISENSE_SETUP/rules/operational/development-workflow-impl.md"
RESULTS="$(mktemp)"
TMPWF="$(mktemp)"
trap 'rm -f "$RESULTS" "$TMPWF"' EXIT

pass() { echo "  ✓ $1"; echo P >> "$RESULTS"; }
fail() { echo "  ✗ $1: $2"; echo F >> "$RESULTS"; }

# T0 — script present + executable
if [ -x "$CHECK" ]; then
  pass "check script present + executable"
else
  fail "check script" "missing or not executable: $CHECK"
fi

# T1 — POSITIVE: real file passes
if [ -x "$CHECK" ] && bash "$CHECK" "$WF" >/dev/null 2>&1; then
  pass "positive: real development-workflow.md satisfies all invariants"
else
  fail "positive" "real development-workflow.md did NOT satisfy the manifest"
fi

# T2 — NEGATIVE: drop the 'never source as shell' security invariant -> must fail
grep -v 'never .source.d as shell' "$WF" > "$TMPWF"
if [ -x "$CHECK" ] && ! bash "$CHECK" "$TMPWF" >/dev/null 2>&1; then
  pass "negative: removing an invariant makes the check fail (exit 1)"
else
  fail "negative" "check did NOT fail when an invariant was removed"
fi

# T3 — NEGATIVE output names the missing invariant
if [ -x "$CHECK" ] && bash "$CHECK" "$TMPWF" 2>&1 | grep -qi "source"; then
  pass "negative: failure output names the missing invariant"
else
  fail "negative output" "failure did not name the missing invariant"
fi

# T4 — F12b: the impl.md coding-phase file must NOT be required to carry the
# always-loaded manifest (the check targets the always-loaded file only).
if [ -x "$CHECK" ] && ! bash "$CHECK" "$IMPL" >/dev/null 2>&1; then
  pass "F12b: impl.md (coding file) is not forced to satisfy the always-loaded manifest"
else
  fail "F12b" "check unexpectedly passed impl.md — manifest is not scoped to the always-loaded file"
fi

# T5 — UNIQUENESS (regression guard for the decorative-pattern class): each
# high-value invariant must be UNIQUELY anchored, so deleting its real line makes
# the check FAIL. A bare-token pattern (e.g. /Refs:/) would stay green here
# because the token also appears in incidental prose — this loop forbids that.
for probe in \
  "on each Tier 1+ commit (or Task" \
  "# once per change" \
  "explicit approval of the plan" \
  "≤3 files" \
  "≤800 lines total" \
  "PreToolUse contract gate"; do
  t5tmp="$(mktemp)"
  grep -vF "$probe" "$WF" > "$t5tmp"
  if [ -x "$CHECK" ] && ! bash "$CHECK" "$t5tmp" >/dev/null 2>&1; then
    pass "uniqueness: removing '$probe' fails the check"
  else
    fail "uniqueness '$probe'" "guard is decorative — check still passed after deletion"
  fi
  rm -f "$t5tmp"
done

P=$(grep -c P "$RESULTS" || true)
F=$(grep -c F "$RESULTS" || true)
echo ""
echo "Passed: $P  Failed: $F"
[ "$F" -eq 0 ]
