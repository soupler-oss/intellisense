# Step 6: Generate architecture-overview.md

**Goal**: Create architecture component diagram and data flow documentation from directory structure and patterns detected.

**Input**: `repo_path`, `stack`, `framework_type`, `directory_tree`, `detected_patterns` (from steps 1-2)

**Output**:
- `knowledge-base/00-system-architecture.md` (1.5-2k tokens)
- Update state.json with outputs_generated and step_completed: 6

---

## Execution

### 1. Determine Architecture Pattern

Based on directory structure, infer architecture layers:

**Go Services (GORM)**:
- Layers typically: HTTP Handlers → Services → Repositories → Database
- Directories: handlers/ or cmd/api/ (HTTP layer) → services/ (business logic) → models/ (data access) → migrations/ (schema)

**Go Services (Buffalo + Pop)**:
- Layers: actions/ (HTTP handlers) → models/ (with Pop scopes as data access) → migrations/

**PHP + Laravel**:
- Layers: Http/Controllers/ (HTTP) → Services/ (business logic) → Models/ (ORM) → migrations/ (schema)

**Angular**:
- Layers: Components (UI) → Services (HTTP/business logic) → Guards (auth) → Interceptors (HTTP)

### 2. Create ASCII Component Diagram

Generate simplified layered diagram (5-8 lines):

**Go/PHP Example**:
```
┌─────────────────────────────────────────────────┐
│                    HTTP Client                   │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  API Layer (Handlers / Controllers)              │
│  - GET /invoices, POST /invoices, etc.     │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Service Layer (Business Logic)                  │
│  - InvoiceService                             │
│  - JournalService                                 │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Repository Layer (Data Access)                  │
│  - InvoiceRepository                          │
│  - JournalRepository                              │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Database (PostgreSQL)                           │
│  - invoices, journal_entries, invoice_items│
└─────────────────────────────────────────────────┘
```

**Angular Example**:
```
┌─────────────────────────────────────────────────┐
│              User (Browser)                      │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Components (UI)                                 │
│  - InvoiceListComponent                       │
│  - InvoiceDetailComponent                     │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Services (HTTP Client)                          │
│  - InvoiceService                             │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  HTTP Interceptors (Auth, Error Handling)        │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Backend API (orders-service, accounts-service, etc.)      │
└─────────────────────────────────────────────────┘
```

### 3. Document Data Flow

Describe typical request-response flow (1-2 paragraphs):

**Go Example**:
```
## Data Flow

### Request: POST /api/invoices
1. HTTP Client sends request with invoice data (JSON body)
2. Handler receives request, validates input (Form Request validation in Laravel, struct tags in Go)
3. Service processes business logic:
   - Checks idempotency (transaction_reference)
   - Calculates amount_minor_units correctly (no float64)
   - Acquires database lock (SELECT FOR UPDATE)
4. Repository executes database transaction:
   - Inserts invoice record
   - Inserts journal entries atomically
   - Releases lock
5. Service returns success response
6. Handler formats response (JSON envelope) and returns to client

**Error Handling**: If any step fails, transaction rolls back, error returned to client with context (request ID, error code).
```

### 4. Document Shared Concerns

List cross-cutting concerns (logging, error handling, validation):

```
## Shared Concerns

### Logging
- Request ID: Generated per request, logged in all layers
- Log Level: info (successful operations), warn (retryable errors), error (failures)
- Sensitive Data: Never log full credit card, full SSN, or API tokens

### Error Handling
- Wrapped Errors: All errors include context (service name, operation, input)
- Error Codes: Numeric codes for programmatic handling (e.g., 1001 = idempotency violation)
- User Messages: Generic to client (e.g., "operation failed"), detailed to logs

### Validation
- Input Validation: At handler level (Form Request in Laravel, struct tags in Go)
- Business Validation: At service level (e.g., check idempotency key before processing)
- Database Constraints: Foreign keys, uniqueness on transaction_reference
```

