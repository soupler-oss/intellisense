# CI

The pre-push hook can be skipped (`git push --no-verify`), so the gate that counts runs in CI and is a required check.

## GitHub Actions

`intellisense init --ci` writes this to `.github/workflows/intellisense.yml`:

```yaml
name: Intellisense

on:
  pull_request:

permissions:
  contents: read

jobs:
  gate:
    name: Intellisense Gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: soupler-oss/intellisense@v2.0.0
```

Then make **Intellisense Gate** a required status check in your branch ruleset.

The action builds the CLI from its own source at the ref you pin, and runs `intellisense check`: the gate over the pull request's commits, plus `sync --check` on the agent instructions. It writes an annotation per problem, a job summary with the tier and the Tier 2 files, and two outputs:

| Output | Value |
|---|---|
| `tier` | `0`, `1` or `2` |
| `blocked` | `true` or `false` |

Use them to ask for more on high-risk changes, for example a second reviewer:

```yaml
      - uses: soupler-oss/intellisense@v2.0.0
        id: gate
      - if: steps.gate.outputs.tier == '2'
        run: gh pr edit "$PR" --add-label tier-2
        env: { GH_TOKEN: "${{ github.token }}", PR: "${{ github.event.pull_request.number }}" }
```

(That step needs `pull-requests: write`.)

### Inputs

| Input | Default | |
|---|---|---|
| `base` | the PR's base commit | Required outside `pull_request` events |
| `head` | the PR's head commit | |
| `check-sync` | `true` | `false` skips the agent-instructions check |
| `working-directory` | `.` | For a repository checked out into a subfolder |

### Security

- The workflow uses `pull_request`, not `pull_request_target`: a fork's PR gets a read-only token, and the gate needs nothing more (`contents: read`).
- The gate judges the PR by the **base branch's** policy, so a PR cannot loosen its own rules.
- Pin the action to a release tag (or a commit SHA, if your policy requires it). If the gate itself lives in the repository being checked, check it out from the base, as this repository does in [`.github/workflows/intellisense.yml`](../.github/workflows/intellisense.yml).

### Squash merges

The gate checks a pull request's own commits, before it merges, so it works with any merge method. If you also want the task trailers kept in the default branch's history, use rebase merging, or a squash message that keeps the commit bodies.

## Other CI systems

Run the CLI directly; it needs `git` and the history between base and head:

```bash
git fetch --unshallow || true
intellisense check --base "$BASE_SHA" --head "$HEAD_SHA" --format text   # or json
```

Exit codes: `0` passed, `1` blocked or instructions out of date, `2` error.
