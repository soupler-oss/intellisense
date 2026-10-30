#!/bin/bash
# scripts/check-workflow-invariants.sh — §6a positive-manifest gate-coverage check.
#
# Asserts that named SAFETY invariants are PRESENT in the always-loaded
# development-workflow.md. This is a POSITIVE MANIFEST, not a global "fail if a
# gate line lives in a coding/reference file" scan — the latter false-positives on
# development-workflow-impl.md's legitimate Phase 2-6 gates (plan finding F12b).
#
# Each manifest entry guards a safety rule that future restructure/dedup edits
# must not silently strand out of the always-loaded file. If a line is genuinely
# moved/reworded, update BOTH the file and the matching pattern here.
#
# Usage: check-workflow-invariants.sh <path-to-development-workflow.md>
# Exit:  0 all invariants present | 1 one or more missing | 2 bad usage
set -u

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "check-workflow-invariants: file not found: ${FILE:-<none>}" >&2
  exit 2
fi

# label::extended-regex — each MUST appear in the always-loaded file.
#
# IMPORTANT: every pattern is UNIQUELY ANCHORED to the one line that states its
# rule (verified to match exactly one line). Bare tokens (Refs:, Change Contract:,
# 800 lines, PreToolUse, ...) are FORBIDDEN here — they also match incidental
# prose (e.g. the "Visibility rule" sentence), so a bare-token guard stays green
# even when the real safety line is stranded. If you add an invariant, grep the
# pattern against development-workflow.md and confirm exactly one match; if you
# reword a guarded line, update its anchor here in the same commit.
MANIFEST=(
  "Tier 1+ task trailer on each commit::on each Tier 1\+ commit \(or Task"
  "Change Contract once per change::# once per change"
  "Tier 2 approval of the plan before editing::explicit approval of the plan"
  "Write Protection scoped to Tier 1+ (F13)::No file modifications .*for.*Tier 1"
  "Enforcement summary: pre-push hook::Pre-push hook"
  "Enforcement summary: PreToolUse gate::PreToolUse contract gate"
  "Enforcement summary: audit chain::Audit chain"
  "Security: never source session JSON as shell::never .source.d as shell"
  "Scope limit: 800 total lines::≤800 lines total"
  "Scope limit: bug_fix 3 files::≤3 files"
  "bug_fix 4th-file STOP gate::4th file touched"
  "Financial bug_fix escalation::Financial Impact Requires Full"
)

missing=0
for entry in "${MANIFEST[@]}"; do
  label="${entry%%::*}"
  regex="${entry#*::}"
  if ! grep -qE "$regex" "$FILE"; then
    echo "MISSING invariant: $label  (pattern: /$regex/)" >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "check-workflow-invariants: $missing invariant(s) missing from $FILE" >&2
  exit 1
fi

echo "check-workflow-invariants: all ${#MANIFEST[@]} invariants present in $FILE"
exit 0
