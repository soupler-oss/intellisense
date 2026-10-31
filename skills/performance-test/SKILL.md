---
name: performance-test
description: Use after /e2e-test passes, to measure end-to-end latency of a flow against its SLA and find the bottleneck.
---

# /performance-test — Cross-Service Latency & Performance Validation

Measures end-to-end latency across complete feature flows. Validates that multi-service interactions meet performance SLAs. Tests database query performance, API response times, and UI rendering latency across the entire call chain.

**When**: After `/e2e-test` passes; before staging approval
**Input**: Scenario name, SLA thresholds (e.g., "refund-flow", p99_ms=2000)
**Output**: Latency breakdown per service, heatmap, SLA pass/fail, bottleneck identification

## Process

1. **Define SLA targets** — From CLAUDE.md performance requirements or defaults
2. **Instrument all services** — Add timing hooks to measure execution per layer
3. **Execute scenario with load** — Run 100+ iterations to collect distribution
4. **Measure at each layer** — API gateway → returns-service → orders-service DB → reporting-service DB → UI render
5. **Analyze percentiles** — p50, p95, p99 latencies; identify outliers
6. **Identify bottlenecks** — Which service/query is slowest? Why?
7. **Report SLA compliance** — Pass if all services within budget, Fail if any exceed

## Output (REQUIRED FORMAT)

> **Illustrative template.** All latencies, percentiles, and verdicts below are
> placeholder examples showing the required shape — NOT measured results.
> Replace every value with figures from an actual run; never copy these numbers
> into a report.

```
## Cross-Service Latency Testing

Scenario: refund-complete-flow
Services: returns-service, orders-service, reporting-service, api-gateway, auth-service
Test duration: 5 minutes (500 requests)
Test timestamp: 2026-04-19T15:45:00Z
Environment: staging

---

### SLA Targets

| Component | SLA (p99) | SLA (p95) | Status |
|-----------|-----------|-----------|--------|
| returns-service API | 200ms | 100ms | ✓ OK |
| orders-service DB (balance update) | 50ms | 30ms | ✓ OK |
| reporting-service DB (audit insert) | 80ms | 50ms | ✓ OK |
| api-gateway webhook | 300ms | 150ms | ⚠️ WARNING |
| auth-service UI render | 500ms | 300ms | ✓ OK |
| **Complete flow (end-to-end)** | **1500ms** | **900ms** | **⚠️ WARNING** |

---

### Detailed Timing Breakdown (500 requests)

#### Layer 1: API Gateway → returns-service Service

```
Total requests: 500
Successful: 500
Failed: 0

Latency Distribution:
  p50:  85ms
  p75:  105ms
  p90:  135ms
  p95:  158ms
  p99:  195ms
  max:  342ms

SLA target (p99): 200ms
✓ PASS — 195ms < 200ms
```

**Timing breakdown (average):**
- Request parsing: 2ms
- Authentication: 8ms
- Route resolution: 1ms
- Handler execution: 74ms
  - Parse refund params: 5ms
  - Validate idempotency_key lookup: 15ms
  - Call orders-service service: 50ms (network + processing)
- Response serialization: 2ms

**Bottleneck: orders-service service call (50ms avg)**

---

#### Layer 2: returns-service → orders-service (Inter-Service API Call)

```
Total requests: 500
Successful: 500
Failed: 0

Latency Distribution:
  p50:  45ms
  p75:  52ms
  p90:  68ms
  p95:  82ms
  p99:  115ms
  max:  180ms

SLA target (p99): 200ms
✓ PASS — 115ms < 200ms

Network breakdown:
  DNS lookup: 1ms
  TCP handshake: 2ms
  Request send: 1ms
  orders-service processing: 38ms
  Response receive: 3ms
```

**orders-service processing breakdown (38ms avg):**
- Request parsing: 1ms
- Balance calculation: 25ms (SELECT FOR UPDATE lock wait)
- Database update: 8ms
- Response serialization: 4ms

---

#### Layer 3: orders-service → Database (SELECT FOR UPDATE)

```
Total requests: 500
Successful: 500
Lock contention: 12 instances (2.4%)

Query: SELECT balance FROM invoices WHERE invoice_id = ? FOR UPDATE

Latency Distribution:
  p50:  8ms
  p75:  10ms
  p90:  18ms
  p95:  25ms
  p99:  42ms
  max:  156ms

SLA target (p99): 50ms
✓ PASS — 42ms < 50ms

