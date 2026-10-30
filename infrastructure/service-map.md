# Service Map

Central registry of your services, their relationships, stack, and paths. Used by `/where-to-start`,
`/cross-service-diagnose` and `/multi-service-plan`.

> **Fill this in for your organization.** It ships empty: an invented fleet would route real work to
> services that do not exist. While the tables are empty, the skills above ask which repository owns a change
> instead of guessing.

**Last Updated**: <date>
**Format Version**: 1.0 (compressed: keep it near ~300 tokens)

---

## Services

| Service | Purpose | Stack | Upstream | Downstream | Path |
|---------|---------|-------|----------|-----------|------|
<!-- e.g. | **orders-service** | Order lifecycle | Go + GORM | web-app | billing-service | ~/projects/orders-service | -->

---

## Shared Concerns

### Shared Database Tables

| Table | Owner | Also reads / writes |
|-------|-------|---------------------|

### Shared Libraries

| Library | Consumers |
|---------|-----------|

### API Contracts

| Endpoint | Consumers |
|----------|-----------|

---

## Quick Reference: Service by Concern

<!-- e.g. **Payments?** → billing-service + web-app -->
