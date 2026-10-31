# Customization

Everything intellisense does in a repository is set in one file, `.intellisense.yml`. `intellisense init` writes it
with every setting and a comment on each. This page is a set of recipes: copy the snippet, change the names, commit.
Every key is described in the [policy reference](policy.md).

After any change:

```bash
intellisense policy validate      # catches typos and impossible settings
intellisense classify             # see how your current changes are judged
intellisense sync                 # only needed after changing agents, skills, stacks or rules
```

> Changing `.intellisense.yml` is itself a high-risk change: commit it with a task reference and a change contract,
> and expect review. The new rules apply to pull requests opened against the branch *after* it is merged.

---

## Mark a folder as risky

Your `ledger/` folder holds money logic but isn't named `payments`. Add a rule to the high-risk tier:

```yaml
tiers:
  - level: 2
    name: 'high risk'
    requires: ['task', 'contract']
    rules:
      - pattern: '(^|/)ledger/'
        reason: 'core ledger'
      # …keep the built-in rules that init wrote here
```

Patterns are regular expressions on the file path. Anchor them, so `(^|/)ledger/` matches `ledger/` and
`services/ledger/` but not `oldledger/`. Check with `intellisense classify services/ledger/post.go`.

To mark something as **routine** instead (generated code, fixtures), add it to the `level: 0` tier.

## Add a stricter tier

Some code is so critical that every change should also come with a test:

```yaml
tiers:
  - level: 3
    name: 'critical'
    requires: ['task', 'contract', 'test']
    rules:
      - pattern: '(^|/)ledger/'
        reason: 'core ledger'
  - level: 2
    # …the existing tiers stay below
```

The `tiers:` list replaces the default as a whole, so keep the tiers you still want.

## Require a changed test

Add `test` to a tier's `requires`. A change then has to add or modify at least one test file. By default a test is a
file in a `test/`, `tests/`, `__tests__/`, `spec/` or `testdata/` folder, or a file named like `x_test.go`,
`x.test.ts`, `x.spec.js`, `XTest.java`, `x_spec.rb` or `test_x.py`. To add your own convention, list it under
`evidence.test_patterns` together with the defaults (`intellisense policy show` prints them — the list replaces the
default as a whole):

```yaml
evidence:
  test_patterns:
    # …the defaults from `intellisense policy show`
    - pattern: '(^|/)e2e/'
      reason: 'end-to-end tests'
```

## Make everything at least "standard"

For a repository where every change is sensitive:

```yaml
minimum_tier: 1
```

## Change what a change contract must say

The default contract needs a `scope` and a `risk` (`low`, `medium` or `high`). Add your own fields — for example, a
required rollback plan and a reviewer:

```yaml
evidence:
  contract:
    fields:
      - name: scope
        required: true
      - name: risk
        required: true
        values: [low, medium, high]
      - name: rollback
        required: true
      - name: reviewer
```

Then a commit line looks like `Change Contract: scope=refunds, risk=high, rollback=feature flag off`.
`intellisense contract fields` shows what is required. For longer contracts, `intellisense contract new "<title>"`
writes a Markdown file from a template; point `evidence.contract.template` at your own.

## Check that tickets really exist

```yaml
integrations:
  tracker: github          # or jira, linear, beads
evidence:
  verify_tasks: true
```

Details, and what each tracker needs, are in [integrations.md](integrations.md#task-trackers).

## Add your own rules for the AI assistants

Write a Markdown file in `.intellisense/rules/organization/`. Limit it to some paths with front matter:

```markdown
---
globs: ["payments/**", "**/*.sql"]
---
# Payments

- Never log card numbers, CVVs or full bank account numbers.
- Amounts are integers in the smallest currency unit, never floats.
```

Run `intellisense sync`. Every assistant gets it in its own format. intellisense never edits this folder.

## Change or switch off a built-in rule

- **Change one:** edit its file under `.intellisense/rules/`. `intellisense rules update` keeps your version and tells
  you it did; `--force` replaces it (keeping a backup).
- **Switch one off:**

  ```yaml
  rules:
    disable: ['operational/proof-standards']
  ```

  `intellisense rules list` shows every rule and its name.

## Add a language

Built-in language rules: Go, PHP/Laravel, Angular, React, Node, Python, Java/Kotlin, Flutter, Rust, C#, Ruby, Swift,
C/C++. `init` detects them; to set them yourself:

```yaml
stacks: ['go', 'react']
```

For any other language, write the rule file and register it:

```yaml
stacks: ['elixir']
custom_stacks:
  - name: elixir
    rule: elixir-patterns.md         # .intellisense/rules/language-specific/elixir-patterns.md
    globs: ['**/*.ex', '**/*.exs']
    markers: ['mix.exs']             # how init detects it
```

## Choose which AI assistants get instructions

```yaml
agents: ['claude', 'codex', 'copilot', 'cursor']
```

Then `intellisense sync`. What each assistant's file contains is in [agents.md](agents.md).

## Add slash commands for Claude Code

```yaml
skills: ['plan', 'tdd', 'verify', 'security-scan']
```

Then `intellisense sync` installs them into `.claude/skills/`. `intellisense skills list` shows the ten available in
Core mode; the full set of 19 comes with [Live mode](live-mode.md).

## Secrets in commits

```yaml
secrets: block        # off | warn (default) | block
```

Added lines are checked for private keys, cloud and chat tokens and hard-coded passwords. A test fixture that has to
look like a secret carries the comment `intellisense:allow-secret` on that line. This is a last line of defence; keep a
real secret scanner (gitleaks, or GitHub push protection) as well.

## Stop pushes to the wrong remote

In a fork workflow everyone pushes to their own fork and opens a pull request upstream. Refuse direct pushes to the
upstream remote:

```yaml
blocked_remotes: ['upstream']
```

## Turn off the comment shortcut

By default, a comment-only edit to an ordinary file is routine (see the README's example 6). To make every edit count:

```yaml
fast_lane: false
```