### 5. Document Test Structure

List where tests exist and what they cover:

```
## Test Structure

### Unit Tests (tests/unit/ or tests/Unit/)
- **InvoiceService_test.go**: Business logic isolation (mocked repositories)
- **JournalCalculator_test.go**: Math functions (amount calculations with int64 minor-currency-units)
- Coverage: 85% of business logic

### Integration Tests (tests/integration/ or tests/Integration/)
- **InvoiceCreateTest_test.go**: Full flow from handler to database
- Uses real PostgreSQL test database
- Coverage: Invoice creation, concurrent requests, idempotency

### Regression Tests
- **IDempotencyTest_test.go**: Same request run twice → no duplicate journal entries
- **ConcurrencyTest_test.go**: 100 concurrent invoice requests → no race conditions
- **BalanceVerificationTest_test.go**: After N operations, account balance = sum of debits/credits
```

### 6. Document Deployment Considerations

List migration, feature flag, and rollback concerns:

```
## Deployment

### Migrations
- Schema changes run via migrations/ directory
- Example: `2026-04-21_add_idempotency_to_invoices.sql`
- Dual-write strategy for column changes (shadow → backfill → parity check → remove)
- Never run migrations during peak hours (9 AM–9 PM UTC)

### Feature Flags
- Soft-delete feature: Environment variable `ENABLE_SOFT_DELETE=true`
- Invoice calculation v2: Feature flag `INVOICE_V2_ENABLED=false` (gradual rollout)
- Toggled at runtime, no code redeploy required

### Rollback Procedure
- **Code**: `git revert [commit-hash]`, redeploy previous version
- **Data**: If migration added column, run `ALTER TABLE remove column` (documented in migration comment)
- **Idempotent Operations**: Safe to rerun same operation (idempotency keys prevent duplicates)
```

### 7. Load Template

Read `skills/analysis/document-service/templates/architecture-overview-template.md`

### 8. Format Complete Output

Combine all sections into architecture-overview.md:

```markdown
# Architecture Overview: orders-service

Generated by `/document-service` on [timestamp]

[ASCII Component Diagram]

[Data Flow section]

[Shared Concerns section]

[Test Structure section]

[Deployment Considerations section]

---

## Key Takeaways
- Three-layer architecture: Handlers → Services → Repositories
- Financial operations use database locks (SELECT FOR UPDATE) for atomicity
- All operations logged with request ID for traceability
- Comprehensive test coverage (unit + integration + regression)
```

### 9. Write File Immediately

Write to `knowledge-base/00-system-architecture.md`

### 10. Update State File

```json
{
  "step_completed": 6,
  "next_step": 7,
  "outputs_generated": [
    "knowledge-base/01-system-source-tree.md",
    "knowledge-base/00-system-context.md",
    "knowledge-base/02-api-contracts.md",
    "knowledge-base/00-system-architecture.md"
  ],
  "completed_steps": [
    {"step": "step_6", "status": "completed", "timestamp": "2026-04-21T10:50:00Z",
     "outputs": ["knowledge-base/00-system-architecture.md"],
     "summary": "architecture-overview.md generated with component diagram, data flow, test structure, and deployment considerations"}
  ]
}
```

### 11. Purge Detailed Data

After writing file and updating state, discard all architectural details from memory.

### 12. Success Criteria

- ✓ File `knowledge-base/00-system-architecture.md` exists and is readable
- ✓ Contains ASCII component diagram showing layers
- ✓ Contains data flow section (1-2 paragraphs per typical request flow)
- ✓ Contains shared concerns section (logging, error handling, validation)
- ✓ Contains test structure section with unit/integration/regression locations
- ✓ Contains deployment section (migrations, feature flags, rollback)
- ✓ File size: 1.5-2k tokens
- ✓ State file updated with outputs_generated array

---

## Next Step

Proceed to step-07-drift-check.md once state file shows `step_completed: 6` and file `knowledge-base/00-system-architecture.md` exists.
