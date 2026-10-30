---
name: intellisense-audit
description: Use during repository setup or any time, to score the repository's documentation maturity and list concrete improvements.
---

# /intellisense-audit — Repository Documentation Health Audit

**When:** During repo setup, or anytime to assess documentation quality
**Goal:** Score repository on documentation maturity and provide actionable improvement suggestions
**Output:** Report + `.intellisense-doc-health.json` state file (committed to git)

---

## Entry Points

```
/intellisense-audit                      — Audit current repo, write .intellisense-doc-health.json
/intellisense-audit --repo /path         — Audit specific repo
/intellisense-audit --repo /path --no-save  — Print report only, don't write state file
```

---

## Token Budget

~2,500 tokens total (single session):
- Read CLAUDE.md
- Read file listings (handlers/, services/, etc.)
- Sample 3 test files + 2 source files
- Read git log (recent commits, last CLAUDE.md update)
- Output report + state file

No external calls or database access.

---

## Scoring Rubric

### 5 Categories × 20 Points = 100 Total Score

#### Category 1: Structure Compliance (0–20)

Expected directories per stack:

**Go:**
- `handlers/` or `routes/` — HTTP layer
- `services/` — business logic
- `models/` — data structures
- `repository/` — database access
- `tests/` or `*_test.go` files — test suite

**PHP/Laravel:**
- `app/Http/Controllers/` — request handlers
- `app/Services/` — business logic
- `app/Models/` — Eloquent models
- `app/Repositories/` — data access
- `tests/` — test suite

**Angular:**
- `src/app/core/` — shared services
- `src/app/shared/` — reusable components
- `src/app/features/` — feature modules
- Component files alongside modules (`*.component.ts`, `*.component.html`)

**Scoring:**
- 20 pts: All expected directories present + consistently named
- 15 pts: 4 of 5 directories present
- 12 pts: 3 of 5 present
- 8 pts: 2 of 5 or inconsistent naming
- 0 pts: Flat structure or no separation

#### Category 2: CLAUDE.md Quality (0–20)

**Presence & Completeness (4 pts for each requirement, max 20):**
- CLAUDE.md exists at repo root (4 pts — essential, Claude starts blind without it)
- Contains Stack section (2 pts)
- Contains Architecture section (2 pts)
- Contains Structural Map section (2 pts)
- Contains Upstream Dependencies section (2 pts)
- Contains Downstream Consumers section (2 pts)
- Contains Domain Terms section (2 pts)
- Contains Known Gotchas with 2+ real entries (2 pts)
- Contains Run/Test/Build section (2 pts)

**Quality Checks (deductions):**
- No placeholder text like `[placeholder]`, `{{TODO}}`, `(stub)` (2 pts if clean)
- No references to `@docs/project-context.md` (-2 pts if present; the auto-loaded context is `@knowledge-base/00-system-context.md`)
- Structural Map lists real file paths that exist on disk (2 pts if accurate)
- `.intellisense-bootstrap.md` file does not exist (-2 pts if present; scaffolding must be migrated to CLAUDE.md and deleted)
- No unresolved `[TODO]` items in `.intellisense-bootstrap.md` if it exists (-2 pts if multiple TODOs remain)

**Total deductions possible: -6 pts, minimum score 0**

#### Category 3: Test Approach (0–20)

**Test File Presence (6 pts):**
- Test files exist in the codebase (unit or integration tests)
- Missing: 0 pts

**Test Naming Quality (4 pts):**
- Go: Test names describe behavior, not function names
  - Good: `TestPayout_ProcessCycle_ReturnsErrorOnDuplicateKey`
  - Bad: `TestProcess`
- PHP: Test method names follow behavior patterns
  - Good: `test_invoice_created_when_payment_succeeds`
  - Bad: `testInvoice`
- Angular: Describe spec behavior, not component names
  - Good: `should display account balance when component loads`
  - Bad: `test account`
- Half of tests checked follow this pattern: 4 pts, few follow: 2 pts, none: 0 pts