Breakdown (when no contention):
  Lock acquisition: 2ms
  Query execution: 3ms
  Result fetch: 1ms
  Lock release: 2ms

Breakdown (when contention - 12 instances):
  Avg wait time: 45ms
  Max wait time: 156ms (lock held by concurrent request)
```

**Lock contention analysis:**
- 12 of 500 requests experienced lock wait >30ms
- Worst case: 156ms (request had to wait for another transaction)
- Root cause: 2 concurrent requests to same invoice_id
- This is expected under load; idempotency prevents duplicate effects
- SLA still met (p99 = 42ms < 50ms)

---

#### Layer 4: reporting-service → Database (Audit Insert)

```
Total requests: 500
Successful: 500

Query: INSERT INTO audit_logs (...) VALUES (...)

Latency Distribution:
  p50:  5ms
  p75:  7ms
  p90:  12ms
  p95:  18ms
  p99:  32ms
  max:  89ms

SLA target (p99): 80ms
✓ PASS — 32ms < 80ms

Breakdown:
  Connection pool get: 1ms
  INSERT execution: 3ms
  Index update (audit_logs_invoice_id): 1ms
  Commit: 1ms
```

**No contention on this table.** Audit inserts are sequential (single writer pattern).

---

#### Layer 5: api-gateway Webhook Delivery

```
Total webhook attempts: 500
Successful: 495 (99%)
Retried: 4 (1st attempt failed, 2nd succeeded)
Failed after retry: 1 (0.2%)

Latency Distribution (including retries):
  p50:  120ms
  p75:  165ms
  p90:  250ms
  p95:  340ms
  p99:  450ms
  max:  1200ms

SLA target (p99): 300ms
⚠️ WARNING — 450ms > 300ms (exceeded by 150ms, or 50% overage)

Breakdown (avg successful):
  Request serialization: 5ms
  Network: 80ms
  webhook endpoint processing: 35ms
  Webhook handler queue: 5ms
  Response receive: 15ms
```

**Bottleneck: Network latency (80ms)**
- api-gateway is in different data center
- Network RTT = 80ms (cannot improve without infrastructure change)
- Potential fix: Move api-gateway to same datacenter (future work)

**Retried failures (4):**
- 1st attempt failed (timeout 1000ms > configured timeout)
- Retry with exponential backoff succeeded
- Pattern: Initial network hiccup, recovery on retry
- Not a code issue; infrastructure stability issue

**1 permanent failure:**
- Webhook endpoint returned 500 error
- Retry also failed with 500
- api-gateway may have been under load or in bad state
- Requires investigation during incident response

---

#### Layer 6: auth-service UI Rendering

```
Total page loads: 500
Successful: 500
Failed: 0

Metrics (after complete API flow):
  HTML received: 45ms
  JavaScript parsing: 120ms
  DOM rendering: 85ms
  React re-render: 95ms
  Image loading: 200ms
  Final paint (first contentful paint): 385ms

SLA target (p99): 500ms
✓ PASS — 385ms < 500ms

Breakdown:
  Network (API call to orders-service): 50ms (parallel, not sequential)
  Rendering: 240ms
  Image lazy load: 200ms (after initial render)
```

**No bottleneck in UI layer.** React re-render (95ms) is acceptable for large component trees.

---

### End-to-End Summary

**Complete flow latency (from API call to UI update):**

```
returns-service API call: 85ms (p50)
  ├─ orders-service response: 45ms
  │  └─ Database SELECT FOR UPDATE: 8ms
  ├─ reporting-service audit: 5ms
  ├─ api-gateway webhook (async): 120ms (happens in background)
  └─ auth-service UI refresh: 385ms (parallel with webhook)

