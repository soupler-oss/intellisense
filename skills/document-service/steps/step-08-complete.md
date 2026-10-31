# Step 8: Finalize

**Goal**: Finalize state file, print manual action checklist, mark workflow complete.

**Input**: State file with all completed_steps entries (steps 1-7)

**Output**:
- Updated `.intellisense-docservice-state.json` with completed timestamp
- Terminal output: Completion checklist for manual review

---

## Execution

### 1. Finalize State File

Update state.json with completion timestamp and summary:

```json
{
  "workflow_version": "1.2.0",
  "timestamps": {
    "started": "2026-04-21T10:30:00Z",
    "last_updated": "2026-04-21T10:55:00Z",
    "completed": "2026-04-21T10:56:00Z"
  },
  "mode": "initial_scan",
  "scan_level": "quick",
  "project_root": "/path/to/your/projects/orders-service",
  "completed_steps": [
    {"step": "step_1", "status": "completed", "timestamp": "...", "outputs": [], "summary": "..."},
    {"step": "step_2", "status": "completed", "timestamp": "...", "outputs": [], "summary": "..."},
    {"step": "step_3", "status": "completed", "timestamp": "...", "outputs": ["knowledge-base/01-system-source-tree.md"], "summary": "..."},
    {"step": "step_4", "status": "completed", "timestamp": "...", "outputs": ["knowledge-base/00-system-context.md"], "summary": "..."},
    {"step": "step_5", "status": "completed", "timestamp": "...", "outputs": ["knowledge-base/02-api-contracts.md"], "summary": "..."},
    {"step": "step_6", "status": "completed", "timestamp": "...", "outputs": ["knowledge-base/00-system-architecture.md"], "summary": "..."},
    {"step": "step_7", "status": "completed", "timestamp": "...", "outputs": [".intellisense-drift-report.md"], "summary": "..."},
    {"step": "step_8", "status": "completed", "timestamp": "2026-04-21T10:56:00Z", "outputs": [], "summary": "Workflow finalized"}
  ],
  "current_step": "complete",
  "outputs_generated": [
    "knowledge-base/01-system-source-tree.md",
    "knowledge-base/00-system-context.md",
    "knowledge-base/02-api-contracts.md",
    "knowledge-base/00-system-architecture.md",
    ".intellisense-drift-report.md"
  ],
  "resume_instructions": "This workflow is complete. To regenerate docs, run: /document-service --repo $(pwd) --update-only"
}
```

### 2. Print Completion Checklist

Output to terminal:

