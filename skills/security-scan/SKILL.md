---
name: security-scan
description: Use before opening a pull request, to scan the change for secrets, injection, auth gaps and financial-safety violations.
---

# /security-scan — Pre-Commit Security Review

Scans code for secrets, injection vulnerabilities, auth gaps, financial security violations.

**When**: Before creating PR; part of `/verify` step
**Triggers**: On any code change; mandatory for financial or auth code
**Prerequisites**: Code must compile/build successfully

## Checks Performed

1. **Secret detection** — API keys, tokens, passwords, SSH keys, credentials
2. **Injection prevention** — SQL injection, command injection, XSS vectors
3. **Auth gaps** — Missing authentication, authorization, permission checks
4. **Financial security** — Unencrypted balance transfers, missing idempotency, race conditions
5. **Crypto safety** — Hardcoded secrets, weak algorithms, unencrypted storage

## Output (REQUIRED FORMAT)

```
## Security Scan Results
Scanned: 23 files modified | 1847 lines added

### ✓ PASS — No Critical Issues

#### Secrets Detection
✓ No API keys found (patterns: sk-, pk_, apikey=, api_key=)
✓ No tokens found (patterns: token=, bearer, jwt_)
✓ No passwords found (patterns: password=, passwd=, pwd=)
✓ No SSH keys (.pem, .key, id_rsa)
✓ No .env files included

#### Injection Prevention
✓ All SQL queries use parameterized queries (no string concatenation)
✓ All user input sanitized before rendering
✓ No hardcoded SQL in code (uses GORM repository pattern)
✓ No shell command execution in user paths

#### Auth Gaps
✓ All new endpoints require authentication check
✓ Authorization enforced (user can only reconcile their own invoices)
✓ Financial endpoints have rate limiting (100 req/min)

#### Financial Security (CRITICAL)
✓ Account mutations use SELECT FOR UPDATE lock
✓ Idempotency check on transaction_reference before processing
✓ Balance read from database, not cache
✓ No float arithmetic for currency (uses int64 minor-currency-units)
✓ Concurrent request test cases included (8 cases)

#### Crypto Safety
✓ No hardcoded secrets
✓ Uses bcrypt for password hashing (>10 rounds)
✓ Encryption uses AES-256-GCM (industry standard)
✓ Secrets read from environment variables only

### Issues Found: 0
### Blockers: 0
### Recommendations: 0

### Sign-Off
✓ **Safe to commit** — All security checks pass
✓ **Proceed to PR** — No security concerns
```

---

## Example: Issues Found

```
## Security Scan Results
Scanned: 15 files modified | 456 lines added

### ⚠️ WARNINGS — Review Before Merging

#### Secrets Detection
1. [HIGH] Database password found hardcoded
   - File: `config/database.go:12`
   - Code: `const DBPassword = "prod-password-123"`
   - Fix: Move to environment variable `DB_PASSWORD`

#### Injection Prevention
2. [CRITICAL] SQL injection vulnerability
   - File: `handlers/reconciliation_handlers.go:45`
   - Code: `WHERE account_id = '` + userID + `'`
   - Fix: Use parameterized query: `WHERE account_id = ?` with args [userID]

#### Financial Security
3. [CRITICAL] Missing idempotency check
   - File: `services/reconciliation_service.go:78`
   - Issue: Process reconciliation without checking `transaction_reference`
   - Risk: Duplicate reconciliation on retry will corrupt balance
   - Fix: Add check: `if exists(transaction_reference) { return cached_result }`

### Issues Found: 3
### Blockers: 2 (CRITICAL issues)
### Recommendations: 1

### Sign-Off
✗ **BLOCKED** — Must fix CRITICAL issues before committing
   1. Fix hardcoded password (HIGH)
   2. Fix SQL injection (CRITICAL) 
   3. Add idempotency check (CRITICAL)
```

## Confidence Thresholds
- **Report only**: Issues with >80% confidence
- **CRITICAL**: Definitely a vulnerability (SQL injection, hardcoded secrets, missing auth)
- **HIGH**: Likely vulnerability (weak crypto, missing idempotency, missing rate limit)
- **MEDIUM**: Should fix (unnecessary permissions, dead code)
- **LOW**: Nice to have (naming clarity, code organization)

## Constraints
1. Do not commit if any CRITICAL issues found
2. Financial code: Extra scrutiny on balance mutations, idempotency, concurrency
3. Auth code: Extra scrutiny on endpoint protection, permission checks
4. Payment code: Extra scrutiny on webhook signature validation, PCI compliance
5. Never ignore "potential" issues — investigate before dismissing
