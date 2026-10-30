---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Database Migrations (Flyway / Liquibase)

Stack-owned subfile of `java-patterns.md`. **Tier 2 content** — migration rules govern production schema operations. Mirrors [`security.md`](../../baseline/security.md) §"Database Migrations". Flyway preferred; Liquibase allowed where established.

## Location

- **Flyway:** `src/main/resources/db/migration/V<timestamp>__<description>.sql` (versioned, one-way) and `R__<description>.sql` (repeatable — views, stored procs)
- **Liquibase:** `src/main/resources/db/changelog/db.changelog-master.yaml` + per-change YAML/SQL files

## Naming (Flyway, required convention)

`V<UTC-timestamp>__<snake_case_description>.sql`

```
V20260514120000__add_index_orders_user_id.sql
V20260514130000__add_column_orders_promo_code.sql
```

- **UTC timestamp** prevents collisions across teams committing in parallel
- **Description must be specific** — `add_index_orders_user_id`, not `add_index`, not `fix`
- Two underscores between timestamp and description (Flyway convention)

## Immutability rule (non-negotiable)

**Never edit a merged versioned migration.** Once `V<...>__foo.sql` lands on `main`, treat it as frozen. To change schema, write a NEW V-file with the fix.

**Why this is mechanical, not advisory:** Flyway records each file's SHA-256 checksum in `flyway_schema_history`. Editing a merged V-file makes downstream deployments fail with `MigrationChecksumMismatch` — the running production app's `flyway_schema_history` no longer matches what's in the new artifact. The fix is either:
1. Roll back the production app to a build that hasn't run this migration yet (impossible if other V-files have run since), OR
2. Manually update `flyway_schema_history` in production to the new checksum (operationally dangerous; loses the audit trail)

Either way, editing a merged V-file is a deploy-breaker. The patterns file calls this an absolute (no LEGACY carveout) — see `java-patterns.md` §"Common Anti-Patterns".

## Required PR checklist for any migration

Mirrors [`security.md`](../../baseline/security.md) Tier 2 baseline:

- [ ] Scheduled outside peak hours (per per-service deploy window in `git-workflow.md` if defined)
- [ ] Shared-table consumers identified (grep `service-map.md` for `Shared Tables` listings) and notified if breaking
- [ ] **Exact rollback SQL in PR description** — actual SQL, not "revert commit". Rollback might require manual DML even after reverting the V-file.
- [ ] No `DROP COLUMN` / `DROP TABLE` in the same PR as the code that stops using the column — must use shadow-mode pattern below

## Shadow-mode column removal (mandatory 4-PR pattern)

Any column drop on a production table follows this sequence. No shortcuts; the bake intervals exist to give all consumers time to catch up.

| PR | Action | Bake before next PR |
|---|---|---|
| 1 | Add new column. App dual-writes old + new. Old column intact. | ≥7 days |
| 2 | Backfill existing rows (script or migration). Parity check: `SELECT COUNT(*) FROM t WHERE old_col != new_col` returns 0. | Until parity green |
| 3 | App stops writing old column. Old column data is now read-only history. | ≥3 days |
| 4 | `DROP COLUMN old_col`. | — |

If at any point during the 4-PR sequence a bug is discovered with the new column, the rollback is "stop writing new column, continue with old column". This requires PR1's dual-write to still be in place — never collapse PR1 and PR2 into one.

## Forbidden within a single migration file

- **DDL + DML mixed on large tables** — `ALTER TABLE ... ADD COLUMN` followed by `UPDATE ... SET ...` in the same V-file. MySQL locks the table during ALTER; the UPDATE stalls or fails with `Lock wait timeout exceeded`. Split into two V-files.
- **`DROP TABLE` without explicit `CREATE TABLE` recovery script in the PR description** — drop without a documented recreation path is irrecoverable.
- **Index creation on tables >1M rows without `ALGORITHM=INPLACE, LOCK=NONE`** (MySQL 5.7+) — naive `CREATE INDEX` locks the table for writes for the duration of the index build (can be minutes on a hot table).

## MySQL-specific: `ALGORITHM=INPLACE, LOCK=NONE`

For online DDL on large MySQL tables, always specify the lock + algorithm hints:

