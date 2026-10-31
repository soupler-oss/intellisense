---
name: learn
description: Use after finishing a feature or fix, to extract the patterns and decisions worth remembering and suggest memory entries.
---

# /learn — Capture Patterns and Update Memory

Extracts architectural insights and patterns from work session; suggests where each one should live.

Shared knowledge goes where every session and agent sees it: a rule (the repo's `CLAUDE.md`, or
`.intellisense/rules/organization/<topic>.md`), or — when the team's tracker is Beads — a Beads memory
(`bd remember`, read back with `bd prime` / `bd memories`). `MEMORY.md` is personal and is NOT a target for `/learn` output.

**When**: After completing a feature or fixing a bug; before commit
**Input**: Session context (code written, tests, decisions made)
**Output**: Extracted patterns with suggested memory entries (one per insight, ready to apply: a rule edit, or a `bd remember` command with Beads)

## Process

1. **Identify new patterns** — Did you solve a problem in a new way?
2. **Check existing patterns** — Is this a variation on established approach?
3. **Extract domain terms** — New business concepts discovered?
4. **Suggest memory updates** — What should future-you remember?
5. **Flag rule additions** — Should rules files be updated?

## Output (REQUIRED FORMAT)

```
## Session Learning Capture
Task: Add account reconciliation to invoice cycle
Repo: orders-service
Time: 2 hours

### Patterns Discovered

#### Pattern 1: Invoice Validation Framework
**What**: Invoices require 3-layer validation (account → invoice → audit)
**Where used**: `services/invoice_service.go`, `services/reconciliation_service.go`
**Why**: Prevents balance drift, ensures account state matches invoice state
**Reusable?**: YES — Any financial operation involving balance mutations should follow this
**Code skeleton**:
```go
type InvoiceValidator interface {
    ValidateAccount(ctx context.Context, accountID int64) error
    ValidateInvoice(ctx context.Context, invoiceID int64) error
    ValidateAuditTrail(ctx context.Context, invoiceID int64) error
}
```
**For shared-lib?**: Consider extracting to shared-lib if billing or ledger need it

#### Pattern 2: Concurrent Access via SELECT FOR UPDATE
**What**: Account balance mutations MUST use SELECT FOR UPDATE lock
**Where**: `services/account_service.go`, `DeductBalance()`, `AddCredit()`
**Why**: Prevents race conditions when multiple requests mutate same balance concurrently
**Test coverage**: 8 test cases for concurrent requests (important!)
**Key learning**: Lock must be held until transaction commits; don't release early

#### Pattern 3: Idempotency via transaction_reference
**What**: Every financial operation needs idempotency via transaction_reference check
**Where**: `handlers/invoice_handlers.go`, invoice acceptance endpoint
**Why**: Retries on timeout must not double-deduct, double-credit, or duplicate invoices
**Pattern**:
```go
if exists(txRef) {
    return cached_result_for_txRef
}
perform_operation()
store(txRef, result)
return result
```

---

### Domain Terms Discovered

| Term | Definition | Used in | Related Terms |
|------|-----------|---------|---------------|
| Reconciliation | Process of matching account balance against invoice cycle total | orders-service invoice flow | Invoice cycle, account balance, invoice mutation |
| Invoice cycle | Time-based grouping of transactions for invoice | orders-service, reporting-service audit trail | Invoice, reconciliation, invoice cycle |
| Parity check | 7-day verification that old balance column = new balance column after migration | Database migration safety protocol | Dual-write, cutover |

**For CLAUDE.md update**: Add "Reconciliation" and "Invoice cycle" to orders-service's Domain Terms section

---

### Suggested Memory Entries

Each suggestion is ready to apply. Keep only the ones worth keeping. Shown here for a team on Beads
(`bd remember`); otherwise add the same text to `.intellisense/rules/organization/` or the repo's `CLAUDE.md`.
Never to MEMORY.md.

1. **User profile — financial expertise**
   ```bash
   bd remember --key user-financial-expertise \
     "User has deep understanding of SELECT FOR UPDATE patterns, idempotency via transaction_reference, and 3-layer validation framework. Inform future financial task routing and explanation depth."
   ```

2. **Feedback — concurrent account access**
   ```bash
   bd remember --key feedback-concurrent-account-access \
     "Use SELECT FOR UPDATE for account balance mutations. Verified with 8 concurrent-request test cases; lock must be held until transaction commits. Why: prevents balance-drift races. How to apply: any account/balance mutation path in orders-service, accounts-service, billing."
   ```

3. **Project — financial validation pattern**
   ```bash
   bd remember --key project-financial-validation-pattern \
     "Invoice validation framework (account → invoice → audit) is the established 3-layer pattern. Use for any new financial operation. Why: prevents reimplementing validation logic per feature. How to apply: invoke whenever a new financial mutation endpoint is added."
   ```

---

### Suggested Rules File Updates

**File**: `rules/operational/patterns.md`
- Add section: "Idempotency Pattern for Financial Operations"
- Content: transaction_reference requirement, best practices, test examples
- Why: Rule files should codify patterns that prevent bugs

**File**: `rules/operational/patterns.md`
- Add section: "3-Layer Validation for Financial State"
- Content: Account-level, operation-level, audit-level validation pattern
- Why: This is a reusable pattern that should be established for all new financial work

---

### Cross-Repo Insights

**Discovered**: orders-service and reporting-service coordination is fragile
- reporting-service consumes orders-service reconciliation API
- If API contract changes, reporting-service breaks silently
- Recommendation: check every consumer of the orders-service API (from service-map.md) before changing it

**Discovered**: accounts-service and orders-service have complex dance around balance mutations
- Both read account_balances; orders-service updates during invoice
- Risk: Locking strategy unclear; could cause deadlocks if accounts-service and orders-service both lock same account
- Recommendation: Add to accounts-service CLAUDE.md "Known Gotchas" section

---

### Confidence Level
- Patterns: HIGH (proven in tests, used multiple places)
- Domain terms: HIGH (confirmed with finance team)
- Cross-repo insights: MEDIUM (observed but not fully validated)

### Recommendation
- [x] Add these patterns to orders-service CLAUDE.md (Architecture section)
- [x] Apply the suggested memory entries above to persist user/feedback/project insights
- [ ] Review cross-repo insights with reporting-service team
- [ ] Consider extracting 3-layer validation to shared-lib (low priority for now)

---

## Example: No New Patterns

```
## Session Learning Capture
Task: Fix typo in invoice email template
Repo: orders-service
Time: 5 minutes

