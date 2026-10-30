# Complete Development Workflow (10 Steps)

End-to-end workflow from requirement intake to deployment. This is the default path for all development tasks.

---

## Step 1 — Intake (Always First)

**Location**: Any directory
**Time**: 2-3 minutes
**Tool**: `/where-to-start`

Run from ANY directory (not necessarily the service repo):
```
/where-to-start add account reconciliation feature
```

Output: Ranked repo list with reasoning.

**Decision**: Does this look right? If developer initially guessed wrong repo, this corrects it.

---

## Step 2 — Discovery (If Multi-Repo Impact)

**Location**: Still any directory
**Time**: 2-3 minutes
**Tool**: `/multi-service-plan` 

If the requirement spans multiple services, run:
```
/multi-service-plan add account reconciliation to payout cycle
```

Output: Per-repo breakdown, deployment sequence, integration points, validation checklist.

**Decision**: Is this the full scope? Confirm before proceeding to planning.

---

## Step 3 — Planning

**Location**: Service repo (cd to the right place from Step 1)
**Time**: 5-10 minutes
**Tools**: `/plan` (single-repo) or `/multi-service-plan` (multi-repo)

### Single-Repo Planning
```
/plan add account reconciliation to payout cycle
```

Output: Affected files, test strategy, risks, success criteria.

### Multi-Repo Planning
```
/multi-service-plan add account reconciliation to payout cycle
```

Output: Per-repo task breakdown, deployment order, integration points.

**Decision**: Does the plan cover all cases? Escalate to architect if uncertain.

---

## Step 4 — Pre-Work Validation (Conditional)

**Only if**: API changes, migrations, or shared-go-lib/ui-widgets work
**Time**: 5-10 minutes
**Tools**: `/validate-api-contract`, `/shared-table-impact`, `/web-component-impact`, `/validate-shared-library`

> **Planned skills, not yet built.** The four commands below show the INTENDED
> interface and do not exist yet. Until they ship, perform each check manually:
> read the consumers from service-map.md (shared tables, library consumers) and
> the affected repos' CLAUDE.md (API contracts), then build/verify by hand.

### API Endpoint Changes
```
/validate-api-contract POST /api/v1/reconcile
```
Checks downstream consumers.

### Shared Database Changes
```
/shared-table-impact account_balances
```
Lists all consumer services.

### ui-widgets Changes
```
/web-component-impact
```
Validates consumer builds.

### shared-go-lib Changes
```
/validate-shared-library
```
Tests all 5 consumers.

**Decision**: Are all consumers compatible? Fix or escalate before implementation.

---

## Step 5 — Implementation (TDD)

**Location**: Service repo
**Time**: 20-40 minutes
**Tool**: `/tdd`

Run:
```
/tdd
```

Follow RED → GREEN → IMPROVE:

### RED Phase
Write failing test.

### GREEN Phase
Write minimum code to pass.

### IMPROVE Phase
Refactor, extract helpers, improve clarity.

**Decision**: Implementation complete and tests passing? Proceed to verification.

---

## Step 6 — Multi-Repo Implementation (If Needed)

**Location**: Each affected service repo (from Step 3)
**Time**: Repeat Step 5 for each repo

Repeat steps 5 for each additional service in the plan.

**Coordination**: Ensure API contracts remain compatible between repos.

---

## Step 7 — Verification

**Location**: Service repo (or all repos if multi-repo)
**Time**: 5-10 minutes
**Tools**: `/verify`, `/code-review`

Run in order:
```
/verify
```

Checks: build → test → lint → security → coverage.

Output: All checks pass OR list of failures.

### If Failures
Fix and re-run `/verify`.

### If Passes
Proceed to code review.

```
/code-review
```

Output: CRITICAL, HIGH, MEDIUM, LOW issues.

### If CRITICAL Issues
Fix and re-run `/code-review`.

### If HIGH Issues Only
Fix before PR (recommended).

---

## Step 8 — Cross-Repo Validation (Multi-Repo Only)

**Location**: Back to Step 7 for each repo
**Time**: 5 minutes per repo

Repeat verification in all affected repos:
- orders-service (main implementation)
- reporting-service (audit trail updates)
- (accounts-service: read-only, no changes)

Ensure:
- All repos build
- All tests pass
- Deployment order is enforced

---

## Step 9 — Knowledge Capture

**Location**: Any directory
**Time**: 3-5 minutes
**Tool**: `/learn`

Run:
```
/learn
```

