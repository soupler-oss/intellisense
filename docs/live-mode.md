# Live mode

Live mode installs intellisense into Claude Code itself, for every repository on a developer's machine. On
top of what [Core mode](../README.md#quick-start) gives every agent (rules, the pre-push gate, the CI
check), it adds what only Claude Code's hooks can do:

- a **prompt classifier** that tiers each request before Claude starts (`scripts/userPromptSubmit-classifier.sh`);
- a **live edit gate** that stops Claude editing a Tier 1+ file without an approved change contract (`scripts/preToolUse-contract-gate.sh`);
- the **slash-command skills** (`/plan`, `/tdd`, `/code-review`, `/verify`, `/incident` and more) and the architect agents;
- **commit metadata** (`Intellisense-Metadata:` trailers) and optional heartbeat telemetry ([contract](telemetry-contract.md));
- optional integrations: a task tracker (Beads, GitHub, Jira, Linear) and the code-review graph, each only if you choose it.

Install it with `intellisense live install`. It unpacks to `~/.intellisense/platform/<version>` and links into `~/.claude/`; `intellisense live uninstall` removes it and puts your previous `~/.claude` back.

## Quick Start (5 Minutes)

```bash
# 1. Install the intellisense binary (it carries Live mode inside it)
brew install soupler-oss/tap/intellisense        # or: curl -fsSL …/install.sh | sh  — see INSTALLATION.md

# 2. Install Live mode for Claude Code on this machine
intellisense live install
#   ? Task tracker (none, beads, github, jira, linear) [none]:
#   ? Code intelligence (none, code-review-graph) [none]:
# Unpacks to ~/.intellisense/platform/<version>, links ~/.claude/, installs only the tools you chose.

# 3. Confirm
intellisense live status

# 4. In each repository, add Core mode (the push and CI gate) — it reads the same .intellisense.yml
cd ~/projects/orders-service && intellisense init
```

Working on intellisense itself? Run the installer from a checkout instead: `bash setup.sh` (it builds the engine
from the checkout when Go is available). `intellisense live uninstall` (or `bash restore.sh`) removes Live mode
and puts your previous `~/.claude` back.

**Adding a repo to Live mode later:** `bash ~/.intellisense/platform/current/setup-repos.sh --repo ~/projects/new-service --stack go`.

### One tier engine

Every Live-mode hook (the prompt classifier's dangerous-phrase guard, the edit gate, `prepare-commit-msg`,
`pre-push`) asks the `intellisense` binary for tiers instead of keeping its own copy of the rules. The engine
reads the repository's `.intellisense.yml`, so an edit, a commit, a push and CI always agree, and a team changes
its tiers in one place. The hooks find the engine at `$INTELLISENSE_BIN`, then `~/.intellisense/bin/intellisense`
(linked by the installer), then `intellisense` on `PATH`. Without it, `pre-push` refuses the push and names the
install command; the edit gate treats every file as Tier 1 (full gating, never relaxed).

## Folder Structure

