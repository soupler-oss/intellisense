# L4-000 · Infrastructure & Deployment Artifact Registry

---
| Field | Value |
|---|---|
| Document ID | L4-000-artifact-registry-v1 |
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

Registry of every artifact in layer **L4 — Infrastructure & Deployment** (environments, CI/CD, infrastructure-as-code, deployment runbooks, cost). This layer owns: *How engineering work is provisioned and deployed*. It does not own: Product intent or architecture decisions.

**Every `.md` artifact under this folder — including numbered subfolders — must have a row below, in the same commit that creates it.** The Statutory Integrity gate (`bin/statutory-integrity.sh`) blocks the PR otherwise. When an artifact's own `Version` or `Last Updated` header changes, update its row here in the same commit.

## Registered Artifacts

| Document ID | Title | Status | Version | Owner | Last Updated |
|---|---|---|---|---|---|
| L4-001-local-dev-setup-v1 | Local Development Setup & Smoke Runbook | Final | v1 | Soupler | 2026-10-30 |
| L4-002-release-runbook-v1 | Release Runbook | Final | v1 | Soupler | 2026-10-30 |

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Registry created by repo-governance v1.3.0 |
