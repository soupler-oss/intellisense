---
name: intellisense
description: Tier-based intellisense gating for requirements, features, bugs, infra/setup changes, cross-repo work, financial/security changes, and migrations. Tier 1 and Tier 2 need a task reference and a change contract; plan and get approval before implementing them.
---

# intellisense Gate Enforcement (Tier-Based)

## How a tier is decided

The repository's `.intellisense.yml` decides, not this skill. Ask the engine:

```bash
intellisense classify            # this change: its tier, and the rule that put each file there
intellisense classify PATH...    # specific paths
```

Each file takes the first tier (highest level first) with a matching path rule; a file no rule matches gets
`default_tier`; the change takes the highest file tier. With the default policy:

| Tier | Typical paths | Needs |
|------|---------------|-------|
| **Tier 0** — routine | docs, tests, comment-only edits | nothing extra |
| **Tier 1** — standard | ordinary code, CI, infrastructure, dependencies, agent instructions, setup scripts | task reference on each commit + one change contract |
| **Tier 2** — high risk | auth, money, migrations, secrets, the governance policy itself | the same evidence, plus human review of the plan before editing |

A repository can add tiers or change what each needs: `intellisense policy show` prints the policy in effect.

---

## Phase 1: Plan and evidence (Tier 1+)

1. **Task reference.** An issue in the team's tracker. Each Tier 1+ commit carries its own trailer, with a key from
   `evidence.task_trailers` (default `Task`, `Refs`, `Beads`):
   ```
   Refs: #123
   ```
2. **Change contract.** Scope and risk, once per change: run `/contract` (Live mode) or
   `intellisense contract new "<title>"`, fill in the front matter, and commit the file under `.intellisense/contracts/`.
   Or put one line in a commit message:
   ```
   Change Contract: scope=rate limiting on auth endpoints, risk=medium, confidence=0.85
   ```
   `intellisense contract fields` lists the fields the policy requires.
3. **Approval (Tier 2).** The user approves the plan in the session before any edit; the pull request's review is the
   recorded approval at merge.

---

## Phase 2+: Implementation

The pre-push hook and CI run the same gate (`intellisense gate`):

- ✅ a task trailer on each Tier 1+ commit (one commit's trailer never covers another)
- ✅ one valid change contract for the change
- ✅ a changed test, where the tier's `requires` lists `test`
- ✅ no likely secrets in added lines

If a check fails → **the push is blocked**, with the fix printed under each problem.

---

## Examples

### Tier 0: documentation
```bash
git commit -m "docs: clarify fork workflow"
git push            # passes: nothing extra needed
```

### Tier 1: setup script
```bash
git commit -m "feat(setup): validate the tracker choice" \
  -m "Refs: #42" \
  -m "Change Contract: scope=setup tracker validation, risk=low, confidence=0.9"
git push            # passes: task trailer + contract found
```

### Tier 2: auth
```bash
git commit -m "fix(auth): rate-limit login attempts" \
  -m "Refs: #57" \
  -m "Change Contract: scope=login rate limiting, risk=high, confidence=0.8"
git push            # passes the gate; the pull request still needs review
```

### No bypass
There is **no `INTELLISENSE_BYPASS`** variable. `git push --no-verify` skips only the local hook: CI runs the same gate
as a required check. A genuine false positive is fixed in `.intellisense.yml` (itself Tier 2, so the fix is reviewed),
or exempted through the governed `.intellisense/exception-allowlist.yaml` (reason + expiry, no self-approval).

---

## Reference

- [docs/policy.md](../../docs/policy.md) — tiers, evidence, the contract schema, every policy key
- [docs/live-mode.md](../../docs/live-mode.md) — the edit-time contract gate and the prompt classifier
- Implementation: `internal/tier`, `internal/gate`, `internal/contract`; Live mode's `hooks/pre-push` and
  `scripts/preToolUse-contract-gate.sh` call the same engine. Tests: `internal/*/…_test.go`, `tests/test_pre_push_*.sh`.
