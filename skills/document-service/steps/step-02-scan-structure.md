# Step 2: Scan Repository Structure

**Goal**: Parse directory tree, identify key folders, detect framework patterns and financial audit patterns.

**Input**: `repo_path`, `stack`, `framework_type` (from step-01)

**Output**: Update `.intellisense-docservice-state.json` with:
- `directory_tree`: Full tree structure
- `file_counts`: Count by directory
- `key_directories`: models/, services/, handlers/, controllers/, routes/, migrations/, etc.
- `detected_patterns`: Financial patterns, ORM patterns, validation patterns
- `tables_detected`: [list] (from migration files)
- `endpoints_detected`: [count]

---

## Execution

### 1. Scan Directory Tree

Use glob patterns to build directory tree (exclude node_modules, .git, dist, build, vendor, coverage):

```
repo/
├── models/ (count: N files)
├── services/ (count: N files)
├── handlers/ / actions/ (count: N files)
├── migrations/ (count: N files)
├── routes/ (count: N files)
├── tests/ / spec/ (count: N files)
├── docs/ (count: N files)
├── config/ (count: N files)
└── [other directories]
```

Count total files in each directory. Record max depth, largest directory by file count.

### 2. Detect Framework-Specific Directories

**Go + GORM**:
- Look for: models/, services/, handlers/, migrations/, tests/
- ORM indicator: Find "gorm.db.DB" or "gorm.Model" in *.go files (quick grep, not exhaustive)

**Go + Pop**:
- Look for: models/, services/, actions/, migrations/, tests/
- ORM indicator: Find "pop.Connection" in *.go files

**PHP + Laravel**:
- Look for: app/Models/, app/Services/, app/Http/Controllers/, app/Http/Requests/, database/migrations/, tests/
- Framework indicator: Find "extends Model" in *.php files

**Angular 12**:
- Look for: src/app/, src/assets/, src/environments/
- Module indicator: Find "*.module.ts", "@NgModule" in src/app/

**Angular 19**:
- Look for: src/app/, src/assets/, src/environments/
- Component indicator: Find "standalone: true" in *.ts files, or @Component with no module reference

### 3. Detect Endpoints (Quick Count)

**Go**:
- Scan routes/ or handlers/ for HTTP handler registrations (grep for "GET ", "POST ", "PUT ", "DELETE ")
- Count occurrences → endpoints_detected = N

**PHP**:
- Scan app/Http/Controllers/ for public function names → count (rough estimate)
- Or read routes/api.php for Route::get(), Route::post() patterns

**Angular**:
- Scan for HTTP client calls in services/ (grep for "http.get", "http.post")
- Count rough endpoint references

### 5. Detect Shared Libraries Used

**Go**:
- Read go.mod, list imports of github.com/your-org packages (e.g., shared-go-lib)
- Record: imports_shared_go: true/false

**PHP**:
- Read composer.json require section, check for internal org packages
- Record: imports_org_libs: true/false

### 6. Update State File

Add to state.json:
```json
{
  "step_completed": 2,
  "next_step": 3,
  "directory_tree": "[ASCII tree output]",
  "file_counts": {
    "models": 5,
    "services": 4,
    "handlers": 6,
    "migrations": 12,
    "tests": 18
  },
  "detected_patterns": {
    "tables_detected": ["payouts", "journal_entries", "account_balances"],
    "endpoints_detected": 8,
    "imports_shared_go": true
  }
}
```

### 7. Success Criteria

- ✓ Directory tree scanned completely
- ✓ Key directories identified by framework type
- ✓ Financial pattern flags set (binary true/false)
- ✓ Endpoint count estimated
- ✓ State file updated with step_completed: 2

---

## Next Step

Proceed to step-03-generate-tree.md once state file shows `step_completed: 2` and contains `detected_patterns` object.
