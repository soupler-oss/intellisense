---
applies_to: [all]
phase: [0]
priority: HIGH
enforcement: advisory
load_when: planning
---

# Protocol Governance Rules

Version: 1.0
Purpose: Define what intellisense owns (execution protocol) vs what repos own (domain knowledge), and resolve conflicts during adoption.

---

## intellisense Owns: Execution Protocol

These rules are canonical to intellisense and apply to all repos. Changing these requires consensus from all repo teams.

- **Development Phase Workflow** (Phase 0-6: Requirements → Implementation → Review → Release)
- **Change Contract Structure** (JSON evidence tracking, scope gating, risk scoring)
- **Session Lifecycle Rules** (git close protocol, token budget, test gates before PR)
- **Security Boundaries** (secret management, PII handling, input validation at system boundaries)
- **Code Quality Standards** (immutability, naming, file/function size limits, dead code removal)
- **Git Workflow** (commit message format, squashing strategy, deployment windows, merge gates)
- **Testing Discipline** (test-first for new code, no test deletion without evidence)
- **Documentation Discipline** (auto-loaded docs, drift detection, token budgets per file type)
- **Agent Orchestration** (which agents run in which phase, what they enforce)
- **Knowledge Governance** (knowledge-base structure, what gets auto-loaded, what stays reference-only)

**Why**: These are meta-level rules that govern HOW repos use intellisense. They are intentionally abstract and language-agnostic. Changing them affects all repos simultaneously, so all repos must agree.

**How to apply**: If a repo wants to deviate from execution protocol (e.g., "we don't do change contracts" or "we skip Phase 1 requirements"), that's a STOP and a conversation — not a local override. Bring it to the protocol governance board.

---

## Repos Own: Domain Knowledge

Each repo maintains authoritative knowledge about their specific business logic, API contracts, data models, and risk landscape. This knowledge lives in the repo's knowledge-base/ and CLAUDE.md.

- **API Contracts** (endpoints, methods, auth, consumers, rate limits)
- **Data Model** (tables, columns, indexes, relationships, soft-delete strategy)
- **Business Logic Rules** (financial rules, validation rules, state machines)
- **Critical Flows** (order processing, payments, user signup, etc.)
- **Risk Register** (high-risk files, protected tables, audit trails)
- **Integrations** (external APIs, webhooks, webhooks we send)
- **Deployment Strategy** (canary, blue-green, feature flags, rollback runbooks)
- **Operational Runbooks** (on-call procedures, common incidents, escalation paths)
- **Known Gotchas** (subtle behaviors, performance cliffs, historical bugs)
- **Domain Terms & Concepts** (your external billing system, fulfilment/order lifecycle terms, minor vs major currency units — whatever your domain uses)

**Why**: These are repo-specific and change frequently as the business evolves. Centralizing them in intellisense would make intellisense a monolithic knowledge dump. Instead, repos maintain authoritative knowledge and intellisense provides the structure (knowledge-base/) and sync tools (drift detection).

**How to apply**: When a developer needs to understand a repo's domain, they read repo-specific knowledge-base/ files, not intellisense documentation.

---

## Priority Order: When intellisense and Repo Rules Conflict

**Scenario**: Repo's CLAUDE.md says "we skip Phase 1 requirements" but intellisense says Phase 1 is mandatory.

**Resolution Order**:

