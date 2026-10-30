---
name: document-service
description: Use to scan a service repository and generate or refresh its source tree, project context, API contracts and architecture docs, with a drift report.
---

# /document-service — Auto-Generate Service Documentation

Scan a service repo, detect stack/patterns, generate 4 markdown docs for CI/dev reference.

**When**: After service repo is created OR quarterly refresh (Monday 2AM cron via CI)
**Input**: Service repo path (auto-detected from CLAUDE.md Stack)
**Output**: 4 docs + drift report + state file (resumable on interrupt)

---

## Entry Point: Fresh vs Resume vs Deep-Dive

### Fresh Run (First Time)
```bash
/document-service --repo ~/projects/[your-service] --stack go
```
Output: All 8 steps run sequentially. Generates 4 docs + schema file.

### Resume (After Interrupt)
```bash
/document-service --resume
```
Reads `.intellisense-docservice-state.json` at the repo root and resumes from the recorded step.

### Deep-Dive (Update Existing)
```bash
/document-service --repo ~/projects/[your-service] --update-only
```
Only re-scans code (steps 1-6), skips user confirmation steps. Overwrites existing docs.

---

## Step-by-Step Execution

```
Step 1: Detect Stack  [5 sec]
  ↓
Step 2: Scan Structure  [30 sec]
  ↓
Step 3: Generate source-tree-analysis.md  [immediate write]
  ↓
Step 4: Generate project-context.md  [with user confirmation per category]
  ↓
Step 5: Generate api-contracts.md  [parse route files, immediate write]
  ↓
Step 6: Generate architecture-overview.md  [from repo structure analysis]
  ↓
Step 7: Drift Check  [compare scan vs CLAUDE.md, write drift-report.md]
  ↓
Step 8: Complete  [finalize state, print checklist]
```

Each step saves state to `.intellisense-docservice-state.json` before proceeding. If interrupted at step N, resume resumes from step N+1.

---

## Output Files

After completion, 4 documents exist in `knowledge-base/`:

1. **source-tree-analysis.md** (2-3k tokens)
   - Directory tree with file counts per directory
   - Financial audit (int64 minor-currency-units usage, SELECT FOR UPDATE, idempotency patterns)
   - CLAUDE.md drift indicators (missing expected files)

2. **project-context.md** (<1.2k tokens, OPTIMIZED FOR LLM)
   - Service name, Stack (Go/PHP/Angular), Description
   - Owned tables (with field types)
   - API endpoints (method, path, auth, consumers)
   - Shared library imports (packages used from your org's shared libraries)
   - Key patterns (ORM type, error handling, concurrency models)
   - Financial rules (minor currency units logic, idempotency, soft-delete)
   - **This file is auto-loaded into Claude context via CLAUDE.md `@knowledge-base/00-system-context.md` reference**

3. **api-contracts.md** (1-2k tokens)
   - Endpoint listing: GET/POST/PUT/DELETE /path
   - Request/response structure (DTO names, field types)
   - Authentication method (API key, Bearer, internal service)
   - Known consumers (which repos call this endpoint)
   - Deprecation status (if endpoint is deprecated)

4. **architecture-overview.md** (1.5-2k tokens)
   - Component diagram (ASCII) showing: API layer, Service layer, Repository layer
   - Data flow: request → service → repository → database
   - Shared concerns: logging, error handling, validation
   - Test structure (unit, integration, E2E locations)
   - Deployment considerations (migrations, feature flags, rollback)

5. **claude-md-drift-report.md** (on-demand)
   - Compares scan output against CLAUDE.md sections
   - Example: "Expected file `models/payout.go` not found — check Stack field in CLAUDE.md"
   - Flags schema drift (expected table `payouts` in code, not found in database schema analysis)

---

## State File (Resumability)

File: `.intellisense-docservice-state.json`

```json
{
  "repo_path": "/path/to/your/service",
  "stack": "go",
  "step_completed": 3,
  "next_step": 4,
  "start_time": "2026-04-21T10:30:00Z",
  "last_update": "2026-04-21T10:31:15Z",
  "files_found": {
    "go_files": 23,
    "test_files": 18,
    "models": 5,
    "handlers": 6,
    "services": 4
  },
  "scan_results": {
    "tables_detected": ["payouts", "payout_items", "journal_entries"],
    "endpoints_detected": 8,
    "imports_shared_lib": true
  },
  "context_data": {
    "project_context_tokens": 1185,
    "categories_confirmed": ["Service name", "Stack", "Owned tables", "API endpoints"]
  }
}
```

On resume, read `step_completed`, skip to `next_step`, use cached `scan_results`.

---

## CI Integration (Weekly Auto-Update)

File: `templates/ci/refresh-docs.yml`

```yaml
name: Refresh Service Documentation
on:
  schedule:
    - cron: '0 2 * * 1'  # Monday 02:00 UTC
jobs:
  document:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run document-service --update-only
        run: |
          /document-service --repo $(pwd) --update-only
      - name: Commit docs if changed
        run: |
          git diff --exit-code knowledge-base/ || (
            git add knowledge-base/
            git commit -m "chore(docs): refresh service documentation via document-service"
            git push
          )
```

Runs every Monday 2 AM. Only commits if docs changed (prevents noise).

---

## Integration with setup-repos.sh

`setup-repos.sh --repo ~/projects/[your-service] --stack go` prepares the repository structure:

1. Copies CLAUDE.md template
2. Creates knowledge-base/ stubs (no docs/ directory)
3. Installs CI workflow (templates/ci/refresh-docs.yml)
4. Installs pre-push hook
5. Prints manual instructions: "Next: run `/document-service --repo . --stack go` to generate docs"

`/document-service` is a separate Claude skill — it scans the actual repo code and generates rich content. Run it separately after setup-repos.sh completes.

---

## Stack-Specific Detection

### Go Repos
- Detect: `go.mod`, GORM vs Pop ORM (check `go.sum`)
- Files: `models/`, `services/`, `handlers/` (standard) OR `actions/` (Buffalo)
- Financial patterns: Search `go.sum` for `pq` (PostgreSQL), find `SELECT FOR UPDATE` in code

### PHP/Laravel Repos
- Detect: `composer.json`, check `laravel/framework` version
- Files: `app/Models/`, `app/Http/Controllers/`, `app/Services/`
- Financial patterns: Check `app/Models` for `SoftDeletes` trait, payment processor webhook handlers (e.g., `app/Http/Controllers/Webhooks/`)

### Angular Repos
- Detect: `package.json`, check `@angular/core` version (12 vs 19)
- Files: `src/app/` with `.module.ts` (v12) or standalone components (v19)
- Component patterns: NgRx for v12, signals for v19

---

## Next: Individual Step Files

See individual step files for details:
- [step-01-detect-stack.md](steps/step-01-detect-stack.md) — Read package files, confirm CLAUDE.md Stack field
- [step-02-scan-structure.md](steps/step-02-scan-structure.md) — Parse directory tree, find patterns
- [step-03-generate-tree.md](steps/step-03-generate-tree.md) — Write source-tree-analysis.md
- [step-04-generate-context.md](steps/step-04-generate-context.md) — Generate project-context.md with user confirmation
- [step-05-generate-apis.md](steps/step-05-generate-apis.md) — Parse API routes, write api-contracts.md
- [step-06-generate-overview.md](steps/step-06-generate-overview.md) — Create architecture-overview.md
- [step-07-drift-check.md](steps/step-07-drift-check.md) — Compare scan vs CLAUDE.md, write drift report
- [step-08-complete.md](steps/step-08-complete.md) — Finalize state file, print checklist