Total (sequential): 85ms + 385ms = 470ms
Total (p99): 195ms + 450ms = 645ms (if webhook blocks; but it doesn't)
Actual (p99, truly async): 195ms + 385ms = 580ms
```

**SLA target (p99): 1500ms (end-to-end)**
**Actual (p99): 580ms**
**Headroom: 920ms (61% under budget)**

✓ **PASS — End-to-end performance meets SLA**

---

### Bottleneck Analysis

| Bottleneck | Layer | Current (p99) | SLA | Status | Impact | Recommendation |
|-----------|-------|---------------|-----|--------|--------|-----------------|
| api-gateway network | Webhook | 450ms | 300ms | ⚠️ WARNING | 50% over SLA | Infrastructure: collocate datacenters (future) |
| returns-service handler | API Gateway | 195ms | 200ms | ✓ OK | 2% margin | Monitor; no urgent action |
| reporting-service DB lock | Database | 42ms | 50ms | ✓ OK | 16% margin | Lock contention acceptable under load |

---

### Load Testing Results

**Concurrency test (10 concurrent refunds to same invoice):**

```
Concurrent requests: 10
Each request: Execute refund for same invoice_id
Duration: 30 seconds

Results:
  Successful refunds: 10 (all succeeded, no duplicates due to idempotency)
  Lock wait time: 85-156ms per request (expected under contention)
  Total invoice balance mutation: Exactly 1x (correct)
  Audit trail: All 10 operations logged (correct)

Conclusion: ✓ PASS — Concurrent access handled correctly with locks
```

---

### Recommendations

1. **Urgent (before production):**
   - [ ] Investigate api-gateway webhook endpoint (1 permanent failure)
   - [ ] Confirm webhook timeout is 1000ms (retry should succeed faster)

2. **Short-term (next sprint):**
   - [ ] Monitor network latency between datacenters
   - [ ] Consider caching orders-service balance queries (if no cache exists)

3. **Long-term (architecture):**
   - [ ] Move api-gateway to same datacenter as orders-service
   - [ ] Implement circuit breaker for webhook delivery (prevent cascading failures)

---

### Sign-Off

✓ **APPROVED FOR PRODUCTION** — End-to-end latency meets SLA with acceptable margin

All p99 latencies are within target (or have clear roadmap to improve).
No infrastructure bottlenecks blocking production.
Load testing shows concurrency is handled correctly.
```

---

## Example: Performance Test Failure

> **Illustrative example** — fabricated numbers demonstrating a FAIL verdict's
> shape, not a real measurement.

```
## Cross-Service Latency Testing

Scenario: refund-complete-flow
Services: returns-service, orders-service, reporting-service, api-gateway, auth-service
Test duration: 5 minutes (500 requests)
Test timestamp: 2026-04-19T16:30:00Z
Environment: staging

---

### SLA Targets

| Component | SLA (p99) | Actual (p99) | Status |
|-----------|-----------|-------------|--------|
| returns-service API | 200ms | 285ms | ✗ FAIL |
| orders-service DB | 50ms | 1250ms | ✗ FAIL |
| Complete flow | 1500ms | 2850ms | ✗ FAIL |

---

### Investigation: orders-service DB Query Bottleneck

**Query: SELECT balance FROM invoices WHERE invoice_id = ? FOR UPDATE**

```
Latency Distribution:
  p50:  125ms (was 8ms before)
  p99:  1250ms (was 42ms before)
  max:  2100ms

Root cause: N+1 query problem detected

Code (WRONG):
for each refund in refunds {
    balance = db.query("SELECT balance FROM invoices WHERE invoice_id = ?", id)  // ← INSIDE LOOP
    update balance
}

Fixed code:
balances = db.query("SELECT balance FROM invoices WHERE invoice_id IN (?)", ids)  // ← BATCHED
for each refund in refunds {
    balance = balances[refund.invoice_id]
    update balance
}
```

**Impact:**
- 500 sequential queries instead of 1 batched query
- Database connection pool exhausted
- Lock contention increased 10x
- Timeouts (2100ms > 1000ms timeout)
- Some requests fail entirely

---

### ❌ BLOCKED FOR PRODUCTION

**Blocker**: orders-service database queries are not batched; N+1 problem causes 25x slowdown

**Required fix:**
1. Change to batched queries (see above)
2. Re-run `/performance-test refund-complete-flow`
3. Confirm p99 drops back to 42ms
4. Only then can feature be released
```

---

## Constraints

1. **Realistic load** — Test with 100+ requests to capture distribution, not just average
2. **Percentile reporting required** — Report p50, p75, p90, p95, p99; not just average
3. **SLA thresholds must exist** — In CLAUDE.md or service-level agreements; cannot be invented
4. **Per-service breakdown required** — Show timing for each service in chain, not just total
5. **Network latency matters** — Don't ignore it; include in analysis
6. **Lock contention must be measured** — For SELECT FOR UPDATE queries, show how long locks are held
7. **Async operations handled correctly** — Webhooks are fire-and-forget; don't block end-to-end latency
8. **Bottleneck identification required** — Show which layer is slowest and why
9. **Headroom required** — SLA target should have margin (don't run at 99% of limit)
10. **Retry behavior must be tested** — If service retries failed requests, measure including retries