**AAA Pattern Visibility (4 pts):**
- Read 2–3 test files, check for Arrange-Act-Assert structure
- Most tests follow AAA: 4 pts
- Some follow: 2 pts
- None visible: 0 pts

**Test Coverage Ratio (4 pts):**
- Test file count ≥ 50% of source file count: 4 pts
- 30–49% coverage: 2 pts
- <30% coverage: 0 pts

**Test File Quality (2 pts):**
- No test files that are all `TODO` or comments: 2 pts
- Some empty/TODO tests found: 1 pt
- Many empty tests: 0 pts

#### Category 4: Pattern Consistency (0–20)

**Error Handling (5 pts):**
- Read 3 source files (handlers or services)
- All use same error wrapping style (`errors.Wrap`, `fmt.Errorf`, `try/catch`, etc.): 5 pts
- 2 of 3 consistent: 3 pts
- Mixed patterns: 0 pts

**ORM Usage (4 pts):**
- No mixing of GORM + Pop (Go), Eloquent + raw SQL (PHP), or different ORMs: 4 pts
- Minor inconsistencies (1–2 files): 2 pts
- Significant mixing: 0 pts

**HTTP Response Envelope (4 pts):**
- All endpoints return same response format: 4 pts
- 80% consistent: 2 pts
- Mixed formats: 0 pts

**File Sizes (4 pts):**
- No single file dramatically larger than peers in same layer (not >3x average): 4 pts
- One outlier found: 2 pts
- Multiple oversized files: 0 pts

**Import Ordering (3 pts):**
- Consistent import style across 2+ files: 3 pts
- Mostly consistent: 1 pt
- Inconsistent: 0 pts

#### Category 5: Documentation Freshness (0–20)

**CLAUDE.md Age (4 pts):**
- Last committed within 60 days: 4 pts
- 60–90 days: 2 pts
- >90 days: 0 pts
- OR: Repo has no structural changes in past 60 days: 4 pts (check git history)

**Stub Text in Docs (4 pts):**
- No placeholder patterns (`{{placeholder}}`, `[pending]`, `(stub)`) in any .md file: 4 pts
- 1–2 occurrences: 2 pts
- Multiple stubs found: 0 pts

**Doc Health File Status (4 pts):**
- `.intellisense-doc-health.json` exists and has no PENDING items >30 days old: 4 pts
- Health file exists but has old PENDING items: 2 pts
- Health file missing: 0 pts

**Structural Map Accuracy (4 pts):**
- All files listed in CLAUDE.md Structural Map exist on disk: 4 pts
- 80% of listed files exist: 2 pts
- <80% exist or section missing: 0 pts

**Docs Directory Cleanliness (4 pts):**
- `knowledge-base/` has no unresolved stub files: 4 pts
- 1–2 stubs in knowledge-base/ with TO-DO markers: 2 pts
- Many unresolved stubs in knowledge-base/: 0 pts

---

## Grade Scale

| Score | Grade | Interpretation |
|-------|-------|---|
| 90–100 | **Excellent** | Documentation is current, structure clear, Claude performs optimally |
| 75–89 | **Good** | Minor gaps but usable; small fixes needed |
| 50–74 | **Works But Risky** | Staleness or gaps possible; CLAUDE.md needs updates |
| 25–49 | **Poor** | Claude may give incorrect guidance; major fixes needed |
| 0–24 | **Critical** | Repo not ready for intellisense; fix before using |

---

## Output Format

### Report (STDOUT)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
intellisense Audit: [your-service] (go)
Date: 2026-04-23
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Category                     Score   Max
─────────────────────────────────────────
Structure Compliance           16      20
CLAUDE.md Quality              12      20
Test Approach                  10      20
Pattern Consistency            13      20
Documentation Freshness         8      20
─────────────────────────────────────────
TOTAL                          59     100
Grade: Works but risky

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOP FIXES (highest impact first)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. [+12 pts] Update CLAUDE.md and resolve stub text
   - Category: CLAUDE.md Quality
   - Issue: CLAUDE.md has placeholder on line 18: "[Service description]"
   - Issue: Known Gotchas needs 1 real entry (currently has 0)
   - Issue: @docs/project-context.md reference found — replace it with @knowledge-base/00-system-context.md
   - Fix: Fill placeholders with real service details, add Known Gotchas from past bugs
   - Effort: 15–30 minutes

