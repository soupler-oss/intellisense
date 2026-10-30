<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Knowledge Base

This directory contains service-specific documentation. Files are loaded by Claude in **00→05 priority order** — lower number = loaded first.

## Files

### Auto-filled by Claude (review & enhance)

- **00-system-architecture.md** — Component diagram, layers, data flow, deployment model.
- **00-system-context.md** — Auto-loaded every session. Service name, stack, core tables, API endpoints, patterns.
- **01-system-tech-stack.md** — Language version, framework, top dependencies, test framework.
- **01-system-source-tree.md** — Depth-3 directory tree with layer descriptions.
- **02-api-contracts.md** — HTTP endpoints exposed (Go/PHP) or consumed (frontend), request/response schemas, auth.
- **02-data-models.md** — DB tables with columns, relationships, indexes (Go/PHP); TypeScript interfaces and DTOs (frontend).
- **04-eng-testing-guide.md** — Test structure, test database setup, CI gates, coverage targets.

### Team-required (humans fill)

- **03-biz-critical-flows.md** — Mission-critical user journeys: payout, payment, reconciliation, etc.
- **03-biz-domain-rules.md** — Business logic, domain constraints, term definitions specific to this service.
- **04-eng-gotchas.md** — Non-obvious issues discovered in production or development, how to avoid them.
- **04-eng-conventions.md** — Naming conventions, error handling style, PR checklist, code review standards.
- **05-meta-changelog.md** — Log of significant changes: date, type (feature/fix/refactor), files changed, approach.

### Special

- **migration-review.md** — (Adopt mode only) Original CLAUDE.md captured at setup time. Review and migrate content.

## When to Update

- **00-system-context.md**: Weekly via `/document-service --update-only` (automated)
- **01-system-tech-stack.md**, **01-system-source-tree.md**, **02-api-contracts.md**, **02-data-models.md**: Re-run `generate-kb-stubs.sh` after major changes
- **03-*, 04-*, 05-*** files: On demand when the aspect changes
- **05-meta-changelog.md**: Mandatory after full_feature and bug_fix merges

## Guidelines

- Keep each file under 2000 lines (split if larger)
- Use domain language, not generic terminology
- Link to code examples when helpful
- If a file is complete and stable, add: `<!-- STABLE — last reviewed YYYY-MM-DD -->`

## Why Separate Files?

Each file is a discrete topic. Claude loads the one it needs, keeping context focused. Only `00-system-context.md` is auto-loaded (stays <1.2k tokens).
