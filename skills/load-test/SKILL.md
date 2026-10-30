---
name: load-test
description: Use after /performance-test passes, to test a flow under concurrent load: pooling, locks, cache coherency, circuit breakers and recovery.
---

# /load-test — Concurrent Access & Scalability Testing

Tests multi-service behavior under concurrent load. Validates connection pooling, lock handling, cache coherency, circuit breaker behavior, and recovery time across the complete call chain.

**When**: After `/performance-test` passes; before production deployment
**Input**: Scenario name, concurrency level (e.g., "refund-flow", concurrency=50)
**Output**: Concurrent request success/failure distribution, lock contention histogram, circuit breaker triggers, recovery time, resource exhaustion points

## Process

1. **Define baseline** — Run single-instance load test (establish baseline latency distribution)
2. **Identify resource limits** — Connection pools, database connections, memory, cache size limits
3. **Execute concurrent test** — Launch N concurrent identical requests (same payout_id, same account, same row)
4. **Measure contentions** — Lock wait times, deadlocks, timeout failures, circuit breaker trips
5. **Verify atomicity** — Concurrent balance mutations don't cause duplicates or inconsistencies
6. **Test recovery** — Inject failures (service restart, connection pool saturation, cache invalidation); measure recovery time
7. **Report scaling behavior** — At what concurrency level does system degrade? What's the breaking point?

## Output (REQUIRED FORMAT)

> **Illustrative template.** All numbers below are placeholder examples showing
> the required shape — NOT measured results. Replace every value with figures
> from an actual run; never copy these numbers into a report.

```
## Concurrent Access & Scalability Testing

Scenario: refund-concurrent-access
Services: returns-service, orders-service, reporting-service, api-gateway
Test environment: staging
Test timestamp: 2026-04-19T16:15:00Z
Concurrency levels tested: 1, 5, 10, 25, 50, 100

---

### Baseline (Single-Instance)

```
Concurrency: 1
Total requests: 100
Successful: 100
Failed: 0
p50 latency: 85ms
p99 latency: 195ms
p99.9 latency: 285ms
```

Baseline established: p99 = 195ms (matches /performance-test SLA)

---

### Concurrency Test: 5 Concurrent Requests

```
Total requests: 500 (5 concurrent × 100 iterations)
Successful: 500
Failed: 0
Lock wait time distribution:
  p50: 2ms (lock acquired immediately)
  p99: 15ms (lock briefly contended)
  max: 42ms (multiple requesters waiting for lock)
Lock contention incidents: 3 of 500 (0.6%)
```

**Latency distribution (WITH lock contention):**
```
p50:  87ms
p95:  125ms
p99:  210ms (was 195ms single-instance, +7.7% degradation acceptable)
p99.9: 305ms
max:  515ms
```

✓ PASS — 5 concurrent requests handled correctly; latency degradation acceptable (<10%)

---

### Concurrency Test: 10 Concurrent Requests

```
Total requests: 1000 (10 concurrent × 100 iterations)
Successful: 1000
Failed: 0
Lock contention incidents: 45 of 1000 (4.5%)
Lock wait time:
  p50: 3ms
  p99: 28ms
  max: 156ms (10 requesters all waiting for same payout_id lock)