### Patterns Discovered
None. This was a straightforward typo fix with no new learnings.

### Domain Terms Discovered
None. No new concepts encountered.

### Suggested Memory Entries
None. No insights to capture.

### Suggested Rules File Updates
None needed.

### Confidence Level
N/A

### Recommendation
No memory or rule updates needed for this task.
```

## Step 6: Propose Repo Knowledge-Base Updates

After capturing personal session learnings, read `git diff` of the current branch.
For each meaningful change, identify which KB stub it belongs to:

| What changed | Target stub |
|-------------|-------------|
| New API endpoint added or modified | `02-api-contracts.md` |
| New business rule discovered or clarified | `03-biz-domain-rules.md` |
| Critical flow modified | `03-biz-critical-flows.md` |
| Non-obvious bug, edge case, or production gotcha | `04-eng-gotchas.md` |
| New pattern or convention established | `04-eng-conventions.md` |
| New domain term used in code | `03-biz-domain-rules.md` |
| Architecture component added or changed | `00-system-architecture.md` |

Output proposed additions as `PROPOSED:` blocks. **Do NOT auto-write to any KB file.**
Developer reviews → approves → commits in same PR as feature/fix or follow-up within 24h.

```
PROPOSED: knowledge-base/04-eng-gotchas.md
"Queue jobs must not close over request context — the context is cancelled
 when the HTTP response returns, silently failing any DB query inside the job."

PROPOSED: knowledge-base/04-eng-conventions.md
"All paginated list endpoints return { data: [], meta: { total, page, per_page } }
 — never return a bare array; callers depend on the meta block for UI pagination."

PROPOSED: knowledge-base/03-biz-domain-rules.md
"Status transitions are one-directional and enforced at the service layer —
 skipping states or reversing is rejected before any DB write."

PROPOSED: knowledge-base/02-api-contracts.md
"List endpoints accept comma-separated filter values (?status=pending,confirmed)
 — not repeated keys (?status=pending&status=confirmed); clients must not use the repeated form."
```

**Why not auto-write:** Incorrect KB entry silently misleads future sessions.
Review takes 2 minutes and catches hallucinations before they propagate.

---

## Constraints
1. **Only capture non-obvious patterns** — "Use tables in queries" is not a pattern, it's obvious
2. **Evidence required** — Don't suggest rules updates without proven examples from code
3. **Reusability threshold** — Pattern should be useful in ≥2 different places
4. **Cross-repo awareness** — Flag if other services might benefit from this pattern
5. **Confidence score required** — Don't suggest changes if less than 80% confident
6. **Domain terms must be confirmed** — Don't make up terminology; verify with domain expert
7. **Never auto-write KB files** — PROPOSED blocks only; developer must approve before applying
