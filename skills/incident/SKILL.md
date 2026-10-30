---
name: incident
description: Use when a production incident is declared: an abbreviated diagnose, fix, safety-check and deploy path with a mandatory financial safety gate.
---

# /incident — Production Incident Fast Path

Abbreviated 4-step workflow for production incidents with mandatory financial safety gate.

**When**: Production incident declared
**Escalation path**: Skip Steps 1-9 of normal workflow, go straight to: Diagnose → Fix → Safety checklist → Deploy
**Time target**: <30 minutes from incident to deployment

> **Planned skills, not yet built:** `/validate-api-contract`,
> `/shared-table-impact`, `/sequence-plan` referenced below do not exist yet.
> Until they do, do those checks **manually** (consumers via service-map.md,
> deployment order by hand) — don't wait on a skill that isn't there.

## 4-Step Fast Path

### Step 1: Rapid Diagnosis (5 min)

Run `/diagnose` immediately (for money flows, apply the financial-impact gate below).
- Check logs, not guesses
- Find root cause fast
- Identify affected services
- Estimate impact scope (e.g., "10% of payouts failing")

If unclear after 5 min: Escalate to on-call engineer. Do NOT continue to Step 2.

### Step 2: Minimal Fix (10 min)

Write smallest possible fix:
- Hotfix branch: `hotfix/JIRA-XXX-brief-description`
- Change as little as possible (one file, 3-5 line fix if possible)
- No refactoring, no cleanup, no nice-to-haves
- Test locally only (no time for full suite during incident)

Example hotfix:
```go
// BEFORE (bug)
return account.Balance // Can be negative

// AFTER (fix)
if account.Balance < 0 {
    return 0 // Cap at zero until we can investigate
}
return account.Balance
```

If fix takes >10 min: You're going too deep. Escalate or revert to last known good state.

### Step 2.5: Incident Communication (2 min)

Notify stakeholders immediately — do not wait for deployment.

**Post to Slack:**
1. Go to `#incidents` channel
2. Post message:
```
[INCIDENT] [service-name] [impact summary] [ETA]
Owner: @your-name

Example:
[INCIDENT] orders-service: Account balance calculation errors affecting 15% of payouts. ETA: Fix deployed by 11:45 AM UTC
```

**Update status page** (if customer-facing):
- Go to status page (internal or public depending on scope)
- Set component status to "Investigating" or "Partial Outage"
- Include same incident description and ETA
- Update every 15 minutes if fix is delayed

**Do NOT overcommunicate** — brief status updates only. Details go in post-incident report.

### Step 3: Financial Safety Checklist (5 min) ⚠️ MANDATORY

**THESE FIVE QUESTIONS ARE NON-NEGOTIABLE. Answer all before deploying.**

1. **Account balance verified in staging?**
   - [ ] Yes: I checked account_balances table in staging with this fix
   - [ ] No: STOP. Test in staging first.

2. **Will this affect transaction idempotency?**
   - [ ] No: Fix doesn't change idempotency logic
   - [ ] Yes: Verified that transaction_reference still prevents duplicates

3. **Are there pending transactions that could race-condition?**
   - [ ] No: Checked logs; no pending transactions
   - [ ] Yes: Added SELECT FOR UPDATE lock to prevent races

4. **Is deployment order enforced for multi-service changes?**
   - [ ] Single service: N/A
   - [ ] Multi-service: Confirmed deployment order with `/sequence-plan`

5. **What is the exact rollback sequence?**
   - [ ] Documented: Rollback SQL/commands in PR description (not just "revert commit")

**If any question unanswered: DO NOT DEPLOY.** Escalate to finance team.

### Step 4: Deploy (10 min)

```bash
# 1. Create PR with hotfix branch
git checkout -b hotfix/JIRA-123-account-cap-at-zero
git add .
git commit -m "fix(accounts-service): cap balance at zero during incident

Temporary fix to prevent reconciliation failures.
Account balances cannot go below zero.

Closes JIRA-123"

git push -u origin hotfix/JIRA-123-account-cap-at-zero

# 2. PR description includes MANDATORY rollback plan
# (Paste into PR):
"""
## Incident Response

Accounts showing negative balances, causing reconciliation to fail.

## Hotfix
Cap balance at zero to unblock payouts.

## Rollback Plan
```sql
-- Revert balance cap: restore original values from backup
UPDATE account_balances 
SET balance = GREATEST(balance, 0) 
WHERE balance < 0;
```

## Financial Safety Checklist
- [x] Account balance verified in staging
- [x] Transaction idempotency maintained
- [x] No pending transactions at time of deploy (10:15 UTC)
- [x] Single-service change (no deployment order needed)
- [x] Rollback SQL documented above
"""

# 3. Request expedited review (1 approver, not 2)
# Tag on-call tech lead

# 4. Merge and deploy (after 1 approval)
git checkout main
git pull origin main
git merge --no-ff hotfix/JIRA-123-account-cap-at-zero
git push origin main

# 5. Deploy to production (using CI/CD)
# OR manual: `kubectl rollout restart accounts-service` if auto-deploy is too slow
```

---

## After Incident: 48-Hour Follow-Up

**Mandatory**: All skipped steps (code review, test coverage, cross-repo validation) must be completed within 48 hours.

Create follow-up ticket:
```
Title: [POST-INCIDENT] Account balance capping — complete code review and tests

Priority: High
Due: 2 days from now

## Skipped Steps
- [ ] Full code review (run `/code-review`)
- [ ] Test coverage analysis (must reach 95% financial paths)
- [ ] Cross-repo validation (run `/validate-api-contract`)
- [ ] Shared table validation (run `/shared-table-impact account_balances`)
- [ ] Root cause analysis (why did balances go negative? Fix that too)

## This Hotfix Was Temporary
- Current fix: Caps balance at zero
- Real fix: Find why balances go negative; prevent it

## Schedule
- Today (incident): Hotfix deployed
- Day 1-2: Code review, tests, validation
- Day 3: Root cause fix (separate PR)
- Day 4: Deploy permanent fix
```

---

## Constraints

1. **Financial safety checklist is non-negotiable** — Even under time pressure, answer all 5 questions
2. **Hotfix branch naming**: `hotfix/JIRA-XXX-brief-description` — Identifies incident clearly
3. **Single approver allowed**: Expedited review is 1 approver, not 2
4. **Rollback plan in PR description**: Exact SQL or commands, not just "revert commit"
5. **48-hour follow-up is mandatory**: Don't leave incident hotfixes in production unfixed
6. **Escalate if unsure**: Financial logic problems = escalate to finance team, not guessing
7. **No permanent code in hotfixes**: Cap at zero, disable feature, reject transactions — but FIX the root cause in follow-up

---

## Decision Tree: Should I Use /incident?

**YES, use /incident if**:
- Production incident is declared
- Customers are affected NOW
- Time pressure is REAL (not artificial)
- You can diagnose the issue quickly

**NO, use normal workflow if**:
- Bug was just discovered, not actively breaking production
- Customers aren't actively impacted
- You have time for code review and testing
- Multi-service changes required (need `/sequence-plan`)

**ESCALATE instead of /incident if**:
- You cannot diagnose the issue in 5 min
- Financial safety checklist cannot be answered honestly
- Requires changes across 3+ services
- On-call engineer is unavailable or overwhelmed
