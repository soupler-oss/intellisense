---
name: cross-service-diagnose
description: Use when a bug shows up in one service but is caused by another, to trace it across service boundaries using the service map.
---

# /cross-service-diagnose — Multi-Repo Bug Diagnosis

Trace bug across service boundaries using service-map call chain.

**When**: Bug appears in one service but caused by another; traces via API/DB relationships
**Input**: Symptom + affected service (e.g., "[symptom] in [service-a], but upstream is [service-b]")
**Output**: Root cause service + likely component

## Process

1. **Map call chain** — Read service-map.md to understand data flow If its tables are empty (the shipped template), ask the user for the call chain instead of guessing it.
2. **Identify direction** — Is problem upstream (data source) or downstream (consumer)?
3. **Trace backward** — Follow dependencies to data source
4. **Check each service** — Query state at each layer
5. **Find where problem first appears** — That service owns the bug

## Output (REQUIRED FORMAT)

```
## Cross-Service Bug Diagnosis
Symptom: [feature-name] failing in [service-a]
Service reporting issue: [service-a]
Status: [error-message or symptom]

### Call Chain (from service-map.md)
[service-a] → reads [shared-table-name] from [service-b]
[service-a] → reads [local-table-name] from own DB
[service-a] → calls [service-b] API to verify [data-type]

### Hypothesis: Check Upstream First
Problem might be: [service-b] returning [data-error]
Problem might be: [service-b] API is slow/timing out
Problem might be: [service-a] query is wrong

---

### Layer-by-Layer Investigation

**Layer 1: [service-b] Database** (upstream data source)
```sql
SELECT COUNT(*) FROM [shared-table-name] WHERE [problematic-condition];
```
Result: [N] rows with [issue-description] ⚠️
Evidence: [service-b] has data quality issue

Check [service-b] query:
```
[code-snippet showing inadequate validation]
```
Finding: [service-b] doesn't validate [data-field] before returning

**Layer 2: [service-b] API Response**
```bash
curl https://[service-b].internal/api/v1/[endpoint]/[id]
```
Response:
```json
{
  "[field-name]": [invalid-value],
  "[id-field]": "[id-value]"
}
```
Finding: API returns [invalid-value] without filtering or error

**Layer 3: [service-a] Logic**
```
[code-snippet showing service-a's handling of data]
```
Evidence: [service-a] correctly handles data, but [service-b] sent invalid value

---

### Root Cause Identified
**Service**: [service-b]
**Component**: `[file-path]` — `[function-name]()` function
**Bug**: [description of the bug]

**Evidence chain**:
1. [service-b] DB has [issue] (Layer 1)
2. [service-b] API returns [issue] (Layer 2)
3. [service-a] fails because it can't [action] (Layer 3)

**Root cause is in [service-b]**, not [service-a].

---

### Confidence Assessment
- Database evidence: [%]
- API evidence: [%]
- Call chain traced: [%]
- **Confidence in root cause**: [%] — Bug is in [service-b] [component]

### Recommended Action
1. Fix [service-b]: [specific fix]
2. Fix [service-b]: [secondary fix if applicable]
3. Test [service-a] after [service-b] fix
4. If [service-b] fix doesn't resolve, escalate to [service-a] repo
```

---

## Complex Example: Async Problem

```
## Cross-Service Bug Diagnosis
Symptom: [consumer-service] missing [event-type] events
Service reporting issue: [consumer-service]
Status: Only [%] of [events] appear in [destination-table]

### Call Chain
[producer-service] (event owner) 
  → async call to [consumer-service] (fire-and-forget)
    → [consumer-service] logs to [event-log-table]

### Hypothesis: Async Delivery Issue
Problem might be: Queue is dropping messages
Problem might be: [consumer-service] consumer is crashing
Problem might be: [producer-service] queue producer is failing silently

---

### Layer-by-Layer Investigation

**Layer 1: [producer-service] Queue Producer**
Check [producer-service] logs for event emission:
```
[timestamp] [[producer-service]] Event 123 completed
[timestamp] [[producer-service]] Queued event for [consumer-service]
[timestamp] [[producer-service]] Event 124 completed
[timestamp] [[producer-service]] Queue error: [error-type]
[timestamp] [[producer-service]] Event 125 completed
[timestamp] [[producer-service]] Queue error: [error-type] (retrying...)
```
Finding: [producer-service] had queue connection issues during [time-range]

**Layer 2: Queue State**
Check how many messages are in queue:
```
Topic: [event-topic-name]
Partition 0: [count] messages
Partition 1: [count] messages
Consumer lag ([consumer-service]): [count] messages
```
Finding: Queue has messages waiting to be consumed; [consumer-service] is catching up

**Layer 3: [consumer-service] Consumer**
Check [consumer-service] logs:
```
[timestamp] [[consumer-service]] Processing event [id]
[timestamp] [[consumer-service]] Inserted log entry
[timestamp] [[consumer-service]] Consumer crashed: [error-type]
[timestamp] [[consumer-service]] Consumer restarted by monitoring
[timestamp] [[consumer-service]] Processing event [id+2] (skipped [id+1])
```
Finding: [consumer-service] crashed and lost messages

---

### Root Cause Identified
**Primary**: [consumer-service] consumer crashes under load ([error-type])
**Secondary**: [producer-service] queue producer had connection issues during same window

**Evidence chain**:
1. [producer-service] attempted to queue events (Layer 1) — mostly succeeded, some failed
2. Queue has messages waiting (Layer 2)
3. [consumer-service] consumer crashes, loses messages (Layer 3)

**Root causes**: 
1. [consumer-service] [resource-issue or code-issue] (primary)
2. [producer-service] queue connection resilience (secondary)

### Recommended Action
1. Fix [consumer-service]: [specific fix for primary root cause]
2. Fix [producer-service]: Improve queue connection retry logic
3. Missing logs from [time-range]: Manual entry or replay queue
4. Prevent recurrence: Set up alerts for consumer lag >[threshold]
```

## Constraints
1. **Map relationships first** — service-map.md is the authority
2. **Follow the call chain backward** — Data flows from A→B→C, trace C←B←A
3. **Verify at each layer** — DB state, API response, service logs
4. **Confidence <80% = escalate further** — You might need multiple hops
5. **Time correlation matters** — Check timestamps to see what happened when
6. **Async problems are hardest** — Queue lag, message loss, consumer crashes all possible
