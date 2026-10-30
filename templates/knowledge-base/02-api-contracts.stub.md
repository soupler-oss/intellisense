<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# API Contracts

Endpoints consumed by OTHER services. Only include external APIs (APIs called by consumers outside this service).

## Endpoint 1: [Method /path]

<!-- TODO: Add each external-facing endpoint consumed by other services -->

```
GET /api/v1/payouts/:cycle_id
```

**Consumed by**: reporting-service, web-app

**Purpose**: Fetch payout details for audit trail and user dashboard

**Auth**: Bearer token (OAuth2) — service-to-service

**Query Parameters**:
- `include_transactions` (boolean, optional) — Include line-item transactions (default: false)

**Response (200 OK)**:
```json
{
  "id": 123,
  "user_id": 456,
  "amount_minor_units": 100000,
  "status": "COMPLETED",
  "created_at": "2026-04-27T10:00:00Z",
  "transactions": [
    {
      "id": 1001,
      "amount_minor_units": 50000,
      "reference_id": "ORD-789"
    }
  ]
}
```

**Errors**:
- `404 Not Found` — payout doesn't exist
- `403 Forbidden` — caller not authorized to view this payout
- `500 Internal Server Error` — [indicate rare case]

**Rate Limit**: 1000 req/min per service; 429 if exceeded

**SLA**: Response within 200ms (p95), 500ms (p99)

---

## Endpoint 2: [Method /path]

```
POST /api/v1/reconcile
```

**Consumed by**: api-gateway

**Purpose**: Trigger account reconciliation for discrepancy resolution

**Auth**: Bearer token (OAuth2) — service-to-service

**Request Body**:
```json
{
  "user_id": 456,
  "expected_balance_cents": 250000
}
```

**Response (202 Accepted)**:
```json
{
  "job_id": "async-job-789",
  "status": "QUEUED",
  "estimated_completion": "2026-04-27T10:05:00Z"
}
```

**Errors**:
- `400 Bad Request` — Missing required field
- `409 Conflict` — Reconciliation already in progress for this user
- `500 Internal Server Error` — [indicate rare case]

**Async Behavior**: Job runs asynchronously; caller polls `/jobs/{job_id}` for result

---

## Versioning Policy

<!-- TODO: How API versioning works -->

- Current version: `/api/v1`
- Deprecated version: `/api/v0` (sunset 2026-06-30)
- Breaking changes: New major version
- Additive changes: No new version required (backward-compatible)

## Deprecation Timeline

<!-- TODO: When endpoints are removed -->

| Endpoint | Deprecated | Sunset |
|----------|-----------|--------|
| GET /api/v0/payouts | 2026-03-01 | 2026-06-30 |

All consumers must migrate to v1 before sunset date.

## Client Library

<!-- TODO: If you provide an SDK -->

Available at: [github.com/your-org/payout-sdk-go]

Version: 1.2.0

Usage:
```go
import "github.com/your-org/payout-sdk-go"

client := payout.NewClient(apiKey)
payout, err := client.GetPayout(ctx, cycleID)
```
