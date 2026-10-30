# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Branch rulesets restrict updates on `main` and `develop` to the organization admin, through a pull request only
  (`.github/governance/rulesets/`, described in `.github/PROTECTION_GUIDE.md`).

### Fixed
- Skills keep their front matter first when checked out with CRLF line endings (Windows); `.gitattributes` checks
  text files out with LF everywhere.
- CI, the release workflow and the GitHub Action build with the current stable Go, so macOS test binaries load.

### Changed
- README rewritten in plain language: what it does, six example scenarios, a five-minute start and a glossary, with
  the technical reference below. The winget command is no longer listed until the package is published.

## [1.0.0]

Risk tiers, evidence gates and shared rules for coding agents, in two modes that share one tier engine: **Core mode**
(per repository, any agent) and **Live mode** (Claude Code, at edit time).

### Added
- **Policy** (`.intellisense.yml`, `version: 1`): `tiers:` is a list of levels 0-9, each with a name, path rules and
  the evidence it `requires`, so a repository can add a tier or change what a tier needs without a code change.
  `intellisense policy show | validate | get`.
- **One tier engine** (`internal/tier`): path → tier, the comment-only fast lane and dangerous phrases. Live mode's
  hooks ask it through `intellisense classify --tier-only`, `check-phrase`, `check-comment-only` and `gate`.
- **Evidence kinds** as pluggable gate checks: `task` (a task trailer on each Tier 1+ commit), `contract` (one change
  contract per change) and `test` (the change touches a file matching `evidence.test_patterns`).
- **Contract schema**: `evidence.contract.fields` defines each field (required, string/number/integer, allowed
  values, min/max). Commit-line and Markdown contracts are validated against it. `intellisense contract new
  "<title>" | check | fields | show | set`. Contracts live in `.intellisense/contracts/<branch>.md`, committed with
  the change, and are read by the edit gate, the pre-push validator and the push/CI gate.
- **Integrations**, all optional: `integrations.tracker` (`none`, `beads`, `github`, `jira`, `linear`) with
  `evidence.verify_tasks: true` to check each task reference exists, and code intelligence (`none`,
  `code-review-graph`). Nothing is installed or checked unless chosen.
- **Agents**: instructions generated for Claude Code, Codex, Copilot and Cursor, with `sync` and drift checks.
- **Languages**: rules for Go, Laravel/PHP, Angular, React, Node, Python, Java, Flutter, Rust, C#/.NET, Ruby/Rails,
  Swift and C/C++, with Live-mode `CLAUDE.md` templates, and `custom_stacks:` for any other language from a rule
  file in the repository.
- **Rule control**: rules are vendored into `.intellisense/rules/`; `rules.disable` switches one off; `rules update`
  keeps files you edited (checksums in `.intellisense/rules/.checksums.json`), `--force` replaces them with a backup.
- **Skills** in Core mode: `skills:` installs portable Claude Code skills into `.claude/skills/`; `intellisense skills
  list`.
- **Guided CLI**: `intellisense` with no arguments shows the repository's status and the next command; `init` asks a
  few questions in a terminal (`--yes` for defaults); every command ends with "Next:"; `help <command>`; `doctor
  --fix` repairs a missing hook, stale instructions, missing rules and the CI workflow.
- **Gate everywhere**: a pre-push hook and a GitHub Action (`action.yml`) run the same `intellisense gate`; secrets in
  added lines are flagged; `blocked_remotes` refuses pushes to named remotes.
- **Live mode from the binary**: `intellisense live install | status | uninstall` unpacks the embedded platform to
  `~/.intellisense/platform/<version>` and runs its installer. It adds the prompt classifier, the PreToolUse contract
  gate, skills, agents, and optional telemetry. `intellisense live templates check | update [--force]` keeps the
  files `setup-repos.sh` copied in step with the platform.
- **Install**: `install.sh` (`curl … | sh`, checksum-verified; `INTELLISENSE_DOWNLOAD_BASE` for a mirror), and a
  Homebrew formula, a Scoop manifest and winget manifests built by the release workflow and attached to every
  release.
- **repo-governance integration**: a pre-push hook that already runs `intellisense gate` counts as installed.