```sql
-- V20260514120000__add_index_orders_user_id.sql
-- Purpose: speed up order listing by user (P90 800ms → 50ms)
-- Rollback: DROP INDEX idx_orders_user_id ON orders;
-- Estimated lock: <1s on 5M-row table (ALGORITHM=INPLACE, LOCK=NONE)

ALTER TABLE orders
  ADD INDEX idx_orders_user_id (user_id),
  ALGORITHM=INPLACE,
  LOCK=NONE;
```

The header comments are part of the convention — purpose, rollback SQL, estimated lock. PR review picks these up.

**Not all operations support `INPLACE, NONE`.** MySQL's online DDL matrix has exceptions (e.g. column-type changes often require `COPY` and a table lock). Test in staging first; if MySQL silently downgrades to `LOCK=SHARED` you'll find out under load.

## PostgreSQL-specific: `CONCURRENTLY` for index creation

```sql
CREATE INDEX CONCURRENTLY idx_orders_user_id ON orders (user_id);
```

`CONCURRENTLY` avoids the exclusive lock — readers and writers continue. Caveats: takes longer overall, can't run inside a transaction (so use Flyway's `mixed=true` mode if your migration framework wraps everything in a transaction by default).

## Liquibase-specific rules

If the repo uses Liquibase instead of Flyway:

- Each `<changeSet>` must have a unique `id` + `author` pair. **Never reuse an `id`** — Liquibase tracks applied changesets by (`id`, `author`); a duplicate is silently skipped, hiding the migration from production.
- Use explicit `<rollback>` blocks for every changeset. Liquibase auto-rollback handles only some operations (drop-column auto-rollback can't recover data; you need a CSV dump in the rollback block for that).
- `runAlways: true` is **forbidden on schema-changing changesets** — idempotency burden falls entirely on the SQL author, and most authors don't write idempotent DDL.

## Testcontainers pattern for migration tests (required)

- Run migrations against a real MySQL/PostgreSQL container matching the prod engine + version
- Verify migration is **idempotent** — run twice; the second run should be a no-op, not an error
- Assert post-migration schema matches `@Entity` annotations (Hibernate's `ddl-auto: validate` catches drift)
- **Never** test migrations against H2 — H2 silently accepts MySQL-incompatible DDL (e.g. MySQL-specific `ALGORITHM=INPLACE` clauses), passing in tests while failing in production

```java
@Testcontainers
@SpringBootTest
class FlywayMigrationsIT {
    @Container
    static MySQLContainer<?> db = new MySQLContainer<>("mysql:8.0.32");

    @DynamicPropertySource
    static void wire(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", db::getJdbcUrl);
        r.add("spring.datasource.username", db::getUsername);
        r.add("spring.datasource.password", db::getPassword);
    }

    @Test
    void migrations_apply_idempotently() {
        // Flyway runs on context startup. If any V-file fails, the
        // test fails to start.
        // Second run: re-applying should be a no-op (Flyway checks
        // flyway_schema_history; already-applied V-files are skipped).
    }
}
```

## Anti-patterns

- Editing a merged V-file (breaks checksum; see "Immutability rule" above)
- Migration ordering by filesystem sort instead of timestamp prefix (`V001__a.sql`, `V002__b.sql`) — works for the first few migrations, breaks the moment two developers commit on different days
- `DROP COLUMN` in the same PR as the code change that stops using it (must use 4-PR shadow-mode)
- DDL + DML mixed in one V-file
- Hibernate generating schema in production (`ddl-auto: update` or `create`) — Flyway/Liquibase owns the schema
- Missing rollback SQL in PR description ("revert commit" is not a rollback for a destructive migration)
- Index creation without `ALGORITHM=INPLACE, LOCK=NONE` (MySQL) / `CONCURRENTLY` (PostgreSQL) on large tables
- Testing migrations against H2 (silently accepts incompatible DDL)
- Liquibase `runAlways: true` on schema-changing changesets

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint; migration immutability is an absolute in §"Common Anti-Patterns"
- [`persistence-jpa.md`](persistence-jpa.md) — `@Entity` ↔ migration drift caught by `ddl-auto: validate`
- [`financial.md`](financial.md) — money columns must be `DECIMAL(precision, scale)` or `BIGINT` (integer minor currency units), never `DOUBLE`
- [`../../baseline/security.md`](../../baseline/security.md) — Tier 2 migration baseline, shared-table consumer identification
- [`service-map.md`](../../../infrastructure/service-map.md) — shared-table registry for impact analysis
