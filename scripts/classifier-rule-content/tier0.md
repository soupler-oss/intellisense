# intellisense Tier 0 — fast path

**Tier 0 = local, low-risk:** doc-only, dep bump (no advisory), cosmetic frontend,
no-behavior refactor, test-only, non-service CI/build config.

**Clarify first (Kind 1):** even on the fast path, if the request is vague or
under-specified ("add caching", "make it faster"), ask ONE clarifying question
before implementing — what exactly, where, and any constraint. Skip if already
clear. The fast path removes *ceremony*, not *understanding*.

**Skipped:** Change Contract, task reference, formal review, full planning cycle.

**Still applies:** `/verify` and `/code-review` may be invoked manually.

**Escalate to Tier 1+ if any of:**
- API response shape change
- DB query or migration
- Auth, payment, security
- Cross-service contract
- Sandbox/prod path divergence

**If uncertain:** treat as Tier 1, not Tier 0.

The contract gate (`scripts/preToolUse-contract-gate.sh`) passes Tier 0 work
through without requiring a contract. Edits proceed normally.
