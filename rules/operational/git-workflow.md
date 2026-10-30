---
applies_to: [full_feature, bug_fix, refactor, hotfix, fix_pr_comments]
phase: [5, 6]
priority: HIGH
enforcement: blocking
load_when: commit
---

# Git Workflow

## Fork Workflow (Mandatory — No Direct Push)

> **Structural enforcement:** the intellisense pre-push hook in every repo's `.git/hooks/pre-push` blocks pushes to `upstream` and to a misconfigured `origin` at the git level. There is no supported bypass.

**Remotes:**

| Remote | Points to | Push? |
|--------|-----------|-------|
| `origin` | your personal fork (`git@github.com:<you>/<repo>.git`) | yes — all pushes |
| `upstream` | the original repo (`git@github.com:<owner>/<repo>.git`) | NEVER — treat as read-only |

**Behavior (trigger → action):**
- No personal fork exists → `gh repo fork <owner>/<repo> --remote=false`
- `origin` missing → `git remote add origin git@github.com:<you>/<repo>.git`; `origin` exists but points to the wrong repo → `git remote set-url origin git@github.com:<you>/<repo>.git`
- `upstream` missing → `git remote add upstream git@github.com:<owner>/<repo>.git`; `upstream` exists but points to the wrong repo → `git remote set-url upstream git@github.com:<owner>/<repo>.git`
- `origin` points to the main repo (not a fork) → STOP, correct it before any push
- Ready to push → `git push origin <branch-name>` (add `-u` on a new branch)
- Opening a PR → raise `fork:<branch-name> → upstream:main` (or `develop`)

**Pre-push gate:**
- [ ] `origin` → fork, `upstream` → original repo (verified via `git remote -v`)
- [ ] Pushing to `origin`, never `upstream`
- [ ] No `--no-verify`, no force-push to a protected branch

---

## Commit & Push Decisions

**Local commit is mandatory and never needs permission; push needs explicit this-session approval** (see [CLAUDE.md](../../CLAUDE.md) → Session Completion):
- Work complete → stage specific files → commit locally with the required trailers
- Push not approved this session → STOP after the local commit; hand off "committed locally on `<branch>`, not pushed — awaiting approval"
- Push approved this session → `git pull --rebase` → `git push origin <branch>`

**Staging discipline:**
- [ ] Stage specific files — never `git add -A` blindly
- [ ] Never commit `.intellisense/session/**`, local/generated files, or changes unrelated to this task
- [ ] Staged diff scanned for secrets, keys, tokens, and PII before commit (see [security.md](../baseline/security.md) → Mandatory Security Checks)

**When a hook blocks the commit/push:** fix the genuine gap, OR surface it to the user as a possible false positive for them to override. Never bypass (`--no-verify`), never make a content-free change just to pass the gate (see [reasoning-integrity.md](../baseline/reasoning-integrity.md) → gate-gaming).

---

## Commit Message Format

```
<type>: <description>

<optional body>

Intellisense-Version: <version>
```

**Types:** Conventional Commits — `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

**Trailers:**

| Trailer | When | Example |
|---------|------|---------|
| `Intellisense-Version` | every Claude commit | `Intellisense-Version: 1.0.0` (read `version` from `~/.claude/config.json`) |
| `Intellisense-Metadata` | every Claude commit | single generated line (see below) |
| task trailer | Tier 1+, on every commit | a key from `evidence.task_trailers` in `.intellisense.yml`: `Task: PROJ-12`, `Refs: #123`, `Beads: intellisense-abc123` |
| `Change Contract` | Tier 1+, once per change | `Change Contract: scope=…, risk=…`, or the committed `.intellisense/contracts/<branch>.md` written by `/contract` |

> The `Intellisense-Version` / `Intellisense-Metadata` format is owned here; the Tier 1+ evidence is defined by the repository's `.intellisense.yml` (`intellisense classify` shows what a change needs). By default Tier 1+ needs a task trailer on each commit and a change contract; the pre-push hook and CI **block** a push without them. Tier 2 approval is the pull request's required review at merge, not a commit trailer.

