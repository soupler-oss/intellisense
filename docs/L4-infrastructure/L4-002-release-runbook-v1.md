# L4-002 · Release Runbook

---
| Field | Value |
|---|---|
| Document ID | L4-002-release-runbook-v1 |
| Layer | L4 — Infrastructure & Deployment |
| Status | Final |
| Version | v1 |
| Created | 2026-10-30 |
| Last Updated | 2026-10-30 |
| Owner | Soupler |
| Reviewers | Soupler |
| Copyright | © 2026 Soupler. All rights reserved. |
| License | Apache-2.0 |
---

## Purpose

How a version of intellisense is released and distributed. Update whenever the release workflow, the package channels
or their credentials change (L0-006 §3.4).

## 1 · Channels

| Channel | Where | Updated by |
|---|---|---|
| GitHub release | `soupler-oss/intellisense` releases: 6 archives (linux, darwin, windows × amd64, arm64), `checksums.txt` | `.github/workflows/release.yml` |
| Homebrew | `soupler-oss/homebrew-tap`, `Formula/intellisense.rb` → `brew install soupler-oss/tap/intellisense` | release workflow, with `HOMEBREW_TAP_TOKEN` |
| Scoop | `soupler-oss/scoop-bucket`, `bucket/intellisense.json` | release workflow, with `SCOOP_BUCKET_TOKEN` |
| `install.sh` | `curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh \| sh` | reads the latest release; checksum-verified |
| winget | manifests attached to each release (`Soupler.Intellisense`) | manual PR to `microsoft/winget-pkgs` — not yet submitted |
| GitHub Action | `uses: soupler-oss/intellisense@vX.Y.Z` | the tag itself |

## 2 · Credentials

- `HOMEBREW_TAP_TOKEN`, `SCOOP_BUCKET_TOKEN`: repository secrets on `soupler-oss/intellisense` holding one fine-grained
  token with **Contents: read and write** on `homebrew-tap` and `scoop-bucket` only. Renew it before it expires; without
  it the workflow still attaches the formula and manifest to the release, but the tap and bucket are not updated.
- The tap and bucket have no branch protection: the workflow pushes to their default branch.

## 3 · Releasing X.Y.Z

1. On a `chore/release-X.Y.Z` branch from `develop`: set `VERSION` to `X.Y.Z`, date the CHANGELOG entry
   (`## [X.Y.Z] - YYYY-MM-DD`), and move `[Unreleased]` notes into it. Pull request into `develop`; merge.
2. Pull request `develop` → `main` titled `release: vX.Y.Z`; merge with **Create a merge commit**.
3. Tag and publish (organization admins only — the `release-tags` ruleset):
   ```bash
   gh release create vX.Y.Z -R soupler-oss/intellisense --target main --title "vX.Y.Z" --notes-file <notes>
   ```
   The notes are the CHANGELOG entry for X.Y.Z.
4. The workflow checks the tag equals `v$(cat VERSION)`, runs `go test`, builds, attaches the files and updates the tap
   and the bucket. Watch it: `gh run list -R soupler-oss/intellisense --workflow Release`.
5. Verify from outside:
   ```bash
   brew update && brew install soupler-oss/tap/intellisense && intellisense version
   curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh | sh
   ```

## 4 · When it fails

- **Tag does not match VERSION**: delete the release and the tag, fix `VERSION` through a pull request, release again.
- **Tap or bucket not updated**: check the token secret exists and has not expired; re-run the failed job.
- **A bad release**: never move or reuse a tag. Fix forward with X.Y.Z+1.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Release runbook for 1.0.0: GitHub release, Homebrew, Scoop, install.sh |
