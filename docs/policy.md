# Policy reference

`.intellisense.yml` at the repository root decides each change's risk tier and the evidence that tier needs. `intellisense init` writes the full default, with comments; every key is optional, and a key you leave out keeps its default. An unknown key is an error, so a typo never quietly falls back to a default. `intellisense policy show` prints the policy in effect, defaults included.

```yaml
version: 1
stacks: ['go']                       # rules vendored into .intellisense/rules/language-specific/
agents: ['claude', 'codex', 'copilot', 'cursor']
skills: ['plan', 'tdd']              # portable Claude Code skills, installed into .claude/skills/
minimum_tier: 0                      # every change is at least this tier
default_tier: 1                      # a file no rule matches
fast_lane: true                      # comment-only diffs of default-tier files drop to Tier 0
secrets: 'warn'                      # off | warn | block
blocked_remotes: []                  # e.g. ['upstream'] in a fork workflow
tiers:                               # any number of levels, 0-9
  - level: 2
    name: 'high risk'
    requires: ['task', 'contract']
    rules:
      - pattern: '(^|/)([Aa]uth|[Oo]auth|...)([._/-]|$)'
        reason: 'auth/identity'
  - level: 1
    name: 'standard'
    requires: ['task', 'contract']
    rules: [...]
  - level: 0
    name: 'routine'
    requires: []
    rules: [...]                     # docs and tests ("safe")
evidence:
  task_trailers: ['Task', 'Refs', 'Beads']
  verify_tasks: false                # ask integrations.tracker whether each task exists
  contract:
    marker: 'Change Contract'
    paths: ['.intellisense/contracts/']
    template: ''                     # your own template for `intellisense contract new`
    fields: [...]                    # what a contract must hold (see Contract)
  test_patterns: [...]               # what counts as a test, for tiers that require `test`
custom_stacks: []                    # your own languages
integrations:
  tracker: none                      # none | beads | github | jira | linear
  code_intel: none                   # none | code-review-graph (Live mode)
rules:
  disable: []                        # switch off vendored rules, e.g. ['operational/proof-standards']
```

## How a tier is decided

For each changed file (a rename counts as a delete of the old path and an add of the new one), the tiers are checked **from the highest level down**, and the first tier with a matching rule wins. A match in the level-0 tier makes the file *safe*. A file no rule matches gets `default_tier`.

