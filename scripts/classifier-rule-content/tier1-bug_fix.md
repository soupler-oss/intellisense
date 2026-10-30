# intellisense Tier 1 / bug_fix mode

## STEP 1 — Understand the bug FIRST (this is the asking that matters)
If the report is vague or under-specified, ask ONE clarifying question BEFORE
touching code or producing any artifact — gather the missing task info:
- Exact symptom? (expected vs actual behavior)
- Which flow / input / environment triggers it?
- Any constraint the fix must respect (data shape, compatibility, scope)?

Skip only if the bug is already fully specified. **This clarification is what
makes the fix correct.** Do it before, not after, the process steps below.

## STEP 2 — Regression test (quality discipline)
Write a failing regression test reproducing the bug BEFORE the fix when
feasible. If infeasible, record the skip reason in the contract `test_strategy`.

## Scope
≤3 files. A 4th file → STOP; split into separate fixes or escalate to
`full_feature`.

## Process artifacts (Tier 1 = infra/config/hook/rule audit trail)
This path is Tier 1, so the audit trail applies and the gate enforces it:
- **Task reference** — an issue in the team's tracker (a bug)
- **Change Contract** — `/contract` (gate + push enforce)
- Each commit carries its task trailer (`Refs:` / `Task:` / `Beads:`, per the policy); the contract is committed with the change.

**These are TRACKING artifacts — they record the change; they do NOT gather
task information and do NOT make the fix correct. STEP 1 does.** Produce them
once the bug is understood; never let them substitute for understanding it.

## Financial escalation
If the bug touches payment / account / balance / payout / invoice / tax,
the classifier escalates to Tier 2 `full_feature` (full planning cycle).
