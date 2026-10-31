# L3-001 · System Architecture

---
| Field | Value |
|---|---|
| Document ID | L3-001-system-architecture-v1 |
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

The map of intellisense: components, boundaries and the decisions behind them. Update this whenever a boundary or
diagram stops being true (L0-006 §3.3). Requirements live in L2-001.

## 1 · Components and boundaries

| Component | Owns | Calls | Must not touch |
|---|---|---|---|
| `internal/policy` | `.intellisense.yml`: tiers, evidence, contract schema, stacks, integrations, rule disables | — | git, the network |
| `internal/tier` | Path → tier, the comment-only fast lane, dangerous phrases. **The only tier engine.** | `policy` | — |
| `internal/gate` | Evidence checks (task, contract, test), secret detection, pre-push ranges, report formats | `tier`, `contract`, `tracker`, git | — |
| `internal/contract` | Contract parsing (commit line, Markdown front matter), schema validation, templates | `policy` | — |
| `internal/tracker` | Optional task verification (beads, github, jira, linear) | the chosen tracker's API | anything unless `verify_tasks` is on |
| `internal/rules` | Vendoring built-in rules with checksums, discovering rules, link localisation | — | `rules/organization/` |
| `internal/adapters` | Per-agent outputs, managed blocks, sync and drift | `rules`, `policy` | files outside the managed blocks |
| `internal/skills` | Portable Claude Code skills installed by `sync` | — | — |
| `internal/hook` | Installing, chaining and removing the pre-push hook | git | other hooks' content |
| `internal/cli` | Commands, help, "Next:" guidance, `live install` | all of the above | — |
| Live mode (Bash: `hooks/`, `scripts/`, `setup.sh`) | Prompt classifier, PreToolUse contract gate, skills, agents, optional telemetry | the Go binary for every tier decision | its own tier patterns (forbidden) |
| `action.yml` | The GitHub Action: builds the binary at the pinned ref and runs `intellisense check` | the binary | — |

## 2 · Data ownership

| Data | Owner | Where |
|---|---|---|
| Policy | the repository | `.intellisense.yml` |
| Vendored rules and their checksums | `internal/rules` | `.intellisense/rules/`, `.intellisense/rules/.checksums.json` |
| Change contracts | the change | commit message line, or `.intellisense/contracts/<branch>.md` |
| Agent instruction files | `internal/adapters` (managed blocks only) | `CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `.cursor/rules/` |
| Live mode install | Live mode | `~/.intellisense/`, linked into `~/.claude/` |

## 3 · Architecture Decision Records

### ADR-001 — One tier engine, in Go
- **Status**: Accepted
- **Context**: Live mode started as Bash with its own tier patterns. Two copies of the tier logic disagreed.
- **Decision**: `internal/tier` is the only tier engine. Live mode's Bash calls `intellisense classify --tier-only`, `check-phrase`, `check-comment-only` and `gate`.
- **Consequences**: an edit, a push and CI always agree. Live mode needs the binary. `tests/test_fast_lane_agreement.sh` fails if a pattern table reappears in Bash.

### ADR-002 — Policy lives in the repository and CI reads it from the base branch
- **Status**: Accepted
- **Context**: a pull request could otherwise loosen the rules it is judged by.
- **Decision**: each repository owns `.intellisense.yml`; CI evaluates a pull request against the policy on its base branch. Changing the policy is itself Tier 2.
- **Consequences**: rule changes need their own reviewed change before they take effect.

### ADR-003 — Two modes, one policy
- **Status**: Accepted
- **Context**: teams use many agents; Claude Code allows checks during the session.
- **Decision**: Core mode (per repository, any agent, push and CI) and Live mode (per machine, Claude Code, edit time) share one engine and one policy.
- **Consequences**: Core mode stays agent-neutral and dependency-free; Live mode features are additive.

### ADR-004 — Split paths for Live mode rules
- **Status**: Accepted
- **Context**: everything under `~/.claude/` loads into every session and costs tokens.
- **Decision**: baseline rules go to `~/.claude/rules/baseline/`; operational and language rules stay in `~/.intellisense/rules/` and load on demand.
- **Consequences**: do not move those paths into `~/.claude/`.

### ADR-005 — Vendored rules with checksums
- **Status**: Accepted
- **Context**: updates used to overwrite rules a team had edited.
- **Decision**: rules are copied into each repository with checksums; updates replace only unedited files, `--force` keeps a backup, `organization/` is never touched.
- **Consequences**: teams own their copies; updates report what they kept.

### ADR-006 — Integrations are optional and off by default
- **Status**: Accepted
- **Context**: trackers and code intelligence were once installed unconditionally.
- **Decision**: `integrations.tracker` and code intelligence default to `none`; nothing is installed or called unless chosen.
- **Consequences**: intellisense works offline and standalone; each integration is tested on its own.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Components, data ownership and ADR-001–006 for 1.0.0 |