1. **intellisense Execution Protocol Wins** (if it's in the protocol-governance list above)
   - Example: "Phase 1 is mandatory" is an execution protocol rule → repo must do it
   - Rationale: Meta-rules govern all repos; deviation requires organizational consensus

2. **Repo Domain Knowledge Customization Allowed** (if it's domain knowledge)
   - Example: Repo CLAUDE.md says "our critical flows are X, Y, Z" → intellisense doesn't override
   - Example: Repo says "we use PostgreSQL, not MySQL" → valid domain choice
   - Rationale: Repos know their domain better than intellisense

3. **Repo-Specific Patterns for Language** (if language-specific rules differ)
   - Language-specific rules (go-patterns.md, laravel-patterns.md, angular-patterns.md) apply to all repos of that language
   - If a Go repo disagrees, they escalate to all 6 Go teams
   - Rationale: Language patterns are shared across multiple repos; one repo doesn't unilaterally change them

4. **Repo Overrides Require Written Record** (if repo explicitly chooses different approach)
   - Override goes in repo CLAUDE.md under "## Security Exceptions" or "## Protocol Exceptions"
   - Include: what rule is being overridden, why, what compensating controls exist
   - Example: "We don't implement rate limiting on auth endpoints because we use OAuth provider's built-in limits"
   - Rationale: Audit trail; next developer knows this was intentional, not accidental

---

## During Pilot Phase: Governance Validation

As intellisense is adopted, repos will have governance gaps (unmanaged protocol blocks, missing knowledge-base files, etc.). These are warnings, not blockers.

### Governance Warnings (Not Blockers)

**When to warn**:
- CLAUDE.md has a "## Execution Mode" or "## Change Contract" heading that intellisense doesn't recognize (suggests this was written before intellisense adoption, needs migration)
- knowledge-base/ directory doesn't exist or is incomplete (missing critical-flows.md, api-contracts.md, etc.)
- Risk register doesn't exist (repo hasn't identified high-risk files)

**How to warn** _(planned — `scripts/validate-claude-governance.sh` is not yet implemented)_:
- Run `scripts/validate-claude-governance.sh .` in repo
- Default mode: prints warnings to stdout, exit 0 (non-blocking)
- `--strict` mode: exit 1 (used in CI to fail PRs)

**What happens**:
- Pilot phase (first 3 months): warnings only, no CI failure
- After pilot: `--strict` mode enabled in CI, warnings become blockers
- Timeline allows repos time to migrate, update, clean up

### Knowledge-Base Drift Detection

Run during CI (weekly or per-PR):

```bash
scripts/intellisense-knowledge-base-health.sh --audit .
```

Detects:
- API routes not in knowledge-base/api-contracts.md
- Queue jobs not in knowledge-base/queues-and-jobs.md
- Redis keys not in knowledge-base/redis-and-cache.md
- High-risk files (>500 lines) not in knowledge-base/risk-register.md

Output: `PASS` or `WARN: update knowledge-base/api-contracts.md to include POST /users/invite`

---

## Implementation Guidance

### For intellisense Maintainers

When adding a new execution protocol rule:

1. Ask: "Does this apply to all repos?"
   - If yes: add to "intellisense Owns" section, increment protocol version
   - If no: it's domain knowledge, belongs in a template or skill, not protocol-governance.md

2. Write the rule concisely (one sentence, what it enforces)

3. Add to rules/operational/development-workflow.md (not here) if it's a Phase 0-6 workflow rule

4. Notify all repo teams that protocol changed (required for consensus)

### For Repo Contributors

When you want to deviate from execution protocol:

1. Identify the rule you disagree with (e.g., "Phase 1 requirements are too heavyweight")

2. Propose a specific alternative (e.g., "We do Phase 1 async, starting after code review")

3. Document in repo CLAUDE.md under "## Protocol Exceptions" with justification

4. Escalate to protocol governance board (all repo leads) for approval

5. If approved, update protocol-governance.md "Priority Order" section to reflect exception

### For New Repos Adopting intellisense

1. Start with intellisense execution protocol (non-negotiable for pilot phase)
2. Create knowledge-base/ directory with 16 template files (auto-scaffolded by `scripts/intellisense-init-knowledge-base.sh`)
3. Migrate existing docs/ into knowledge-base/ files (documented in template)
4. Run governance validation: `scripts/validate-claude-governance.sh --strict .` _(planned — not yet implemented)_
5. Fix warnings before first PR
6. Enable drift detection in CI: run `scripts/intellisense-knowledge-base-health.sh --audit .` on every PR

---

## Governance Validation Workflow

**Phase: Planning (Phase 0)**

Before implementation starts, confirm:
- [ ] CLAUDE.md has no unmanaged protocol headings (run validator)
- [ ] knowledge-base/ directory exists and is >80% complete
- [ ] risk-register.md identifies high-risk files
- [ ] Token budgets set for this repo's rule files

**Phase: Implementation (Phase 2-3)**

If you modify CLAUDE.md or add new domain knowledge:
- [ ] Update knowledge-base/ files
- [ ] Run `scripts/intellisense-drift-check.sh .` to verify code-documentation sync _(planned — not yet implemented)_
- [ ] Commit together: code + knowledge-base updates in same PR

**Phase: Review (Phase 4)**

Code reviewer checks:
- [ ] High-risk files have been reviewed extra carefully
- [ ] Protected files (migrations, config, secrets) have explicit approval notes
- [ ] Knowledge-base files updated to match code changes
- [ ] Drift check passes

---

## Known Gaps (Pilot Phase)

These areas are not yet governed by intellisense but will be in v2:

- **Agent Behavior Contracts**: What agents can and cannot do during each phase (coming in v2)
- **Cross-Repo Protocol**: How repos coordinate when one change affects multiple services (coming in v2)
- **Financial Audit Trail**: Specific rules for payment repos (currently in individual CLAUDE.md files, will be centralized in v2)
- **Schema Change Governance**: How to migrate shared tables safely (currently manual, will have automation in v2)

---

## AI Regression Pattern Lifecycle

Catalog `@rules/operational/ai-regression-patterns.md` is hard-capped at 1500 tokens. Additions that breach the cap block until compression or retirement.

**Adding a pattern.** Requires ≥2 documented incidents, OR a reasoned argument with ≥1 hypothetical demonstrating the bug class. Submission includes: name, origin, affected stacks, detection signal, mitigation pointer, retirement criteria. Approved by platform-rules-owner; consensus required only to reject.

**Per-entry metadata** (tracked manually during pilot, automated in Phase 2): `sprints_active`, confirmed `catches`, `dismissed` count, `last_caught` date.

**Retirement triggers** (any one):
- ≥4 consecutive sprints with 0 catches
- Mechanical detector (linter, type checker, schema diff) covers the pattern → drop from human-attention catalog
- Origin system rewritten or deprecated
- Pattern subsumed by a broader pattern (merge)
- `false_positives / catches > 3` (over-trigger signal)

**Review cadence.** Quarterly catalog review. Decision record committed under `docs/pattern-reviews/<YYYY-Qn>.md`. Skipped review = catalog frozen for that quarter (no silent drift).

**Merge/split.** Merge when two patterns share >70% of trigger conditions. Split when one pattern's mitigation differs by stack to the point a single trigger description misleads.

---

## Metrics Are Diagnostic, Not KPIs

Metrics emitted by the review and pattern systems (e.g., `[NEEDS-VERIFICATION]` confirmation rate, independent-review adherence, FP rate, bypass frequency) exist to detect when rules need revision. They MUST NOT:

- Evaluate individual developer or reviewer performance
- Auto-block PRs based on threshold violations (always retro decisions)
- Promote/demote developers, teams, or services
- Justify removing oversight (a "good" metric is not proof of safety)

Optimization target: defect reduction + developer trust. NOT making the dashboard look green. When a metric improves suddenly, investigate before celebrating — a drop in `[NEEDS-VERIFICATION]` rate may mean reviewers got better OR learned to suppress uncertainty. No metric in isolation: every retro decision must reference at least 2 metrics + 1 qualitative signal.

---

## Pattern Review Report Format

Manual during pilot; automated by `scripts/generate-pattern-review.sh` in Phase 2. Schema for the quarterly report (committed under `docs/pattern-reviews/<YYYY-Qn>.md`):

- Per-pattern stats table (id, name, invocations, catches, dismissals, last_caught, stacks)
- Auto-flagged candidates for retirement / tightening / splitting
- Cross-pattern overlaps detected
- Catalog token footprint (current vs cap)
- Human-decision checklist (retire, tighten, split, add)

---

**Version**: 1.0 (Pilot Phase)  
**Last Updated**: 2026-04-27  
**Maintainer**: intellisense Platform Team