```

**Latency distribution:**
```
p50:  92ms
p95:  155ms
p99:  285ms (was 195ms single-instance, +46% degradation, still under 300ms threshold)
p99.9: 425ms
max:  1042ms (timeout-close, but didn't fail)
```

✓ PASS — 10 concurrent requests handled; lock contention expected and managed correctly

---

### Concurrency Test: 25 Concurrent Requests

```
Total requests: 2500 (25 concurrent × 100 iterations)
Successful: 2495
Failed: 5 (0.2% failure rate due to timeout)
Lock contention: 312 of 2500 (12.5%)
Lock wait time:
  p50: 8ms
  p99: 85ms (queue building up)
  max: 1250ms (near timeout threshold of 1000ms)
```

**Latency distribution:**
```
p50:  105ms
p95:  245ms
p99:  520ms (was 195ms single-instance, +167% degradation)
p99.9: 890ms
max:  2100ms
```

**Failures (5):**
- 4 failures due to lock wait timeout (exceeded 1000ms default)
- 1 failure due to database connection pool saturation (max pool size hit)

⚠️ WARNING — 25 concurrent requests approaching limits. Latency degradation 167%. Failures starting to occur.

---

### Concurrency Test: 50 Concurrent Requests

```
Total requests: 5000 (50 concurrent × 100 iterations)
Successful: 4850
Failed: 150 (3% failure rate)
Lock contention: 1450 of 5000 (29%)
Lock wait time:
  p99: 245ms
  max: 2800ms (well beyond timeout)
```

**Latency distribution (successful requests only):**
```
p50:  185ms
p95:  645ms
p99:  1890ms (timeout-adjacent)
p99.9: 3200ms
```

**Failure breakdown:**
- 95 failures due to lock wait timeout
- 40 failures due to connection pool exhaustion (db/connection limit)
- 15 failures due to query timeout (database under load)

**Circuit breaker behavior:**
- None triggered (no cascading failures detected)
- But retry backoff starting to accumulate

❌ FAIL — 50 concurrent requests exceeds system capacity. 3% failure rate unacceptable for production. Bottleneck: connection pool (25 connections) insufficient for 50 concurrent requesters.

---

### Concurrency Test: 100 Concurrent Requests (Stress Test)

```
Total requests: 1000 (100 concurrent × 10 iterations, reduced to prevent cascade)
Successful: 620
Failed: 380 (38% failure rate)
Lock contention: ~100% (all requests waiting)
```

**Cascade observed:**
- At T+15sec: orders-service connection pool exhausted (max 25 connections)
- At T+18sec: orders-service returns "connection pool timeout" errors
- At T+22sec: orders-service circuit breaker trips (after 10 consecutive failures)
- At T+25sec: Circuit breaker prevents new requests, fails fast instead of timing out
- At T+30sec: Circuit breaker half-open (allows 1 test request)
- At T+32sec: orders-service responsive again; circuit breaker closes
- Recovery time: 17 seconds (from first failure to circuit breaker close)

**Latency when flowing:**
```
p99: 8500ms (requests waiting in circuit breaker queue)
max: 12000ms (test timeout)
```

✗ REJECT — 100 concurrent requests causes cascading failure. Circuit breaker + recovery working as designed, but system cannot handle this load.

---

### Resource Analysis

**Connection Pool Sizing:**
```
Current orders-service pool: 25 connections
Current api-gateway pool: 30 connections

At 50 concurrent requests:
  Used connections: 35-40 (exceeds 25-connection limit)
  Waiting for connection: 10-15
  Wait time: 100-300ms per request
  
At 100 concurrent requests:
  Queuing: 75+ requests waiting for 25 connections
  Pool exhaustion: permanent
```

**Recommendation: Increase orders-service connection pool from 25 to 50.**

**Lock Contention Analysis:**

```
At 25 concurrent requests to same payout_id:
  Queue depth: 10-15 (average)
  p99 lock wait: 85ms
  Max lock wait: 1250ms
  
Root cause: SELECT FOR UPDATE lock held for 50-60ms while orders-service processes.
All other requesters queue behind this lock.

This is expected behavior for financial consistency. Mitigation:
  (1) Partition payouts by user_id (different locks for different users)
  (2) Reduce transaction duration (move non-critical work outside lock)
  (3) Accept higher latency at peak load
```

**Cache Behavior Under Load:**

```
Cache type: Redis (balance cache, if enabled)
Cache hit rate at low concurrency (5 requests): 95%
Cache hit rate at high concurrency (50 requests): 60% (cache invalidation thrashing)
Cache invalidation latency: 15-30ms per balance mutation

Finding: If cache is used for account balance decisions, cache invalidation causes thundering herd.
Recommendation: NEVER cache account balance for transactional decisions. Cache only read-heavy, rarely-changing data.
```

---

### Recovery Testing

**Scenario 1: Service Restart (orders-service)**

```
Normal load: 10 concurrent requests
At T=0: orders-service service killed (simulating crash)
At T=0-5: Current requests in flight fail (connection lost)
At T=5-10: Circuit breaker trips after 3 consecutive failures
At T=10-15: Service restarts, circuit breaker half-open
At T=15-20: Circuit breaker closes, traffic resumes
Total recovery time: 15-20 seconds

During recovery: 8 requests failed out of 50 attempted (16% failure rate)
Post-recovery: p99 latency returns to baseline (195ms) within 1 second
```

**Scenario 2: Database Connection Pool Saturation**

```
Normal load: 25 concurrent requests
At T=0: Close all idle connections in pool (simulate pool leak)
Pool goes from 25 available to 0 available
At T=0-5: Requests wait for connection (queue builds)
At T=5-10: Connection timeout threshold exceeded; requests start failing
At T=10-15: Circuit breaker trips (10 consecutive failures)
At T=15-30: Service unable to recover (connections still exhausted)
At T=30+: Manually restart orders-service service
Recovery time: 30+ seconds (manual intervention required)
```

**Finding: Connection pool leak causes cascade.** Recommendation: Add health check to drain and rebuild connection pool if stuck.

**Scenario 3: Cache Invalidation (Account Balance)**

```
Load: 10 concurrent balance deductions on same account
Cache: Redis with 1-second TTL

Expected: Cache hit on first read, TTL expires, cache invalidated
Actual: 
  Request 1: Cache miss (cold start) → DB read (10ms) → update (8ms) → invalidate (2ms) → 20ms total
  Request 2: Cache miss (invalidated by request 1) → DB read (10ms) → update (8ms) → invalidate (2ms) → 20ms total
  ...all 10 requests cache-miss because invalidation happens before TTL expires

This is correct behavior — balance must be fresh. But the pattern shows cache is not helpful for balance decisions.
```

---

### Summary Table

| Concurrency | Success Rate | p99 Latency | Failures | Status |
|-------------|--------------|-------------|----------|--------|
| 1           | 100%         | 195ms       | 0        | ✓ PASS |
| 5           | 100%         | 210ms       | 0        | ✓ PASS |
| 10          | 100%         | 285ms       | 0        | ✓ PASS |
| 25          | 99.8%        | 520ms       | 5        | ⚠️ WARNING |
| 50          | 97%          | 1890ms      | 150      | ❌ FAIL |
| 100         | 62%          | 8500ms      | 380      | ❌ FAIL |

**Recommended safe concurrency**: 10 (all succeed, <10% latency degradation)
**Maximum acceptable concurrency**: 25 (>99% success, latency degradation acceptable)
**Breaking point**: 50+ (failures begin, circuit breaker triggers)

---

### Recommendations

1. **Immediate (before production):**
   - [ ] Increase orders-service connection pool from 25 to 50
   - [ ] Test recommended safe concurrency (10) against production database scale

2. **Short-term (next sprint):**
   - [ ] Implement circuit breaker for inter-service calls (if not present)
   - [ ] Add connection pool health check to detect leaks
   - [ ] Monitor lock contention on payouts table in production

3. **Long-term (architecture):**
   - [ ] Partition payouts by user_id to reduce lock contention (different users → different locks)
   - [ ] Reduce transaction duration inside SELECT FOR UPDATE lock
   - [ ] Consider eventual consistency for non-critical balance reads

---

### Load Test Escalation Criteria

**If /load-test shows any of the following, BLOCK production deployment:**
- Failure rate >1% at 10 concurrent requests
- p99 latency >2x baseline at 25 concurrent requests
- Circuit breaker required at <25 concurrent requests
- Recovery time >30 seconds after service restart

**If any escalation criteria met, address bottleneck and re-run /load-test.**

---

### Sign-Off

✓ **APPROVED FOR PRODUCTION** (with conditions)

- System safely handles up to 10 concurrent requests with <10% latency increase
- System can tolerate 25 concurrent requests with acceptable failures
- Circuit breaker and recovery mechanisms working correctly
- Connection pool saturation is the limiting factor; increase from 25 to 50
- After connection pool increase, re-run /load-test to validate new limits

Deployment contingent on: (1) connection pool increase, (2) load test re-run confirming capacity
```

---

## Constraints

1. **Production-scale data** — Test against realistic data volumes (10M+ payouts in database), not toy data
2. **Concurrent requests to same row** — Test financial operations that contend for same lock (payout_id, account_id)
3. **Percentile reporting required** — Report p50, p95, p99, p99.9, max; not just average
4. **Lock wait time measured separately** — Distinguish between application latency and lock wait latency
5. **Failure modes tested** — Service crash, connection pool exhaustion, circuit breaker behavior, recovery
6. **Recovery time measured** — From failure injection to system fully operational (not just request succeeding)
7. **Throughput vs latency trade-off** — Show how system degrades under increasing load
8. **Resource limits identified** — Exactly what runs out first? Connections? Memory? CPU?
9. **Cascading failure detection** — Does one service failure cascade to others?
10. **Idempotency under concurrency** — Even with 100 concurrent requests, no duplicate balance mutations allowed
