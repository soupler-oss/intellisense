---
name: code-review
description: Use after /verify passes and before committing, to review the change for correctness, security gaps, AI-regression patterns and drift from the plan.
---

# /code-review — Code Quality Review (Phase 4)

**When:** After `/verify` passes, before commit (Phase 4 Review)
**Goal:** Identify code quality issues, security gaps, and plan deviations
**See:** `@rules/operational/ai-regression-patterns.md` (catalog), `@rules/operational/agents.md` (review protocols), `@rules/operational/testing.md` (evidence types).

> **Run this independently for high-risk shapes.** For open-ended / "remove-all"
> / security / enforcement-changing changes, this review MUST run as a **fresh,
> separate pass** — a subagent (or different model) that sees only the diff +
> contract, **not** the implementer's session. Inline self-review shares the
> author's blind spots and rationalizations; a cold pass does not. The skill can
> only *request* this — the actual independence comes from **how it is invoked**
> (fresh context / different model), not from this checklist. Bounded
> single-target tasks may review inline.

---

## The 5-Step Review Process

### Step 0: Predict Before Inspect

Risk-pattern change OR Tier 1/2: follow `@rules/operational/agents.md §Predict-Before-Inspect` before opening the diff. Tier 1/2 + risk pattern: hand off per §Independent Review Protocol. Tier 0 skips.

### Step 0.5: Impact Analysis (only when the team chose the code graph)

This step asks the engineering questions defined in `@rules/operational/intelligence-sources.md`:

- **change-spread** — what does this change touch? (forward dependency analysis)
- **who-calls** — who calls the modified code? (backward dependency trace)
- **what-changed-and-where-does-it-spread** — drift signals across structural concerns

Skip this step entirely when:
- The team's code intelligence is not `code-review-graph` (`INTELLISENSE_CODE_INTEL` in `~/.intellisense/integrations.env`; `none` is the default) — use `rg` / `Read` for the same questions.
- The repo is not intellisense-managed (no `<!-- INTELLISENSE-MANAGED -->` in `CLAUDE.md` and no `.intellisense/MANAGED` file).
- The repo has `.intellisense/graph-exception.json` (graph use opted-out; output for the rest of the review is marked `[INTELLISENSE-WEAK-STACK: <stack> — exception mode (...)]`).
- The change is Tier 0 (per `@rules/operational/proof-standards.md` minimal path).

**Mandatory stacks** (none by default; the organization opts a stack in via `INTELLISENSE_GRAPH_MANDATORY_STACKS`):

1. Read `.intellisense/graph-status.json` (gitignored, runtime artifact written by `setup-repos.sh` / `scripts/graph-bootstrap.sh`).
2. If the file is missing — graph is not built. **Stop the workflow.** Print to the developer:
   ```
   This stack requires the code graph for /code-review §Impact Analysis, and it is not built for this repo.
   Build it (asks before changing anything):
     bash scripts/graph-bootstrap.sh --repo "$PWD" --stack <stack>
   ```
   Do NOT auto-build inside this skill. For a stack that is not mandatory, ask for consent to build it (default `N`); without it, answer the questions with `rg` / `Read` and continue.
3. If the file exists, treat its `readiness` field as authoritative:
   - `ready` → use the engineering questions to populate the Impact Analysis section below.
   - `failed` → stop and direct the developer to `bash scripts/graph-bootstrap.sh --repo "$PWD" --stack <stack> --repair`.
   - `skipped` → exception path; mark output `[INTELLISENSE-WEAK-STACK]` and proceed to Step 1.
4. If the `advisory` field is non-empty (weak stack, candidate stack, `--min-nodes` override, or exception mode), include the advisory marker verbatim in every Impact Analysis claim — graph results from these contexts are structurally less reliable; do not project false authority.

**For weak stacks (Laravel, Angular):** the graph builds best-effort; readiness is advisory; output is marked `[INTELLISENSE-WEAK-STACK: <stack> — <reason>]`. Use Impact Analysis as a hint, not as ground truth — cross-check magic-method dispatch, queue/event handlers, and DI-resolved targets manually.

**For candidate-supported stacks (TS/JS, Java, etc.):** treated as weak until validated; same `[INTELLISENSE-WEAK-STACK]` marker discipline applies.

**Impact Analysis output (write before Step 1):**

