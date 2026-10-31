# Installation Guide — Detailed Setup Instructions

> **Start here.** Install the binary, then pick a mode:
>
> ```bash
> brew install soupler-oss/tap/intellisense     # or: curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh | sh
> cd your-repo && intellisense init             # Core mode: any agent, one repository (asks a few questions)
> intellisense live install                     # Live mode: live checks inside Claude Code, every repository on this machine
> ```
>
> Windows: `scoop bucket add soupler https://github.com/soupler-oss/scoop-bucket && scoop install intellisense` (Core mode; Live mode needs WSL).
> With Go: `go install github.com/soupler-oss/intellisense/cmd/intellisense@latest`. Run `intellisense` anywhere to see what to do next.
>
> The rest of this guide installs Live mode **from a git checkout** with `setup.sh` — the path for contributors to
> intellisense itself. `setup.sh` takes `--tracker` and `--code-intel` (both default to `none`: nothing extra is installed).

**Duration**: 10-15 minutes  
**Requirements**: Bash 4+, git, file permissions to ~/.claude  
**Verification**: Run verify-setup.sh after completion

---

## Prerequisites

### Check Requirements
```bash
# Check bash version
bash --version  # Should be 4.0+

# Check git
git --version

# Check home directory exists
ls ~
```

### Create ~/.claude directory (if needed)
```bash
mkdir -p ~/.claude
ls -la ~/ | grep claude  # Should show drwxr-xr-x
```

---

## Step 1: Copy INTELLISENSE_SETUP Folder

**Option A: Copy from current location**
```bash
cp -r <path-to-intellisense-setup> ~/intellisense-setup

cd ~/intellisense-setup
ls -la  # Should show: README.md, setup.sh, verify-setup.sh, rules/, skills/, etc.
```

**Option B: Clone from git (if available)**
```bash
git clone [repo-url] ~/intellisense-setup
cd ~/intellisense-setup
```

---

## Step 2: Make Setup Scripts Executable

```bash
chmod +x setup.sh
chmod +x verify-setup.sh

ls -la setup.sh  # Should show -rwxr-xr-x
```

---

## Step 3: Run Automated Setup

### Interactive Mode (Default)

```bash
bash setup.sh
```

Prompts for decisions at each phase. Press Enter to accept defaults.

### Non-Interactive Mode (CI/CD Pipelines)

```bash
bash setup.sh --non-interactive --skip-repo-setup
```

Runs without any prompts, uses default values. Safe for automated deployments.

**What setup.sh does:**

1. Creates ~/.claude directory structure:
   ```
   ~/.claude/
   ├── rules/
   │   ├── baseline/
   │   ├── language-specific/
   │   └── operational/
   ├── skills/
   ├── agents/
   ├── infrastructure/
   ├── teams/
   ├── projects/
   └── MEMORY.md
   ```

2. Creates symlinks from INTELLISENSE_SETUP to ~/.claude/:
   - All rule files → symlinked (not copied)
   - All skill files → symlinked (not copied)
   - All agent specs → symlinked (not copied)
   - Templates → symlinked
   - Infrastructure docs → symlinked
   - service-map.md → symlinked

   **Why symlinks?** Changes to INTELLISENSE_SETUP automatically propagate to ~/.claude without re-running setup.sh.

3. Sets permissions:
   ```bash
   chmod -R 755 ~/.claude/rules
   chmod -R 755 ~/.claude/skills
   chmod -R 755 ~/.claude/agents
   chmod 644 ~/.claude/MEMORY.md
   ```

4. Creates initialization file ~/.claude/INITIALIZED
   ```bash
   cat ~/.claude/INITIALIZED  # Shows timestamp of setup
   ```

**Expected Output**:
```
✓ Creating ~/.claude directory structure...
✓ Copying rules files...
✓ Copying skills files...
✓ Copying agent specs...
✓ Copying templates...
✓ Copying infrastructure docs...
✓ Syncing service-map.md...
✓ Creating MEMORY.md (if new)...
✓ Setting permissions...
✓ Setup complete! Run verify-setup.sh to confirm.
```

---

## Step 4: Verify Installation

```bash
bash verify-setup.sh
```

**What verify-setup.sh checks (categories — counts and version pins are reported by the script itself, not duplicated here):**

