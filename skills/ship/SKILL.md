---
name: ship
description: Use when a change is ready to ship, to run the deterministic branch, test, commit, push and pull-request pipeline.
---

# /ship — Deterministic ship: branch → tests → commit → push → PR

Runs the deterministic shipping pipeline so the mechanical tail (trailer
discovery, ordering, failed pushes) never sends you spelunking through hooks.

## What it does

Invoke the orchestrator and surface its output **verbatim** — every failure line
already contains the exact next action:

```bash
bash "$REPO_ROOT/scripts/intellisense-ship.sh" [--dry-run] [--base <branch>]
```

Steps (each is a read-only preflight first; STOPS at the first failure):
1. **branch** — refuses the integration branch / detached HEAD / empty diff.
2. **fork remote** — origin must be your fork, distinct from upstream.
3. **Evidence preflight** — runs the same gate as pre-push (`intellisense gate`: a
   task trailer per Tier 1+ commit, the change contract) and checks the contract's
   state, so you learn what pre-push would reject *before* pushing.
4. **tests** — stack-inferred; never pushes red; unknown stack → refuses without
   `--skip-tests --ack-skip-tests`.
5. **push + PR** — pushes EXISTING commits to origin (fork) and opens the PR.

Ship ships **existing commits** — it refuses a dirty working tree (staged or
unstaged) and never creates a commit itself. This keeps trailers deterministic
(the commits the preflight validated are exactly what is pushed) and avoids an
interactive editor. Commit your work first (each Tier 1+ commit with its task trailer,
and the contract), then run `/ship`.

## Flags
- `--dry-run` — print the full plan (tier, contract status, selected tests,
  trailer preview, PR target) and **mutate nothing**.
- `--base <branch>` — PR base; set for **stacked PRs** (e.g. `--base feat/parent`).
- `--skip-tests --ack-skip-tests` — deliberately skip tests (both required).

## Hard guarantees (do NOT override)
The script **never** pushes to upstream, **never** force-pushes, **never** uses
`--no-verify`, and **never** auto-approves a contract — the human "proceed" on the
contract stays a real decision. `pre-push` remains the authoritative gate; `ship`
only mirrors it up front. Do not pass flags or edits that defeat these.

## Usage notes for Claude
- Run `--dry-run` first when unsure; show the plan to the user.
- If a step fails, relay the printed `Next:` line — do not improvise a bypass.
- This automates *ceremony*, not *judgment*: it does not replace `/contract`,
  approval, or understanding the change.
