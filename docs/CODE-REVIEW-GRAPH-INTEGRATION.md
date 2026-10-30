# Code-Review-Graph in intellisense

`code-review-graph` is an **optional** code-intelligence tool for Live mode. A team that chooses it gets a structural
graph of each repository, and `/code-review` uses it to answer *who calls this* and *what does this change touch*.
A team that does not choose it loses nothing else: the same questions are answered with `rg` / `Read`.

Skills name engineering questions, not tool names; the backend lives behind one mapping file
(`rules/operational/intelligence-sources.md`).

---

## Choosing it

```bash
intellisense live install --code-intel code-review-graph    # or: bash setup.sh --code-intel code-review-graph
```

The choice is recorded in `~/.intellisense/integrations.env` (`INTELLISENSE_CODE_INTEL`). With `none`, the default:
setup installs nothing, `setup-repos.sh` builds no graph, the pre-push hook and `intellisense-health.sh` report
nothing about graphs, and `/code-review` skips its Impact Analysis step.

### Third-party dependency — why nothing is mandatory by default

`code-review-graph` is a single-maintainer, MIT-licensed, third-party tool (see Upstream below) — not something
intellisense controls or can guarantee will keep being maintained. So even when chosen, every stack tops out at
**candidate-supported** by default (built, advisory, never blocking).

An organization that has evaluated the tool and wants hard enforcement for a stack opts in explicitly:

```bash
INTELLISENSE_GRAPH_MANDATORY_STACKS="go python" bash setup-repos.sh --repo /path/to/repo --stack go
```

Record a standing choice in `rules/organization/` (or `intellisense.graph_mandatory_stacks` in
`~/.claude/settings.json`) rather than passing the env var by hand. Clear the validation bar in "Candidate → Mandatory
Promotion" (`rules/operational/graph-supported-stacks.md`) first.

---

## When the graph is required

With the graph chosen, graph use is required when **all** hold:

```
graph_required = intellisense_managed_repo
              AND mandatory_stack
              AND graph_native_workflow       (/code-review §Impact Analysis)
```

Otherwise it is advisory. See `rules/operational/graph-policy.md` for the canonical statement.

### Stack matrix

| Stack | Status | Behavior |
|---|---|---|
| Any stack the organization lists as mandatory | mandatory-supported | Graph built; readiness enforced |
| Go, Python, TS / JS / Node / NestJS / React, Java / C# / Kotlin / Rust | candidate-supported | Built, readiness advisory, output marked `[INTELLISENSE-WEAK-STACK: ... — candidate stack, not yet validated for intellisense]` |
| Laravel / PHP, Angular, Flutter / Dart | weak | Best-effort build, output marked `[INTELLISENSE-WEAK-STACK: ... — <reason>]`; **no exception required** |
| Vue 2/3 | unsupported | `setup-repos.sh` declines without `--graph-exception unsupported-stack` |
| Other (Solidity, GDScript, etc.) | case-by-case | Decided per repo |

Source of truth: `rules/operational/graph-supported-stacks.md`.

### Enforcement at push

The pre-push hook **warns** on a missing or stale graph in an intellisense-managed repo of a supported stack. It
**blocks** only for a mandatory stack with `intellisense.graph_enforcement=block` in `~/.claude/settings.json`.

---

## Version Pin

```
code-review-graph==2.3.2
```

Exact pin, not a range. The version lives in three places that must be updated together:

- `setup.sh` (`CRG_REQUIRED_VERSION`)
- `scripts/lib/intellisense-graph.sh` (`intellisense_graph_required_version`)
- `rules/operational/intelligence-sources.md` (Provider configuration table)

Floor bumps require `verify-setup.sh` against the new version on at least one repo per supported stack, PR review,
and all three files updated in one commit.

---

## Install

With `--code-intel code-review-graph`, `setup.sh` tries, in order:

1. **uv tool install** (preferred when `uv` is on PATH; modern, isolated)
2. **pipx install** (canonical isolated Python tools)
3. **pip install --user** (last resort; works in locked-down environments)

After a successful install, the binary lives at `~/.local/bin/code-review-graph` and the MCP config is written to
`~/.claude/settings.json`. If all three fail, setup stops with the remediation for each path. `setup-repos.sh`
re-detects the install on every run (they are separate processes and share no state).

### IT prerequisites

- Python ≥ 3.10 (upstream requirement).
- Network access to PyPI for the install.
- Either `pipx`, `uv`, or `pip` on PATH; `~/.local/bin` writable.

---

## Per-Repo Onboarding

```bash
bash setup-repos.sh --repo <path> --stack <stack> --code-intel code-review-graph [--migrate] [--repair]
```

1. Stack detection and classification (`scripts/lib/intellisense-graph.sh intellisense_graph_stack_support`).
2. intellisense-managed marker written: `<!-- INTELLISENSE-MANAGED -->` in `CLAUDE.md`, or `.intellisense/MANAGED`
   with `--skip-claude-md`.
3. `code-review-graph build` via `scripts/graph-bootstrap.sh`, with streamed progress.
4. `.gitignore` gains `.code-review-graph/` and `.intellisense/graph-status.json` if missing.
5. Readiness checked (below) and `.intellisense/graph-status.json` written with build metadata and the advisory marker.

