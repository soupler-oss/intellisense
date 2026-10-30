---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# AI Regression Patterns

When an AI session generates code AND reviews its own output, predictable bug classes survive same-model review. This file is the trigger map only — execution detail lives in routed references. Treat it as a checklist while planning, implementing, and writing tests; not as deep documentation.

Loaded in coding modes (`full_feature`, `bug_fix`, `fix_pr_comments`) and referenced explicitly from `/tdd`. Code-review and independent-review hand-offs live in `@rules/operational/agents.md`.

## Architecture Rule

The catalog is the single source of truth for pattern-to-stack routing.
Stack-specific implementation details and code examples MUST live only in
`rules/language-specific/<stack>-patterns.md`.
Shared operational files (`testing.md`, `/tdd`, `/code-review`) should
reference the catalog generically rather than enumerating stacks directly.

**Exception for large stacks (Hybrid Entrypoint — intellisense standard):** a stack
MAY route heavy framework-specific guidance into
`rules/language-specific/<stack>/*.md` subfiles when **either** condition
holds: (a) the entrypoint `<stack>-patterns.md` would otherwise exceed
**~350 lines**, or (b) a topic has a **distinct load condition** (e.g.
financial-only, migrations-only) that justifies isolation independent of
size. The entrypoint `<stack>-patterns.md` must always exist and serve as
the catalog-routed canonical reference. Catalog Routes point to the
entrypoint by default; subfile-specific Routes are allowed only when a
specific section's content genuinely lives in a subfile. Existing peer
files (go, python, laravel, node, react, angular) are not required to
retrofit — they remain valid monolithic entrypoints; the threshold is a
forward-looking trigger, not a retrofit mandate.

**Adding a new stack** (entire onboarding cost):
1. Create `rules/language-specific/<stack>-patterns.md` with an §"Isolated Real-Persistence Tests" section covering the applicable patterns.
2. Append `, @rules/language-specific/<stack>-patterns.md §<section>` to the **Routes** list of each applicable pattern (P1–P4) below.

`testing.md`, `/tdd`, and `/code-review` do not need editing — they already reference the catalog generically. Duplicated stack lists in shared operational files have produced real omission bugs (Python initially missed in `/tdd`); this rule prevents recurrence.

## P1 — Sandbox/Production Path Divergence

**Trigger:** code branches on an environment, mock, or sandbox flag and the two branches construct different return shapes (hardcoded sandbox response vs. ORM-derived production response).

**Why it slips past same-model review:** the writer updates one branch and the reviewer (same session) inherits the writer's mental model that "the change is in the controller" — never re-examines the other branch.

**Routes:**
- Evidence: `@rules/operational/testing.md §Risk-Pattern Evidence Types` (side-by-side response from both paths)
- Test patterns: `@rules/language-specific/laravel-patterns.md §Isolated Persistence-Path Feature Tests`, `@rules/language-specific/angular-patterns.md §Isolated Real-Persistence-Path Tests`, `@rules/language-specific/python-patterns.md §Isolated Real-Persistence Tests for HTTP/DB Code`, `@rules/language-specific/node-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/java-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/rust-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/csharp-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/ruby-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/cpp-patterns.md §Isolated Real-Persistence Tests`

## P2 — SELECT / Projection Omission

**Trigger:** a response gains, renames, or removes a field without a corresponding change to the underlying query projection (ORM `select`/`Select` clause, raw SQL column list, GraphQL projection).

**Why it slips past same-model review:** the response shape change is visible in the diff; the SELECT clause sits in a different file or line range. Mock-based tests pass because the mock returns the field. Key-only assertions (`assertJsonStructure`) pass against `null` returns from unselected columns.

**Routes:**
- Evidence: `@rules/operational/testing.md §Risk-Pattern Evidence Types` (curl with non-null fixture, value asserted)
- Persistence rule: `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`
- Test patterns: `@rules/language-specific/laravel-patterns.md §Isolated Persistence-Path Feature Tests`, `@rules/language-specific/go-patterns.md §Isolated Real-Persistence Tests for HTTP/DB Code`, `@rules/language-specific/python-patterns.md §Isolated Real-Persistence Tests for HTTP/DB Code`, `@rules/language-specific/node-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/java-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/rust-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/csharp-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/ruby-patterns.md §Isolated Real-Persistence Tests`, `@rules/language-specific/cpp-patterns.md §Isolated Real-Persistence Tests`

## P3 — Error State Leakage

**Trigger:** an error path is added or modified, but prior success state (cached data, loaded entities, partial form state) is not cleared. The UI or API returns an error AND stale success data simultaneously.

**Why it slips past same-model review:** the error branch is reviewed in isolation; nobody asks "what state from the success path is still set?"

**Routes:**
- Test patterns: `@rules/language-specific/angular-patterns.md §Isolated Real-Persistence-Path Tests` (state-cleanup subsection), `@rules/language-specific/python-patterns.md §Isolated Real-Persistence Tests for HTTP/DB Code` (P3 subsection), `@rules/language-specific/node-patterns.md §Isolated Real-Persistence Tests` (P3 subsection), `@rules/language-specific/react-patterns.md §Isolated Real-Persistence Tests` (P3 subsection), `@rules/language-specific/java-patterns.md §Isolated Real-Persistence Tests` (P3 subsection), `@rules/language-specific/flutter-patterns.md §Isolated Real-Persistence Tests` (P3 subsection), `@rules/language-specific/swift-patterns.md §Isolated Real-Persistence Tests` (P3)
- Backend: error-handler tests must assert prior context is reset before the error response is returned.

## P4 — Optimistic Update Without Rollback

**Trigger:** UI or cache mutation occurs before API confirmation; on failure, no compensating action restores prior state.

**Why it slips past same-model review:** the success path is fully visible; the failure path is implicit ("API will succeed"). Tests rarely simulate API failure post-mutation.

**Routes:**
- Test patterns: `@rules/language-specific/angular-patterns.md §Isolated Real-Persistence-Path Tests` (rollback subsection), `@rules/language-specific/react-patterns.md §Isolated Real-Persistence Tests` (P4 subsection), `@rules/language-specific/flutter-patterns.md §Isolated Real-Persistence Tests` (P4 subsection), `@rules/language-specific/swift-patterns.md §Isolated Real-Persistence Tests` (P4)

## Independent review

For triggers above + Tier 1/2 changes, an independent-review session is the structural defense. Protocol lives in `@rules/operational/agents.md §independent-review-protocol`.

## Lifecycle

- This file is hard-capped at 1500 estimated tokens. Adding a new pattern requires retiring or compressing an existing entry.
- Add/retire/review cadence governance lives in `@rules/operational/protocol-governance.md §pattern-lifecycle`.
- Treat this catalog as advisory discipline — not a gate.

## How to use this file

1. **Planning:** scan triggers; if the change matches one, name the pattern (`P1`–`P4`) in the Change Contract.
2. **TDD RED:** write tests per the persistence-path rule; assert VALUES, not just keys.
3. **Self-review:** for each matching pattern, explicitly check its "why it slips past" against the diff before approving your own work.
