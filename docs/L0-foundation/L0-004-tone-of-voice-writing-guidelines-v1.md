# L0-004 · Tone of Voice & Writing Guidelines

---
| Field | Value |
|---|---|
| Document ID | L0-004-tone-of-voice-writing-guidelines-v1 |
| Layer | L0 — Foundation Standards |
| Status | Final |
| Version | v1 |
| Created | 2026-10-30 |
| Last Updated | 2026-10-31 |
| Owner | Soupler |
| Reviewers | Soupler |
| Copyright | © 2026 Soupler. All rights reserved. |
| License | Apache-2.0 |
---

## Purpose

How intellisense is written — in docs, CLI output, commit messages and PRs.

## 1 · Voice

intellisense is an open-source tool, not a brand product, so it has no brand voice: it is written for the developer
reading it, in four qualities.

| Quality | We say | We don't say |
|---|---|---|
| **Plain** | "The push stops and says what's missing." | "Leverage seamless governance enforcement." |
| **Specific** | "A change to `payments/` needs a ticket and a change note." | "Risky changes need extra evidence." |
| **Direct** | "Run `intellisense sync`." | "You may want to consider running sync." |
| **Honest** | "Scoop is untested on Windows so far." | "Works everywhere." |

No marketing words (*seamless*, *powerful*, *revolutionary*), no exclamation marks, and no claims the code doesn't
back.

## 2 · Rules that apply to documentation regardless of brand voice

- Lead with the decision or the finding, then the evidence.
- Prefer concrete numbers and named things over adjectives.
- Say what is *not* known. A flagged gap beats a confident guess.
- Corrections are recorded in Version history with the date and the cause; never silently rewritten.
- One term per concept across all layers; define it once (L1/L2) and link to it.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Initial release from repo-governance v1.3.0 |
| v1 | 2026-10-31 | Soupler | Voice set for an open-source project (no brand voice); the gap is closed |
