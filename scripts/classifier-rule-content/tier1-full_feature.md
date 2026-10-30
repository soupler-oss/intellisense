# intellisense Tier 1 / full_feature mode

## Required artifacts (before any Edit/Write)
1. **Spec Design Review Gate** — produce JSON: `{critical_issues, major_concerns, clarifying_questions, security_risks, implementation_ready: bool, confidence_score: 0.0-1.0}`. Proceed only when `implementation_ready=true` AND `clarifying_questions` is empty.
2. **Task reference** — an issue in the team's tracker (cross-repo / infra / rule / agent changes are Tier 1)
3. **Change Contract** — `/contract` (validator enforces; commit gate)
4. **Explicit user "proceed"** — not inferred

## Limits
- ≤15 files, ≤800 lines per Phase 1 → Phase 2 gate
- If scope exceeds: escalate to multi-service planning (`/multi-service-plan`)

## TDD discipline
Phase 2: write failing tests first. Phase 3: minimum impl to green.
Phase 4: `/code-review`. Phase 5: commit. Phase 6: push + PR.

## Evidence (required for push)
```
Refs: #123                                        # task trailer on each Tier 1+ commit (key per .intellisense.yml)
Change Contract: scope=…, risk=low|medium|high    # once per change, or the committed contract file
```

## Approval Checkpoints
Before any destructive action (delete, reset, force-push, drop table):
1. Present analysis, 2. State action explicitly, 3. Ask approval, 4. Wait for explicit response, 5. Execute only after.

## Cross-repo work
If 2+ services affected, invoke `/multi-service-plan` and `strategic-architect`
agent. Per-service Change Contracts; coordinated rollout order documented.

## Contract gate behavior
PreToolUse hook blocks edits until contract is valid. Allowlist:
`.intellisense/session/**` always passes through.