```
INTELLISENSE_SETUP/
├── README.md (this file)
├── CLAUDE.md — Platform CLAUDE.md (rules for editing this repo)
├── QUICK_START.md — 5-step guide for new developers
├── INSTALLATION.md — Step-by-step setup instructions
├── CHANGELOG.md — Version history
│
├── setup.sh — Automated global + per-repo setup
├── setup-repos.sh — Add a new repo to intellisense later
├── restore.sh — Uninstall intellisense and recover original ~/.claude state
├── verify-setup.sh — Verify installation success
│
├── rules/ — Constraint files (loaded by Claude per context)
│   ├── baseline/ (always loaded)
│   │   ├── reasoning-integrity.md
│   │   └── security.md
│   │
│   ├── language-specific/ (loaded based on repo stack)
│   │   ├── go-patterns.md
│   │   ├── laravel-patterns.md
│   │   ├── angular-patterns.md
│   │   ├── node-patterns.md
│   │   ├── python-patterns.md
│   │   ├── react-patterns.md
│   │   ├── java-patterns.md         — entrypoint (hybrid-entrypoint pattern)
│   │   ├── java/                    — Java subfiles (spring-boot, persistence-jpa, db-migrations, testing, security-config, financial, lombok)
│   │   └── flutter-patterns.md
│   │
│   └── operational/ (loaded at phase/task start)
│       ├── development-workflow.md
│       ├── development-workflow-impl.md
│       ├── git-workflow.md
│       ├── coding-style.md
│       ├── testing.md
│       ├── patterns.md
│       ├── agents.md
│       ├── ai-regression-patterns.md
│       ├── graph-policy.md
│       ├── graph-supported-stacks.md
│       ├── intelligence-sources.md
│       ├── proof-standards.md
│       ├── protocol-governance.md
│       └── task-tracking-beads.md
│
├── skills/ — In-context slash commands (18 skills, flat layout: skills/<name>/SKILL.md)
│   ├── intellisense/             — Tier-based intellisense gating
│   ├── intellisense-audit/       — Repository documentation health audit
│   ├── code-review/      — Phase 4 code quality review
│   ├── contract/         — Layer 1 Change Contract artifact
│   ├── cross-service-diagnose/ — Multi-repo bug diagnosis
│   ├── diagnose/         — Bug root-cause analysis
│   ├── document-service/ — Auto-generate service docs
│   ├── e2e-test/         — End-to-end testing
│   ├── incident/         — Production incident fast path
│   ├── learn/            — Capture patterns and update memory
│   ├── load-test/        — Concurrent access & scalability
│   ├── multi-service-plan/ — Multi-repo feature planning
│   ├── performance-test/ — Cross-service latency validation
│   ├── plan/             — Single-repo requirement analysis
│   ├── security-scan/    — Pre-commit security review
│   ├── tdd/              — Test-driven development workflow
│   ├── verify/           — Full verification suite
│   └── where-to-start/   — Find the right repo
│
├── agents/ — Isolated agents for specialized tasks
│   ├── code-architect.md       — Single-service feature design
│   └── strategic-architect.md  — Cross-service system design
│
├── templates/ — CLAUDE.md and scaffolding templates per stack
│   ├── CLAUDE.md.go.template
│   ├── CLAUDE.md.php.template
│   ├── CLAUDE.md.angular.template
│   ├── CLAUDE.md.node.template
│   ├── CLAUDE.md.python.template
│   ├── CLAUDE.md.react.template
│   ├── CLAUDE.md.java.template
│   ├── CLAUDE.md.flutter.template
│   ├── ci/              — refresh-docs.yml, intellisense-version-report.yml
│   ├── docs/            — 4 documentation stubs
│   ├── knowledge-base/  — 14 numbered .stub.md files (00–05 prefix)
│   └── rules/           — queue-jobs.md
│
├── infrastructure/
│   ├── service-map.md       — Central service registry
│   ├── knowledge-base.md    — Term ownership & disambiguation
│   └── hooks-template.json  — Hook configuration template
│
├── scripts/      — Utility scripts (validate-intellisense-content.sh, generate-kb-stubs.sh, intellisense-* helpers)
├── hooks/        — pre-push git hook (intellisense enforcement)
├── hook-packs/   — Per-stack hook bundles (angular, basic, go, graph, laravel, node, python, react)
├── tests/        — Setup / repo / restore test scripts
├── knowledge-base/ — Top-level shared knowledge base
│
└── docs/
    ├── WORKFLOW.md                         — Developer workflow
    ├── CODE-REVIEW-GRAPH-INTEGRATION.md    — Graph-backed code review
    ├── fork-workflow.md                    — Fork workflow + enforcement (canonical)
    └── language-support-onboarding.md      — Adding a new language
```

---

## The change contract (one file)

`/contract` writes `.intellisense/contracts/<branch>.md` (`/` in the branch name becomes `__`) and you commit it with
the change. Its YAML front matter holds every field; the same file is read three ways:

