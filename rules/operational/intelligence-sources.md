---
applies_to: [all]
phase: [0, 1, 2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: planning
---

# Intelligence Sources

Skills ask **engineering questions**. This file maps each question to its current backend provider. Skills name questions, not upstream tool names — keeping skill text durable across backend changes.

**Lazy population.** Only the questions used by `/code-review` §Impact Analysis are registered. Add rows when new workflows need them; never pre-populate.

## Questions

The provider is used only when the team chose `code-review-graph` as its code intelligence; otherwise answer the same questions with `rg` / `Read`.

| Engineering question | Purpose | Current provider | Provider call |
|---|---|---|---|
| **change-spread** | What does this change touch? Forward dependency analysis. | `code-review-graph` | `get_impact_radius_tool` |
| **who-calls** | Who calls this code? Backward dependency trace. | `code-review-graph` | `query_graph_tool` (pattern: `callers_of`) |
| **what-changed-and-where-does-it-spread** | Drift detection: what changed in this diff and where does the change propagate? | `code-review-graph` | `detect_changes_tool` |

## Provider configuration

| Field | Value |
|---|---|
| backend | `code-review-graph` |
| version pin | `==2.3.2` |
| install path | `setup.sh --code-intel code-review-graph` (uvx → pipx → pip --user) |
| MCP config | `~/.claude/settings.json` `mcpServers["code-review-graph"]` |
| per-repo data | `<repo>/.code-review-graph/graph.db` (gitignored, 5-50 MB) |
| status file (intellisense) | `.intellisense/graph-status.json` (gitignored runtime artifact) |
| exception file (intellisense) | `.intellisense/graph-exception.json` (committed; opt-out from graph use) |

## Skill conformance rule

**Skills (and only skills)** MUST reference engineering questions defined here, not upstream MCP tool names directly. The lint rule in `scripts/validate-intellisense-content.sh` enforces this on `skills/*/SKILL.md` files.

Setup scripts, hooks, docs, and templates MAY name `code-review-graph` directly — they install, configure, and document it.

## Adding a new question (lazy)

When a workflow needs a new question:

1. Add a row to the table above with the engineering name, purpose, current provider, and provider call.
2. Reference the engineering name in the skill text — never the provider call.
3. Do NOT pre-add rows for questions no workflow uses.

## Cross-references

- `@rules/operational/graph-supported-stacks.md` — which stacks support which questions
- `@rules/operational/graph-policy.md` — when graph use is required (full policy; pointer summary in `@rules/operational/development-workflow.md §Codebase Exploration`)
- `@docs/CODE-REVIEW-GRAPH-INTEGRATION.md` — backend install and opting in