1. `~/.claude` directory exists and is readable
2. Rule files present (count from runtime)
3. Skill files present (count from runtime)
4. Agent specs present
5. Template files present
6. Infrastructure docs present
7. `service-map.md` synced
8. `MEMORY.md` initialized
9. File permissions correct
10. `.intellisense-version` matches the version in `VERSION` (which is the SoT)
11. **Per-repo CLAUDE.md, knowledge-base and `.intellisense/version`** for each registered repo (hard-fail if missing); `.beads/config.yaml` too when the tracker is Beads
12. `code-review-graph` MCP at the pinned version — only when you chose it (`--code-intel code-review-graph`; the pin lives in `setup.sh:CRG_REQUIRED_VERSION`)
13. `bd` CLI on PATH — only when the tracker is Beads
14. INTELLISENSE_SETUP pre-push hook installed
15. Pre-push hook executable and wired into `.git/hooks/`
16. Total installation size sanity check

**Optional tools — installed only if you choose them** (single source of truth in the script itself):
- `--code-intel code-review-graph`: `code-review-graph` at the pinned version (see `setup.sh:CRG_REQUIRED_VERSION`) via the install hierarchy declared in `setup.sh` (Step 17 — exits 1 if all paths fail).
- `--tracker beads`: `beads` via Homebrew, then `bd init` for INTELLISENSE_SETUP plus chained pre-push hook (Step 16.5 — exits 1 on any failure).

With `--tracker none|github|jira|linear` and `--code-intel none`, setup installs neither.

If verify-setup.sh exits non-zero, re-run `bash setup.sh` to install whatever is missing. Do not proceed to your first task until verify is green.

---

## Step 4.5: Layer 3 Setup — Configure Service Repositories

This step sets up CLAUDE.md files in your existing service repositories.

```bash
cd ~/intellisense-setup
bash setup.sh
```

When setup.sh reaches Layer 3, it will ask:
```
Auto-detect repos in ~/applications? (yes/no) [yes]:
```

Answer `yes` to auto-detect, or provide your repos base path.

### For Each Repository with Existing CLAUDE.md

setup.sh analyzes the file and presents options:

```
Analyzing existing CLAUDE.md...
  • intellisense rules block: not found
  • Language-specific rules: missing
  • Workflow rules: missing

Suggestion: inject — No intellisense rules found; inject will add both language-specific and workflow rules
Choose action? (replace/inject/skip) [inject]:
```

**Three options:**
- **inject** (default) — Adds intellisense rules block to existing file, preserves all custom content
- **replace** — Backs up existing file, uses fresh intellisense template
- **skip** — Keeps existing CLAUDE.md unchanged

**Key:** Regardless of CLAUDE.md choice, docs/ directory and CI setup continue.

**Example flow:**
```bash
# Option 1: Use suggested action (press Enter)
Choose action? (replace/inject/skip) [inject]: 
✓ intellisense rules block injected into existing CLAUDE.md

# Option 2: Replace with fresh template
Choose action? (replace/inject/skip) [inject]: replace
✓ Original CLAUDE.md preserved: .intellisense/.backup/CLAUDE.md.original
✓ CLAUDE.md replaced with intellisense template

# Option 3: Keep existing unchanged
Choose action? (replace/inject/skip) [inject]: skip
ℹ Keeping existing CLAUDE.md unchanged (proceeding with docs/CI setup)
```

---

## Step 4.6: Non-Interactive Per-Repo Setup (For CI/CD)

If setting up multiple repos programmatically, use non-interactive mode:

```bash
# Setup a single repo without prompts
bash setup-repos.sh \
  --repo ~/projects/orders-service \
  --stack go \
  --non-interactive \
  --skip-claude-md

# Or with different CLAUDE.md handling
bash setup-repos.sh \
  --repo ~/projects/orders-service \
  --stack go \
  --non-interactive \
  --claude-md-action inject  # or: replace, skip
```

**Non-interactive defaults:**
- CLAUDE.md action: "inject" (adds intellisense rules to existing files)
- Hooks: installed if missing, skipped if identical, saved as `.intellisense-new` if different
- CI workflows: same behavior as hooks

**To force-replace differing hooks/workflows (with backup):**

```bash
bash setup-repos.sh \
  --repo ~/projects/orders-service \
  --stack go \
  --non-interactive \
  --force
  # Original hooks backed up with timestamp
```

### CI/CD Pipeline Example (GitHub Actions)

