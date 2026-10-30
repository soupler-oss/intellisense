---
applies_to: [full_feature, bug_fix]
phase: [2, 3]
priority: HIGH
enforcement: blocking
load_when: coding
---

# Testing Rules

Test design + the GREEN gate. TDD-cycle mechanics: `/tdd` skill + [impl.md](./development-workflow-impl.md) Phase 2. Canonical owner of coverage thresholds, the evidence table, and the persistence-path rule.

## Coverage (canonical)

| Scope | Threshold | Enforced by |
|---|---|---|
| New code (functions/branches in the diff, not whole file) | ≥80% branches · functions · lines · statements | `/verify` blocks on miss |
| Critical financial paths | ≥95% | `/verify` |
| Bug fix | all paths + regression test that fails before the fix | `/verify` + `/code-review` |

## Test Types (all required for features)

| Type | Scope | Note |
|---|---|---|
| Unit | one function in isolation | mock external services |
| Integration | service interactions, DB queries, API endpoints | real persistence where the bug class lives (§Persistence-Path) |
| E2E | critical user flows | framework per language |

## Naming & Structure

Name by behavior, never the function: `returns 0 when vectors are orthogonal`, `throws when API key is missing`, `falls back to substring search when Redis is unavailable` — not `calculateSimilarity`. Structure every test Arrange-Act-Assert. Stack examples → [language-specific rules](../language-specific/).

## Test Quality (gate)

- [ ] One behavior per test; deterministic (flaky → quarantine + tracked issue, never a blind retry)
- [ ] External services mocked in unit tests — never a real API
- [ ] Multiple input scenarios → table-driven pattern (language rules)

## Test Failure (trigger → action)

- Test fails → check isolation (depending on external state?) → verify mocks return what the real service returns → fix the implementation, not the test
- Test itself is wrong → fix it AND document why in the PR
- Same test fails 3+ times → `/tdd` (troubleshooting reference)

## Before Claiming GREEN (gate)

Green runner ≠ done — bugs hide on un-exercised paths (memory: `feedback-unit-tests-mask-integration-bugs`). All must hold:

- [ ] Failure-path test for every visible branch — each `if`, `switch`, `match`, or error return in the diff names its non-happy test
- [ ] Per-enum-value tests — each variant its own test, not a grouped case-arm
- [ ] Change Contract re-read; diff walked vs `files_affected` + `test_strategy` (drift → stop, fix one)
- [ ] No deferrals — a TODO or skipped failure-path test in this diff → complete it or file a tracked issue and remove it from the diff
- [ ] `/verify` run — full suite, not just the edited file

## Completion Checklist (gate)

TDD-internal verification checklist is owned by `/tdd`.

- [ ] Failing test written + shown before implementation
- [ ] Unit tests for all new functions; integration tests for all new endpoints + DB ops
- [ ] Every bug fix has a regression test that would have caught the original bug
- [ ] AAA structure; behavior-based names; no real APIs in unit tests
- [ ] Untested paths listed explicitly (or "all paths covered")
- [ ] Financial: idempotency + balance formula + concurrent scenario tested

## Risk-Pattern Evidence

When a change matches a pattern in [ai-regression-patterns.md](./ai-regression-patterns.md), the test alone is insufficient — pair it with raw evidence. `/code-review` checks these.

| Change | Required evidence |
|---|---|
| Response field added/renamed/removed (P2) | endpoint `curl` vs a non-null fixture row, showing the field's VALUE |
| DB query change — SELECT, JOIN, or WHERE | `EXPLAIN` or query log showing columns actually selected |
| Sandbox / production path divergence (P1) | side-by-side response from BOTH paths, same fixture |
| Bug fix (any) | test output BEFORE (red, with the failure message) AND AFTER (green) |
| Auth / authz change | `curl` with valid token AND with invalid/missing (expect 401/403) |
| Migration | schema before AND after; rollback also run |
| Concurrency-sensitive code | N parallel runs (`xargs -P10`) showing no duplicates / races |
| Payment / balance | idempotency (same request ×N → one effect) + concurrent run |

Evidence must be raw tool output (not paraphrased), must reference the specific fixture / row, and for Tier 2 carry timestamp + command in the header.

## Persistence-Path Rule (shape/query changes)

Adding, removing, or renaming an API response field, or changing query projection or filter → the Step 1 RED test MUST hit an isolated real persistence path AND assert the field's **VALUE** against a fixture. Key-only assertions (`assertJsonStructure`, "field exists") pass against `null` from unselected columns — the P2 bug class.

| Isolated real path (allowed) | Not allowed |
|---|---|
| in-memory DB (per-test schema + fixture) | shared dev DB |
| transactional test DB resetting per test | long-lived staging DB |
| containerized engine-fidelity runner | mocked ORM |
| HTTP-layer harness (real router + serializer) | |

Per-stack tooling + pattern routing → [ai-regression-patterns.md](./ai-regression-patterns.md) (single source of truth; this file does not enumerate stacks).
