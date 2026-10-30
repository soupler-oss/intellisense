---
applies_to: [all]
phase: [0, 1]
priority: HIGH
enforcement: advisory
load_when: planning
---

# Proof Standards

Every intellisense plan/report must declare two labels and follow a proof standard matched to the change type.

### How this rule is loaded

`load_when: planning` satisfies validator schema; it does NOT auto-load. Discoverability comes from the cross-reference in `@rules/operational/development-workflow.md §Phase 1: Plan`. Every plan MUST explicitly reference this file.

## Two labels (mandatory)

- **intellisense Risk Tier** — impact/enforcement: 0 (no enforcement change), 1 (cross-repo / pilot-required), 2 (security/financial/migration).
- **Proof Type** — evidence standard: A, B, or C (table below).

## Proof Type table

| Type | Change | Required proof |
|---|---|---|
| **A** | Pure wording cleanup — markdown text edits with no workflow behavior change | Structural verification: grep absence/presence + `validate-intellisense-content.sh` + `wc -w` token check + read-back of changed lines |
| **B** | Workflow / rule / process change — anything that changes how Claude or developers act | Behavior simulation: realistic flow showing **before behavior + after behavior + failure path**. Grep + validator alone is NOT enough. |
| **C** | Executable / hook / test / validator change — runnable code | Run positive case + run negative case + show exact output |

**Hard rule:** do not claim "works" unless the proof type matches the change type.

## Type B anti-theater rule

Behavior simulations for Type B changes MUST be specified in the plan **before** implementation. Each scenario requires this 6-row spec, pre-declared:

1. Scenario name
2. Before behavior expected
3. After behavior expected
4. Failure path expected
5. Exact command / dry-run / review packet to execute
6. Pass/fail criteria

Post-implementation report shows actual vs pre-declared, item-by-item; deltas flagged honestly, not retconned.

## Mandatory matrices

Every plan includes both:

- **6-column proof matrix** — columns: Proof Type | Required proof | Before behavior | After behavior | Failure path tested | Token impact.
- **Goal Fulfillment Matrix** — columns: Goal | How this change supports it | Proof / command | Token impact | Risk. Goals: (1) reduce same-model blind spots, (2) proof over theory, (3) no token bloat, (4) no duplicated stack refs, (5) cheap stack onboarding.

## 5 pre-push questions

1. Which original goal does this improve?
2. What proof shows it works?
3. What failure path was tested?
4. What token cost was added?
5. Did any shared file become less generic?

## Cross-references

- `@rules/operational/ai-regression-patterns.md §Architecture Rule` (catalog-as-single-source-of-truth)
- `@rules/operational/agents.md §Independent Review Protocol`
- `@rules/operational/protocol-governance.md` (Pattern Lifecycle, Metrics-Diagnostic-not-KPI)