```yaml
name: Setup intellisense
on: [push]

jobs:
  setup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup intellisense global
        run: |
          bash setup.sh --non-interactive --skip-repo-setup
      
      - name: Setup current repo
        run: |
          bash setup-repos.sh \
            --repo ${{ github.workspace }} \
            --stack go \
            --non-interactive
```

---

## Step 5: Read Documentation

```bash
# In order:
cat README.md                                  # Overview, install, the two modes
cat docs/live-mode.md                          # Live mode: what goes where and why
cat QUICK_START.md                             # Your first task
cat docs/WORKFLOW.md                           # Complete workflow
cat docs/CODE-REVIEW-GRAPH-INTEGRATION.md      # Optional code graph: choosing it, install, when it applies
cat rules/operational/development-workflow.md  # Phase 0-1, mode detection, task tracking
```

For financial code rules, see `rules/language-specific/laravel-patterns.md` (PHP account/queue patterns) and `rules/language-specific/go-patterns.md` (financial concurrency, SELECT FOR UPDATE).

---

## Incremental Setup (Smart Re-runs)

### Version Tracking

When setup completes successfully, both `setup.sh` and `setup-repos.sh` write version files:

- **Global**: `~/.claude/.intellisense-version` (created by setup.sh — user-home, not committed anywhere)
- **Per-repo**: `.intellisense/version` in each service repository (created by setup-repos.sh — tracked in git)

**Per-repo version file format** (`<repo>/.intellisense/version`, deterministic and byte-identical across developers):
```
INTELLISENSE_VERSION=1.0.0
STACK=go
```

Per-developer metadata (`installed_by`, `installed_date`) is captured in `<repo>/.intellisense/local.json`, which is gitignored. The tracked `.intellisense/version` file intentionally omits per-developer fields so that re-running setup on a different machine produces zero diff.

**Global version file format** (`~/.claude/.intellisense-version`, in user home, never committed):
```
INTELLISENSE_VERSION=1.0.0
INSTALLED_DATE=2026-04-25T10:30:00Z
INTELLISENSE_SETUP_PATH=/Users/you/Project/intellisense
UPDATED_BY=your_username
```

### Smart Skip Logic

When you run `setup.sh` or `setup-repos.sh` again on an already-configured directory:

1. **Version check**: Script reads the version file and compares with current intellisense version
2. **If versions match**:
   - Global setup (`setup.sh`): Skips steps 1-13, goes straight to validation
   - Per-repo setup (`setup-repos.sh`): Skips CLAUDE.md creation and docs/ setup
3. **If versions differ** or version file missing: Runs full setup as normal

**This means:**
- Second run on same repo: Completes in seconds (validation only)
- After updating INTELLISENSE_SETUP: Next setup run detects new version and re-runs everything
- Incremental work: Can re-run setup multiple times without redundant operations

### Force Re-run

To force a complete re-run even with matching version:

```bash
# Global re-run (re-do ~/.claude setup)
rm ~/.claude/.intellisense-version
bash setup.sh

# Per-repo re-run (re-do a specific repo)
rm <repo-path>/.intellisense/version
bash setup-repos.sh --repo <repo-path> --stack go|php|angular

# Or use --force flag in setup-repos.sh (backs up existing before replacing)
bash setup-repos.sh --repo <repo-path> --stack go --force
```

---

## Step 6: Test with Your First Service

### A. Test with orders-service repo

```bash
cd ~/projects/orders-service  # Your service repo
```

### B. Open CLAUDE.md

```bash
cat CLAUDE.md
```

**Verify it has these sections:**
- Local Path
- Stack (should be "Go")
- Architecture
- Upstream Dependencies (should list accounts-service, api-gateway)
- Downstream Consumers (should list reporting-service, api-gateway)
- Shared Database Tables (should list transactions, invoices)
- API Contracts
- Library Consumers (shared-go-lib)
- Deployment Order
- Domain Terms
- Financial Rules (if applicable)
- Run/Test/Build
- Known Gotchas

### C. Start Your First Task

```
/where-to-start implement account reconciliation feature
```

---

## Troubleshooting

### Issue: "mkdir: cannot create directory ~/.claude"

**Cause**: Permission denied on home directory

**Fix**:
```bash
# Check permissions
ls -la ~ | head -5
# Fix if needed
chmod 755 ~
```

### Issue: "setup.sh: command not found"

**Cause**: setup.sh not executable

**Fix**:
```bash
chmod +x setup.sh
bash setup.sh
```

### Issue: "Copy failed: No such file or directory"

**Cause**: INTELLISENSE_SETUP folder not found

