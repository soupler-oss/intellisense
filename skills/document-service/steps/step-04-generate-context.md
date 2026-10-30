# Step 4: Generate project-context.md

**Goal**: Present discovered service information category-by-category to user for confirmation, then generate lean LLM-optimized documentation (<1.2k tokens).

**Input**: `repo_path`, `stack`, `framework_type`, `detected_patterns` (from steps 1-2)

**Output**:
- `knowledge-base/00-system-context.md` (<1.2k tokens, LLM-optimized)
- Update state.json with outputs_generated and step_completed: 4

---

## Execution

### 1. Discover Service Information

Scan codebase to extract:

**Service Metadata**:
- Service name: Read from go.mod module name (Go) or composer.json name (PHP) or package.json name (Angular)
- Service description: Read first line from README.md if exists, else auto-generate from directory structure

**Owned Tables** (Go/PHP only):
- Scan models/ or app/Models/ for database model definitions
- Extract table names and field types
- Example: `payouts: {id: int64, amount: int64, status: string, created_at: timestamp, deleted_at: timestamp}`

**API Endpoints**:
- Scan routes/ or app/Http/ or src/app/ for endpoint definitions
- Extract: method (GET/POST/PUT/DELETE), path, authentication type, consumer services (if documented)
- Example: `GET /api/payouts/list — auth: Bearer token — consumers: orders-service, dashboard`

**Shared Library Imports**:
- Read go.mod or composer.json
- List internal org packages: shared-go-lib (Go), org-shared-libs (PHP)
- Extract specific packages used: encryption, kafka, notifications, email

**Key Patterns**:
- ORM type: GORM, Pop, Eloquent
- Error handling: errors.Wrap, fmt.Errorf, Exception throwing
- Concurrency: goroutines, channels, sync.Mutex, async/await
- State management (Angular): NgRx, signals, Context

### 2. Present to User (Non-Autonomous Mode)

Display categories one-by-one with checkboxes:

```
=== Project Context Generation ===

Category 1: Service Name
Detected: "orders-service" (from go.mod)
Correct? [✓] Yes [ ] No (type new name)

Category 2: Stack
Detected: Go | GORM
Correct? [✓] Yes [ ] No (select different)

Category 3: Owned Tables (5 detected)
Detected:
  - payouts: {id, amount_minor_units: int64, status, created_at, updated_at, deleted_at}
  - journal_entries: {id, payout_id, amount_minor_units: int64, ...}
  - ...
Review and confirm? [✓] Yes [ ] Edit [ ] Skip

Category 4: API Endpoints (8 detected)
Detected:
  - GET /api/payouts/list
  - POST /api/payouts
  - ... (8 total)
Review and confirm? [✓] Yes [ ] Edit [ ] Skip

Category 5: Shared Library Imports
Detected:
  - shared-go-lib/crypto
  - shared-go-lib/kafka
  - shared-go-lib/notifications
Correct? [✓] Yes [ ] No (edit list)

Category 6: Key Patterns
Detected:
  - ORM: GORM
  - Error handling: fmt.Errorf with wrapping
  - Concurrency: sync.Mutex for balance operations
Correct? [✓] Yes [ ] No (edit)

```

Collect confirmations. If user selects [No] or [Edit], accept corrections and update extracted info.

### 3. Load Template

Read `skills/analysis/document-service/templates/project-context-template.md`

### 4. Format Output

Generate <1.2k token version:

```markdown
# Project Context: orders-service

**Stack**: Go | GORM ORM | PostgreSQL

## Owned Tables
- `payouts`: id, amount_minor_units (int64), status (enum), created_at, updated_at, deleted_at
- `journal_entries`: id, payout_id (fk), amount_minor_units (int64), created_at, updated_at
- `payout_items`: id, payout_id (fk), item_id, quantity, amount_minor_units (int64)

## API Endpoints
- `GET /api/payouts/list` — Auth: Bearer | Consumers: Dashboard, Reporting
- `POST /api/payouts` — Auth: Bearer | Consumers: Payout Service
- `GET /api/payouts/:id` — Auth: Bearer | Consumers: Dashboard
- `PUT /api/payouts/:id/finalize` — Auth: Service | Consumers: Payout Cycle
- `DELETE /api/payouts/:id` (soft-delete) — Auth: Service

## Shared Libraries
- shared-go-lib/crypto: Encryption utilities
- shared-go-lib/kafka: Event publishing
- shared-go-lib/notifications: Email/Slack alerts

## Key Patterns
- **ORM**: GORM with database/sql for atomic operations
- **Error Handling**: fmt.Errorf with error wrapping
- **Concurrency**: sync.Mutex for balance mutations, SELECT FOR UPDATE for DB-level locking
- **Soft Delete**: All financial records use deleted_at column
```

**Token estimate**: Format to fit ~900-1,100 tokens (approximately 1,800-2,200 words in markdown)

### 5. Write File Immediately

Write to `knowledge-base/00-system-context.md`

### 6. Update State File

```json
{
  "step_completed": 4,
  "next_step": 5,
  "outputs_generated": ["knowledge-base/01-system-source-tree.md", "knowledge-base/00-system-context.md"],
  "context_data": {
    "service_name": "orders-service",
    "stack": "go",
    "framework_type": "GORM",
    "tables_confirmed": ["payouts", "journal_entries", "payout_items"],
    "endpoints_confirmed": 5,
    "project_context_tokens": 950,
    "categories_confirmed": ["Service name", "Stack", "Owned tables", "API endpoints", "Shared libraries", "Key patterns"]
  },
  "completed_steps": [
    {"step": "step_4", "status": "completed", "timestamp": "2026-04-21T10:40:00Z",
     "outputs": ["knowledge-base/00-system-context.md"],
     "summary": "project-context.md generated with user confirmations across 6 categories, <1.2k tokens"}
  ]
}
```

### 7. Purge Detailed Data

After writing file and updating state, discard:
- Detailed table definitions
- Detailed endpoint listing
- Full library import list
- Keep only: confirmed counts and names in context_data

### 8. Success Criteria

- ✓ File `knowledge-base/00-system-context.md` exists and is readable
- ✓ File size: <1.2k tokens (2,000-2,400 words max)
- ✓ All 6 categories present: Service name, Stack, Tables, Endpoints, Libraries, Patterns
- ✓ User confirmations collected (non-autonomous) or skipped (autonomous mode)
- ✓ State file updated with context_data object and categories_confirmed array

---

## Next Step

Proceed to step-05-generate-apis.md once state file shows `step_completed: 4` and file `knowledge-base/00-system-context.md` exists.