```
## Impact Analysis

Stack: <stack> (<support>)
graph_state: nodes=<N>, built_at_utc=<ISO8601>, readiness=<ready|failed|skipped>
[Advisory marker, if any]

change-spread:
- <file:line> → impacts: <list of affected nodes/files>
- ...

who-calls (per modified function/method):
- <symbol> ← called by: <list of callers>
- ...

what-changed-and-where-does-it-spread (drift signals):
- <signal> — <evidence>
- ...
```

If Impact Analysis surfaces a hub or bridge node touch, escalate to Tier 1+ per the Phase 1 plan rules even if the original change classification was lower. Document the escalation in the review output.

**Impact Discovery — contract cross-check:** For Tier 1/2 work in intellisense-managed repos, two separate checks run here:

1. **Contract evidence (primary):** The Change Contract's `impact_analysis` field MUST carry the Impact Discovery block produced during `/plan`, or the explicit escape value `n/a — <reason>`. If empty/missing → flag as `[HIGH] Missing Impact Discovery contract evidence` (see Step 4 HIGH).
2. **PR status line (documentation):** The PR description SHOULD include `Code graph: built | stale | unavailable | not used`. If missing → flag as `[HIGH] Missing code-graph PR status line`. This records graph readiness, NOT caller evidence — it cannot substitute for the contract field.

The validator emits a warn-only stderr message at push time when the contract field is empty; `/code-review` surfaces it as a HIGH issue to ensure the dev/Claude doesn't merge with the warning unaddressed.

### Step 1: Gather Context

**What changed?**
```bash
git diff HEAD  # See unstaged changes
git diff --staged  # See staged changes
```

**Files affected:** List all modified files and their sizes. Flag if any file >800 lines.

**What was the plan?** Recall Phase 1 plan (already in session context):
- Original requirement
- Planned approach
- Any constraints or special handling

---

### Step 2: Understand Scope

**Identify:**
- Which files were modified and why
- What feature/fix does this complete
- How do changes connect to the original plan
- Are there dependencies or integration points

**Question:** Does scope match the plan from Phase 1? Any unplanned changes?

---

### Step 3: Read Surrounding Code

**Don't review changes in isolation.**

For each modified file:
1. Read the entire file (not just the diff)
2. Understand imports and dependencies
3. Look at call sites (who uses this code)
4. Check established patterns in the file (how do similar functions look?)
5. Verify integration with existing code

---

### Step 4: Apply Review Checklist

Apply each category below. Use `[NEEDS-VERIFICATION]` for real risks where evidence is missing — do not suppress uncertainty.

#### CRITICAL (Blocks PR)

- [ ] **Hardcoded secrets** — API keys, passwords, tokens, connection strings in source code
- [ ] **SQL injection** — String concatenation in queries instead of parameterized queries
- [ ] **XSS vulnerabilities** — Unescaped user input rendered in HTML/JSX
- [ ] **Path traversal** — User-controlled file paths without sanitization
- [ ] **Authentication bypass** — Missing auth checks on protected routes
- [ ] **Data loss** — Overwrites without backup, deletions without soft-delete
- [ ] **Race conditions** — Concurrent mutations on shared data without locking

**Example (CRITICAL):**
```go
// BAD: SQL injection via string concatenation
query := fmt.Sprintf("SELECT * FROM users WHERE id = %d", userID)

// GOOD: Parameterized query
query := "SELECT * FROM users WHERE id = $1"
rows, _ := db.Query(query, userID)
```

#### HIGH (Should Fix Before Merge)

- [ ] **File size >800 lines** — Split into separate files by responsibility
- [ ] **Function >50 lines** — Extract logic into helper functions
- [ ] **Nesting >4 levels deep** — Use early returns, extract helpers
- [ ] **Missing error handling** — Unhandled errors, empty catch blocks, silent failures
- [ ] **Pattern violations** — Mixing GORM/Pop ORMs, inconsistent error wrapping
- [ ] **Missing tests for new code** — New functions/endpoints without test coverage
- [ ] **Dead code** — Commented-out code, unused imports, unreachable branches
- [ ] **Plan deviation without justification** — Implementation differs from Phase 1 plan
- [ ] **Missing Impact Discovery contract evidence** — Tier 1/2 PR's Change Contract has empty/missing `impact_analysis`. Required regardless of PR description state — the PR line records graph readiness, not caller evidence, so the two cannot substitute for each other. Resolution: populate `impact_analysis` with graph/rg evidence OR write `n/a — <reason>` (e.g. `n/a — graph unavailable`, `n/a — weak stack`, `n/a — non-intellisense repo`).
- [ ] **Missing code-graph PR status line** — Tier 1/2 PR in an intellisense-managed repo has no `Code graph: built|stale|unavailable|not used` line in its description. This is a separate documentation check from the contract field above. Both must pass.