**Fix**:
```bash
# Verify INTELLISENSE_SETUP location
ls -la ~/intellisense-setup

# If not found, copy again
cp -r <path-to-intellisense-setup> ~/intellisense-setup
cd ~/intellisense-setup
bash setup.sh
```

### Issue: verify-setup.sh says "missing files"

**Cause**: setup.sh didn't complete successfully

**Fix**:
```bash
# Clean up and retry
rm -rf ~/.claude
cd ~/intellisense-setup
bash setup.sh
bash verify-setup.sh
```

### Issue: "MEMORY.md not writable"

**Cause**: Permission denied on MEMORY.md

**Fix**:
```bash
chmod 644 ~/.claude/MEMORY.md
chmod 755 ~/.claude
```

---

## Understanding Hook & Workflow Installation

setup-repos.sh handles git hooks and CI workflows carefully to avoid overwriting customizations:

### Installation Policy

| Scenario | Default | With --force |
|----------|---------|--------------|
| Hook missing | ✅ Install | ✅ Install |
| Hook identical | ⏭️ Skip | ⏭️ Skip |
| Hook different | 📋 Candidate | ✏️ Backup + replace |
| Workflow missing | ✅ Install | ✅ Install |
| Workflow identical | ⏭️ Skip | ⏭️ Skip |
| Workflow different | 📋 Candidate | ✏️ Backup + replace |

### Example Scenarios

**Scenario 1: First-time setup**
```bash
bash setup-repos.sh --repo ~/projects/new-service --stack go

# Result: Hooks and workflows installed cleanly
# Files created:
#   - .git/hooks/pre-push (intellisense hook)
#   - .github/workflows/refresh-docs.yml (intellisense workflow)
```

**Scenario 2: Repo has custom pre-push hook**
```bash
# Your hook exists at .git/hooks/pre-push with custom logic

bash setup-repos.sh --repo ~/projects/orders-service --stack go

# Result: Your hook is preserved
# File created: .git/hooks/pre-push.intellisense-new (intellisense hook available for review)
# Action: You can review and manually integrate if needed
#         Or, ignore if your hook is sufficient
```

**Scenario 3: Updating with custom hook (force replace)**
```bash
# You want to update to intellisense hook but need to preserve the original

bash setup-repos.sh --repo ~/projects/orders-service --stack go --force

# Result: Your hook backed up and replaced
# Files created:
#   - .git/hooks/pre-push (new intellisense hook)
#   - .git/hooks/pre-push.bak-20260424102530 (your original hook)
# 
# If needed, restore original:
# cp .git/hooks/pre-push.bak-20260424102530 .git/hooks/pre-push
```

### Finding intellisense Candidates After Setup

If setup created `.intellisense-new` candidate files, you can find them:

```bash
# All candidates in a repo
find ~/projects/orders-service -name "*.intellisense-new"

# Check if hook differs
diff .git/hooks/pre-push .git/hooks/pre-push.intellisense-new

# If you want to use the intellisense hook, replace it
cp .git/hooks/pre-push.intellisense-new .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

---

## Manual Installation (If setup.sh Fails)

If setup.sh doesn't work, do this manually:

```bash
# Create directory structure
mkdir -p ~/.claude/rules/baseline
mkdir -p ~/.claude/rules/language-specific
mkdir -p ~/.claude/rules/operational
mkdir -p ~/.claude/skills/planning
mkdir -p ~/.claude/skills/implementation
mkdir -p ~/.claude/skills/verification
mkdir -p ~/.claude/skills/diagnosis
mkdir -p ~/.claude/skills/qa
mkdir -p ~/.claude/skills/incidents
mkdir -p ~/.claude/skills/knowledge
mkdir -p ~/.claude/agents
mkdir -p ~/.claude/infrastructure
mkdir -p ~/.claude/templates
mkdir -p ~/.claude/teams
mkdir -p ~/.claude/projects

