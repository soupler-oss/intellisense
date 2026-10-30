---
name: tdd
description: Use when implementing features, fixing bugs, or making behavior-changing refactors. (Pure refactors that preserve behavior skip Phase 2 TDD per intellisense's `refactor` mode — existing tests must stay green; no new failing tests written.) Enforces RED-GREEN-REFACTOR with runtime-RED gates, retry and regression bounds, opt-in layer purity, and stack-aware persistence-path testing.
---

# /tdd — Test-Driven Development Workflow

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

If test passes immediately → you're testing existing code. Delete code. Start over.

---

## When to Use

✅ **Always:**
- New features
- Bug fixes
- **Behavior-changing** refactors (any refactor that adds, removes, or changes observable behavior)
- API endpoints
- Components

❌ **No exceptions for the above.** No "too simple," "already tested manually," "already coded."

⏭ **Skip /tdd for pure refactors** (no observable behavior change — renames, extractions, dead-code removal). Per intellisense's `refactor` mode, Phase 2 TDD is skipped: existing tests must stay green; do not write new failing tests. If a "refactor" reveals a test failure, it's a bug — switch to `bug_fix` mode and run /tdd properly.

---

## Pre-flight: Phase 1 Handoff

Before starting RED, check that Phase 1 produced what /tdd needs to work slice-by-slice:

- If the Phase 1 plan / Change Contract has a behavior decomposition (a `slices` list or a per-file behavior mapping) → use it.
- If `files_affected` ≤ 1 (single-behavior fix) → no decomposition needed.
- **If a multi-file change has no decomposition → decompose inline before RED.** Output the slice list (one testable behavior per slice) and proceed slice-by-slice.

This does **not** require `.intellisense/contracts/<branch>.md` to exist. The contract file is Layer 1 transitional (optional today) — /tdd uses slice info if present, generates inline if absent.

For repos with `.intellisense/tdd.yaml` declaring a `layer_map`, slices SHOULD be ordered inside-out: domain → domain-service → application → infrastructure. See "Layer Purity Check (opt-in)" in REFACTOR.

### Mark the session as TDD-active

The UserPromptSubmit reminder hook (`scripts/userpromptsubmit-tdd-rules.sh`) injects 5 critical rules at every prompt only when the session is in TDD context. Set the marker at start; clear at end. The marker lives under `.intellisense/session/` (already gitignored / local-only).

**At /tdd start (before Step 1 RED):**
```bash
mkdir -p .intellisense/session && touch .intellisense/session/tdd-mode
```

**At /tdd completion (after final slice's REFACTOR + full-suite green) OR abort (retry-bound exhausted, regression-bound exhausted, manual stop):**
```bash
rm -f .intellisense/session/tdd-mode
```

If you forget to clear the marker, the reminder hook keeps firing in subsequent prompts (~55 tokens/prompt). Not harmful, just wasteful. Clear it.

The hook also fires when the user's prompt explicitly contains TDD keywords (e.g., `/tdd`, `RED`, `GREEN`, `failing test`) — so even without a marker, prompts that name TDD work get the reminder. The marker is for sustained sessions where you don't repeat keywords every turn.

---

## Red-Green-Refactor Cycle

### Step 1: RED — Write Failing Test

Write **ONE test** showing what should happen for the **current slice only**:

**Requirements:**
- Clear name describing behavior (not function name)
- Tests real code (minimal mocks, only if unavoidable)
- One responsibility ("and" in name? Split it)
- Minimal setup

**Good test:**
```go
func TestRetryOperation_RetriesUpToThreeTimes(t *testing.T) {
    attempts := 0
    operation := func() error {
        attempts++
        if attempts < 3 {
            return errors.New("fail")
        }
        return nil
    }

    err := retryOperation(operation)

    assert.NoError(t, err)
    assert.Equal(t, 3, attempts)
}
```

**Bad test:**
```go
func TestRetry(t *testing.T) {
    mock := NewMockOp()  // Testing mock, not code
    retryOperation(mock)
    assert.Called(mock, 3)  // Asserts on mock existence
}
```

**Stack-specific test patterns:** consult `@rules/operational/ai-regression-patterns.md` and the matching language-specific rule.

---

### Step 2: VERIFY RED (MANDATORY Gate)

**Run the test:**
```bash
go test ./path/to/test_file.go
# or
php artisan test tests/UnitTest.php
# or
ng test --watch=false
```

**Confirm ALL THREE:**
- [ ] Test **fails at the assertion** (red — not green, not compile/import error)
- [ ] Failure message is **expected** and meaningful
- [ ] Fails because **feature is missing** (not typo, not syntax)

**Compile/import failures are not sufficient RED.** Create the smallest stub needed for the import to resolve, then re-run to get an assertion-level RED before business implementation. Cost: ~5 seconds for a stub. Benefit: proof your assertion is wired to the right field/value.

**If test passes immediately:**
> You're testing existing code. Fix the test or delete the feature you're testing. Re-run until it fails correctly.

**If test errors at compile/import:**
> Add a minimal stub (empty class/function) so the import resolves. Re-run. The test should now fail at the assertion.

**This gate cannot be skipped.** You must WATCH the assertion-level failure before implementing.

---

### Step 3: GREEN — Implement Minimal Code

Write **simplest code** to make test pass. Nothing more:

```go
func retryOperation(op func() error) error {
    for i := 0; i < 3; i++ {
        if err := op(); err == nil {
            return nil
        }
        if i == 2 {
            return err
        }
    }
    return nil
}
```

❌ **Don't:**
- Add config options not in test
- Handle error cases not in test
- "Optimize" performance
- Refactor other code
- Add logging or monitoring
- Over-engineer

✅ **Do:**
- Keep functions <50 lines (see `@rules/operational/coding-style.md`)
- Use existing patterns from codebase
- Write code you can read

#### Retry Bound (max 5 attempts)

If the test still fails after your first implementation:
1. Re-read the failure output. Identify what the test expected vs. what it got.
2. Try a different approach (not a tweak — a different strategy).
3. Each retry: state in your reasoning the previous attempt's strategy and why it failed.
4. **Maximum 5 implementation attempts.**

After 5 failed attempts → **STOP**. Emit a diagnostic block and halt the slice:

```
TDD-RETRY-EXHAUSTED
slice: <current slice description>
test: <test name>
strategies_attempted:
  1. <one-line summary>
  2. <one-line summary>
  3. <one-line summary>
  4. <one-line summary>
  5. <one-line summary>
current_failure: <last failure message>
files_touched: <list>
recommended_next_action: <"adjust the test", "redesign API", "debug manually", etc.>
```

In **interactive mode** → ask the user to choose. In **auto mode** → halt the slice. Do not continue implementation.

**Editing the test:**
- Do **not** edit the test to match implementation. That is capitulation.
- Edit the test **only** if RED revealed the assertion or setup is invalid (e.g., wrong fixture, wrong expected value). Then re-run RED from scratch (Step 2).
- The distinction: changing what the test ASSERTS (forbidden) vs. fixing how the test SETS UP (legitimate, requires re-RED).

---

### Step 4: VERIFY GREEN (MANDATORY Gate)

#### Tiered Test Runs

Running the full suite after every slice is impractical for monoliths. Run in tiers:

| Tier | When | Command (example) |
|---|---|---|
| **Slice test** | Always, every retry | `go test -run TestRetry_X ./internal/billing/` |
| **Impacted module/package** | After slice passes | `go test ./internal/billing/...`<br>`phpunit --filter Billing`<br>`ng test --include='**/billing/**'` |
| **Full suite** | At end of /tdd run, OR when slice touches: shared infrastructure, financial paths, auth, middleware, persistence layer, public APIs | `go test ./...`<br>`php artisan test`<br>`ng test --watch=false` |

**Confirm ALL THREE before moving on:**
- [ ] Slice test **passes** (green)
- [ ] **Impacted module tests pass** (no regressions)
- [ ] **No errors, no warnings** in output

**If your slice test fails:** Fix the implementation, not the test (see Step 3 "Editing the test" rule).

**If impacted module tests regress:** see Regression Bound below.

#### Regression Bound (max 3 fix attempts)

If the slice passes but impacted tests regress:
1. Identify failing tests from output.
2. Apply the smallest fix that restores them.
3. **Re-run the slice's test + the regressed tests** (NOT the full suite).
4. **Maximum 3 regression-fix attempts.**

After 3 failed attempts → **STOP** and emit a diagnostic block (same format as Retry Bound). In auto mode, halt the slice.

After the slice + regressed tests are all green: re-run the full suite immediately if the slice meets a trigger condition above (shared infra, financial, auth, middleware, persistence, public APIs). Otherwise defer until the end of the /tdd run. **The full suite MUST run at least once before /tdd is considered complete** — at the latest, after the final slice's REFACTOR. Skipping the end-of-run full suite is a TDD violation.

**This gate cannot be skipped.** You must WATCH it pass before refactoring.

---

### Step 5: REFACTOR — Improve While Green

After tests pass, improve code (tests stay green):

- Remove duplication
- Better variable/function names
- Extract helper functions
- Clarify logic

**Do not:**
- Add features
- Change behavior
- Break tests

If code is already clean, refactoring is optional.

#### Layer Purity Check (opt-in)

If `.intellisense/tdd.yaml` exists in the repo root with a `layer_map`, scan modified files for dependency-direction violations:

```yaml
# .intellisense/tdd.yaml — example for a Go DDD service
layer_map:
  internal/domain/: domain
  internal/application/: application
  internal/infrastructure/: infrastructure
  internal/adapters/: infrastructure
```

For each file modified during this slice:
1. Determine its layer (longest prefix match against `layer_map`).
2. Read its imports.
3. For each imported module that maps to an *outer* layer → **violation**.

Layer order: `domain` < `domain-service` < `application` < `infrastructure`.

Fix violations by moving the dependency to a port interface in the inner layer; concrete implementation goes in the outer layer.

**If `.intellisense/tdd.yaml` doesn't exist → skip silently.** Most repos in the fleet (Laravel MVC, Angular apps, flat services) don't have layered architecture. Forcing the check would be noise.

---

### Step 6: REPEAT

Next slice → write failing test → verify failure → implement → verify pass → refactor → repeat.

---

## Coverage Targets

Coverage is **enforced by `/verify`**, not /tdd. Targets are listed here so tests are designed to hit them from Step 1:

- **Default new code:** 80% (branches, functions, lines, statements all ≥80%)
- **Financial code:** **95%+** (mandatory; see `@rules/operational/testing.md` for financial test types — idempotency, concurrency, balance formula)
- **Bug fixes:** all paths covered + regression test proving bug is fixed

Run coverage report via `/verify`. /tdd does not gate on coverage.

---

## When Mocking — Read Before Adding Any Mock

Mocking introduces three failure modes that account for ~90% of mock-related test bugs: testing mock existence (not behavior), polluting production with test-only methods, and mocking without understanding side effects. **Before introducing any mock, read `skills/tdd/references/anti-patterns.md`** for gate questions and concrete examples for each pattern.

That same reference file contains the **"Why Order Matters"** rationalization-counter table. Read it when you catch yourself thinking "I'll test after," "I already manually tested," or "I'll skip TDD just this once."

---

## Real-Persistence-Path Tests for Risk Patterns

When a change matches any pattern in `@rules/operational/ai-regression-patterns.md` — response shape change, query/projection change, sandbox/production path divergence, error-state cleanup (P3), or optimistic update without rollback (P4) — the failing test in **Step 1 RED** must follow the persistence-path rule, not the default mock-friendly pattern.

**Rule (from `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`):**
- Use an isolated real persistence path (in-memory DB, transactional test DB, containerized engine, HTTP-layer testing harness) — NOT a mock of the layer where the bug class lives.
- Assert the field's **VALUE** against a fixture, not just key presence. A test that passes against a `null` return from an unselected column is not a real RED.

**Why this matters for TDD:** the RED gate's purpose is to prove the test can fail when the feature is missing. Mock-based tests on shape/query changes pass against the writer's mental model — same-model blind spot. Real persistence exposes projection bugs (P2) at RED time.

This rule plugs the **highest-frequency** mock-leakage failure mode (response shape / projection). It does not plug all spec-to-implementation leakage — algorithm-baking and impl-detail coupling still need vigilance via the Iron Law and Red Flags.

**Self-check before declaring RED valid for a risk pattern:**
- [ ] Test exercises a real persistence/query path (no mock at the asserted layer)?
- [ ] Test asserts a VALUE from the fixture, not just key existence?
- [ ] If implementation has the bug, does this test actually fail with a meaningful message?

---

## When Stuck or About to Violate — Read the Troubleshooting Reference

If you're stuck (don't know how to test it, test setup is huge, same test failing 3+ times, tempted to change the test) OR about to violate TDD (code before test, test passes immediately, "I'll test after," etc.), **read `skills/tdd/references/troubleshooting.md`**.

It contains:
- **"When Stuck"** table — 8 common stuck states with concrete actions
- **"Red Flags"** checklist — 14 violations that mean "DELETE CODE, START OVER"

The iron-rules hook (~55 tokens/turn during git work) reminds you of the 5 most critical rules at every prompt. The troubleshooting reference is the deeper layer — read it when you need more than the hook covers.

---

## Verification Checklist

Before marking work complete:

- [ ] Every new function/method has a test
- [ ] Watched each test fail at the assertion level (saw the failure message)
- [ ] Watched each test pass (all green)
- [ ] All tests use real code (mocks only if unavoidable)
- [ ] No other tests broke (impacted module tests + full suite at milestones)
- [ ] Output pristine (no errors, warnings, or lint issues)
- [ ] Financial code includes: idempotency + concurrency + balance tests
- [ ] If repo has `.intellisense/tdd.yaml` — layer purity check passed
- [ ] No retry bound exhausted without an emitted diagnostic
- [ ] Coverage targets met (verified by `/verify`, not gated here)

**Can't check all boxes?** You skipped TDD. Start over.

---

## Stack-Specific Patterns

For concrete code examples, consult the matching language-specific rule for your stack. Stack-to-rule routing is in `@rules/operational/ai-regression-patterns.md`.

---

## Next Step

After implementation completes:
1. Run `/verify` for full verification (build → test → lint → security → financial checks; enforces 80%/95% coverage)
2. Run `/code-review` before PR
3. For financial code: confirm 95%+ coverage report in PR

---

## Questions?

- **How do I test this?** See stack-specific pattern files
- **How much coverage is enough?** Default 80%, financial 95%+. Enforced by `/verify`. See `@rules/operational/testing.md`
- **Still rationalizing?** Read `skills/tdd/references/anti-patterns.md` (Why Order Matters) and `skills/tdd/references/troubleshooting.md` (Red Flags)
- **Test is hard to write?** Design might be wrong. Listen to test. Hard to test = hard to use.
- **Hit a retry bound?** That's the rule firing correctly. Emit diagnostic. Don't push through.