2. [+6 pts] Add test files for uncovered services
   - Category: Test Approach
   - Issue: services/reconciliation.go has no matching test file
   - Issue: services/payout_cycle.go has no test file
   - Fix: Create reconciliation_test.go and payout_cycle_test.go
   - Fix: Use behavior-based naming: TestReconciliation_ProcessCycle_ReturnsErrorOnDuplicateKey
   - Effort: 2–4 hours

3. [+4 pts] Improve Documentation Freshness
   - Category: Documentation Freshness
   - Issue: .intellisense-doc-health.json not found (or too old)
   - Fix: Run /intellisense-audit again, or manually create state file with current audit score
   - Effort: <5 minutes (run this command)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### State File: `.intellisense-doc-health.json`

Location: Repository root (committed to git, shared across all developers)

```json
{
  "schema_version": "1.0",
  "service": "[your-service]",
  "stack": "go",
  "last_audit_score": 59,
  "last_audit_date": "2026-04-23",
  "last_audit_by": "claude-code",
  "category_scores": {
    "structure": 16,
    "claude_md_quality": 12,
    "test_approach": 10,
    "pattern_consistency": 13,
    "documentation_freshness": 8
  },
  "pending_doc_updates": [
    {
      "id": "drift-001",
      "section": "structural-map",
      "reason": "src/middleware/ added in PR",
      "detected_date": "2026-04-15",
      "detected_in_pr": "#123",
      "status": "PENDING",
      "priority": "MEDIUM",
      "suggested_text": "- middleware/ → Auth verification, rate limiting"
    }
  ],
  "update_history": [
    {
      "date": "2026-04-10",
      "section": "api-patterns",
      "change": "Updated error envelope format description",
      "updated_by": "[developer-name]",
      "pr_reference": "#119"
    }
  ],
  "audit_history": [
    {
      "date": "2026-04-01",
      "score": 52,
      "run_by": "claude-code"
    },
    {
      "date": "2026-04-23",
      "score": 59,
      "run_by": "claude-code"
    }
  ]
}
```

**Fields:**
- `schema_version`: "1.0" (for migration if schema changes)
- `service`: Repository name
- `stack`: Go, PHP, or Angular
- `last_audit_score`: Latest audit score (0–100)
- `last_audit_date`: ISO 8601 date of latest audit
- `last_audit_by`: Who ran the audit (usually "claude-code")
- `category_scores`: Per-category breakdown
- `pending_doc_updates`: Drift items detected in PRs but not yet documented (PENDING → CONFIRMED → RESOLVED/DISMISSED)
- `update_history`: Team documentation updates (who, when, what section, PR reference)
- `audit_history`: All audit runs with scores (tracking improvement over time)

**Merge Conflict Resolution:**
- If both `audit_history` entries keep multiple records, use **higher score** as `last_audit_score`
- `pending_doc_updates` merges by appending with unique `id` field

---

## After Audit Completes

1. **Share results with team:**
   - Grade and TOP FIXES visible to all developers
   - `.intellisense-doc-health.json` committed to git so all devs can see status

2. **Track improvements:**
   - Next audit run compares against previous score
   - Update history shows who improved what, when

3. **Downstream in /code-review:**
   - During PR, `/code-review` checks `.intellisense-doc-health.json` for PENDING items
   - If your PR resolves a PENDING item, it's auto-detected and suggested for closure

---

## Quality Assurance

**Before reporting a score:**
- [ ] Examined CLAUDE.md for placeholders or stubs
- [ ] Sampled at least 2 test files, 2 source files per layer
- [ ] Verified directory structure matches stack expectations
- [ ] Checked git history for last CLAUDE.md edit date
- [ ] Confirmed Structural Map files exist on disk

**Confidence:**
- All category scores are based on actual file inspection, not assumptions
- If data is incomplete or ambiguous, state confidence level in findings section
