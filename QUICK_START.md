# QUICK START — Your First Task with intellisense

> **Start here.** Install the binary, then pick a mode:
>
> ```bash
> brew install soupler-oss/tap/intellisense     # or: curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh | sh
> cd your-repo && intellisense init             # Core mode: any agent, one repository (asks a few questions)
> intellisense live install                     # Live mode: live checks inside Claude Code, every repository on this machine
> ```
>
> Windows: `winget install Soupler.Intellisense`, or `scoop bucket add soupler https://github.com/soupler-oss/scoop-bucket && scoop install intellisense` (Core mode; Live mode needs WSL).
> With Go: `go install github.com/soupler-oss/intellisense/cmd/intellisense@latest`. Run `intellisense` anywhere to see what to do next.
>
> The rest of this guide installs Live mode **from a git checkout** with `setup.sh` — the path for contributors to
> intellisense itself. `setup.sh` takes `--tracker` and `--code-intel` (both default to `none`: nothing extra is installed).

**Time**: 15 minutes  
**Goal**: Complete one task from requirement to PR using the intellisense workflow  
**Prerequisites**: 
- `bash setup.sh` already run; ~/.claude directory synced (Layer 2)
- Service repos initialized with CLAUDE.md (Layer 3) — run `bash setup.sh` and complete Layer 3 setup if not done

---

## Task Example: Add account reconciliation feature to orders-service

### Step 1: Intake (1 minute)

Open any directory. Run:
```
/where-to-start add account reconciliation feature
```

This searches service-map.md + all CLAUDE.md files. Returns ranked repo list with reasoning.

**Expected output:**
```
## Primary Service
- orders-service: Handles billing, invoicing, and balance mutations

## Related Services  
- accounts-service: Balance store (upstream to orders-service)
- reporting-service: Audit trail (reads from orders-service transactions)

## Action
Open: ~/projects/orders-service
```

### Step 2: Planning (3 minutes)

Open orders-service repo. Run:
```
/plan add account reconciliation to billing cycle
```

This analyzes the requirement through a 7-step framework:
1. Search for existing patterns (reuse-first)
2. Identify affected files
3. Determine test strategy (95%+ coverage for financial code)
4. Flag deployment dependencies
5. List implementation risks
6. Define success criteria
7. Escalation checklist (if financial — always flag for financial code)

**Expected output:**
```
## Affected Files
- handler/billing.go
- service/reconciliation.go (NEW)
- test/billing_test.go

## Test Strategy
- Unit: reconciliation logic, balance matching
- Integration: database transactions, concurrent requests
- Coverage target: 95%+ (financial code)
- Special: concurrent reconciliation request handling

## Risks
- Race conditions on account_balances table (shared with accounts-service)
- Existing reconciliation logic in reporting-service may conflict

## Deployment Order
1. Deploy orders-service (new reconciliation)
2. Notify reporting-service team of new audit events
3. No changes needed to accounts-service (read-only)

## Success Criteria
✓ Reconciliation matches billing cycles
✓ Concurrent requests don't create duplicates (idempotency)
✓ All financial mutations logged to reporting-service
✓ 95%+ test coverage
```

### Step 3: Implementation (5 minutes)

Run:
```
/tdd
```

**RED phase**: Write failing test
```go
func TestAccountReconciliation_MatchesBillingCycle(t *testing.T) {
    // Test that reconciliation balances equal billing total
    // Test fails — not implemented yet
}
```

**GREEN phase**: Write minimum code to pass
```go
func (s *Service) ReconcileAccount(ctx context.Context, cycleID int64) error {
    // Implement reconciliation logic
    // Test passes
}
```

**IMPROVE phase**: Refactor while keeping tests green
- Extract validation to separate function
- Add concurrent request tests
- Improve error messages

### Step 4: Verification (3 minutes)

Run:
```
/verify
```

This runs:
- ✓ `go build ./...` (compiles)
- ✓ `go test ./...` (tests pass)
- ✓ `go vet ./...` (static analysis)
- ✓ Coverage check (95%+ for financial paths)
- ✓ Linter (no warnings)
- ✓ `/code-review` (code quality)
- ✓ `/security-scan` (no vulnerabilities)

If all green → proceed to Step 5.

### Step 5: Cross-Repo Validation (2 minutes)

Since account_balances is shared with accounts-service:

Check the table's consumers manually from service-map.md → Shared Database
Tables (`/shared-table-impact` is planned, not yet built — the block below
shows the information you need to assemble by hand):
```
## Table: account_balances
## Owner: accounts-service
## Readers/Writers: orders-service, reporting-service, api-gateway

## Validation Status
✓ accounts-service — no changes needed (read-only access)
✓ reporting-service — audit trail updates (compatible with change)
✓ api-gateway — no direct account access
```

### Step 6: Knowledge Capture (1 minute)

Run:
```
/learn
```

Extracts patterns from your session. If new architectural insights discovered:
```
Updates to MEMORY.md:
- New pattern: account reconciliation should always use billing cycle as source of truth
- Consider: extract to shared pattern if other services need reconciliation
```

### Step 7: Commit & PR (2 minutes)

**Before you commit** — every Tier 1 and Tier 2 commit carries a task trailer (`Refs:`, `Task:`, or `Beads:` — whichever keys your `.intellisense.yml` accepts), and the change carries one Change Contract. The pre-push hook and CI block the push otherwise. Account/billing work is Tier 2 (financial), so open or pick the issue in your tracker first, and get the plan approved before editing (`rules/operational/development-workflow.md`).

Then commit with the task reference; the contract is the committed `.intellisense/contracts/<branch>.md` from `/contract`, or one line:

```bash
git checkout -b feat/JIRA-123-account-reconciliation
git add .
git commit -m "feat(orders-service): add account reconciliation to billing cycle

- Validates account balance against billing cycle total
- Uses SELECT FOR UPDATE for race-condition safety
- Includes concurrent request test suite
- 95%+ test coverage (financial code)

Task: JIRA-123
Change Contract: scope=account reconciliation in billing cycle, risk=high, confidence=0.8"

git push -u origin feat/JIRA-123-account-reconciliation
```

Create PR with description:
```markdown
## What
Add account reconciliation to billing cycle. Validates that account_balances 
matches sum of all billing records.

## Why
Prevents long-term balance drift. Catches bugs in billing or account mutation logic.

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

## Workflow Checklist

- [ ] `/where-to-start` (identified correct repo)
- [ ] `/plan` (understood requirement)
- [ ] `/tdd` (RED → GREEN → IMPROVE)
- [ ] `/verify` (all checks pass)
- [ ] Shared-table / API-contract impact checked via service-map.md (if applicable; `/shared-table-impact` and `/validate-api-contract` are planned, not yet built)
- [ ] `/learn` (captured knowledge)
- [ ] Commit with conventional format
- [ ] PR with complete description
- [ ] Request review from team

---

## If Something Goes Wrong

**Test fails mysteriously?**
→ Run `/diagnose` (traces the failure in current repo context)

**Not sure if change breaks other services?**
→ Run `/multi-service-plan` Step 0 (discovers affected repos from service-map.md;
`/discover-impact` is planned, not yet built)

**Shared library changed (shared-go-lib)?**
→ Build all 5 consumers by hand (`/validate-shared-library` is planned, not yet built)

**API endpoint changed?**
→ Check downstream consumers from the CLAUDE.md API Contracts section by hand
(`/validate-api-contract` is planned, not yet built)

**Shared database table modified?**
→ Find all consumers via service-map.md Shared Database Tables by hand
(`/shared-table-impact` is planned, not yet built)

**Production incident?**
→ Run `/incident` (fast diagnosis + minimal fix + safety checklist)

**PHP: `vendor/autoload.php` not found after worktree creation?**
→ See [laravel-patterns.md → Worktree PHP Dependencies](../rules/language-specific/laravel-patterns.md#worktree-php-dependencies) for setup options: (1) Local composer install, (2) Symlink from dev machine, (3) Docker volume mount, or (4) Environment-managed.

---

## Key Rules to Remember

1. **Always run `/plan` before coding** — it catches 80% of issues
2. **Financial code is 95%+ coverage minimum** — no exceptions
3. **Use `/tdd` discipline** — RED → GREEN → IMPROVE
4. **/verify must pass before PR** — every check
5. **Cross-repo impacts must be validated** — manually via service-map.md consumers until the planned /shared-table-impact, /validate-api-contract, /validate-shared-library skills ship
6. **/incident is the fast path for production** — financial checklist still mandatory

---

## Next: Full Workflow

Once you've completed one task, read `docs/WORKFLOW.md` for the complete 10-step workflow covering:
- Complex cross-repo work
- Shared library changes
- Web Component changes
- Multi-team coordination
- Deployment sequencing
- Rollback planning

---

**Start your first task now:**
```
/where-to-start [your requirement]
```