Output: Extracted patterns, architectural insights, and suggested rule or memory entries (one per insight).

**Action**: Keep the ones worth keeping: as a rule (the repo's `CLAUDE.md` or `.intellisense/rules/organization/`), or with `bd remember` when the team's tracker is Beads. intellisense does not use MEMORY.md. Update the relevant service-repo CLAUDE.md if a new architectural fact was discovered.

---

## Step 10 — Commit & PR

**Location**: Service repo
**Time**: 10-15 minutes

### Commit
```bash
git checkout -b feat/JIRA-123-account-reconciliation
git add .
git commit -m "feat(orders-service): add account reconciliation to payout cycle

- Validates account balance against payout cycle total
- Uses SELECT FOR UPDATE for race-condition safety
- Includes concurrent request test suite
- 95%+ test coverage (financial code)

Closes JIRA-123"

git push -u origin feat/JIRA-123-account-reconciliation
```

### PR Description
```markdown
## What
Add account reconciliation to payout cycle. Validates that account_balances 
matches sum of all payout records.

## Why
Prevents long-term balance drift. Catches bugs in payout or account mutation logic.

## Testing
- Unit: reconciliation matching logic (15 cases)
- Integration: concurrent requests, database transactions (8 cases)
- Coverage: 95%+ (financial code), 82% overall

## Cross-Repo Impact
- accounts-service: read-only access, no changes
- reporting-service: audit trail updates (compatible)

## Deployment Order
1. orders-service (this change)
2. Monitor logs for reconciliation events
3. Notify reporting-service team

## Rollback Plan
Revert commit. Reconciliation state is read-only; no data loss.

Signed-off-by: Your Name <email>
```

---

## Incident Fast Path (Production Only)

If production incident: Skip to `/incident` immediately. Replaces steps 1-10 with abbreviated workflow:

1. Run `/incident`
2. Follow abbreviated workflow
3. Must complete financial safety checklist (non-negotiable)
4. Create PR with rollback plan
5. Expedited review (1 approver)
6. Deploy
7. Create follow-up ticket to complete skipped steps within 48 hours

---

## Troubleshooting During Workflow

**Test fails mysteriously?**
→ Run `/diagnose` (traces failure in current repo)

**Not sure if change breaks other services?**
→ Run `/multi-service-plan` Step 0 (discovers affected repos from service-map.md;
the dedicated `/discover-impact` skill is planned, not yet built)

**Shared library changed?**
→ Build all consumers listed in service-map.md by hand
(`/validate-shared-library` is planned, not yet built)

**API endpoint changed?**
→ Check downstream consumers from the CLAUDE.md API Contracts section by hand
(`/validate-api-contract` is planned, not yet built)

**Shared database table modified?**
→ Find all consumers via service-map.md Shared Database Tables by hand
(`/shared-table-impact` is planned, not yet built)

---

## Workflow Checklist

- [ ] Step 1: `/where-to-start` (identified correct repo)
- [ ] Step 2: `/multi-service-plan` Step 0 impact discovery (if multi-repo)
- [ ] Step 3: `/plan` or `/multi-service-plan` (understood requirement)
- [ ] Step 4: Pre-work validation (if API/migration/shared-lib changes)
- [ ] Step 5: `/tdd` (RED → GREEN → IMPROVE)
- [ ] Step 6: Repeat Step 5 for each repo (if multi-repo)
- [ ] Step 7: `/verify`, `/code-review` (all checks pass)
- [ ] Step 8: Cross-repo validation (if multi-repo)
- [ ] Step 9: `/learn` (captured knowledge)
- [ ] Step 10: Commit with conventional format, PR with complete description

---

## Time Budgets

| Step | Time | Task |
|------|------|------|
| 1 | 2-3 min | `/where-to-start` |
| 2 | 2-3 min | `/multi-service-plan` Step 0 impact discovery (if multi-repo) |
| 3 | 5-10 min | `/plan` or `/multi-service-plan` |
| 4 | 5-10 min | Pre-work validation (conditional) |
| 5-6 | 20-40 min | `/tdd` (per repo) |
| 7-8 | 5-10 min | `/verify`, `/code-review` (per repo) |
| 9 | 3-5 min | `/learn` |
| 10 | 10-15 min | Commit & PR |
| **Total** | **60-100 min** | **Full workflow (typical single-repo feature)** |

Multi-repo features take longer (repeat steps 5-8 per service).

---

**This is the default workflow.** Always follow it unless `/incident` is triggered.
