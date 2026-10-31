<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Meta Changelog

Log of significant changes. Updated after every full_feature or bug_fix merge.

## Entry Format

```markdown
### YYYY-MM-DD | [Type] | [Summary]

**Files Changed**: [file-list]

**What Changed**: [1-2 sentence summary]

**Key Approach**: [How was it done? What pattern/technique?]

**Why This Matters**: [Impact on service behavior, performance, compliance, etc.]

**Edge Cases Handled**:
- [Case 1]
- [Case 2]

**Testing**: [Test coverage, integration tests, manual testing]

**Deployment**: [Any migration, configuration, or coordination needed?]

**Related Issues/PRs**: [Links to context]
```

---

## Example Entry

### 2026-04-27 | feature | Add idempotency key support to invoice API

**Files Changed**:
- handlers/invoice.go
- models/invoice.go
- migrations/add_idempotency_key.sql
- tests/invoice_test.go

**What Changed**: Invoice API now requires Idempotency-Key header. Duplicate requests with same key are deduplicated and return cached response.

**Key Approach**:
- Added `idempotency_key` column to invoices table (unique constraint)
- Before processing, check if idempotency_key exists in DB
- If exists, return cached response
- If new, process and cache response

**Why This Matters**:
- Payment retries are now safe; network failures don't cause double-charges
- SLA: 99.99% uptime for payment API; idempotency is mandatory for financial transactions
- Compliance: PCI-DSS requirement for idempotent payment processing

**Edge Cases Handled**:
- Concurrent requests with same idempotency_key: only one processes, others wait (via DB unique constraint + SELECT FOR UPDATE)
- Stale cache: response cached for 24 hours; after that, key can be reused for new payment
- Partial failure: if response is partially successful, cache the full response (all-or-nothing semantics)

**Testing**:
- Unit test: duplicate idempotency_key returns same response
- Integration test: concurrent requests with same key (race condition test)
- Load test: 100 concurrent requests per second, deduplicate correctly
- Coverage: 95% (financial code requirement)

**Deployment**:
- Must deploy after database migration runs
- No configuration changes needed
- No downstream impact (API change is additive, not breaking)
- Rollback: remove idempotency_key column (if needed within 24 hours of deploy)

**Related Issues/PRs**:
- Jira: FIN-123 "Add idempotency to payments"
- PR: #456 "Idempotent invoice processing"

---

## Recent Changes

<!-- TODO: Entries below will be maintained as features ship -->

### YYYY-MM-DD | [Type] | [Summary]

[Entry content following format above]

---

## How to Maintain This File

**After every full_feature or bug_fix merge**:

1. Create new entry at the top (most recent first)
2. Fill in all sections: What, Why, How, Tests, Deployment, Related
3. Copy the URL of the merged PR into Related Issues/PRs
4. If documentation needs update as a result, note it here for follow-up

**Quarterly review**:
- Identify patterns (e.g., "we keep hitting the same transaction isolation issue")
- Move repeated pattern to 04-eng-gotchas.md
- Update 00-system-architecture.md if big changes accumulated
- Trim very old entries (>1 year) unless still relevant

**When a gotcha happens**:
- Retrospective: did we document this in 05-meta-changelog.md?
- If yes: we should have caught it in code review
- If no: add incident analysis as new entry, plus entry to 04-eng-gotchas.md
