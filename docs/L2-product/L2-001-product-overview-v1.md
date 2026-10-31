# L2-001 · Product Overview

---
| Field | Value |
|---|---|
| Document ID | L2-001-product-overview-v1 |
| Layer | L2 — Product Requirements |
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

What intellisense is, who it is for and what it must do. The README explains the product to users; this document is
the requirement it is built against. Change a requirement here first, then the architecture (L3) and the code.

## 1 · Problem

Coding agents change risky code (auth, money, migrations, secrets) with the same confidence as a typo fix, and nothing
records which kind of change happened. Each agent reads its own instruction file, so a team's rules drift apart.

## 2 · Users

| User | Needs |
|---|---|
| Developer using an AI assistant | Routine changes go straight through; a blocked push says exactly what to add. |
| Tech lead / maintainer | Risky changes arrive with a task and a stated scope and risk; one rule set for every assistant. |
| Organisation running many repositories | The same gate locally and in CI; policy per repository; works with or without repo-governance. |

## 3 · Requirements

| ID | Requirement |
|---|---|
| R1 | Every change gets a risk tier from the paths it touches, using rules in `.intellisense.yml`. Tiers, their names and the evidence each needs are configurable. |
| R2 | A Tier 1+ change needs the evidence its tier requires (by default a task reference on each commit and one change contract). Missing evidence blocks the push and names the fix. |
| R3 | The same gate runs at `git push` and in CI. CI judges a pull request by the policy on its base branch. |
| R4 | One rule set is written into each supported agent's own format (Claude Code, Codex, Copilot, Cursor), with a drift check. |
| R5 | Intellisense works standalone. repo-governance is an optional integration, never a dependency. |
| R6 | Optional tools (task trackers, code intelligence, telemetry) are off unless chosen. Core mode makes no network call unless `verify_tasks` is on. |
| R7 | Installs as one binary on macOS, Linux and Windows (Homebrew, Scoop, `install.sh`, `go install`). |
| R8 | Live mode adds checks during a Claude Code session using the same tier engine and policy. |
| R9 | Local edits to vendored rules and templates survive updates. |

## 4 · Out of scope

- Reviewing the code itself: intellisense checks that evidence exists, not that the change is correct.
- Repository scaffolding, documentation layers and branch rules: that is repo-governance.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Initial product overview for 1.0.0 |