**Example (HIGH):**
```go
// BAD: Deep nesting + missing error handling
func ProcessPayment(userID int) {
  user := getUser(userID)
  if user != nil {
    if user.Balance > 0 {
      if user.Active {
        // Process payment — no error handling
        ChargeCard(user)
      }
    }
  }
}

// GOOD: Early returns + error handling
func ProcessPayment(userID int) error {
  user, err := getUser(userID)
  if err != nil {
    return fmt.Errorf("fetch user: %w", err)
  }
  if user == nil || !user.Active {
    return errors.New("user not available")
  }
  if user.Balance <= 0 {
    return errors.New("insufficient balance")
  }
  return ChargeCard(user)
}
```

#### MEDIUM (Suggestions)

- [ ] **Naming clarity** — Single-letter variables (x, tmp, w) in complex contexts
- [ ] **Function extraction opportunity** — Repeated logic that should be a helper
- [ ] **Immutability concerns** — Mutations where immutable patterns would be clearer
- [ ] **Missing JSDoc/comments** — Public functions without documentation
- [ ] **Magic numbers** — Unexplained numeric constants (use named constants)
- [ ] **Inefficient algorithms** — O(n²) when O(n log n) is possible

**Example (MEDIUM):**
```go
// BAD: Repeated logic, no clarity
w := getUserAccount(id)
if w == nil { return }
b := w.GetBalance()
if b < 100 { return }

// GOOD: Extracted, named clearly
account, err := getUserAccount(id)
if err != nil || account == nil {
  return fmt.Errorf("account unavailable: %w", err)
}
if !account.HasMinimumBalance(100) {
  return errors.New("insufficient balance")
}
```

#### LOW (Nice-to-Have)

- [ ] **Style inconsistencies** — Mixed semicolons, quote styles, indentation
- [ ] **TODO/FIXME without tickets** — TODOs should reference issue numbers
- [ ] **Formatting** — Code could be more readable with better layout
- [ ] **Documentation improvements** — Comments could be clearer

#### NEEDS-VERIFICATION (real risk lacking evidence)

Schema (all four fields required):

```
[NEEDS-VERIFICATION] [Pn?] <terse, specific title>
File: <path:line>
Hypothesis: <what invariant might fail — one sentence>
Why uncertain: <what evidence is missing or ambiguous>
Resolves with: <specific, reproducible proof>
```

Cap ≤5 per PR; generic titles rejected. Tag `[Pn]` for patterns. Resolves with the named artifact, upgrades to HIGH/CRITICAL, or dismisses.

---

### Step 4b: Failure-Path Discipline Check

Apply the 5-point checklist from `@rules/operational/testing.md § Before Claiming GREEN` to this PR's diff. Each unchecked item is a HIGH issue (report via the Step 5 schema).

1. **Failure-path tests** exist for every visible branch in the diff (`if`, `switch`, `match`, error return).
2. **Change Contract** (`.intellisense/contracts/<branch>.md`) re-read against shipped `files_affected` + `test_strategy` — flag drift.
3. **Per-enum-value tests**, not grouped case-arms.
4. **No "small deferrals"** — TODOs / `// fix later` / skipped failure-path tests inside the diff are HIGH issues.
5. **`/verify`** ran on the full suite, not just the touched file.

Do **not** duplicate the testing.md text here — reference the section by path so the two cannot drift. Pattern basis: n=2 incidents (2026-05-19, 2026-05-21) cited in testing.md intro.

---

### Step 4c: Completeness Check (defect-class / "fix-all" changes)

For a change that fixes a **class** ("fix all X", "remove every use of Y",
"rename across the repo", "change this symbol everywhere"), reviewing the diff
is not enough — **the diff cannot show what was missed.** Confirm **zero**
instances survive outside the diff (minus an explicit allowlist: archived docs,
intentional examples). Any survivor is a **HIGH** issue. This is the one check
that looks *outside* the diff; every other step here reviews what's *in* it.