`--migrate` adds the graph to a repo onboarded earlier; existing `CLAUDE.md` and `knowledge-base/` content is kept.

### Readiness criteria

A graph is "ready" iff ALL of:

1. `code-review-graph build` exit code 0.
2. `nodes >= minimal_stack_threshold` (default 50 for known stacks; per-repo override via `--min-nodes <N>`).
3. `last_updated` timestamp present and within 10 minutes of build completion.

### Exception path (opt-out, not weak-stack)

```bash
bash setup-repos.sh --migrate --graph-exception unsupported-stack \
    --owner <email> --expires <YYYY-MM-DD>
```

Writes `.intellisense/graph-exception.json` (committed; NOT gitignored). The graph build is skipped. Skills detect the
file and run with read-only fallback marked `[INTELLISENSE-WEAK-STACK: <stack> — exception mode (...)]`.

Weak stacks (Laravel, Angular) do **not** need an exception — they build best-effort and output is marked. The
exception is for repos opting out of graph use entirely.

---

## Storage Layout

### Per-repo (graph data)

```
<repo>/.code-review-graph/
├── graph.db           ← SQLite database (5–50 MB)
├── graph.db-wal
└── graph.db-shm
```

**Gitignored** — `setup-repos.sh` adds `.code-review-graph/` to the repo's `.gitignore` if missing.

### Per-repo (intellisense metadata)

```
<repo>/.intellisense/
├── MANAGED              ← committed (governance boundary)
├── graph-exception.json ← committed (auditable opt-out, time-bound)
└── graph-status.json    ← gitignored (runtime artifact, regenerated each build)
```

### `.intellisense/graph-status.json` schema

```json
{
  "stack": "go",
  "stack_support": "mandatory-supported" | "candidate-supported" | "weak" | "unsupported",
  "nodes": 24881,
  "built_at_utc": "2026-05-07T03:14:00Z",
  "upstream_last_updated": "2026-05-07T03:14:00Z",
  "build_exit_code": 0,
  "readiness": "ready" | "failed" | "skipped",
  "build_time_ms": 47000,
  "min_nodes_threshold": 50,
  "min_nodes_override": null,
  "advisory": "[INTELLISENSE-WEAK-STACK: ...]" | null
}
```

- `built_at_utc` is **authoritative** for freshness checks (written by `setup-repos.sh` via `date -u +%Y-%m-%dT%H:%M:%SZ`).
- `upstream_last_updated` is provider metadata; diagnostic only.

### Per-user (small registry, no source code)

```
~/.code-review-graph/
├── registry.json     ← multi-repo list for cross_repo_search_tool
├── watch.toml        ← daemon config
├── daemon.pid
└── logs/             ← watcher logs (paths only)
```

---

## Bootstrap Script (`scripts/graph-bootstrap.sh`)

Non-interactive: the skill / assistant flow asks for consent; this script just runs when called.

```bash
bash scripts/graph-bootstrap.sh \
    --repo <path> --stack <stack> \
    [--yes] [--min-nodes <N>] [--skip-flows]
```

Idempotent. Called by `setup-repos.sh` (onboarding, `--migrate`, `--repair`), by a developer fixing a stale graph,
and by `/code-review` after the user consents.

Exit codes:

- `0` — success (graph ready, or skipped for exception path)
- `1` — prerequisite failed (no binary, wrong version, repo not intellisense-managed, unsupported stack without exception)
- `2` — bad arguments
- `3` — build or readiness failed for a mandatory-supported stack

---

## Universal Advisory Marker

```
[INTELLISENSE-WEAK-STACK: <stack> — <reason>]
```

Required prefix on any graph-derived output when ANY of:

- Stack classified `weak` (Laravel, Angular, Flutter).
- Stack classified `candidate-supported` and not yet validated.
- `.intellisense/graph-exception.json` present.
- Graph built with `--min-nodes <N>` below the stack default.

Composed once per repo by `scripts/lib/intellisense-graph.sh intellisense_graph_advisory_marker` and emitted by all
consumers (skills, hooks, bootstrap output, status JSON `advisory` field), so prefixing is consistent.

---

## Health and exceptions

```bash
bash scripts/intellisense-health.sh --format graph <path>    # graph state for one repo
bash scripts/intellisense-health.sh --exceptions <path>      # every graph-exception.json under <path>, with owner and expiry
```

Exceptions carry an owner and an expiry date; review the roster before each expiry.

## Turning it off

Re-run `intellisense live install --code-intel none` (or `bash setup.sh --code-intel none`). Graph checks stop; the
per-repo `.code-review-graph/` data can be deleted. Rules, skills, agents and the tier gate are unaffected.

---

## Cross-References

- **Stack classification rule:** `rules/operational/graph-supported-stacks.md`
- **Engineering-question vocabulary:** `rules/operational/intelligence-sources.md`
- **Graph policy:** `rules/operational/graph-policy.md` (full policy); pointer summary at `rules/operational/development-workflow.md §Codebase Exploration`
- **Upstream:** [tirth8205/code-review-graph](https://github.com/tirth8205/code-review-graph) (MIT, 100% local)