| When | Who | What it checks |
|---|---|---|
| Before an edit | PreToolUse gate | `state` is `approved`/`active`, the task binding (R7), the file is in `files_affected` |
| At push | pre-push hook | the schema and Gate Rules R1–R6, scope drift |
| At push and in CI | `intellisense gate` | the policy's contract fields (`scope`, `risk` …) — the change's contract evidence |

`intellisense contract show FILE` prints the front matter as JSON; `intellisense contract set FILE state=approved`
changes a field in place. Writing under `.intellisense/contracts/` never needs a contract itself.

## Per-repository rules

Live mode's rules come from the platform (`~/.intellisense/rules/`), and each repository can layer its own on
top through the managed block in its `CLAUDE.md` (written by `setup-repos.sh`):

- a repository that has its own copy of its language rule in `.intellisense/rules/language-specific/` (from
  `intellisense init`, edited or not) points at that copy instead of the platform's;
- an operational rule the repository changed in `.intellisense/rules/operational/` is listed as its version;
- a rule in `rules.disable` (`.intellisense.yml`) is left out;
- every file in `.intellisense/rules/organization/` is listed.

Re-run `setup-repos.sh` for the repository after changing these to refresh the block.

## Keeping onboarded repositories current

`setup-repos.sh` records each file it copies from the platform (the CI workflows, the vendored PR validator) in
`.intellisense/templates.json`, with the checksum of what it wrote. After upgrading Live mode:

```bash
intellisense live templates check     # current / outdated / missing / kept (edited here)
intellisense live templates update    # refresh the unedited and missing ones; edited files are kept
intellisense live templates update --force   # also replace edited ones (a .bak copy is kept)
```

## Optional Tools

