---
applies_to: [full_feature, design_review_only]
phase: [1]
priority: MEDIUM
enforcement: advisory
load_when: planning
---

# Patterns & Reuse-First Rules

**Design Phase Only** — This file loads during planning and design. Implementation-level patterns (Go, Laravel, Angular syntax) are in language-specific rule files.

## Instruction Interpretation: Validate Assumptions Before Executing

Before designing a solution or choosing patterns, validate that instructions and requirements don't assume facts contradicting actual system structure. Following instructions blindly causes failures when the instruction author's assumptions don't match reality.

### Six Types of Assumptions to Validate

#### 1. Uniformity Assumptions
**What**: Instruction says "apply X uniformly to A, B, and C" but system treats them differently.

**Check Procedure:**
- When instruction uses words like "all," "every," "uniform," "consistent" — ask: Does the system actually treat these items identically?
- Search for evidence of differentiation: different configs, different paths, different ownership, different versions
- If system has mixed characteristics → red flag for differentiation

**Example (Real from intellisense Item 13):**
- Instruction: "prefix every rule file path with ~/.intellisense/"
- Assumption: All rule files live in the same place
- Reality: Baseline rules symlinked to ~/.claude/rules/baseline/, operational rules in ~/.intellisense/rules/
- Red flag: Global CLAUDE.md already showed mixed paths — should have triggered assumption validation
- Correct: Category-specific prefixes, not uniform

#### 2. Existence Assumptions
**What**: Instruction references a skill, agent, service, or file that doesn't exist or has been renamed.

**Check Procedure:**
- Before designing around any referenced tool: verify it exists in current system
- Search: `grep`, `ls`, `find`, check git history for renames/removals
- If not found → ask for clarification OR find current name

**Example (Real from intellisense Item 4):**
- Instruction: "Run `/security-review` skill to assess scope"
- Check: Does /security-review skill exist in intellisense?
- Reality: No — dead reference that should have been caught before design phase
- Correct: Replace with actual skill like `/verify`

#### 3. Responsibility Assumptions
**What**: Instruction assumes single owner/maintainer for something actually owned by multiple systems.

**Check Procedure:**
- When instruction says "X is responsible for Y" — verify ownership across codebase
- Check: Who writes this code? Who deploys it? Who patches it?
- If multiple systems touch the same resource → shared responsibility, not single

**Example:**
- Instruction assumes: "setup.sh generates all rule paths"
- Reality: Rule files are symlinked (owned by intellisense), generated output owned by setup.sh
- Correct: Acknowledge shared structure instead of assuming single responsibility

#### 4. Path/Structure Assumptions
**What**: Instruction assumes file locations, directory layouts, or config keys match actual structure.

**Check Procedure:**
- For every file path: verify it exists with `ls`, `find`
- For every config key: read actual config file and confirm the key exists
- For every directory structure: `ls -la` the directories
- If structure doesn't match → instruction was written for a different system state

**Example (Real from intellisense Item 13):**
- Instruction: "Read the version from ~/.claude/config.json"
- Check: Does this field actually exist in what setup.sh generates?
- If missing → either setup.sh must write it, OR instruction must be corrected

#### 5. Exception Assumptions
**What**: Instruction says "always" or "never" but codebase has documented exceptions.

**Check Procedure:**
- When instruction has absolute language ("always," "never," "never skip") — search for exceptions
- Check CLAUDE.md files, git history, comments for documented special cases
- If exceptions exist → either instruction is wrong or exceptions are stale

**Example:**
- Instruction: "Never skip Phase 2 TDD"
- Check: Are there modes that skip Phase 2?
- Reality: Yes — `pr_review`, `design_review_only`, `fix_pr_comments`, `refactor`, `hotfix` all skip Phase 2
- Correct: Conditional rule (depends on mode) instead of absolute

#### 6. Single-Solution Assumptions
**What**: Instruction assumes one pattern/approach sufficient when system requires multiple.

**Check Procedure:**
- When instruction says "use pattern X for all cases" — check if cases are identical
- Look for: Different languages, frameworks, threat models, scales, ownership models
- If variety exists → pattern might fail in some contexts

**Example:**
- Instruction: "Apply the same API response envelope to all endpoints"
- Reality: Existing APIs must stay unchanged (backward compatibility); only new APIs use envelope
- Correct: Conditional pattern (new APIs only) instead of universal

### Integration Into Design & Planning

When analyzing requirements or instructions:

1. **Identify assumptions** — What is this assuming to be true?
   - Look for absolute language: "always," "never," "uniform," "every"
   - Look for implicit structure: "file at X," "field in Y," "owned by Z"

2. **Validate against reality** — Search the codebase
   - File/path existence: `ls`, `find`, `grep`
   - Config structure: Read actual files
   - Ownership: Check git log, codebase structure
   - Exceptions: Read CLAUDE.md, rules, comments

3. **Flag mismatches** — If assumption contradicts reality, STOP design
   - Do NOT assume instruction author knows current system state
   - Ask for clarification OR adjust scope based on actual structure

4. **Document corrections** — State what assumption was wrong and how you adjusted
   - Prevents future re-discovery of the same issue
   - Helps instruction authors update their guidance

---

## Reuse-First Mandate

**Core principle**: Consistency beats perfection. Follow existing patterns even if they're not ideal.

### Decision Tree: When to Reuse vs. Create New

**Step 1: Does this code already exist?**
```
Does similar code exist in current repo?
  ├─ YES → Use it (or extend if needed). STOP.
  └─ NO → Go to Step 2
```

**Step 2: Can you reuse from a shared library or sibling services?**
```
Does this exist in a shared library or another service?
  ├─ YES, perfect fit → Reuse it. STOP.
  ├─ YES, close fit → Wrap or extend it. Document why.
  └─ NO → Go to Step 3
```

**Step 3: Does established pattern exist in this codebase?**
```
Do other services use a pattern for this concern?
  ├─ YES → Follow their pattern (even if not ideal). CONSISTENCY WINS.
  └─ NO → Create new, document why existing code couldn't be reused
```

### What "Following Existing Pattern" Means

If the codebase uses:
- Error handling: `errors.Wrap(err)` — use it, even if `fmt.Errorf` is newer
- Repository pattern: `UserRepo interface` — follow it, don't invent `UserStore`
- API response: `{status, data, errors}` — use it, don't create `{ok, result, message}`

**Exception**: If existing pattern is **security risk** (e.g., SQL concatenation, hardcoded secrets), stop and escalate. Do not follow unsafe patterns.

## Repository Pattern

**Rule**: If the codebase has established repository/data access pattern, follow it exactly.

**Standard layers:**
- **Repository interface** — defines data access methods
- **Repository implementation** — implements queries
- **Service layer** — uses repository, contains business logic
- **Handler/Controller** — calls service, handles HTTP

**Do not:**
- Put database queries directly in handlers/controllers
- Mix two different data access patterns in the same codebase
- Create a new pattern because you prefer it

**If codebase violates this:**
- Example: Handlers directly querying DB
- Action: Follow their pattern for YOUR code (consistency)
- Document: Note in PR "Following existing pattern in this codebase"
- Don't fix: Unless explicitly asked in requirements

## API Response Envelope

**For new APIs only** — This envelope is the standard for newly created endpoints. Existing APIs with different patterns must continue unchanged to avoid breaking production.

**Existing APIs with different patterns:**
- Continue using existing pattern (no retroactive changes)
- If standardizing: version the API (`/v2/endpoint`) and maintain backward compatibility
- Document transition plan and deprecation timeline in PR before shipping

**Standard envelope for new APIs:**
```json
{
  "status": "success|error",
  "data": {},
  "message": "Human-readable message",
  "errors": []
}
```

**Migration example (if standardizing existing API):**
1. Add `/v2/endpoint` with new envelope
2. Keep `/v1/endpoint` active for 30+ days (deprecation period)
3. Both versions active simultaneously during transition
4. Remove `/v1/endpoint` only after confirmed client migration
5. Document in CHANGELOG.md and notify consumers

## Skeleton Project Search

When starting a new feature that resembles existing functionality:
1. Spend 15 minutes max searching for similar features
2. Find the most similar existing feature — use as skeleton (copy structure, replace specifics)
3. This ensures consistency in: error handling, logging, validation, testing patterns

**Time constraint matters:**
- If you find similar feature in first 10 minutes: use it
- If searching takes >15 minutes: use the most similar thing you found
- If no similar feature exists: use language-specific patterns from rule files

**What skeleton search prevents:**
- Inventing new error handling when error handling already exists
- Creating custom validators when validation already exists
- Different testing patterns in similar features

**What it doesn't require:**
- Perfect match (80% similar is enough)
- Refactoring existing code to improve it (follow as-is)
- Waiting for ideal pattern to be created