Use the right tool for the kind of completeness (full table in `/verify` §7):
text/string → `grep`; **code symbol / API / caller → code-review-graph
who-calls / change-spread** (Step 0.5 Impact Analysis — grep misses callers
that reach the symbol via an interface/wrapper); behavioral/edge-case → this
review. Skip for bounded single-target changes.
Cross-check against `/verify` §7 (Completeness Sweep). Skip for bounded
single-target changes.

---

### Step 5: Report Findings

**Format:** For each issue, report as:

```
[SEVERITY] Category: Brief title
File: src/path/to/file.go:42
Issue: Detailed explanation of what's wrong and why it matters
Fix: Code example showing the correct approach
```

For `[NEEDS-VERIFICATION]` use the Step 4 schema.

**Example output:**

```
[CRITICAL] Security: Hardcoded API key in source
File: src/api/client.go:15
Issue: API key "sk-prod-abc123" is hardcoded and will be committed to git history.
  Credentials in source are a security breach.
Fix: Move to environment variable and add to .gitignore/.env.example
  const apiKey = os.Getenv("API_KEY")
  if apiKey == "" {
    panic("API_KEY env var not set")
  }

---

[HIGH] Code Quality: Function exceeds size limit
File: src/account/balance.go:120
Issue: Function CalculateBalance() is 95 lines. Limit is 50 lines.
  Extract validation and rounding into separate functions.
Fix: Split into: CalculateBalance() → ValidateInput() → RoundBalance()

---

[MEDIUM] Naming: Unclear variable name
File: src/payment/processor.go:35
Issue: Variable "p" is used for "processor". Single letters reduce readability.
Fix: Rename to "processor" — no performance cost, better clarity
```

---

### Step 5b: Documentation Drift Check

**Goal:** Detect when CLAUDE.md needs updating due to structural changes in this PR.

In intellisense-managed supported repos, this step uses the **what-changed-and-where-does-it-spread** engineering question (per `@rules/operational/intelligence-sources.md`) to surface the five drift signals from a single graph-derived diff analysis instead of file-by-file pattern matching. The signal categories below are the ones the question must surface; in non-intellisense repos and Tier 0 work, fall back to the manual pattern matching documented in each signal.

**Five drift detection signals:**

**Signal 1: New directory added**
- Pattern: New folder created (e.g., `+++ b/src/middleware/`)
- Check: Does CLAUDE.md Structural Map mention this folder?
- Flag if: Missing from Structural Map section
- Suggested action: Add to Structural Map with purpose

**Signal 2: New route/handler registration**
- Pattern: New HTTP endpoint defined
  - Go: `router.GET|POST|PUT|DELETE(...)` in handlers or routes file
  - PHP: `Route::get|post|put|delete(...)` in routes/api.php
  - Angular: `HttpClient.get|post|put|delete(...)` in services
- Check: Is this endpoint called by OTHER services? (Heuristic: under `/api/` not `/internal/`)
- Flag if: External endpoint not documented in "API Contracts" section
- Suggested action: Add to API Contracts with method, path, consumer, description

**Signal 3: New external dependency**
- Pattern: New line in `go.mod` / `composer.json` / `package.json` require section
- Check: Is this an internal org service or major provider (Stripe, AWS SDK, Twilio, etc.)?
- Flag if: Missing from "Upstream Dependencies" section
- Suggested action: Add to Upstream Dependencies with reason

**Signal 4: New migration file or table created**
- Pattern: New file in `migrations/` or `database/migrations/`
- Check: Does the table belong to THIS service, or is it shared (written by 2+ services)?
- Flag if: Shared table missing from "Shared Database Tables" section
- Suggested action: Add to Shared Database Tables with list of all writers

**Signal 5: Pending drift already tracked**
- Pattern: Check `.intellisense-doc-health.json` for PENDING doc items
- Check: Do any PENDING items match changes in this PR?
- Flag if: Pending item resolved but CLAUDE.md not updated
- Suggested action: Update CLAUDE.md section + mark PENDING item as RESOLVED

**Output format (table):**

