<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Engineering Gotchas

Non-obvious issues discovered in production or development. Avoid repeating them.

## Gotcha 1: [Issue Name]

<!-- TODO: Add each gotcha discovered -->

**Description**: [What the issue is]

**When it occurs**: [Conditions that trigger it]

**How to avoid**:
1. [Prevention step 1]
2. [Prevention step 2]
3. [Testing strategy to catch it]

**If it happens**:
1. [Debug step 1]
2. [Fix step 1]

**Example**: Transaction Isolation in GORM

**Description**: GORM transactions default to READ_COMMITTED isolation. If two concurrent requests both read a balance and deduct it, both may succeed, causing double deduction.

**When it occurs**:
- High concurrency on the same user's account
- Two invoice requests arrive within milliseconds of each other
- No SELECT FOR UPDATE on balance check

**How to avoid**:
1. Always use SELECT FOR UPDATE for balance mutations:
   ```go
   var balance int64
   db.WithContext(ctx).Clauses(clause.Locking{Strength: "UPDATE"}).
     Where("user_id = ?", userID).
     First(&balance)
   ```
2. Test with concurrent requests:
   ```bash
   ab -n 100 -c 10 http://localhost:8000/settle
   ```
3. Verify balance unchanged after 100 concurrent requests

**If it happens**:
1. Query transaction log: `SELECT * FROM transactions WHERE user_id = ? ORDER BY created_at DESC`
2. Identify duplicate invoice
3. Reverse one invoice with credit transaction
4. Notify user of accidental double-deduction
5. Add regression test (concurrent invoices on same user)

---

## Gotcha 2: Redis Cache Stale Reads

**Description**: Balance cached in Redis is stale; user makes withdrawal assuming higher balance, transaction fails.

**When it occurs**:
- Cache TTL is long (>5 min)
- Concurrent updates from multiple services
- Cache invalidation doesn't fire (race condition)

**How to avoid**:
1. Short TTL for critical fields (5 min for balance, not 24 hours)
2. Always verify against DB before state-changing operations:
   ```go
   // Read from cache for display
   displayBalance := redisGet("user_balance_" + userID)

   // But verify in DB before deduction
   dbBalance := db.Model(&User{}).Where("id = ?", userID).Select("balance")
   if dbBalance < amount {
     return ErrInsufficientFunds
   }
   ```
3. Cache invalidation on write:
   ```go
   // Update DB
   db.Model(&User{ID: userID}).Update("balance", newBalance)
   // Invalidate cache immediately
   redisDelete("user_balance_" + userID)
   ```

**If it happens**:
1. Check Redis TTL: `TTL user_balance_<user_id>`
2. Delete stale keys: `DEL user_balance_*`
3. Restart Redis cache refresh job
4. Reduce TTL to 2 min
5. Add integration test: write → verify cache invalidated → read returns fresh value

---

## Gotcha 3: Webhook Retry Explosion

**Description**: Webhook fails, our system retries exponentially, external API gets pounded with thousands of requests from us.

**When it occurs**:
- External API temporarily unavailable (maintenance, DDoS)
- Network latency spike causes all webhooks to timeout
- We retry aggressively without backoff

**How to avoid**:
1. Use exponential backoff with jitter:
   ```
   wait = base_delay × (2 ^ attempt) + random_jitter
   Attempts: 1s, 2s, 4s, 8s, 16s, give up
   ```
2. Cap max retries (5-10 total, not unlimited)
3. Circuit breaker pattern: if >10% of requests to external API fail, stop retrying, queue for manual review
4. Batch retries: instead of 1000 immediate retries, schedule 10 bulk retries over 24 hours

**If it happens**:
1. Check queue depth: `queue_depth --queue webhook-retries`
2. Pause retries: `queue_control --pause webhook-retries`
3. Manually trigger external API health check
4. Resume retries once API responds: `queue_control --resume webhook-retries`
5. Rotate API key if credential-based rate limit

---

## Gotcha 4: Migration Lock on High-Traffic Table

**Description**: Long-running migration locks `account_balances` table. Reads timeout. User-facing invoice requests fail.

**When it occurs**:
- ALTER TABLE on high-traffic table during business hours
- Migration takes >30 seconds (typical: index creation, column add with backfill)
- No read-write timeout configuration

**How to avoid**:
1. Schedule migrations during low-traffic windows (2-6 AM UTC)
2. Use online migration tool (Percona pt-online-schema-change) for large tables:
   ```bash
   pt-online-schema-change --alter "ADD COLUMN new_field INT" D=db,t=account_balances --execute
   ```
3. Test migration locally with production data snapshot (verify time <30s)
4. Communicate maintenance window to users (banner, email)
5. Have rollback SQL ready (see operational-runbook.md)

**If it happens**:
1. Kill migration: `KILL <migration_query_id>;`
2. Rollback to previous schema: `ALTER TABLE ... ADD/DROP ...` (reverse the change)
3. Verify invoice requests resume (latency should drop)
4. Re-run migration during low-traffic window with online tool
5. Alert ops to schedule future migrations outside peak hours

---

## Gotcha 5: Idempotency Key Collision

**Description**: Two different payments use the same idempotency key. Second payment processed as duplicate and blocked.

**When it occurs**:
- Client generates idempotency key unsafely (sequential, predictable)
- Retry logic reuses same key across different requests
- Clock skew on client side causes same timestamp for multiple requests

**How to avoid**:
1. Use cryptographically secure UUID for idempotency key (not timestamp or sequential):
   ```go
   idempotencyKey := uuid.New().String()  // Good
   idempotencyKey := strconv.Itoa(time.Now().Unix())  // Bad (collision risk)
   ```
2. Document for API consumers:
   ```
   Idempotency-Key: Must be a UUID; uniquely identifies this request
   Do NOT reuse the same key for different payments
   ```
3. Server-side validation: reject non-UUID keys
4. Test with concurrent requests using same key (should deduplicate, not fail)

**If it happens**:
1. Identify duplicate payment: `SELECT * FROM payments WHERE idempotency_key = '<key>'`
2. Verify amounts match
3. Check if both charged (should not be; deduplication should block second)
4. Refund duplicate if both charged
5. Contact client to regenerate idempotency key for future requests

---

## Gotcha 6: Soft-Delete Query Bypasses

**Description**: Engineer writes SQL query without WHERE deleted_at IS NULL, returns both active and deleted records.

**When it occurs**:
- Direct SQL queries (not through ORM)
- ORM default scopes not applied
- JOIN queries forgetting soft-delete scope

**How to avoid**:
1. Use ORM default scopes (GORM: `scope.Where("deleted_at IS NULL")`)
2. Code review: check every SQL query for soft-delete condition
3. Test: delete a record, verify it's not returned by list endpoints
4. Use `SELECT deleted_at, COUNT(*) GROUP BY` to catch scope bypasses

**If it happens**:
1. Search codebase for raw SQL queries: `grep -r "SELECT.*FROM invoices" --include="*.go"`
2. Add `WHERE deleted_at IS NULL` to queries missing it
3. Add regression test: delete record, verify not in response
4. Run full test suite (should catch any newly broken tests)