Example:
```
feat: add idempotency check for balance deduction

Prevents duplicate deductions when the same request is retried.

Intellisense-Version: 1.0.0
Task: FN-123
Change Contract: scope=idempotent balance deduction, risk=high, confidence=0.85
```

Note: commit attribution is disabled globally via `~/.claude/settings.json`.

### Intellisense-Metadata inline trailer

Guarantees attribution reaches analytics even when the `prepare-commit-msg` hook is inactive (another tool such as Beads owns `core.hooksPath`, fresh clone, second machine, `--no-verify`).

**Behavior (trigger → action):**
- Before a normal commit → `bash "$INTELLISENSE_SETUP/scripts/intellisense-inline-trailer.sh"` (tier from staged files)
- Amending / repairing a commit → `bash "$INTELLISENSE_SETUP/scripts/intellisense-inline-trailer.sh" --commit HEAD`

Include its single `Intellisense-Metadata: {...}` line in the commit body exactly once (do not hand-carry a previous commit's trailer onto an amend). It carries `author_type=claude_inline` and omits tokens. When the intellisense hook is active it replaces this line with an accurate `claude_with_intellisense` trailer — so each commit ends with **exactly one** `Intellisense-Metadata` trailer.

---

## Branch Naming

Format: `<type>/<BOARD>-<TICKET>-intellisense-<description>`

> **MANDATORY:** every branch name MUST contain the literal `intellisense` marker, exactly as positioned above (between `<TICKET>` and `<description>`). Never create a branch without it — no exceptions.

| Segment | Source / rule |
|---------|---------------|
| `<type>` | `feat` · `fix` · `refactor` · `test` · `docs` · `chore` · `perf` · `ci` |
| `<BOARD>` | Jira board abbreviation (e.g. `FN` Finance, `MD` …) from the requirement / ticket |
| `<TICKET>` | ticket number from the requirement / ticket |
| `intellisense` | **required literal** — present in every branch name, never omitted |
| `<description>` | short kebab-case summary |

- BOARD or TICKET not provided → STOP, ask the user for the Jira ticket before creating the branch.
- Branch name about to be created without the `intellisense` marker → STOP, fix it before running `git checkout -b` / `git switch -c`.

Examples:
- `feat/FN-123-intellisense-idempotency-check-balance-deduction`
- `fix/FN-456-intellisense-tax-calculation-credit-notes`
- `refactor/MD-789-intellisense-extract-payout-cycle-validation`

---

## Pull Request Workflow

**Behavior (trigger → action):**
- Drafting the PR → base the summary on the full-history diff `git diff <base-branch>...HEAD`, not just the latest commit; link the Jira ticket
- New branch → `git push -u origin <branch-name>`
- Merging → **rebase merge only** (squash/plain merge destroys `Intellisense-Metadata:` trailers; see [development-workflow.md](./development-workflow.md) → Merge-Method Policy)

**Merge gate:**
- [ ] Review requested from the appropriate team members
- [ ] Human approval received — never self-merge
- [ ] All CI checks pass
- [ ] Merge method is rebase

---

## Safety

- [ ] Quality / security / testing checks complete (run in Phase 4 — do not commit if incomplete; see [development-workflow-impl.md](./development-workflow-impl.md) → Phase 4: Review)
- [ ] Never force-push to `main` / `master` / `develop`
- [ ] Use `--force-with-lease` (never plain `--force`) when a force is genuinely required
- [ ] Never skip pre-commit / pre-push hooks (`--no-verify`)
- [ ] Destructive action (force-push, branch delete, overwrite) → state it and ask the user yes/no first

---

> For the full development process (planning, TDD, code review) before git operations,
> see [development-workflow.md](./development-workflow.md) (Phases 0–1) and [development-workflow-impl.md](./development-workflow-impl.md) (Phases 2–6).
