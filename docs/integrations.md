# Integrations

Intellisense works on its own with nothing else installed. Everything on this page is **optional and off by
default**: nothing is installed, called or sent unless you turn it on.

| Integration | What it gives you | Core mode | Live mode |
|---|---|---|---|
| [Task tracker](#task-trackers) | Commits point at real tickets; optionally checked to exist | ✓ | ✓ |
| [code-review-graph](#code-review-graph) | A map of your code, so reviews can answer "who calls this?" | — | ✓ |
| [Usage telemetry](#usage-telemetry) | Per-commit and per-day usage data for your own dashboard | — | ✓ |

---

## Task trackers

### What it is

Standard and high-risk changes need a **task reference**: a line at the end of the commit message that says which
ticket the work is for, such as `Refs: #42` or `Jira: PROJ-12`. The tracker setting decides which ticket system those
references point at:

| Tracker | Example reference | Good for |
|---|---|---|
| `none` (default) | `Task: anything` | Trying intellisense out, or teams without a ticket system. The reference is checked to be present, not to exist. |
| `github` | `Refs: #42`, `Fixes: #42` | Teams using GitHub Issues |
| `jira` | `Jira: PROJ-12` | Teams using Jira |
| `linear` | `Linear: ENG-12` | Teams using Linear |
| `beads` | `Beads: bd-a1b2` | A local, git-backed tracker that lives inside the repository — useful for solo developers and for AI assistants that file their own follow-up tasks |

### What it adds

- **The right trailer names.** Choosing a tracker sets `evidence.task_trailers` to the keys that tracker uses (for
  example `Jira`, `Task`, `Refs` for Jira).
- **Checking that tickets exist (optional).** With `evidence.verify_tasks: true`, the gate asks the tracker about each
  reference and blocks a commit that names a ticket that doesn't exist. This is the only network call Core mode ever
  makes. If the tracker can't be reached, the gate warns instead of blocking.

| Tracker | How it checks | What you need |
|---|---|---|
| `github` | `gh issue view <n>` | the `gh` CLI, logged in |
| `jira` | Jira REST API | `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` |
| `linear` | Linear GraphQL API | `LINEAR_API_KEY` |
| `beads` | `bd show <id>` | the `bd` CLI |

### Turn it on — Core mode

```bash
intellisense init --tracker github            # or jira, linear, beads
```

or in `.intellisense.yml`:

```yaml
integrations:
  tracker: github
evidence:
  task_trailers: ['Refs', 'Fixes', 'Task']
  verify_tasks: true                          # optional: check each ticket exists
```

### Turn it on — Live mode

```bash
intellisense live install --tracker beads
```

Only `beads` installs a tool (the `bd` CLI, and a `.beads/` folder in each repository you onboard). With Beads, Claude
also follows a short rule on when to open a ticket first and how to look for existing work (`bd ready`, `bd search`).

### Turn it off

Set `integrations.tracker: none` (and `verify_tasks: false`). Task references are still required for standard and
high-risk changes; they are just not checked against a tracker.

---

## code-review-graph

### What it is

[code-review-graph](https://pypi.org/project/code-review-graph/) is a third-party tool that builds a map of a
repository: which functions call which, and what a change reaches. With it, Claude's `/code-review` can answer "who
calls this function?" and "what else does this change affect?" from the map instead of searching text.

### What it adds

- An **impact analysis** step in `/code-review`.
- A graph built per repository when you onboard it, kept fresh by the push hook.
- A **warning** at push when the graph is missing or stale.

It is advisory by default: a missing graph warns, never blocks. Without it you lose nothing else — the same questions
are answered by searching the code.

### Turn it on — Live mode only

```bash
intellisense live install --code-intel code-review-graph
```

This installs `code-review-graph` (Python) and its MCP server. Record the choice for a repository in
`.intellisense.yml` with `integrations.code_intel: code-review-graph`. To make the graph **required** for some
languages, see [CODE-REVIEW-GRAPH-INTEGRATION.md](CODE-REVIEW-GRAPH-INTEGRATION.md#third-party-dependency--why-nothing-is-mandatory-by-default).

It is Live-mode only because the graph is used by Claude during a session (`/code-review`); Core mode's checks don't
need it.

### Turn it off

Reinstall with `--code-intel none` (or leave it out — `none` is the default). Nothing graph-related runs then.

Full details: [CODE-REVIEW-GRAPH-INTEGRATION.md](CODE-REVIEW-GRAPH-INTEGRATION.md).

---

## Usage telemetry

### What it is

For organizations that want to measure how AI-assisted development is going, Live mode can report usage to **your
own** collector. Intellisense ships no collector and no default address: without one, nothing is sent.

### What it adds

- **Commit metadata:** each commit made in a Live-mode session carries one `Intellisense-Metadata:` line — tier, which
  rules and skills were involved, token counts. It stays in your git history; nothing is sent.
- **A heartbeat:** up to three times a day, each developer's machine sends a small JSON summary (counts, never code or
  prompts) to your collector.

### Turn it on — Live mode only

Your platform admin gives you the collector's address and token:

```bash
INTELLISENSE_HEARTBEAT_ENDPOINT='https://…' INTELLISENSE_HEARTBEAT_TOKEN='…' intellisense live install
```

The exact data sent is documented field by field in [telemetry-contract.md](telemetry-contract.md).

### Turn it off

```bash
intellisense live install --no-heartbeat
```

Without an endpoint and token it is off anyway. Core mode never sends usage data.
