<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# System Context

**Auto-loaded into Claude context via CLAUDE.md.** Keep under 1.2k tokens.

## Service

<!-- TODO: Service name and one-line purpose -->
[Service Name]: [Handles X for Y]

## Stack

<!-- TODO: Language, framework, ORM, database -->
[Go/PHP/Angular] with [framework/ORM]

## Owned Tables

<!-- TODO: Tables primarily owned/written by this service -->
- `table_name` — [purpose, soft-delete: yes/no]
- `table_name` — [purpose]

## Shared Tables

<!-- TODO: Tables written by 2+ services (cross-service risk) -->
- `table_name` — also written by [service, service]
- `table_name` — also written by [service]

## Key Endpoints

<!-- TODO: Endpoints consumed by other services (external API) -->
- GET /api/v1/[resource]: consumed by [service] — [purpose]
- POST /api/v1/[resource]: consumed by [service] — [purpose]

## Financial Rules (if applicable)

<!-- TODO: Money/payment rules specific to this service -->
- [Rule]: [Why it matters]
- [Rule]: [Why it matters]

Example:
- Balance mutations use SELECT FOR UPDATE: Prevents race conditions
- Idempotency key required: Ensures no duplicate charges
- All currency stored as int64 minor-currency-units: Prevents float rounding errors

## Critical Patterns

<!-- TODO: Architecture patterns, design decisions, non-obvious constraints -->
- [Pattern]: [Why used, when to apply]
- [Pattern]: [Why used]

Example:
- Event-driven invoice: async jobs decouple payment processing from account updates
- Soft-delete only: maintains audit trail for regulatory compliance
- Redis cache for read-heavy lookups: with 5-minute TTL, fallback to DB on miss

## Upstream Dependencies

<!-- TODO: Services this service depends on (calls/queries) -->
- [Service Name]: [why, API endpoint/table]
- [Service Name]: [why]

## Downstream Consumers

<!-- TODO: Services that depend on this service (call its APIs, read tables) -->
- [Service Name]: [what they consume]
- [Service Name]: [what they consume]
