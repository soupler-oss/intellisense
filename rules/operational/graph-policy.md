## Codebase Exploration (code graph, when the team chose it)

Skills name engineering questions; the upstream backend lives behind a single mapping file. See `@rules/operational/intelligence-sources.md` for the active question → provider table and `@rules/operational/graph-supported-stacks.md` for stack classification.

### When the graph applies

The code graph is optional: it is used only when the team chose `code-review-graph` as its code intelligence
(`intellisense live install --code-intel code-review-graph`, recorded in `~/.intellisense/integrations.env`). With
`none` (the default) nothing below applies, and `rg` / `Read` / `Glob` are the exploration tools.

When it was chosen, graph use is **required** only when ALL of these hold:

```
graph_required = intellisense_managed_repo
              AND mandatory_stack          (none by default — the organization opts a stack in via
                                             INTELLISENSE_GRAPH_MANDATORY_STACKS or intellisense.graph_mandatory_stacks)
              AND graph_native_workflow    (/code-review §Impact Analysis)
```

Otherwise the graph is advisory: used when it is ready, and a missing graph is reported, not blocking. No stack is
mandatory by default — `code-review-graph` is a single-maintainer third-party tool, and this framework does not make an
organization depend on it without opting in (see `@docs/CODE-REVIEW-GRAPH-INTEGRATION.md` § Third-party dependency).

### Graph-native workflows

| Workflow | Required engineering questions (per `intelligence-sources.md`) |
|---|---|
| `/code-review` §Impact Analysis | `change-spread`, `who-calls`, `what-changed-and-where-does-it-spread` |

Other skills (`/plan` blast-radius, `/multi-service-plan`, `/document-service`, `/diagnose`) may use the graph when it is ready, but never require it.

### Stack classification (lookup, not parsing)

- **mandatory-supported** (none by default; org opts in per-stack via `INTELLISENSE_GRAPH_MANDATORY_STACKS`, e.g. Go, Python once vetted): readiness enforced; missing/stale graph blocks graph-native skills.
- **candidate-supported** (TS/JS/Node/NestJS/React, Java/C#/Kotlin/Rust): graph built, readiness advisory, output marked `[INTELLISENSE-WEAK-STACK: <stack> — candidate stack, not yet validated for intellisense]`.
- **weak** (Laravel, Angular): graph built best-effort; output marked `[INTELLISENSE-WEAK-STACK: <stack> — <reason>]`. No exception required.
- **unsupported** (Vue): `setup-repos.sh` declines without `--graph-exception unsupported-stack`.

The `[INTELLISENSE-WEAK-STACK: ...]` advisory marker is computed once per repo by `scripts/lib/intellisense-graph.sh intellisense_graph_advisory_marker` and consumed by every skill, hook, and bootstrap output.

### Missing graph

- A graph-native skill missing a graph **asks for consent** (default `N`); if given, it runs `bash scripts/graph-bootstrap.sh --yes --repo <path> --stack <stack>` in the foreground. For a mandatory stack it stops instead, printing that command.
- The pre-push hook **warns** on a missing or stale graph; it blocks only for a mandatory stack with `intellisense.graph_enforcement=block`.

### Tool naming discipline (skill-only)

Skills MUST reference engineering questions defined in `@rules/operational/intelligence-sources.md` — they MUST NOT name upstream MCP tool names directly. Setup scripts, hooks, docs, and templates MAY name `code-review-graph` (they install / configure / document it). The lint in `scripts/validate-intellisense-content.sh` enforces the skill-only rule.

### Fallback policy

For Tier 0 work (per `@rules/operational/proof-standards.md` minimal path) and whenever the graph does not apply (above), `rg` / `Read` / `Glob` remain the primary exploration tools. Graph-first is **not** universal — small/config-only PRs and unsupported stacks legitimately read directly.

Pattern queries (regex / string / raw content) use `rg` regardless — graph is for structural questions, not text search.
