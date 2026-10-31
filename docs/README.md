# Documentation

Every intellisense document, by what you want to do.

## Start

| Document | For |
|---|---|
| [README](../README.md) | What intellisense is, six example scenarios, the five-minute start |
| [Quick start](../QUICK_START.md) | Your first ordinary, standard and high-risk change |
| [Installation](../INSTALLATION.md) | Every install method, step by step, for both modes |

## Set it up your way

| Document | For |
|---|---|
| [Customization](customization.md) | Recipes: risky folders, extra tiers, required tests, contract fields, your own rules, languages, assistants, slash commands, secrets, remotes |
| [Policy reference](policy.md) | Every setting in `.intellisense.yml`, and exactly how a tier is decided |
| [Integrations](integrations.md) | Ticket systems (GitHub, Jira, Linear, Beads), code-review-graph, usage telemetry — what each is and how to turn it on or off |
| [Agents](agents.md) | What Claude Code, Codex, Copilot and Cursor each receive |
| [CI](ci.md) | The GitHub Action, making it a required check, other CI systems |

## Claude Code (Live mode)

| Document | For |
|---|---|
| [Live mode](live-mode.md) | What Live mode adds, installing it, per-repository rules and templates, optional tools |
| [Development workflow](WORKFLOW.md) | The ten-step path from requirement to pull request with the slash commands |
| [code-review-graph in depth](CODE-REVIEW-GRAPH-INTEGRATION.md) | Supported languages, making the graph required, storage, health checks |
| [Telemetry contract](telemetry-contract.md) | Every field of the commit metadata and the heartbeat, for whoever runs the collector |
| [Adding a language](language-support-onboarding.md) | Adding a new language to Live mode's rules and templates |

## Teams and repositories

| Document | For |
|---|---|
| [Fork workflow](fork-workflow.md) | Contributors pushing to forks; blocked remotes; branch protection |

## How intellisense itself is built

| Layer | Contents |
|---|---|
| [L0 standards](L0-foundation/) | How documents in this repository are written, named and governed |
| [L2 product](L2-product/) | Product overview: the problem, users, requirements |
| [L3 architecture](L3-architecture/) | Components, data ownership, architecture decisions (ADR-001–006) |
| [L4 infrastructure](L4-infrastructure/) | Local setup and smoke tests; the release runbook |
| [L6 remediation](L6-remediation/) · [L6.1](L6.1-remediation-execution/) · [L7](L7-forensics/) | Audits, fixes and their evidence for security reports and review findings |
