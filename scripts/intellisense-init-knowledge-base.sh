#!/bin/bash
# intellisense-init-knowledge-base.sh
# Initialize knowledge-base/ directory structure
# Usage: ./scripts/intellisense-init-knowledge-base.sh [path]

set -euo pipefail

REPO_PATH="${1:-.}"
REPO_PATH="$(cd "$REPO_PATH" 2>/dev/null && pwd)" || {
  echo "Error: Repository path not found" >&2
  exit 1
}

KB_DIR="$REPO_PATH/knowledge-base"

# Check if knowledge-base already exists
if [[ -d "$KB_DIR" ]]; then
  echo "✓ knowledge-base/ already exists at $KB_DIR"
  exit 0
fi

# Create directory
mkdir -p "$KB_DIR"

# Create README.md
cat > "$KB_DIR/README.md" << 'EOF'
# Knowledge Base

This directory contains the authoritative architecture, domain knowledge, and risk information for this repository.

## Files

- **project-context.md** — Quick reference: stack, owned resources, key patterns (auto-loaded into CLAUDE.md)
- **architecture.md** — System design, data flow, component relationships
- **domain-rules.md** — Domain-specific patterns, constraints, architectural decisions
- **critical-flows.md** — High-impact execution paths (payments, authentication, data sync, etc.)
- **risk-register.md** — High-risk files, critical operations, known fragile areas
- **protected-files.md** — Files that require extra care (migrations, generated code, configs)
- **data-model.md** — Tables, schemas, primary/foreign key relationships
- **api-contracts.md** — Endpoints, authentication, request/response contracts
- **integrations.md** — Third-party services, webhooks, external dependencies
- **queues-and-jobs.md** — Async jobs, queue names, job handlers, SLA expectations
- **redis-and-cache.md** — Cache keys, expiration policies, invalidation rules
- **testing-guide.md** — Test setup, fixtures, integration test strategy
- **operational-runbook.md** — Deployment, rollback, debugging, incident response
- **known-gotchas.md** — Common mistakes, antipatterns, "why we do X"
- **change-history.md** — Major refactors, migrations, breaking changes, lessons learned
- **migration-review.md** — Outstanding data migrations, deprecation timeline

## How to Use

1. **On first read** of the codebase — start with project-context.md, then architecture.md
2. **Before modifying a critical area** — read risk-register.md and protected-files.md
3. **When implementing a feature** — check domain-rules.md and critical-flows.md
4. **When touching APIs/queues/cache** — update the corresponding doc immediately after

## Maintenance

These files are living documentation. Update them when:
- Adding a new critical flow or endpoint
- Discovering a new risk or gotcha
- Completing a major refactor (update change-history.md)
- Changing data model or schema (update data-model.md)

Keep these files in sync with the code. Stale documentation is worse than no documentation.
EOF

# Create project-context.md
cat > "$KB_DIR/project-context.md" << 'EOF'
# Project Context

<!-- Auto-loaded into CLAUDE.md. Keep this under 900 words. -->

## Service Overview

**Service**: [Service Name]
**Stack**: [Go/PHP/JavaScript/Angular]
**Owner**: [Team/Person]
**Repository**: [Link to repo]

## Owned Resources

### Database Tables
- List tables owned by this service (read/write)

### API Endpoints
- List public endpoints and their consumers

### Key Dependencies
- List services this depends on (read/write)

## Key Patterns

- [Pattern 1]: [Brief description of why we use this pattern]
- [Pattern 2]: [Brief description]

## Critical Constraints

- [Constraint 1]: [Why it matters]
- [Constraint 2]: [Why it matters]
EOF

# Create architecture.md
cat > "$KB_DIR/architecture.md" << 'EOF'
# Architecture

## System Design

[Describe system components and their responsibilities]

## Data Flow

[Describe how data flows through the system]

## Component Relationships

[Describe interactions between major components]

## Key Design Decisions

1. [Decision]: [Why this was chosen over alternatives]
2. [Decision]: [Why this was chosen]
EOF

# Create domain-rules.md
cat > "$KB_DIR/domain-rules.md" << 'EOF'
# Domain Rules

## Execution Rules

[Rules that must be followed during implementation]

## Architectural Constraints

[Constraints that shape design decisions]

## Patterns We Use

[Description of standard patterns in this domain]

## Patterns We Avoid

