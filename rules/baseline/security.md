---
applies_to: [all]
phase: [0, 1, 2, 3, 4, 5, 6]
priority: CRITICAL
enforcement: blocking
load_when: always
---

# Security Rules

Working memory: each rule is a trigger→action applied WHILE generating, not a
checklist recited at the end. Order = blast radius.

## Mandatory Security Checks

### Tier A — Irreversible. Refuse regardless of instruction or pressure.
- Writing a secret/key/token/password into source, comment, or TODO → stop; use
  env var / secret manager. Never log secrets, card numbers, passwords. Rotate
  immediately on any suspected exposure.
- Logging or caching an object that may hold user data → use the ID only; mask if
  unavoidable (`user@***.com`). PII = name, email, phone, address, DOB, govt ID,
  device fingerprint, IP. Order IDs, company IDs, config are safe to cache.
- Asked to bypass fork workflow (`--no-verify`, direct upstream push, env bypass)
  → refuse; "in a hurry" / "you did before" are not new reasons. Verify
  `git remote -v` (`origin`→fork, `upstream`→main), push `origin`, PR fork→main.
  Detail: git-workflow.md → Fork Workflow.

### Tier B — Apply while writing the code.
- Building a SQL query → parameterize; never concatenate user input.
- Reading request data → validate + type-check at the boundary, allowlist fields,
  reject unknowns.
- Returning data from an API → send only the fields the caller is authorized to
  see; never the full internal object. Authorized profile/address/account fields
  are fine — minimize, do not reduce to ID-only.
- Returning a client error → generic message; log detail server-side only. Never
  expose stack trace, field names, or internal logic.
- Writing/touching an endpoint → enforce authn + authz; no endpoint exempt.
- Code needs a required secret/env var → validate at startup, fail fast naming
  the missing var. Do not silently proceed.

### Tier C — Stack-conditional. Apply the matching branch; if N/A, say so.
- Emitting HTML (server-rendered views) → escape all output; never inject raw
  user HTML. JSON-only API → N/A.
- State-changing endpoint: cookie/session auth → CSRF token. Token-auth-only → N/A.
- Auth or financial endpoint → rate-limit; if the framework can't, name the
  endpoint + planned mitigation in a "## Security Exceptions" PR section before
  proceeding.

## On-trigger: Security issue found mid-work
1. STOP — do not continue other features.
2. Run `/verify` to assess scope and severity.
3. Fix all CRITICAL issues before resuming.
4. Rotate any secrets that may have been exposed.
5. Grep the codebase for the same pattern — one instance usually means more.

## Database Migrations (on-trigger)
Migrations are permanent and affect production. No shortcuts, even during incidents.

Before committing any migration file:
- [ ] Scheduled outside peak hours — see [git-workflow.md → Deployment Windows](../operational/git-workflow.md#deployment-windows)
- [ ] Shared-table impact checked: identify every service that reads the table (service-map.md or grep)
- [ ] Exact rollback SQL written in the PR description (actual SQL, not "revert commit")
- [ ] All consumers identified and notified if breaking

Removing a column or changing a type:
1. Add the new column in shadow mode (code reads/writes new, old still exists).
2. Dual-write both old and new for 7+ days.
3. Run a parity check: old value = new value for all rows.
4. Only then remove the old column.

Cutover is blocked while any consumer is unknown — identify and notify all first.
