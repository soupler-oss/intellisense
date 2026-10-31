---
applies_to: [go, php]
phase: [2, 3, 4, 5]
priority: HIGH
enforcement: blocking
load_when: task involves background jobs, queue workers, event listeners, scheduled tasks, retry logic
---

# Queue and Job Rules

## Loads when:

Load this rule file when the current task involves any of:
- Adding, modifying, or removing background jobs or queue workers
- Changing queue names, retry counts, or timeouts
- Adding event listeners or event-driven processing
- Writing scheduled tasks or cron jobs
- Modifying dead-letter queue handling

Do NOT load for frontend (Angular/React/Next/Vue) tasks — not applicable.

---

## Queue Naming

- Queue names must be defined in a central registry (PHP: `app/Constants/QueueNames.php`; Go: `pkg/config/jobs.go` or equivalent)
- Never hardcode queue names as string literals in job files — import from the central registry
- Use kebab-case: `invoice-processing`, `invoice-generation`, `webhook-retries`

## Idempotency (Non-negotiable)

Every job MUST be idempotent:
- Keyed by a business identifier (e.g., `invoice_id`, `event_id`) — NOT by job ID
- Running the same job twice with the same input must produce the same result
- Check for already-processed state at the start of the job handler before doing any work

## Retry Policy

Default retry policy unless the job has specific requirements:
- Strategy: exponential backoff
- Max retries: 5
- Backoff: 1s, 2s, 4s, 8s, 16s (32 seconds total)
- Final failure: move to dead-letter queue; alert ops; do NOT silently discard

## Dead-Letter Queue

- Every queue must have a corresponding DLQ: `dlq-[queue-name]`
- DLQ messages must be inspectable and replayable via admin tooling
- DLQ retention: minimum 30 days
- DLQ depth >10 must trigger an alert (page oncall)

## Failure Handling

On final retry failure:
1. Mark the job as FAILED in the database (never leave it in an ambiguous state)
2. Send alert to ops (Slack or equivalent)
3. Do NOT retry automatically after final failure — require human decision to replay

## Job Dependency Ordering

- Document job dependencies explicitly (Job B depends on Job A completing successfully)
- Never assume job ordering based on queue priority alone — use explicit dependency checks
- If Job B requires Job A's output, Job B must re-read the database state, not trust in-memory state

## Monitoring Requirements

Every job must have observable metrics:
- Success rate (target: ≥99.9%)
- Processing latency p95 (alert if >5s)
- Failure rate (alert if >0.1%)
- Queue depth (alert if >1000)

## Security

- Jobs must not log PII in their input/output (log IDs only, not full objects)
- Job input must be validated before processing begins
- Jobs that modify financial state require the same SELECT FOR UPDATE and idempotency guarantees as synchronous handlers

---

## Reference

See `knowledge-base/02-api-contracts.md` for the full job catalog (auto-extracted by Claude).
For queue topology and dependency graph, see `knowledge-base/03-biz-critical-flows.md`.
