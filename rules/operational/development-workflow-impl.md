---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4, 5, 6]
priority: CRITICAL
enforcement: blocking
load_when: coding
---

# Development Workflow — Implementation Phases (2–6)

Loaded for coding modes. Read after development-workflow.md (Phases 0–1, Approval Checkpoints, Tier/Mode tables).

## Phase 2: TDD

**Entry — must already exist:** Phase 1 Change Contract written with accurate `files_affected[]` (re-run `/contract` if scope changes); PreToolUse gate active (`bash verify-setup.sh` Check 17). **If the gate blocks: update the contract (re-run `/contract`), do NOT bypass.** Classifier/graph overrides (`--reason`, `INTELLISENSE_GRAPH_ENFORCE_OVERRIDE`) are emergency-only and audited to `~/.claude-intellisense/*.jsonl`. **`git push --no-verify` is different — it bypasses the pre-push hook entirely, leaves NO audit trail, and MUST NOT be used.** Routine bypass defeats intellisense and surfaces in review. Runtime deps must be available (language-specific rules) or tests can't run.

**bug_fix scope:** canonical limit + STOP-on-exceed live in development-workflow.md (Mode Definitions / Mode Enforcement). Do NOT enter Phase 2 if the contract exceeds it.

**Applies to `full_feature` / `bug_fix` only.** Skip Phase 2 for `pr_review`/`qa`/`design_review_only`/`fix_pr_comments`/`refactor`/`hotfix`. (`refactor`: existing tests stay green — a revealed failure is a bug, escalate. `hotfix`: write the regression test in Phase 4.)

**STOP — Gate Phase 2 → Phase 3 (blocking):**
- [ ] Failing test written and SHOWN to user
- [ ] Test RUN and confirmed failing (visible output, not assumed)

For `bug_fix`: regression test when feasible, else document the reason. **Silent skip = compliance violation.**

**Execution:** RED (write the failing test first, show it) → GREEN (minimum code to pass, no extras) → IMPROVE (refactor, tests green). Structure + coverage: testing.md (80% baseline, 95% financial). Done when all new functions/endpoints have tests and pass in isolation.

## Phase 3: Implement

**STOP — Gate Phase 3 → Phase 4 (blocking):**
- [ ] Language-specific build passes
- [ ] All files <800 lines, all functions <50 lines, nesting ≤4
- [ ] No dead code
- [ ] Security checks complete (security.md)

**Scope discipline — before writing each function, remove it if:** not explicitly in the requirement (stop, ask) · an interface for one implementation (use a concrete type) · a config option not required · an error case not required · an optimization without a measured problem.

**Build verification (end of Phase 3):** Go — `go build ./... && go test ./... && go vet ./...`; PHP — `php artisan test`, `php -l` changed files, verify routes; Angular — `ng build`, `ng test`, bundle growth <5%. Follow coding-style.md + language-specific rules.

**Queue/job work:** load `templates/rules/queue-jobs.md` before writing any job/worker/listener/scheduled/retry code — blocking for Go and PHP.

## Phase 4: Review

**STOP — Gate Phase 4 → Phase 5 (blocking):**
- [ ] `/verify` — zero CRITICAL (fix + re-run until clean)
- [ ] `/code-review` — zero HIGH (or documented in PR)
- [ ] Pre-commit checklist (git-workflow.md): code quality, security, testing, build

CRITICAL must fix; HIGH should fix (else document why in PR); MEDIUM/LOW optional. Bug fix: run `/diagnose` (or `/cross-service-diagnose`) to confirm the root cause is addressed.

## Phase 5: Commit & Verify Fork

**Before commit:** run `$INTELLISENSE_SETUP/scripts/check-fork.sh` — confirms `origin` is your fork, not upstream (fixes it if misconfigured).

**STOP — Gate Phase 5 → Phase 6 (blocking):**
- [ ] Fork check passed (✓)
- [ ] Commit created, conventional format (git-workflow.md), branch `type/BOARD-TICKET-intellisense-description`

**Commit safety:** never force-push main/master/develop · never `--no-verify` · review the diff before push · atomic, independently-buildable commits.

## Phase 6: Push & PR

**Gate:** Phase 5 commit complete; CI checks pass locally.

**Mandatory Pre-PR Approval Checkpoint (non-negotiable, every PR):** present Phase 4 verification findings → state "I'm about to create PR for branch [name]" → list prerequisites done (Phase 4 complete, `/verify` no CRITICAL, tests passing, build verified) → ask "proceed? (yes/no)" → wait for an explicit "yes" (do NOT infer). If told "continue without asking," repeat this checkpoint.

**Push:** review `git diff origin/main..HEAD` → `git push origin [branch-name]`.

**Risk & Confidence (emit before PR for `full_feature` / `bug_fix`):**
```json
{ "confidence_score": 0.0, "breaking_change_probability": 0.0, "performance_impact": "none|low|moderate|high", "security_considerations": [], "large_file_modified": false, "multi_tenant_risk": 0.0, "edge_cases_considered": [], "total_test_iterations": 0 }
```
**Auto-label:** `confidence_score<0.75` OR `breaking_change_probability>0.2` OR `large_file_modified` OR `multi_tenant_risk>0.2` → `AI Assisted – Mandatory Review`; else `AI Generated – Safe Candidate`.

**PR description:** link the Jira ticket; what changed / why / testing done / rollback plan. Request review; **wait for approval before merge** (no force-merge to main/develop; ≥1 approver; CI green).

## After Phase 6: Update Knowledge-Base (`full_feature` / `bug_fix`)

Within 24h of merge: run `/learn` (mandatory) → review proposed KB additions (catches hallucinations) → apply approved changes to `knowledge-base/` (02 api-contracts, 03 biz-rules/flows, 04 gotchas, 00 architecture) → commit `docs(kb): capture learnings after <name>`. Only code-verified facts belong in auto stubs (00–02); team stubs (03–05) need human review. Empty knowledge is safer than incorrect knowledge.
