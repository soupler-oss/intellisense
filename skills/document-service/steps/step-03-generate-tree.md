# Step 3: Generate source-tree-analysis.md

**Goal**: Format directory tree and structural analysis using BMAD template, write immediately to disk.

**Input**: `repo_path`, `directory_tree`, `critical_folders`, `entry_points`, `file_types`, `asset_locations`, `config_files` (from step-02)

**Output**: 
- `knowledge-base/01-system-source-tree.md` file written to disk
- Update `.intellisense-docservice-state.json` with outputs_generated and step_completed: 3

---

## Execution

### 1. Load BMAD Template

Read `skills/analysis/document-service/templates/source-tree-template.md` (BMAD-based)

### 2. Build Sections from Scan Data

Populate BMAD template sections with detected information:

- **Overview**: Summary of project structure (single vs. multi-part)
- **Directory Structure**: Complete ASCII tree from step-02
- **Critical Directories**: Framework-specific directories with descriptions (models/, services/, handlers/, etc.)
- **Entry Points**: Main entry point(s) and bootstrap process
- **File Organization Patterns**: Detected patterns (e.g., "services handle business logic", "models define entities")
- **Key File Types**: Categorized by function (.go/.php/.ts files, test files, config files)
- **Asset Locations**: Non-code assets (images, stylesheets, documentation)
- **Configuration Files**: Identified config files with their purposes
- **Development Notes**: Build commands, tooling, local setup requirements

### 3. Write File Immediately

Write formatted output to `knowledge-base/01-system-source-tree.md`:

```markdown
# [project_name] - Source Tree Analysis

**Date:** [timestamp]

## Overview
[project structure summary]

## Complete Directory Structure
[ASCII tree]

## Critical Directories
[framework-specific directories with purposes]

## Entry Points
[main and additional entry points]

## File Organization Patterns
[detected patterns]

## Key File Types
[file type categories]

## Asset Locations
[non-code asset directories]

## Configuration Files
[config file listing]

## Notes for Development
[setup and build instructions]

---
_Generated using BMAD Method `document-project` workflow_
```

### 4. Update State File

After writing file, update state.json:

```json
{
  "step_completed": 3,
  "next_step": 4,
  "outputs_generated": ["knowledge-base/01-system-source-tree.md"],
  "completed_steps": [
    {"step": "step_3", "status": "completed", "timestamp": "2026-04-21T10:35:00Z", 
     "outputs": ["knowledge-base/01-system-source-tree.md"], 
     "summary": "source-tree-analysis.md generated with directory tree, critical directories, entry points, and file organization patterns"}
  ]
}
```

### 5. Purge Detailed Data

After updating state file, discard from memory:
- directory_tree (full ASCII)
- file_counts object
- Critical folder details

Keep only: step_completed: 3 status in state.json

### 6. Success Criteria

- ✓ File `knowledge-base/01-system-source-tree.md` exists and is readable
- ✓ Contains Overview section
- ✓ Contains Complete Directory Structure section with ASCII tree
- ✓ Contains Critical Directories section with framework context
- ✓ Contains Entry Points, File Organization Patterns, Key File Types
- ✓ File size: 2-4k tokens (approximately 2,000-5,000 words)
- ✓ State file updated with outputs_generated array

---

## Next Step

Proceed to step-04-generate-context.md once state file shows `step_completed: 3` and file `knowledge-base/01-system-source-tree.md` exists.
