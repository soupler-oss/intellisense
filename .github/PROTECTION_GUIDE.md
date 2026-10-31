# Branch Protection Guide

Soupler uses **GitHub Flow with a promotion branch**: feature → `develop` → `main`. The default branch is `main`, so
visitors see the released version; pull requests target `develop` (the `Branch Policy` check rejects anything else
into `main`). Protection is enforced by **repository rulesets**, not classic branch protection — `gh api repos/.../branches/<branch>/protection` returns 404 by design.

## Rulesets (source of truth: `.github/governance/rulesets/*.json`)

| Ruleset | Target | What it enforces |
|---|---|---|
| `main-develop-protection` | `develop` | PR required (code owner, last push approved, threads resolved) · only the organization admin can merge · squash/rebase only · linear history · no force-push · required checks |
| `main-protection` | `main` | PR required · only the organization admin can merge · merge commits only · no force-push · required checks incl. `Branch Policy` |
| `main-develop-undeletable` | `main`, `develop` | deletion blocked, no bypass actors |
| `release-tags` | `v*` tags | only the maintainer (organization admin) may create, move or delete a release tag |

Required checks: `Statutory Integrity` · `PR Metadata` · `Secret Scan` · `Tests` · `Branch Policy` (main only) · `Intellisense Gate` (develop only).

`Intellisense Gate` is this repository running its own gate on itself (`.github/workflows/intellisense.yml`, `uses: ./`): a pull request must carry the evidence its risk tier needs under `.intellisense.yml`.

## Who can merge

Both branch rulesets carry **Restrict updates**: only the bypass actor — the organization admin, and only through a pull request — can change `main` or `develop`. Nobody pushes directly, and a collaborator's approved pull request still waits for the admin to merge it.

## What a ruleset cannot do

A ruleset has no concept of a PR's head branch, so "only `develop` may PR into `main`" is enforced by `.github/workflows/branch-policy.yml`.

## Applying and changing

```bash
gov github .                                   # from repo-governance: create/update the rulesets
gh api repos/soupler-oss/intellisense/rulesets      # inspect
```

When a required job is renamed in a workflow, update the matching ruleset JSON in the same PR — a renamed job that is not in the ruleset silently stops being enforced.

## Release

`develop` → `main` PR titled `release: vX.Y.Z …`, merge commit, then tag `main`. Every `v*` tag needs a `CHANGELOG.md` entry.
