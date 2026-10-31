# L0-010 · Repository Topology

---
| Field | Value |
|---|---|
| Document ID | L0-010-org-repo-topology-v1 |
| Layer | L0 — Foundation Standards |
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

Which repositories make up Soupler, what each owns, and which direction truth flows. This is the document behind every "never modify a sibling from here" rule in the repos' `CLAUDE.md` files.

<!-- gov:begin topology -->
- **`intellisense`** — profile `package`: Agent-neutral AI coding governance: risk tiers, evidence gates, CI checks and rules for Claude Code, Codex, Copilot and Cursor.
<!-- gov:end topology -->

Standards (L0) live in **`intellisense`**.

## Rules

1. One repository owns each fact; others follow. Following never edits the owner.
2. Locally the repos are siblings under one parent directory (`../<repo>`); tooling and docs refer to siblings by that relative path.
3. A change that spans repos is made in the owner first, then in each follower, as separate PRs in their own repositories.
4. Cross-origin calls between a client repo and an API repo require the API's allowed-origins list to be updated in the same change.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Initial release from repo-governance v1.3.0 |