Live mode needs `bash`, `git`, `jq` and the engine. Everything else is a choice made at install time
(`--tracker`, `--code-intel`, or the installer's questions), recorded in `~/.intellisense/integrations.env`,
and installed only when chosen:

| Choice | Installs | Used for |
|---|---|---|
| `--tracker beads` | the `bd` CLI, and `.beads/` in each onboarded repo | a local task tracker; `Beads: <id>` trailers |
| `--tracker github \| jira \| linear` | nothing | task trailers (`Refs:`, `Jira:`, `Linear:`), optionally verified (`evidence.verify_tasks`) |
| `--code-intel code-review-graph` | `code-review-graph` (Python) and its MCP server | `who-calls`, `change-spread` and the graph-native review workflows |
| a heartbeat token | a daily heartbeat job | usage telemetry; without a token it stays off ([contract](telemetry-contract.md)) |

`verify-setup.sh` checks only the tools you chose. `setup-repos.sh` builds the per-repo graph only with
`code-review-graph`, and initialises `.beads/` only with `beads`; otherwise it chains the intellisense hooks
straight into the repository's hooks directory.

## Installation Checklist

- [ ] Install the binary (`brew install soupler-oss/tap/intellisense`)
- [ ] Run `intellisense live install` — choose a tracker and code intelligence (both may be `none`)
- [ ] Run `intellisense live status` and `bash ~/.intellisense/platform/current/verify-setup.sh`
- [ ] Fill `[TODO]` sections in each repo's `.intellisense-bootstrap.md`, migrate to `CLAUDE.md`, delete bootstrap file
- [ ] Run `/intellisense-audit` on each repo — score should reach 75+ before starting work
- [ ] Read this page and [`policy.md`](policy.md) — understand tiers, evidence and the 3-tier layout

---

## Key Files to Read First

1. **docs/live-mode.md** (this page) and **docs/policy.md** — how it works and why
2. **QUICK_START.md** — First task walkthrough
3. **INSTALLATION.md** — Detailed step-by-step setup
4. **infrastructure/service-map.md** — Service relationships and responsibilities
5. **docs/WORKFLOW.md** — Complete 10-step development workflow

---

## Recovery & Uninstall

**If intellisense is not working correctly**, you can safely uninstall and recover your original setup:

```bash
cd ~/intellisense
bash restore.sh
# Interactive prompt will show what will be removed/restored
# Confirm with: yes
```

**What restore.sh does:**
- Removes all intellisense symlinks from `~/.claude/` and `~/.intellisense/`
- Restores original directories/files from `.bak-TIMESTAMP` backups (created during setup.sh)
- Deletes intellisense-generated files (config.json, .intellisense-initialized, etc.)
- **Restores `~/.claude/CLAUDE.md`** from the oldest `~/.intellisense-backups/CLAUDE.bak-<ts>` (your pre-intellisense original, if any) and clears intermediate rotations. If no backup exists, the intellisense-installed copy is simply removed.
- **Preserves** your MEMORY.md, `teams/`, and `applications/` (developer-owned)

**Setup.sh backup behavior:**
- When setup.sh finds a pre-existing real directory at a symlink path (e.g., `~/.claude/skills/`), it automatically backs it up with a timestamp: `~/.intellisense-backups/skills.bak-20260424010716`
- Symlink is then created pointing to INTELLISENSE_SETUP
- On subsequent setup.sh runs, correct symlinks are skipped; wrong symlinks are updated
- **`~/.claude/CLAUDE.md` is regenerated on every run** (including the version-match fast path). Any prior copy is moved to `~/.intellisense-backups/CLAUDE.bak-<YYYYMMDDhhmmss>` (no `.md` extension so `$HOME/**/*.md` globs miss it); retention capped at 3

**Example: Developer with pre-existing skills directory**
```
1. Pre-existing:  ~/.claude/skills/ (real directory)
2. After setup:   ~/.claude/skills → INTELLISENSE_SETUP/skills (symlink)
                  ~/.claude/skills.bak-20260424010716/ (backup of original)
3. After restore: ~/.claude/skills/ (original directory restored)
                  Symlink removed, backup cleaned up
```

---

## Version Tracking & Incremental Setup

Both `setup.sh` and `setup-repos.sh` track setup version to enable incremental re-runs:

**How it works:**
1. On first run: Setup completes, writes version files (`~/.claude/.intellisense-version`, and `.intellisense/version` per repo)
2. On subsequent runs with same intellisense version: Script skips already-completed steps (validation only)
3. When intellisense version updates: Script detects mismatch and re-runs full setup

**Benefits:**
- Repeated setup runs complete in seconds (no redundant work)
- Auto-detection of intellisense updates (re-runs when version bumps)
- Safe for CI/CD pipelines (idempotent)

**To force re-run:**
```bash
rm ~/.claude/.intellisense-version              # Force global re-run
rm <repo-path>/.intellisense/version            # Force per-repo re-run
bash setup-repos.sh --repo <repo> --stack go --force  # Backup existing and re-run
```

---

## Non-Interactive Mode

For CI/CD pipelines and automated deployments, all scripts support non-interactive mode:

```bash
# Global setup (no prompts)
bash setup.sh --non-interactive --skip-repo-setup

# Per-repo setup (no prompts)
bash setup-repos.sh --repo ~/projects/orders-service --stack go --non-interactive

# Restore without prompts (requires --yes to proceed)
bash restore.sh --non-interactive --yes

# Preview changes without applying
bash restore.sh --dry-run
```

**Key behaviors in non-interactive mode:**
- All prompts are skipped (uses defaults or --yes flag)
- CLAUDE.md action defaults to "inject" (add intellisense rules to existing files)
- Override with `--claude-md-action replace|skip` for different behavior
- Hooks/workflows that differ from intellisense versions create `.intellisense-new` candidates (not auto-replaced)
- Use `--force` with setup-repos.sh to backup and replace differing hooks/workflows

---

## CLI Flags Reference

### setup.sh

**Global Setup Flags**:
- `--non-interactive` — Skip all prompts, use defaults
- `--dry-run` — Show what would be done without making changes
- `--intellisense-setup <path>` — Override INTELLISENSE_SETUP location (default: script directory)
- `--repos-base <path>` — Base directory for auto-detection (default: ~/applications)
- `--setup-repos` — Enable Layer 3 (per-repo setup) explicitly
- `--skip-repo-setup` — Skip Layer 3 entirely (just global ~/.claude setup)
- `--install-hooks` — Install git hooks in discovered repos (default if Layer 3 enabled)
- `--skip-hooks` — Skip git hook installation
- `--install-ci` — Install CI workflows in discovered repos (default if Layer 3 enabled)
- `--skip-ci` — Skip CI workflow installation
- `--claude-md-action inject|replace|skip` — Control CLAUDE.md handling (non-interactive only)
- `--tracker none|beads|github|jira|linear` — Task tracker (default: ask; `none` when non-interactive). Only `beads` installs a tool
- `--code-intel none|code-review-graph` — Code intelligence (default: ask; `none` when non-interactive)
- `--no-heartbeat` — Do not install the usage heartbeat (it is also off when no token is available)

**Example — CI pipeline setup:**
```bash
bash setup.sh \
  --non-interactive \
  --repos-base /mnt/repos \
  --skip-repo-setup  # Just global setup, repos handled separately
```

### setup-repos.sh

**Per-Repo Setup Flags**:
- `--repo <path>` — Repository path (required)
- `--stack go|php|angular|python|node|react|java` — Language stack (required)
- `--tracker …` / `--code-intel …` — Override the choices recorded by setup.sh for this repository
- `--non-interactive` — Skip prompts for CLAUDE.md action
- `--force` — Backup and replace differing hooks/workflows (careful — backs up original)
- `--skip-claude-md` — Don't touch CLAUDE.md (use with --non-interactive)
- `--claude-md-action inject|replace|skip` — Override CLAUDE.md action
- `--skip-hooks` — Don't install git hooks
- `--skip-ci` — Don't install CI workflows
- `--intellisense-setup <path>` — Override INTELLISENSE_SETUP location

**Example — Setup repo with custom hook safely:**
```bash
bash setup-repos.sh \
  --repo ~/projects/orders-service \
  --stack go \
  --non-interactive \
  --skip-claude-md \
  # Custom hook will be preserved, intellisense hook saved as .git/hooks/pre-push.intellisense-new
```

**Example — Force update hook (backs up original):**
```bash
bash setup-repos.sh \
  --repo ~/projects/orders-service \
  --stack go \
  --force  # Backs up existing hook, installs intellisense hook
```

### restore.sh

**Restore/Uninstall Flags**:
- `--non-interactive` — Skip confirmation prompt (requires --yes to proceed)
- `--yes` — Auto-confirm restore (use with --non-interactive)
- `--dry-run` — Preview changes without applying them

**Example — Dry-run restore:**
```bash
bash restore.sh --dry-run
# Shows what would be removed/restored, doesn't make changes
```

**Example — Non-interactive restore (automated):**
```bash
bash restore.sh --non-interactive --yes
# Proceeds immediately without prompts
```

---

## Hook & CI Workflow Installation Behavior

When setup-repos.sh installs git hooks and GitHub Actions workflows, it follows a safe policy:

| Scenario | Default Behavior | With --force |
|----------|------------------|--------------|
| **Hook doesn't exist** | Install intellisense hook | Install intellisense hook |
| **Identical hook exists** | Skip (no change) | Skip (no change) |
| **Different hook exists** | Create `.intellisense-new` candidate | Backup + replace |
| **Workflow missing** | Install intellisense workflow | Install intellisense workflow |
| **Identical workflow** | Skip (no change) | Skip (no change) |
| **Different workflow** | Create `.intellisense-new` candidate | Backup + replace |

**Default behavior protects existing hooks:**
```bash
# You have a custom pre-push hook in ~/projects/orders-service/.git/hooks/
bash setup-repos.sh --repo ~/projects/orders-service --stack go

# Result:
# - Original hook preserved
# - intellisense hook saved as: .git/hooks/pre-push.intellisense-new
# - You can review and merge manually
```

**With --force, backups are created:**
```bash
bash setup-repos.sh --repo ~/projects/orders-service --stack go --force

# Result:
# - Original hook backed up: .git/hooks/pre-push.bak-20260424102530
# - intellisense hook installed
# - You can restore original with: cp .git/hooks/pre-push.bak-* .git/hooks/pre-push
```

**Checking for .intellisense-new candidates after setup:**
```bash
find ~/.claude -name "*.intellisense-new" -o -name ".intellisense-new"
# Or in a specific repo:
find ~/projects/orders-service -name "*.intellisense-new"
```

---

## Intelligent CLAUDE.md Handling

When setting up a repo that already has a CLAUDE.md file, setup.sh analyzes what's present and suggests the best action:

**Analysis checks for:**
- intellisense rules block (`intellisense:BEGIN` marker or rule references)
- Language-specific rules (`go-patterns`, `laravel-patterns`, `angular-patterns`)
- Workflow rules (`development-workflow` references)

**Automatic suggestions:**
- All rules present → **skip** (preserve existing CLAUDE.md)
- Some/no rules → **inject** (add missing intellisense rules block, default choice)
- Starting fresh → **replace** (use full intellisense template)

**Three-option prompt:**
```
Suggestion: inject — No intellisense rules found; inject will add both language-specific and workflow rules
Choose action? (replace/inject/skip) [inject]:
```

**Inject preserves existing content** — appends intellisense rules block with `<!-- intellisense:BEGIN/END -->` markers (idempotent, won't duplicate if run twice)

---

## Core Concepts (TL;DR)

**2 Agents** (loaded on-demand): code-architect (single-service feature design), strategic-architect (cross-service system design)

**18 Skills** (in-context): /intellisense, /intellisense-audit, /code-review, /contract, /cross-service-diagnose, /diagnose, /document-service, /e2e-test, /incident, /learn, /load-test, /multi-service-plan, /performance-test, /plan, /security-scan, /tdd, /verify, /where-to-start

**Baseline Rules** (always on): reasoning-integrity, security (~0.7k always); development-workflow + agents from operational (always); development-workflow-impl + testing + coding-style + patterns conditional when writing code (~2k+2-3k)

**Context-Triggered Rules**: Language-specific, protocol-specific, operational (loaded on demand)

**Service Map**: Central registry of all 11 services, relationships, and shared concerns

**Financial Safety**: 5 non-negotiable constraints (evidence-first diagnosis, 95%+ coverage, idempotency, SELECT FOR UPDATE, UTC timezone)

**Lazy-Load CLAUDE.md**: Load only sections relevant to current task (300-700 tokens vs. 1500-2500 full)

---

## Context Budget

| Scenario | Baseline | Language | Task-Specific | **Total** |
|----------|----------|----------|---------------|-----------|
| Single-repo impl | 10-15k | 3-5k | — | **13-20k** |
| Cross-repo plan | 10-15k | 3-5k | 1-2k | **14-22k** |
| Incident | 10-15k | 3-5k | 0.4k | **13-21k** |
| **Freed per session** | — | — | — | **170-185k available** |

Original baseline was 74-117k tokens. Optimized reduces to 17-27k. **Context savings: 47-90k tokens per session (65% reduction).**

---

## Support & Troubleshooting

**Verify installation:**
```bash
bash verify-setup.sh
```

---

## For Developers Using intellisense

1. **First task?** Read `QUICK_START.md`
2. **Implementing a feature?** Follow `docs/WORKFLOW.md` (10 steps)
3. **Working cross-repo?** Start with `/where-to-start`, then `/multi-service-plan`
4. **Debugging a bug?** Start with `/diagnose` (it will route you to correct repo)

---

## Contact & Updates

- **Report issues:** https://github.com/soupler-oss/intellisense/issues
- **Suggest improvements:** https://github.com/soupler-oss/intellisense/discussions
- **Architecture questions:** Refer to this page and `docs/policy.md`

---

**Next Step:** Run `setup.sh` and then read `QUICK_START.md`.