```
╔════════════════════════════════════════════════════════╗
║  /document-service Workflow Complete                   ║
╚════════════════════════════════════════════════════════╝

✓ WORKFLOW SUMMARY
  Mode: initial_scan
  Scan Level: quick
  Duration: 26 minutes (10:30 → 10:56)
  Status: SUCCESS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ DOCUMENTATION GENERATED

  [✓] knowledge-base/01-system-source-tree.md
      - Directory structure with file counts
      - Financial audit (int64 minor-currency-units, SELECT FOR UPDATE, idempotency)
      - CLAUDE.md drift indicators
      - Size: 2.8k tokens

  [✓] knowledge-base/00-system-context.md
      - Service metadata (orders-service, Go, GORM)
      - Owned tables (invoices, journal_entries, invoice_items)
      - API endpoints (8 documented)
      - Shared libraries (shared-lib/crypto, shared-lib/kafka)
      - Key patterns (error handling, concurrency, soft-delete)
      - Size: 1.1k tokens (auto-loaded into Claude via @knowledge-base/00-system-context.md)

  [✓] knowledge-base/02-api-contracts.md
      - 8 HTTP endpoints with method/path/auth/consumers
      - Request/response structures (DTO fields and types)
      - Authentication types (Bearer token, Service-to-service)
      - Size: 1.9k tokens

  [✓] knowledge-base/00-system-architecture.md
      - ASCII component diagram (Handlers → Services → Repositories → Database)
      - Data flow documentation (typical request-response)
      - Shared concerns (logging, error handling, validation)
      - Test structure (unit, integration, regression locations)
      - Deployment considerations (migrations, feature flags, rollback)
      - Size: 1.8k tokens

  [⚠️] .intellisense-drift-report.md
      - 4 drift items found (severity: 2×MEDIUM, 1×LOW)
      - Missing: invoice_reconciliation table, 2 endpoints, soft-delete domain term
      - Recommendation: Update CLAUDE.md before next deployment
      - Size: 2.1k tokens

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 MANUAL ACTIONS REQUIRED

  [ ] 1. Review project-context.md
        ✓ Verify service name, stack, tables, endpoints are correct
        ✓ Check that all owned tables are listed
        ✓ Confirm token count < 1.2k (currently: 1.1k)

  [ ] 2. Review drift report (if generated)
        Location: .intellisense-drift-report.md
        ⚠️ Status: FAILED (4 items found)
        Action: Fix CLAUDE.md to match codebase
        - Add invoice_reconciliation to Shared Tables section
        - Add 2 missing endpoints to API Contracts section
        - Add Soft Delete to Domain Terms section

  [ ] 3. Update CLAUDE.md (if drift found)
        Current drift status: FAILED (4 items)
        Update all 5 sections:
        - [ ] Stack: ✓ Matches detected (Go + GORM)
        - [ ] Architecture: ✓ Correct (3-layer)
        - [ ] Shared Tables: ❌ Add invoice_reconciliation
        - [ ] API Contracts: ❌ Add missing endpoints
        - [ ] Domain Terms: ❌ Add Soft Delete definition

  [ ] 4. Commit generated docs to git
        Run: git add knowledge-base/ .intellisense-drift-report.md && git commit -m "docs: auto-generated service documentation"
        Files: 4 markdown files + 1 state file (.intellisense-docservice-state.json)

  [ ] 5. (Optional) Set up weekly refresh
        The CI workflow can auto-update docs weekly:
        - Install: templates/ci/refresh-docs.yml → .github/workflows/
        - Schedule: Monday 2 AM UTC (cron: '0 2 * * 1')
        - Command: /document-service --update-only (skips steps 1-6, fast refresh)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔄 NEXT STEPS

  1. If this is initial setup:
     → Open knowledge-base/00-system-context.md in your text editor
     → Scan for accuracy, make small edits if needed
     → `@knowledge-base/00-system-context.md` is already included in your CLAUDE.md template — no action needed.
     → Commit changes

  2. If drift report found:
     → Open .intellisense-drift-report.md
     → For each item, update CLAUDE.md with recommended fixes
     → Re-run: /document-service --resume (skips completed steps, re-runs drift check)
     → Verify drift_check_status: PASSED

  3. For future runs:
     → Fresh scan: /document-service --repo $(pwd) --stack go
     → Update only: /document-service --update-only (faster, skips steps 1-6)
     → Resume: /document-service --resume (if interrupted)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 STATISTICS

  Stack: go (GORM ORM)
  Files Scanned: 150 total (models: 5, services: 4, handlers: 6, migrations: 12, tests: 18)
  Tables Detected: 4 (invoices, journal_entries, invoice_items, invoice_reconciliation)
  Endpoints Detected: 8 (GET: 3, POST: 1, PUT: 1, DELETE: 1, PATCH: 2)
  Financial Patterns: 5/5 (int64 minor-currency-units, SELECT FOR UPDATE, idempotency, soft-delete, audit trail)
  Shared Libraries: 2 (shared-lib/crypto, shared-lib/kafka)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ State file saved: .intellisense-docservice-state.json
✓ Resume support: Run `/document-service --resume` to continue if interrupted
✓ Weekly refresh: Run `/document-service --update-only` to refresh docs without re-scanning

Documentation generation complete. All files ready for review.
```

### 3. Update State File with Step 8

Add final entry to completed_steps:

```json
{
  "step": "step_8",
  "status": "completed",
  "timestamp": "2026-04-21T10:56:00Z",
  "outputs": [],
  "summary": "Workflow finalized, completion checklist printed"
}
```

Set `current_step: "complete"` and `next_step: null`

### 4. Exit Gracefully

Print final message:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

All done! 🎉

Review the docs:
  - Read: knowledge-base/00-system-context.md (auto-loaded in CLAUDE.md context)
  - Reference: knowledge-base/02-api-contracts.md (endpoint reference)
  - Architecture: knowledge-base/00-system-architecture.md (system design)
  - Drift: .intellisense-drift-report.md (if updates needed)

Questions? Check SKILL.md in document-service/ directory.
```

### 5. Success Criteria

- ✓ State file finalized with completed timestamp
- ✓ Completion checklist printed to terminal (not returned in response)
- ✓ All generated files listed in outputs_generated array
- ✓ Manual action items documented (CLAUDE.md updates, git commit, optional CI setup)
- ✓ Statistics provided (stack, file counts, patterns detected)
- ✓ Resume instructions clear (--resume, --update-only)
- ✓ Exit message friendly and informative

---

## Workflow Complete

No further steps. State file ready for next invocation:
- **Fresh run**: `/document-service --repo . --stack go` (overwrites all files)
- **Resume**: `/document-service --resume` (resumes from next_step)
- **Update-only**: `/document-service --update-only` (steps 1-6 skipped, fast refresh)
