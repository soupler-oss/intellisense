# intellisense Tier 1 / refactor mode

## Required artifacts (before any Edit/Write)
1. **Task reference** — an issue in the team's tracker (refactors of infra/rules are Tier 1)
2. **Change Contract** — `/contract` (validator enforces)
3. **Explicit user "proceed"** — not inferred

## Phase 2 is SKIPPED
Refactors preserve behavior. No new failing tests. Existing tests must stay green.
If a refactor reveals a test failure, it's a **bug, not a refactor** —
escalate mode to `bug_fix` and write the failing regression test first.

## Limit: ≤10 files
If 11th file touched: STOP. Split into separate refactor PRs.

## What counts as refactor (behavior-preserving)
- Rename variable / function / module
- Extract helper
- Move code between files without API change
- Reorganize directory structure
- Deduplicate three+ similar code blocks

## What is NOT a refactor (mode is wrong)
- Adding/removing features → full_feature
- Changing function signature consumed externally → full_feature
- Performance improvement with behavioral side-effect → full_feature

## Evidence (required for push)
```
Refs: #123                                        # task trailer on each Tier 1+ commit (key per .intellisense.yml)
Change Contract: scope=…, risk=low|medium|high    # once per change, or the committed contract file
```

## Contract gate behavior
PreToolUse hook blocks edits until contract valid. Allowlist:
`.intellisense/session/**` always passes through.
