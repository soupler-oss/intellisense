# Step 1: Detect Stack

**Goal**: Read package files, identify technology stack, confirm CLAUDE.md Stack field matches detected stack.

**Input**: `repo_path`, optionally `stack` parameter from command-line

**Output**: Update `.intellisense-docservice-state.json` with:
- `stack`: "go" | "php" | "angular"
- `framework_type`: "GORM" | "Pop" | "Laravel" | "Angular12" | "Angular19"
- `primary_language`: "go" | "php" | "typescript"

---

## Execution

### 1. Detect from Package Files

Read package files in this order (stop at first match):

**Go Stack**:
- Check for `go.mod` — if exists, stack = "go"
- Read `go.sum` to detect ORM:
  - Contains "gorm.io" → framework_type = "GORM"
  - Contains "github.com/gobuffalo/pop" → framework_type = "Pop"
  - If neither, assume standard library or custom ORM

**PHP Stack**:
- Check for `composer.json` — if exists, stack = "php"
- Read composer.json to detect framework:
  - Contains "laravel/framework" → framework_type = "Laravel"
  - Contains "symfony/http-kernel" → framework_type = "Symfony" (not supported, flag warning)
  - If neither, assume generic PHP (not supported)

**Angular Stack**:
- Check for `package.json` — if exists, stack = "angular"
- Read package.json to detect Angular version:
  - Contains "@angular/core": "^12" → framework_type = "Angular12"
  - Contains "@angular/core": "^19" or higher → framework_type = "Angular19"
  - If no @angular/core, not an Angular repo

### 2. Validate Against CLAUDE.md

Read `CLAUDE.md` in repo root:
- Extract `Stack: [go|php|angular]` field from first section
- If detected stack ≠ CLAUDE.md Stack:
  - In non-autonomous mode: Ask user "CLAUDE.md says 'php' but detected 'go'. Which is correct?"
  - In autonomous mode: Use detected stack, log discrepancy to drift report
- If no Stack field in CLAUDE.md: Abort with error "CLAUDE.md missing Stack field. Add it manually and re-run."

### 3. Update State File

Add to `.intellisense-docservice-state.json`:
```json
{
  "step_completed": 1,
  "next_step": 2,
  "stack": "go",
  "framework_type": "GORM",
  "primary_language": "go",
  "claude_md_validation": "passed" | "warning",
  "validation_notes": "..."
}
```

### 4. Success Criteria

- ✓ Stack detected from package files
- ✓ Stack matches CLAUDE.md field (or user confirmed discrepancy)
- ✓ Framework type identified (GORM/Pop/Laravel/Angular12/Angular19)
- ✓ State file updated with step_completed: 1

### 5. Failure Scenarios

| Scenario | Action |
|----------|--------|
| No go.mod, composer.json, or package.json found | Abort: "Cannot detect stack. Repo has no package files." |
| CLAUDE.md Stack field missing | Abort: "CLAUDE.md missing Stack field." |
| Stack mismatch (detected ≠ CLAUDE.md) | Autonomous: log warning, continue; Non-autonomous: ask user |
| Unsupported framework (e.g., Symfony) | Abort: "Framework not supported by document-service." |

---

## Next Step

Proceed to step-02-scan-structure.md once state file shows `step_completed: 1`.