Patterns are [RE2 regular expressions](https://github.com/google/re2/wiki/Syntax) matched against the repo-relative path with `/` separators. Anchor them: `(^|/)auth([._/-]|$)` matches `internal/auth/x.go` and `auth.go` but not `authors/index.md`.

**Fast lane.** A file that reached its tier only through `default_tier` drops to Tier 0 when every line its diff adds or removes is a comment in that file's language (`//`, `#`, `/* … */` on one line, `<!-- … -->`, or any line of a doc file). It does not drop when the diff contains a phrase like *disable*, *bypass*, *comment out* or *skip validation*, or a directive that silences a tool — `nolint`, `noqa`, `nosec`, `@ts-ignore`, `type: ignore`, `istanbul ignore`, `pragma: no cover` and similar (the full list is `DangerousPhrases` in `internal/tier/tier.go`): commenting code out or switching a check off is a behaviour change. Files matched by a rule never use the fast lane. Turn it off with `fast_lane: false`.

The change's tier is the highest file tier, raised to `minimum_tier`. `intellisense classify` shows the decision for every file:

```console
$ intellisense classify internal/auth/login.go docs/setup.md go.mod
Tier 2 — high risk
  Tier 2  internal/auth/login.go                           tier2     auth/identity
  Tier 0  docs/setup.md                                    safe      documentation
  Tier 1  go.mod                                           tier1     dependencies
requires: task + contract
```

## Adding a tier, or changing what one needs

`tiers:` is a list, so a repository can add a level or change a level's evidence without a code change. For example, a ledger that needs a changed test on top of the usual evidence:

```yaml
tiers:
  - level: 3
    name: 'critical'
    requires: ['task', 'contract', 'test']
    rules:
      - pattern: '(^|/)ledger/'
        reason: 'core ledger'
  - level: 2
    ...
```

Rules: levels are 0-9 and unique; `default_tier` and `minimum_tier` must be levels up to the highest one defined; a level the policy does not define needs what the nearest lower level needs. The list replaces the default list as a whole, so keep the tiers you still want (the file `init` wrote has them all).

## Evidence

| Kind | What the gate checks |
|---|---|
| `task` | Each commit at a tier that requires `task` **by its own changes** carries its own trailer, one of `evidence.task_trailers` (case-insensitive: `Task: PROJ-12`, `refs: #123`). One commit's trailer never covers another. |
| `contract` | The change carries one valid change contract (below), once per change. |
| `test` | The change adds or modifies at least one file matching `evidence.test_patterns`. |

Merge commits are not checked themselves; the commits they merge are. History from before the repository adopted intellisense is exempt from task trailers (see [adoption](#adoption)). Likely secrets are checked at every tier (see [secrets](#secrets)).

### Verifying task references

With `integrations.tracker` set and `evidence.verify_tasks: true`, the gate asks the tracker whether each reference exists, and blocks a commit that names one that does not:

| Tracker | How it asks | Needs |
|---|---|---|
| `github` | `gh issue view <n>` (`#12`, or `owner/repo#12`) | the `gh` CLI, logged in |
| `beads` | `bd show <id>` | the `bd` CLI |
| `jira` | `GET $JIRA_BASE_URL/rest/api/3/issue/<KEY>` | `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` |
| `linear` | the Linear GraphQL API | `LINEAR_API_KEY` |

When the tracker cannot be asked (tool missing, no token, network down) the gate warns instead of blocking. This is the only network call Core mode makes, and only when you turn it on.

## Contract

A change contract states what a change does and how risky it is. It lives either on one commit-message line:

```
Change Contract: scope=refund API, risk=high, confidence=0.8
```

or in a Markdown file under `evidence.contract.paths`, with the fields as front matter. `intellisense contract new "refund API"` writes one from the template:

```markdown
---
scope: refund API
risk: high
confidence: 0.8
---
# Change Contract: refund API
## What changes …
```

In Live mode, `/contract` writes the branch's contract as `.intellisense/contracts/<branch>.md` with more fields
(state, files, task binding); the gate reads it like any contract file, and accepts `requirement` and `risk_level`
for `scope` and `risk`.

Both forms are validated against `evidence.contract.fields`. A file that only mentions the marker, or a template whose placeholders (`'<scope>'`) are still there, is not a contract. The default fields:

```yaml
fields:
  - name: scope
    required: true
  - name: risk
    required: true
    values: [low, medium, high]
  - name: confidence
    type: number
    min: 0
    max: 1
  - name: files_affected
    type: integer
    min: 0
  - name: estimated_lines
    type: integer
    min: 0
```

A field has a `name`, optional `required`, a `type` (`string`, the default, `number` or `integer`), allowed `values` for strings, and `min`/`max` for numbers. Fields the spec does not name are free-form. `template:` points at your own Markdown template (`{{title}}` and `{{date}}` are filled in). `intellisense contract fields` lists what the policy requires; `intellisense contract check FILE` validates a file.

## Stacks

`stacks:` picks the language rules vendored into `.intellisense/rules/language-specific/`. Built in: `go`, `php` (Laravel), `angular`, `react`, `node`, `python`, `java` (and Kotlin), `flutter`, `rust`, `csharp`, `ruby`, `swift`, `cpp`. `init` detects them from files at the repository root (`go.mod`, `package.json`, `*.csproj` …).

For any other language, define a custom stack and keep its rule file in the repository:

```yaml
stacks: ['elixir']
custom_stacks:
  - name: elixir
    rule: elixir-patterns.md          # .intellisense/rules/language-specific/elixir-patterns.md
    globs: ['**/*.ex', '**/*.exs']   # the files the rule applies to
    markers: ['mix.exs']             # how `init` detects it
```

## Rules

`intellisense init` copies the built-in rules into `.intellisense/rules/` and records a checksum of each file in `.intellisense/rules/.checksums.json`.

- **Change a rule:** edit its file. `intellisense rules update` refreshes only the files you have not edited and lists the ones it kept; `--force` replaces them too.
- **Switch a rule off:** list it under `rules.disable` (its path under `.intellisense/rules/` without `.md`). An unedited copy is removed by the next `rules update`; agents never see a disabled rule.
- **Add your own:** put Markdown files in `.intellisense/rules/organization/`, optionally scoped with front matter (`globs: ["billing/**"]`). intellisense never writes there.

## Which policy judges a change

The gate reads the policy **from the base of the range** (the pull request's base, or the remote branch being pushed to), not from the change itself. A pull request that loosens `.intellisense.yml` is therefore judged by the old rules, and the loosening is itself Tier 2: it needs evidence and review. When the base has no policy (the adoption itself), the policy committed at the head is used. `intellisense gate --policy working` uses the working tree's file instead, for experimenting locally.

## Adoption

On the first push or pull request that adds `.intellisense.yml`, the commits before the adoption commit cannot carry trailers, so they are exempt; the adoption commit and everything after it are not. If the base already has a policy, nothing is exempt. Deleting the policy later does not exempt anything: the deletion is a Tier 2 change, and later commits are still checked against the base's policy.

## Secrets

With `secrets: warn` (the default) or `block`, added lines are checked for private keys, AWS access keys, GitHub and Slack tokens, and hard-coded credentials (`api_key = "…"`, `password: "…"`). A test fixture that has to look like a secret carries the comment `intellisense:allow-secret` on the same line. This is a last line of defence, not a secret scanner: keep running gitleaks or your platform's push protection.

## Blocked remotes

`blocked_remotes: ['upstream']` makes the pre-push hook refuse any push to a remote with that name, for fork workflows where everyone pushes to their own fork and opens a pull request. It is read from the working tree, since it is about where you push from.
