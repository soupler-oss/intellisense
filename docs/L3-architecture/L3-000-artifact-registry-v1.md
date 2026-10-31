# L3-000 · Architecture Artifact Registry

---
| Field | Value |
|---|---|
| Document ID | L3-000-artifact-registry-v1 |
| Layer | L3 — Architecture |
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

Registry of every artifact in layer **L3 — Architecture** (system design, ADRs, API contracts, data model, security architecture). This layer owns: *How the system is engineered: boundaries, API contracts, data model, security*. It does not own: Runbooks or GTM strategy.

**Every `.md` artifact under this folder — including numbered subfolders — must have a row below, in the same commit that creates it.** The Statutory Integrity gate (`bin/statutory-integrity.sh`) blocks the PR otherwise. When an artifact's own `Version` or `Last Updated` header changes, update its row here in the same commit.

## Registered Artifacts

| Document ID | Title | Status | Version | Owner | Last Updated |
|---|---|---|---|---|---|
| L3-001-system-architecture-v1 | System Architecture | Final | v1 | Soupler | 2026-10-30 |

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Registry created by repo-governance v1.3.0 |