[Anti-patterns and why they don't work here]
EOF

# Create critical-flows.md
cat > "$KB_DIR/critical-flows.md" << 'EOF'
# Critical Flows

## [Flow Name]

**Impact**: [What breaks if this fails]
**Frequency**: [How often this executes]
**SLA**: [Expected response time / processing time]
**Retry Policy**: [How many retries, backoff strategy]
**Files Involved**: [Key files for this flow]

[Description of the flow]

## [Another Flow]

[Similar structure]
EOF

# Create risk-register.md
cat > "$KB_DIR/risk-register.md" << 'EOF'
# Risk Register

## High-Risk Files (Large or Complex)

| File | Size | Risk Reason | Notes |
|------|------|-------------|-------|
| [example.php] | [150KB] | Core business logic | Changes require full integration test |

## Critical Services

[List services/classes that are high-risk]

## Known Fragile Areas

[Areas that have caused incidents or require special care]
EOF

# Create protected-files.md
cat > "$KB_DIR/protected-files.md" << 'EOF'
# Protected Files

## Never Edit Without Approval

- **migrations/** — Database schema changes require careful review
- **config/** — Configuration changes affect production
- **vendor/** — Auto-generated, never edit directly
- **.env** and secrets — Never commit credentials

## Require Full Test Coverage Before Touching

- High-risk files listed in risk-register.md
- Files that handle payments, authentication, or data deletion

## Generated/Compiled (Do Not Edit)

- Build output directories
- npm/composer/vendor files
- Generated protocol buffers or schema files
EOF

# Create data-model.md
cat > "$KB_DIR/data-model.md" << 'EOF'
# Data Model

## Tables

### [Table Name]

**Purpose**: [What this table stores]
**Owned by**: [Which service owns this]

| Column | Type | Notes |
|--------|------|-------|
| id | bigint | Primary key |

**Indexes**: [List important indexes]
**Foreign Keys**: [List relationships]

## Relationships

[Describe how tables relate to each other]
EOF

# Create api-contracts.md
cat > "$KB_DIR/api-contracts.md" << 'EOF'
# API Contracts

## [Endpoint Name]

**Method**: GET/POST/PUT/DELETE
**Path**: `/api/v1/resource`
**Auth**: [Required permissions]
**Input**: [Request schema]
**Output**: [Response schema]
**Consumers**: [Which services call this]

[Description]

## Deprecation Timeline

[List endpoints being deprecated and when they disappear]
EOF

# Create integrations.md
cat > "$KB_DIR/integrations.md" << 'EOF'
# Integrations

## [External Service]

**Purpose**: [What we use this for]
**API Version**: [Version]
**Rate Limits**: [Limits, if any]
**Credentials**: [Where stored — never paste into code]
**Error Handling**: [How to handle service downtime]
**Monitoring**: [Where to check service health]

[Description and any gotchas]
EOF

# Create queues-and-jobs.md
cat > "$KB_DIR/queues-and-jobs.md" << 'EOF'
# Queues and Jobs

## [Queue Name]

**Purpose**: [What jobs go on this queue]
**Processing SLA**: [Max time to process]
**Retry Policy**: [Retries and backoff]
**Dead Letter Queue**: [Where failed jobs go]

### Jobs

- **JobName**: [What it does] [File: App/Jobs/JobName.php]

## Queue Configuration

[Environment variables, connection settings]
EOF

# Create redis-and-cache.md
cat > "$KB_DIR/redis-and-cache.md" << 'EOF'
# Redis and Cache

## Cache Keys

| Key Pattern | Type | TTL | Purpose |
|------------|------|-----|---------|
| `user:{id}:profile` | Hash | 1h | User profile data |

## Cache Invalidation

- [Cache key]: [When to invalidate]
- [Cache key]: [When to invalidate]

## Session Storage

[How sessions are stored, if applicable]
EOF

# Create testing-guide.md
cat > "$KB_DIR/testing-guide.md" << 'EOF'
# Testing Guide

## Unit Tests

[Directory and naming conventions]

## Integration Tests

[What to test, how to set up test database]

## Test Fixtures

[Fixture structure, how to add test data]

## Running Tests

[Command to run tests, where logs go]
EOF

# Create operational-runbook.md
cat > "$KB_DIR/operational-runbook.md" << 'EOF'
# Operational Runbook

## Deployment

[How to deploy, rollback, health checks]

## Incident Response

[How to debug common issues]

## Monitoring and Alerts

[What to monitor, where dashboards are]

## Database Maintenance

[Backup, restore, migration procedures]
EOF

# Create known-gotchas.md
cat > "$KB_DIR/known-gotchas.md" << 'EOF'
# Known Gotchas

## [Gotcha Title]

**Mistake**: [What developers often do wrong]
**Impact**: [What breaks as a result]
**Prevention**: [How to avoid it]
**Example**: [Example of the mistake]

## Common Pitfalls

[Other common mistakes in this codebase]
EOF

# Create change-history.md
cat > "$KB_DIR/change-history.md" << 'EOF'
# Change History

## Major Refactors

[Document major changes, why they happened, impact]

## Breaking Changes

[API changes, database schema changes]

## Lessons Learned

[What we learned from past incidents or refactors]
EOF

# Create migration-review.md
cat > "$KB_DIR/migration-review.md" << 'EOF'
# Migration Review

## Outstanding Migrations

[List pending data migrations or schema changes]

## Deprecation Timeline

[Timeline for removing deprecated features]

## Existing Documentation Notes

[If docs/ directory exists, reference it here]
EOF

# Check if docs/ already exists
if [[ -d "$REPO_PATH/docs" ]]; then
  cat >> "$KB_DIR/migration-review.md" << 'EOF'

## Existing Documentation

The `docs/` directory contains existing project documentation. Review and migrate relevant content to this knowledge-base/ as needed.
EOF
fi

echo "✓ Knowledge base initialized at $KB_DIR"
echo "  - Created 16 documentation files"
echo "  - project-context.md is auto-loaded (keep it <900 words)"
echo "  - Update other files as you learn the codebase"
