<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Data Models

## Primary Tables

<!-- TODO: Main tables owned by this service -->

### table_name

```
id (int64, PK)
user_id (int64, FK → users.id)
amount_minor_units (int64) — Always minor currency units, never float
status (enum: NEW, PENDING, COMPLETED, FAILED) — No lowercase
created_at (timestamp, not null)
updated_at (timestamp, not null)
deleted_at (timestamp, nullable) — Soft-delete; NULL = active
```

**Purpose**: [What this table stores]

**Key Constraint**: [Unique or business rule]
- `UNIQUE(user_id, reference_id)` — Prevent duplicate charges

**Access Patterns**:
- Index on `user_id, created_at` — Fast per-user history lookup
- Index on `status, updated_at` — Fast job queue scan

**Soft-Delete Policy**: Logical delete only; no hard deletes. Facilitates audit trail.

---

## Reference Tables

<!-- TODO: Lookup tables, enums, config -->

### table_name

```
id (int64, PK)
code (varchar, unique) — e.g., 'GST_18'
value (int64 or varchar)
created_at (timestamp)
```

**Purpose**: [What this stores]

---

## Relationships

<!-- TODO: How tables relate to each other -->

**Example**:
```
users (1) ──── (M) transactions
       ├─ user_id FK
       └─ settled_at determines ownership

payouts (1) ──── (M) invoices
       ├─ payout_id FK
       └─ Must be COMPLETED before invoice created
```

---

## Soft-Delete vs Hard-Delete

<!-- TODO: Policy on which tables soft-delete, which allow hard-delete -->

**Soft-delete only** (maintain audit trail):
- transactions — Financial audit trail must be preserved
- payouts — Payout history must be queryable
- [any table with compliance/audit requirement]

**Hard-delete allowed** (non-critical):
- [logs] — TTL-based cleanup
- [temp tables] — Session-scoped

---

## Indexes

<!-- TODO: All important indexes for query performance -->

| Table | Index | Columns | Reason |
|-------|-------|---------|--------|
| transactions | idx_user_created | (user_id, created_at DESC) | Per-user history queries |
| transactions | idx_status_updated | (status, updated_at) | Job queue scans |
| payouts | idx_user_status | (user_id, status) | User dashboard filter |

---

## Migration Strategy

<!-- TODO: Guidelines for adding/removing columns -->

**Adding columns**:
- Add with default value
- Backfill in a separate migration if expensive
- No blocking operations during peak hours

**Removing columns**:
1. Remove column from code (write only, read both old/new)
2. Backfill new column for 7+ days
3. Verify parity (old value = new value for all rows)
4. Remove old column in separate migration

**Shared tables** (written by 2+ services):
- Coordinate with other service owners
- Schedule migration during low-traffic window
- All consumers must deploy before/after in correct order
