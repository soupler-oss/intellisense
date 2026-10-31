---
name: multi-service-plan
description: Use when a feature touches more than one service, to break it into per-repository tasks with a safe deployment order.
---

# /multi-service-plan — Multi-Repo Feature Planning

Analyze a cross-service requirement into per-repo task breakdown with deployment sequence.

**When**: Multi-repo feature (1+ services affected)
**Triggers**: Multi-service changes, API design, shared library changes (affecting multiple consumers)

## Input
- Requirement statement: "add [feature-name] to [service-function]"
  - Example: "add reconciliation validation to payment processing"
- Optional: Repo list if already known; if omitted, Step 0 discovers it

## Process (8 steps)

0. **Discover affected repos** (if not already provided) — Read service-map.md. If its tables are empty (the shipped template), ask the user which repos are affected instead of guessing. Analyze requirement term by term against infrastructure/knowledge-base.md. Search codebase for keyword matches in CLAUDE.md Service definitions. Identify all repos reading/writing affected tables or consuming affected APIs. Rank by relevance: primary (direct), secondary (downstream), tertiary (shared config).

1. **Read service-map.md** — Understand relationships, call chains, shared concerns (for identified repos)
2. **Read each affected repo's CLAUDE.md** — Stack, Architecture, Shared Database Tables, API Contracts, Library Consumers, Deployment Order sections only
3. **Identify integration points** — How and Where do repos talk? Shared tables? API calls? Shared libraries?
4. **Design per-repo tasks** — Break down requirement into repo-specific implementations
5. **Determine deployment order** — Which repo deploys first? Which are blocking?
6. **Identify pre-work validation** — Which checks must happen before coding: an API contract's consumers, a shared table's readers and writers, a shared library's or component's consumers? List each consumer from service-map.md and the repos' CLAUDE.md, to be checked by hand.
7. **Flag escalations** — Financial logic? Requires architect review? Shared library? Web Component?

## Output (REQUIRED FORMAT)

```
## Repos Affected (in deployment order)
1. **[service-a]** — [feature-implementation-scope]
2. **[service-b]** — [dependent-action-description]
3. **[service-c]** — [consumer-action-description]

## Per-Repo Task Breakdown

### Repo 1: [service-a]
- **Task**: Implement [feature-name] in [service-function]
- **Files**: [model-files], [service-files], [handler-files]
- **Tests**: [test-type-1], [test-type-2], [test-type-3] (N test cases)
- **Dependencies**: Reads from [shared-table-name] (shared table)
- **Pre-work**: List every reader and writer of [shared-table-name] from service-map.md; confirm none is unknown
- **Risk**: [risk-level] — [mitigation]. Flag for `/verify` and `/code-review` if high-risk changes.

### Repo 2: [service-b]
- **Task**: Implement [feature-name] for [service-b]
- **Files**: [model-files], [handler-files]
- **Tests**: [test-type-1], [test-type-2] (N test cases)
- **Dependencies**: Reads [service-a] API ([METHOD] [/path])
- **Pre-work**: Check every consumer of [METHOD] [/path] (CLAUDE.md API Contracts) still works with the change
- **Risk**: API contract changed; [service-b] is downstream consumer

### Repo 3: [service-c]
- **Task**: Integrate [feature-name] from [service-a]
- **Files**: [controller-files], [service-files]
- **Tests**: [integration-test-type] (N test cases)
- **Dependencies**: Calls [service-a] ([METHOD] [/path])
- **Pre-work**: Covered by the API consumer check for [service-a]

## Deployment Order
1. Deploy [service-a] FIRST (provides new API endpoint or data)
2. Deploy [service-b] (consumes endpoint, safe to deploy any time after [service-a])
3. Deploy [service-c] (consumes endpoint, safe to deploy any time after [service-a])
   - Parallel deploy possible: [service-b] and [service-c] can deploy simultaneously after [service-a]

## Rollback Plan
In case of production incident, reverse deployment order:
1. **Rollback [service-c]** (revert to previous version)
2. **Rollback [service-b]** (revert to previous version)
3. **Rollback [service-a]** (revert to previous version, restore database with pre-migration state if applicable)

Per-service rollback commands:
- **[service-a]**: `git revert [commit] && [build-command] && [migration-rollback-if-applicable]`
- **[service-b]**: `git revert [commit] && [build-command]`
- **[service-c]**: `git revert [commit] && [build-command]`

Database rollback (if shared table migrations involved):
- If [shared-table-name] altered: Restore from backup or run the migration's explicit rollback SQL

**Time estimate**: Full rollback should complete in <10 minutes with database restore, <2 minutes without.

## Integration Tests
- After all repos deployed: verify [feature-name] flow end-to-end
- [Data-source] in [service-a] → [Processing] in [service-a] → [Result] in [service-b] → Triggered from [service-c]

## Pre-Work Validation Required (After Deployment Plan)
- [ ] Every reader and writer of each shared table identified and checked
- [ ] Every consumer of each changed API contract checked for compatibility
- [ ] Architect review for [domain] logic design (if applicable)

## Success Criteria
- All repos build and tests pass independently
- Cross-repo integration tests pass
- Safety checklist complete (95%+ coverage on critical paths if applicable)
- All pre-work validations pass
```

## Constraints
1. Never assume deployment order — CLAUDE.md section is source of truth
2. If a shared table is involved, its readers and writers MUST be checked first
3. If an API contract changes, its consumers MUST be checked first
4. Financial logic requires 95%+ test coverage — non-negotiable
5. List ALL repos, not just the ones you plan to modify (read-only repos matter for validation)
