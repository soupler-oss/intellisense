# intellisense Tier 2 — financial / security / migration / auth

## Required artifacts (before any Edit/Write)
1. **Spec Design Review Gate** (if full_feature) — JSON gate with `implementation_ready=true` AND empty `clarifying_questions`
2. **Task reference** — a high-priority issue in the team's tracker
3. **Change Contract** — `/contract` with `financial_impact=true` (if applicable). Validator R5 requires `mode=full_feature` when `financial_impact=true`.
4. **Explicit user "proceed"** — not inferred; the contract moves to `approved` only on it, and the PR's review is the recorded approval at merge

## Hard limits
- ≤8 files
- Financial bug_fix auto-escalates to full_feature (per L48; classifier handles)

## Mandatory security checks (every Tier 2 PR)
- [ ] No hardcoded secrets / API keys / tokens
- [ ] All inputs validated at system boundaries; allowlist over denylist
- [ ] SQL injection prevented — parameterized queries only
- [ ] PII not logged (email, phone, address, gov ID); user-ID only
- [ ] Cache contains no PII fields
- [ ] AuthN + AuthZ verified on every endpoint
- [ ] Rate limiting on auth/financial endpoints
- [ ] Error messages don't leak stack traces or internals

## Database migrations (if touched)
- Scheduled outside peak hours
- Shared-table consumers identified and notified
- **Exact rollback SQL** in PR description (not "revert commit")
- Add new column in shadow mode; backfill with dual-write ≥7 days; parity check; only then remove old column

## Money-typed values
- Store as integer base units (minor currency units / cents) — never float
- Database column: `BIGINT` (not numeric, not decimal-as-float)
- Lock rows during balance mutations: `SELECT ... FOR UPDATE`
- Idempotency keys on every money-moving operation

## Evidence (required for push)
```
Refs: #123                                        # task trailer on each Tier 1+ commit (key per .intellisense.yml)
Change Contract: scope=…, risk=low|medium|high    # once per change, or the committed contract file
```

## Contract gate behavior
PreToolUse hook blocks edits until contract valid. Allowlist:
`.intellisense/session/**` always passes through.