```
## Documentation Drift Check

| Signal | Detected | CLAUDE.md Current? | Action |
|--------|----------|-------------------|--------|
| New layer: middleware/ | YES | NO | Add to Structural Map |
| New endpoint: POST /api/v1/refund | YES | YES | No action |
| New dependency: stripe-go | YES | NO | Add to Upstream Dependencies |
| New migration: payments table | YES | YES (shared) | No action |
| Pending PENDING-001 | Resolved | YES | Update status to RESOLVED |

**Documentation Status:** 2 items need CLAUDE.md updates.

**Suggested additions:**
```
Under ## Structural Map:
- middleware/ → Auth verification, rate limiting

Under ## Upstream Dependencies:
- Stripe: Payment gateway for refund processing
```

**Next:** Update CLAUDE.md before merging, or confirm these items and proceed.
```

If no drift detected: `Documentation is current — no CLAUDE.md updates needed.`

**Auto-update rule:** Claude SUGGESTS updates, does not auto-apply, unless dev confirms. If item is already CONFIRMED in `.intellisense-doc-health.json` pending_doc_updates, Claude can apply and update status to RESOLVED.

---

## Plan Alignment Check

Before reporting, ask:

**Does this implementation match the Phase 1 plan?**

- [ ] Feature scope matches planned scope?
- [ ] Approach matches planned approach?
- [ ] Any unplanned changes? (good or bad?)
- [ ] Any planned elements missing?

**If significant deviation found:**
- State the deviation explicitly: "Plan said X, code implements Y"
- Assess: Is deviation justified? Does it improve the design?
- If unjustified: Add to HIGH issues

---

## Approval Criteria

**APPROVE** (Ready to merge):
- No CRITICAL issues
- No HIGH issues (or HIGH issues documented with justification)
- Plan alignment confirmed
- All `[NEEDS-VERIFICATION]` items resolved (artifact pasted, upgraded, or dismissed)

**WARNING** (Can merge with caution):
- 1-2 HIGH issues that are understood and acceptable
- All CRITICAL resolved
- Deviations documented in PR description

**BLOCK** (Do not merge):
- Any CRITICAL issues remain
- Multiple HIGH issues
- Major plan deviations unexplained

---

## Review Summary (REQUIRED)

Always end review with:

```
## Code Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | ✓ pass |
| HIGH     | 1     | ⚠ warn |
| MEDIUM   | 2     | ℹ info |
| LOW      | 0     | - |

**Plan Alignment:** ✓ Implementation matches Phase 1 plan

**Verdict:** ⚠ WARNING — 1 HIGH issue should be resolved before merge
  - FunctionSize: CalculateBalance() 95 lines → extract helpers
  
**Next:** Fix HIGH issues, re-run `/code-review`, then proceed to commit
```

---

## Language-Specific Patterns

Before flagging pattern violations, consult the matching language-specific rule for the stack under review. Stack-to-rule routing is documented in `@rules/operational/ai-regression-patterns.md`.

If code matches the established pattern in that language: No issue to report.

---

## Quick Checklist (Apply in Step 4)

Before reporting any issue:

- [ ] CRITICAL: Is this a security breach, data loss, or authentication bypass?
- [ ] HIGH: Does it exceed coding-style limits (file size, function size, nesting)?
- [ ] HIGH: Is there missing error handling or test coverage?
- [ ] MEDIUM: Could naming or organization be improved?
- [ ] MEDIUM: Does this match existing codebase patterns?
- [ ] LOW: Is this a minor style improvement?
- [ ] Uncertain but plausible: use `[NEEDS-VERIFICATION]` (schema in §Step 4) — do not suppress.

---

## What NOT to Report

- ❌ "This could be optimized" (unless measured problem exists)
- ❌ "I would have done it differently" (unless it violates rules)
- ❌ "This is unused code" (unless provably dead — check call sites)
- ❌ "Add error handling for case X" (unless case X can actually happen)
- ❌ "This function is too long" (unless >50 lines AND complex)
- ❌ Stylistic preference (unless violates project conventions)

---

## After Review

1. **Fix CRITICAL issues** — Always before merge
2. **Fix HIGH issues** — Or document in PR why it's acceptable
3. **Consider MEDIUM issues** — Nice-to-have improvements
4. **Re-run `/code-review`** if changes significant
5. **Update PR description** with fixes made
6. **Proceed to Phase 6 Commit** when HIGH issues resolved

