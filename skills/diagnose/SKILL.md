---
name: diagnose
description: Use when a test fails or behaviour is unexpected in this repository, to trace the bug to its root cause before writing a fix.
---

# /diagnose — Bug Root-Cause Analysis

## Purpose
Trace a reported bug to its root cause in the current repo context.

## When to Use
- Test failure or unexpected behavior in current repo
- Need to understand root cause before implementing fix
- After bug report or incident

## Methodology

### Step 1: Reproduce
- Run test or workflow that demonstrates bug
- Capture exact error message
- Note when it occurs (on every run? intermittent?)

### Step 2: Trace
- Search codebase for error message
- Check git blame for recent changes to affected code
- Review related tests and mocks

### Step 3: Analyze
- Check error handling at each layer (handler → service → repository)
- Verify database state (if applicable)
- Check for concurrent access issues

### Step 4: Validate
- Propose minimal reproducer test
- Confirm fix resolves the issue
- Check for similar patterns in codebase

## Output Example
```
## Bug Report
Test `TestAccountReconciliation_Concurrent` fails intermittently

## Root Cause
File: service/reconciliation.go:142
Issue: Missing SELECT FOR UPDATE lock on account_balances table
Cause: Concurrent reconciliation requests can race-condition on balance read

## Reproducer
Run test 10x: `for i in {1..10}; do go test -run TestAccountReconciliation_Concurrent; done`

## Fix
Add SELECT FOR UPDATE to balance query before update:
```sql
SELECT balance FROM account_balances WHERE id = ? FOR UPDATE
```

## Confidence
HIGH (race condition clearly detectable in code, test reproduces 100%)
```

## Edge Cases
- If bug cannot be reproduced in current repo: `/cross-service-diagnose` may be needed
- If insufficient evidence: State what additional information is needed

## Next Step
Write failing test that reproduces bug, then fix with `/tdd`.
