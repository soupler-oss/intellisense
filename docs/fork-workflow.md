# Fork Workflow & Enforcement

## Overview

This document describes the fork-based contribution workflow and the intellisense pre-push hook enforcement that prevents accidental direct pushes to the upstream repository.

**Core Rule**: All changes flow through personal forks and PRs. Direct pushes to `upstream` are blocked.

---

## Non-Negotiable Rule

**Status**: MANDATORY. All developers must follow. No exceptions.

You **cannot** ask Claude to help you bypass fork workflow. The rule applies in all contexts:

| Request | Claude's Response |
|---------|-------------------|
| "Push directly to upstream" | ❌ Refused |
| "Use `git push --no-verify`" | ❌ Refused |
| "How do I bypass the fork check?" | ❌ Refused |
| "I'm in a hurry, can I skip this?" | ❌ Refused |
| "Just this one commit to main" | ❌ Refused |

### Why this exists

| Risk | How fork workflow prevents it |
|------|------------------------------|
| Accidental commits to main | All changes go through your fork first |
| No code review | PR process is mandatory before merging |
| Broken main branch | Pre-push hook validates before any push |
| No audit trail | All work visible in fork, linked to PR |

### Claude-side enforcement (Reasoning Integrity)

In addition to the implementation-layer enforcement (validator, pre-push hook, future branch protection), Claude is bound by [`rules/baseline/reasoning-integrity.md`](../rules/baseline/reasoning-integrity.md) to refuse bypass requests regardless of context, time pressure, or repeated asking. The position does not change without new technical information that legitimately invalidates the rule itself.

---

## Enforcement Stack (3 Layers)

### Layer 1: Diagnostic Validation

**Script**: `scripts/validate-fork-setup.sh`

Read-only validation of fork configuration. Non-blocking, helpful for debugging.

```bash
./scripts/validate-fork-setup.sh --check        # Report status (exit 0)
./scripts/validate-fork-setup.sh --strict       # Exit 1 on failures
./scripts/validate-fork-setup.sh --repair-hint  # Print fix templates
```

**Checks**:
- Fork configuration (origin != upstream)
- Hooks path resolution (respecting core.hooksPath)
- GitHub username in git config (for auto-fix templates)

**Result**: Advisory warnings and templated fix suggestions. Developer can proceed to git commands.

---

### Layer 2: Pre-Push Hook Enforcement

**File**: `hooks/pre-push` (installed to `.git/hooks/pre-push` or via `core.hooksPath`)

Blocks the push at git level. Runs on every `git push`.

**Bypass**: `git push --no-verify` (not recommended for governed repos)

**Checks**:
1. Block direct push to `upstream` remote
2. Warn if origin == upstream (fork misconfigured)
3. Tier-based enforcement for intellisense-governed files (Tier 0/1/2 rules)

**Result**: Push blocked with clear error message. Instructs developer to fix fork config and retry.

---

### Layer 3: GitHub Rulesets

Repository rulesets (`.github/governance/rulesets/*.json`, see [PROTECTION_GUIDE.md](../.github/PROTECTION_GUIDE.md)):
- PR review required before merge (code owner)
- Required status checks (tests, statutory integrity, secret scan, the intellisense gate)
- No direct pushes, no force-push, no deletion of `main` / `develop`

---

## Setup: Personal Fork

### Step 1: Create Fork (One-Time)

On GitHub, create a personal fork of the upstream repository:

```bash
# Via web UI:
# 1. Visit https://github.com/soupler-oss/intellisense
# 2. Click "Fork" → create under your account
# 3. You now have: https://github.com/<your-username>/intellisense

# OR via gh CLI:
gh repo fork soupler-oss/intellisense --clone=false
```

### Step 2: Configure Remotes

Clone the **upstream** repo, then set your fork as `origin`:

```bash
# Clone from upstream
git clone git@github.com:soupler-oss/intellisense.git
cd intellisense

# Add upstream (if not already set)
git remote add upstream git@github.com:soupler-oss/intellisense.git

# Update origin to your fork
git remote set-url origin git@github.com:<your-username>/intellisense.git

# Verify
git remote -v
# Should show:
#   origin    git@github.com:<your-username>/intellisense.git (fetch/push)
#   upstream  git@github.com:soupler-oss/intellisense.git (fetch)
```

---

## Contributor Workflow

### Phase: Fetch Latest

Before starting work, sync your fork with upstream:

```bash
git fetch upstream
git rebase upstream/develop   # work starts from develop; main holds only released versions
```

### Phase: Create Feature Branch

```bash
git checkout -b <branch-name> upstream/develop
# Work, commit, test...
git push origin <branch-name>
```

