<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# System Architecture

## Layers

<!-- TODO: Describe the main layers of this service -->

Example for Go service:
```
handlers/           → HTTP entry point, request parsing, auth, routing
├─ [handler].go
services/           → Business logic, orchestration, transaction coordination
├─ [service].go
repository/         → Database access via ORM (GORM, Pop)
├─ [repo].go
models/             → Struct definitions
├─ [model].go
middleware/         → Cross-cutting concerns (auth, logging, rate limiting)
├─ [middleware].go
tests/              → Unit tests (*_test.go alongside source)
```

## Security & Auth Layer

<!-- Optional: If this service has authentication/authorization, describe the auth model -->

TODO if applicable — middleware chain, auth guards, token flow, permission system

## Real-time Layer

<!-- Optional: If this service uses WebSockets, Server-Sent Events, or other real-time mechanisms -->

TODO if applicable — protocol (WebSocket/SSE), message types, broadcast patterns, connection lifecycle

## Data Flow

<!-- TODO: High-level data flow for main requests -->

**Example**: Invoice request → handler validates → service updates account → emits event → job updates ledger

## Database Design

<!-- TODO: Key tables, relationships, constraints -->

- Primary key strategy: [serial/UUID]
- Soft-delete: [yes/no]
- Transaction isolation: [READ_COMMITTED/REPEATABLE_READ/SERIALIZABLE]

## Deployment Model

<!-- TODO: How is this service deployed? Containers, monolith, serverless? -->

- Container: Docker / [other]
- Orchestration: Kubernetes / [other]
- Horizontal scaling: Stateless / [stateful because X]

## Key Dependencies

<!-- TODO: Internal and external dependencies that shape the design -->

**Internal**:
- Depends on [service] for [what]
- Consumed by [service] which [what]

**External**:
- Stripe API for payment processing
- AWS S3 for document storage
- [other external service]

## Known Constraints

<!-- TODO: Constraints that limit design choices -->

- [Constraint]: [Why it exists, what it affects]
- [Constraint]: [Why it exists]

Example:
- SELECT FOR UPDATE required on account_balances: Database-level locking prevents race conditions during concurrent invoices
- 60-second timeout on payment gateway calls: Gateway SLA is 120s; we timeout at 60s and retry