# Create symlinks (from ~/intellisense-setup location) — NOT copies
ln -sf ~/intellisense-setup/rules/baseline/* ~/.claude/rules/baseline/
ln -sf ~/intellisense-setup/rules/language-specific/* ~/.claude/rules/language-specific/
ln -sf ~/intellisense-setup/rules/operational/* ~/.claude/rules/operational/

ln -sf ~/intellisense-setup/skills/planning/* ~/.claude/skills/planning/
ln -sf ~/intellisense-setup/skills/implementation/* ~/.claude/skills/implementation/
# ... symlink all other skill files ...

ln -sf ~/intellisense-setup/agents/* ~/.claude/agents/
ln -sf ~/intellisense-setup/templates/* ~/.claude/templates/
ln -sf ~/intellisense-setup/infrastructure/* ~/.claude/infrastructure/

# Symlink service map
ln -sf ~/intellisense-setup/infrastructure/service-map.md ~/.claude/service-map.md

# Create MEMORY.md (local only, not symlinked)
touch ~/.claude/MEMORY.md

# Set permissions
chmod -R 755 ~/.claude/rules
chmod -R 755 ~/.claude/skills
chmod 644 ~/.claude/MEMORY.md

# Mark as initialized
date > ~/.claude/INITIALIZED

echo "Manual setup complete! Run verify-setup.sh to confirm."
```

**Why symlinks instead of copies?** Symlinks ensure that updates to INTELLISENSE_SETUP (rules, skills, agents) automatically propagate to ~/.claude without re-running setup.sh. MEMORY.md remains local (not symlinked) since it's unique per developer.

---

## Uninstall / Restore

If you need to remove intellisense and restore your original setup:

### Interactive Restore

```bash
cd ~/intellisense-setup
bash restore.sh
# Shows what will be removed/restored, prompts for confirmation
```

### Dry-Run (Preview Without Changes)

```bash
bash restore.sh --dry-run
# Shows exactly what would be removed/restored without making any changes
```

### Non-Interactive Restore (For CI/CD)

```bash
bash restore.sh --non-interactive --yes
# Proceeds immediately without any prompts
```

### What restore.sh Does

- ✅ Removes intellisense-managed symlinks from ~/.claude/
- ✅ Restores original files from `.bak-TIMESTAMP` backups (created during setup.sh)
- ✅ Deletes intellisense-generated configuration files
- ✅ **Restores `~/.claude/CLAUDE.md`** from the oldest `~/.intellisense-backups/CLAUDE.bak-<ts>` (your pre-intellisense original, if any) and clears intermediate rotations; if no backup exists, the intellisense-installed copy is removed
- 🛡️ Preserves MEMORY.md (developer-owned)
- 🛡️ Preserves teams/ and projects/ directories
- 🛡️ Never deletes pre-existing content outside the intellisense-managed paths

### Example: Full Uninstall & Restore

```bash
cd ~/intellisense-setup

# Preview what will happen
bash restore.sh --dry-run

# If satisfied, proceed
bash restore.sh --non-interactive --yes

# Verify restoration
ls -la ~/.claude/
# Should show original directories, not symlinks
```

---

## Post-Installation Checks

### 1. Verify ~/.claude Structure
```bash
tree ~/.claude  # Or: find ~/.claude -type f | wc -l
# Should show ~50+ files
```

### 2. Verify File Permissions
```bash
ls -la ~/.claude | head -10
# Should show drwxr-xr-x for directories, -rw-r--r-- for files
```

### 3. Verify service-map.md is Synced
```bash
ls -la ~/.claude/service-map.md
cat ~/.claude/service-map.md | head -20
# Should show service list
```

### 4. Verify MEMORY.md Exists
```bash
ls -la ~/.claude/MEMORY.md
# Should be empty or have default structure
```

### 5. Test a Skill (Optional)
```bash
cd ~/projects/orders-service
# Try a skill (will fail if Claude not integrated, but should not error on setup)
# /where-to-start test account feature
```

---

## Next Steps After Installation

1. ✅ **Setup complete**
2. 📖 **Read**: QUICK_START.md (15 min)
3. 🎯 **Start**: Your first task using `/where-to-start [requirement]`
4. 📚 **Reference**: Keep docs/WORKFLOW.md open for complete workflow
5. 🔐 **Financial code?** Read docs/FINANCIAL_SAFETY.md before implementation
6. 🔀 **Cross-repo work?** Run `/multi-service-plan` — its Step 0 discovers all affected repos

---

## Support

**Installation Issues?**
- Check troubleshooting section above
- Verify file permissions with `ls -la ~/.claude`
- Confirm INTELLISENSE_SETUP is complete with `ls -la ~/intellisense-setup`

**Usage Questions?**
- Read QUICK_START.md
- Check docs/policy.md
- Review docs/live-mode.md

---

**Installation Status**: ✅ Ready  
**Next**: Read QUICK_START.md and start your first task!
