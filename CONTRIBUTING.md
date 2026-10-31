# Contributing

Thank you for your interest. This is an open-source project maintained by **Soupler**, licensed under the [Apache License 2.0](LICENSE).

## How changes get in

Only the maintainer can push to, approve changes on, or merge into this repository. Everyone else contributes through a fork:

```
your fork: feature branch  ->  PR into develop  ->  maintainer review  ->  develop  ->  (maintainer promotes) main
```

- **Fork** the repository and branch from `develop`: `<type>/<short-slug>` where type is `feat fix docs chore tech infra`.
- **Open your PR against `develop`.** The repository's default branch is `main` (it holds the released version), so
  GitHub preselects `main` as the base: change it to `develop`. PRs targeting `main` are rejected by the
  `Branch Policy` check; only the maintainer's `develop` → `main` promotion goes there.
- Branch protection applies to everyone: every change needs a pull request, the required checks (`Statutory Integrity`, `PR Metadata`, `Tests`, `Secret Scan`, `Intellisense Gate`, and `Branch Policy` for `main`) must pass, and the maintainer must approve. Release tags (`v*`) can only be created by the maintainer.
- First-time contributors' workflow runs need the maintainer's approval before they start.

## This repository gates itself

intellisense runs its own gate on its own pull requests (`.intellisense.yml`, `.github/workflows/intellisense.yml`). Most code changes are Tier 1 and changes to the gate itself (`internal/gate`, `internal/tier`, `internal/policy`, `internal/hook`, `hooks/pre-push`, the Live-mode tier libraries, `rules/baseline/`) are Tier 2. Both need, in your commit messages:

```
Refs: #123
Change Contract: scope=<what changes>, risk=low|medium|high, confidence=0.8
```

`Refs:` goes on **each** Tier 1+ commit; the contract goes on one. Docs and tests alone need neither. Check before you push:

```bash
go run ./cmd/intellisense classify            # your working tree
go run ./cmd/intellisense gate --base origin/develop
```

## Before you open a PR

```bash
bash bin/install-hooks.sh          # once per clone: commit-msg, pre-commit (gitleaks) and pre-push (this repo's gate)
bash scripts/ci/test.sh            # Go suite + Bash suite (tests for optional tools skip when they are missing)
bash scripts/ci/lint.sh            # gofmt, go vet, bash -n, JSON
bash bin/statutory-integrity.sh    # the docs gate CI runs
```

- **PR title** is a Conventional Commit: `type(scope): short imperative description` (`feat fix docs chore tech infra refactor test ci build perf`).
- **PR body** keeps the template's `## Docs update` block with `- Status: UPDATED` or `- Status: EXEMPT` and real `- Notes:`. No AI attribution in commits or PR text.
- **Every behaviour change has a test that fails without it.** Gate behaviour is tested against real repositories and real `git push` (see `internal/cli/cli_test.go`), not by asserting on strings alone.
- **Update `CHANGELOG.md`**, and bump `VERSION` when behaviour changes (patch: fixes; minor: new options or rules; major: an existing policy, rule or generated file changes meaning).
- **Stay generic.** No company-, product- or person-specific names, repos or examples anywhere; use neutral placeholders (`Example Org`, `orders-service`, `PROJ-123`).
- **Keep the CLI small.** Go standard library plus `gopkg.in/yaml.v3`; a new dependency needs an issue first.
- Read [`CLAUDE.md`](CLAUDE.md) for the architecture before changing rules, skills or templates: rule changes reach every governed repository.

## Good first contributions

- **A stack**: a rule file under `rules/language-specific/` plus its entry in `internal/policy/stacks.go` (name, globs, marker files).
- **An agent adapter**: a new output in `internal/adapters/` with its tests, and a row in [docs/agents.md](docs/agents.md).
- **A CI system**: a documented recipe in [docs/ci.md](docs/ci.md) for GitLab, Bitbucket or Azure Pipelines.
- **A tier false positive**: a failing case in `internal/tier/tier_test.go`, then the pattern fix.

## Licensing of contributions

Unless you state otherwise, any contribution you intentionally submit for inclusion is licensed under the Apache License 2.0, as described in section 5 of the license, without additional terms. By opening a PR you confirm you have the right to submit it under that license.

## Reporting problems

- Bugs and ideas: open an issue using the templates.
- **Security vulnerabilities: do not open a public issue**; see [SECURITY.md](SECURITY.md).

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Questions and ideas that aren't bugs go to [Discussions](https://github.com/soupler-oss/intellisense/discussions).