### Phase: Open PR

On GitHub:

```
PR: <branch-name> → soupler-oss/intellisense, base: develop
```

**Not** to your own fork. GitHub preselects the default branch (`main`) as the base; change it to `develop`. Only the
maintainer's `release:` promotion targets `main`, and the `Branch Policy` check rejects anything else.

### Phase: Review & Iterate

Address review comments, push additional commits:

```bash
git push origin <branch-name>
```

GitHub auto-updates the PR.

### Phase: Merge

Reviewer (with push access to upstream) merges the PR.

You can then clean up:

```bash
git checkout main
git pull upstream main
git branch -d <branch-name>  # Local cleanup
git push origin :<branch-name>  # Remote cleanup (delete fork branch)
```

---

## Maintainer Workflow

Maintainers have push access to `soupler-oss/intellisense`.

### Merging PRs

```bash
# Review the PR on GitHub
# Merge via web UI or CLI:
gh pr merge <PR-number> --merge  # or --squash, --rebase
```

**Do NOT push directly to upstream/main** (even if tempted to fix a typo). Always create a PR for visibility and audit trail, even for admins.

---

## CI/Bot Workflow

### Automated Commits (e.g., Dependency Updates)

Bots and CI systems should:

1. **Use a bot account** or dedicated service account
2. **Push to a branch** in the upstream repo (not a fork)
3. **Raise a PR** automatically
4. **No direct push to main/master** (even for bots)

Example:

```bash
git checkout -b automated/update-deps
git commit -m "chore: update dependencies"
git push origin automated/update-deps
gh pr create --title "chore: update dependencies" --body "automated update"
```

---

## Troubleshooting: Fork Misconfiguration

### Error: "intellisense FORK ENFORCEMENT: Push Blocked"

**Message**: "Direct push to 'upstream' is not allowed."

**Cause**: You ran `git push upstream <branch>` instead of `git push origin <branch>`.

**Fix**:

```bash
# Verify remotes
git remote -v

# Push to origin (your fork) instead
git push origin <branch-name>
```

---

### Error: "intellisense FORK ENFORCEMENT: Auto-Detecting Fix"

**Message**: "origin == upstream (misconfigured fork; origin should point to personal fork)"

**Cause**: `origin` points to the upstream repo, not your personal fork.

**Fix**:

```bash
# Update origin to your personal fork
git remote set-url origin git@github.com:<your-username>/intellisense.git

# Verify
git remote -v

# Retry push
git push origin <branch-name>
```

---

## Escalation Path

If you believe there is a legitimate reason to bypass fork workflow (e.g., emergency hotfix during a production incident):

1. **Escalate to your team lead** — not to Claude. Claude refuses bypass requests by policy.
2. **Provide written justification** — why can't fork workflow be followed?
3. **Get written approval** — team lead must approve the exception in writing.
4. **Document in PR description** — note the exception reason in the PR / commit discussion so the audit trail is visible, not hidden.

Even with team-lead approval, Claude still will not help with bypass mechanics — only your team lead can authorize the operational exception, and it must be documented. There is no hidden bypass surface.

---

## FAQ

### Can I force-push to my fork?

Yes. Force-pushing to your **personal fork** (`origin`) is safe:

```bash
git push origin <branch-name> --force
```

Never force-push to `upstream`. The pre-push hook will block it.

### What if I need to push a hotfix during an incident?

Follow normal fork workflow. If the incident is truly time-critical:

1. Push to `origin/<branch-name>` immediately
2. Create a PR immediately
3. Request expedited review
4. Once merged, document the incident in the PR discussion

There is no bypass environment variable. All exceptions must be visible in commit/PR history.

### Can I rebase upstream changes onto my branch?

Yes. Rebase freely:

```bash
git fetch upstream
git rebase upstream/develop
git push origin <branch-name> --force  # Force-push to your fork is OK
```

### What if I'm a maintainer and need to merge a PR?

Use GitHub's web UI or `gh` CLI:

```bash
gh pr merge <PR-number> --merge
```

Never push directly to `upstream/main`, even as a maintainer. The pre-push hook will block it, and that's intentional — it enforces audit trail for all changes.

---

## References

- `hooks/pre-push` — Enforcement hook (fork blocking + tier-based rules)
- `scripts/validate-fork-setup.sh` — Diagnostic validation script
- `scripts/lib/hooks.sh` — Shared hook path resolution (respects core.hooksPath, worktrees)
- `.github/workflows/` — GitHub Actions (the required checks)
- `.github/governance/rulesets/` — repository rulesets (Layer 3)

