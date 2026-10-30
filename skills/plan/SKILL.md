---
name: plan
description: Use before implementing a feature, fix or refactor in one repository, to turn the requirement into concrete, ordered execution steps.
---

# /plan — Single-Repo Requirement Analysis

## Purpose
Analyze a single-repo requirement into concrete execution steps before implementation begins.

## When to Use
- Single-repo feature, fix, or refactor
- Must run before any implementation
- Use `/multi-service-plan` if impact spans 2+ repos

## Rules (Non-Negotiable)
1. Search for existing patterns before designing new code
2. Financial code requires 95%+ test coverage minimum
3. Flag all deployment dependencies from CLAUDE.md
4. Extract reusable components to shared libraries if applicable

## Input
A requirement like: "add [feature-name] to [service-function]"

Example: "add reconciliation validation to payment processing"

---

## Design Alternatives
Propose 2-3 approaches with trade-offs:

**Approach A (Recommended)**
- Pros: [list]
- Cons: [list]
- Trade-off: [simplicity vs performance vs maintainability]

**Approach B**
- Pros: [list]
- Cons: [list]

**Decision:** Chose A because [constraint or principle].

---

## Assumptions & Constraints (Karpathy)
Surface assumptions before proceeding:
- [ ] What does success look like? (measurable)
- [ ] What constraints apply? (framework, dependencies, data patterns)
- [ ] What are you assuming about the codebase?
- [ ] What could go wrong? (failure modes, edge cases)

---

## Impact Discovery

**Run for:** Tier 1/2 in intellisense-managed repos. Tier 0 skips. Full policy: `rules/operational/graph-policy.md`.

For each function/endpoint the change modifies:

1. **Source.** Read `.intellisense/graph-status.json`. If `readiness=ready` and built within 7 days → run `who-calls <symbol>` and `change-spread <file>`. Java repos: exclude `**/test/**`, `**/generated/**`, `**/examples/**`. Otherwise → `rg -n "<symbol>\(" --type=<lang>`; mark `graph_available: no`.
2. **Classify each suggestion.** `added` (will edit), `verified_unchanged` (record one-line reason), `dismissed` (record one-line reason).
3. **Weak stacks** (Laravel, plain JS, advisory TS): mark `[INTELLISENSE-WEAK-STACK: <stack> — verify manually]`. Magic methods, queue/event handlers, DI targets need manual cross-check.

Output block (copy verbatim into contract `impact_analysis`; per-suggestion reasons into `impact_analysis_dismissed_suggestions`):

```
Stack: <stack> (<support-tier>)
Graph: built | stale | unavailable
Changed surface: <symbol> in <file:line>
Suggested callers (<N>):
- <file>: added | verified_unchanged — <reason> | dismissed — <reason>
Downstream paths checked: <event/queue/api consumer> — <action>
```

---

## Output
```
## Affected Files
- handlers/[handler-name].go (or Controller.php for Laravel)
- services/[service-name].go (or Service.php for Laravel)
- tests/[service-name]_test.go (or Tests/ for Laravel)

## Test Strategy
- Unit: [feature logic], [data validation]
- Integration: database transactions, concurrent requests
- Coverage target: 95%+ (if financial code)
- Special: [specific concurrency/idempotency concerns]

## Risks
- Race conditions on [shared-table-name] table (shared with [upstream-service])
- Existing [feature] logic in [downstream-service] may conflict

## Deployment Order
1. Deploy [this-service] ([what-changes])
2. Notify [affected-service] team of [new-events or API changes]
3. No changes needed to [read-only-service] (read-only)

## Success Criteria
✓ [Feature] matches [acceptance criteria]
✓ Concurrent requests don't create duplicates (idempotency)
✓ All financial mutations logged (if applicable)
✓ [Coverage %]+ test coverage
```

---

## Challenge Mode (Optional)
Stress-test the design:
- Does this handle [specific edge case]?
- What if [concurrent/race condition scenario]?
- Is [key assumption] actually true?
- Are we over-engineering for [speculative case]?

---

## Next Step
Proceed to implementation with `/tdd` after plan approval.
