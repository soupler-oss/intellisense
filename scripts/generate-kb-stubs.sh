#!/bin/bash

# intellisense Knowledge-Base Stub Generator
# Extracts structured documentation from code using Claude CLI
# Usage: ./scripts/generate-kb-stubs.sh --repo /path/to/repo --stack go|php|angular --kb-dir /path/to/knowledge-base

set -e

# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
source "$(dirname "${BASH_SOURCE[0]}")/lib/intellisense-paths.sh"

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'  # No Color
DIM='\033[2m'
BOLD='\033[1m'

# Parse arguments
REPO_PATH=""
STACK=""
KB_DIR=""

while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO_PATH="$2"; shift 2;;
    --stack) STACK="$2"; shift 2;;
    --kb-dir) KB_DIR="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# Validate arguments
if [ -z "$REPO_PATH" ] || [ -z "$STACK" ] || [ -z "$KB_DIR" ]; then
  echo "Usage: $0 --repo PATH --stack go|php|angular --kb-dir PATH"
  exit 1
fi

# Check if Claude CLI is available
if ! command -v claude &> /dev/null; then
  echo -e "${YELLOW}⚠ Claude CLI not found — stubs will remain empty${NC}"
  exit 0
fi

# Test-mode escape hatch: skip Claude extractions entirely. Used by test
# fixtures so test-intellisense-scripts.sh doesn't hang on Claude-CLI calls that
# can take minutes. The stubs remain as-is (filled by templates earlier
# in setup-repos.sh, or untouched team-required ones).
if [ "${INTELLISENSE_SKIP_KB_EXTRACT:-0}" = "1" ]; then
  echo -e "${YELLOW}⚠ INTELLISENSE_SKIP_KB_EXTRACT=1 — skipping Claude extractions (test mode)${NC}"
  exit 0
fi

# Initialize status tracking (POSIX-compatible)
TOTAL_ATTEMPTED=0
TOTAL_FILLED=0
FILLED_STUBS=""
EMPTY_STUBS=""
STUB_COUNTER=0
STUB_TOTAL=0
EXTRACTION_START=0

# Helper: Extract stub with Claude
extract_stub() {
  local stub_name=$1
  local output_file=$2
  local prompt=$3
  local target_percent=$4

  # Show progress line for each stub
  STUB_COUNTER=$((STUB_COUNTER + 1))
  echo -ne "  ${BLUE}→${NC} [$STUB_COUNTER/$STUB_TOTAL] ${stub_name}..."
  local STUB_START
  STUB_START=$(date +%s)

  # Idempotent: skip Claude call if stub already extracted
  if [ -f "$output_file" ] && grep -q "auto-extracted by Claude" "$output_file"; then
    echo -e " ${DIM}already extracted${NC}"
    FILLED_STUBS="${FILLED_STUBS}  ${stub_name} (${target_percent} — already extracted)\n"
    TOTAL_FILLED=$((TOTAL_FILLED + 1))
    TOTAL_ATTEMPTED=$((TOTAL_ATTEMPTED + 1))
    return
  fi

  # Non-destructive: if file exists WITHOUT intellisense marker, the team wrote it — skip entirely.
  # Don't run Claude extraction and don't create a .intellisense-new.md sidecar; team content wins.
  if [ -f "$output_file" ] && ! grep -q "<!-- intellisense:" "$output_file" 2>/dev/null; then
    echo -e " ${DIM}skipped (team-authored, no intellisense marker)${NC}"
    FILLED_STUBS="${FILLED_STUBS}  ${stub_name} (team-authored — skipped)\n"
    return
  fi
  local WRITE_TO="$output_file"

  TOTAL_ATTEMPTED=$((TOTAL_ATTEMPTED + 1))

  # Run extraction prompt
  EXTRACT_OUTPUT=$(cd "$REPO_PATH" && claude -p "$prompt" < /dev/null 2>/dev/null || echo "")

  local STUB_END
  STUB_END=$(date +%s)
  local ELAPSED=$((STUB_END - STUB_START))

  if [ -z "$EXTRACT_OUTPUT" ] || [ $(echo "$EXTRACT_OUTPUT" | wc -c) -lt 50 ]; then
    echo -e " ${YELLOW}empty${NC} (${ELAPSED}s)"
    EMPTY_STUBS="${EMPTY_STUBS}  ${stub_name} (0%)\n"
    return
  fi

  # Write extracted content to file
  {
    echo "<!-- intellisense: This stub was auto-extracted by Claude (${target_percent} extracted). -->"
    echo "<!-- Review and enhance the content below. -->"
    echo ""
    echo "$EXTRACT_OUTPUT"
  } > "$WRITE_TO"

  echo -e " ${GREEN}✓${NC} ${target_percent} filled (${ELAPSED}s)"
  FILLED_STUBS="${FILLED_STUBS}  ${stub_name} (${target_percent})\n"
  TOTAL_FILLED=$((TOTAL_FILLED + 1))
}

is_frontend_stack() {
  [[ "$STACK" == "angular" || "$STACK" == "react" || "$STACK" == "next" || "$STACK" == "vue" ]]
}

# Ensure KB directory exists
mkdir -p "$KB_DIR"

echo -e "${BLUE}→ Extracting Knowledge-Base Stubs for $STACK${NC}"
echo -e "${DIM}Repo: $REPO_PATH${NC}"
echo ""

# Frontend also extracts 02-data-models using TypeScript interfaces/DTOs — total is always 7
STUB_TOTAL=7

EXTRACTION_START=$(date +%s)
echo -e "${DIM}  Running $STUB_TOTAL Claude extractions — this may take a few minutes${NC}"
echo ""

# === STUB 1: 02-data-models.md (90% extractable) — backend only ===
# Frontend stacks (angular/react/next/vue) use TypeScript interfaces directly in source; no KB file needed.
if ! is_frontend_stack; then
extract_stub "02-data-models.md" "$KB_DIR/02-data-models.md" \
"Scan this $STACK repository. Extract data models/structures from:
- PHP Laravel: database/migrations/*.php files → table names, columns, types, keys, relationships
- Go: models/ directory, database type hints → table structure
- Frontend (Angular/React/Next/Vue): scan src/**/*.model.ts, *.interface.ts, *.dto.ts, types/*.ts → exported type/interface names, fields, types. No DB tables.

For each table or type found, output format:
\`\`\`
### TableName (or InterfaceName)
- column1/field1: type (nullable: yes/no, indexed: yes/no)
- column2/field2: type (references: OtherTable.column OR type name)
[... all columns/fields ...]
Relationships/extends: belongsTo X, hasMany Y (OR extends/implements for interfaces)
\`\`\`

List ALL tables or types found. Output ONLY the catalog, no explanation." \
"90%"
fi # end backend-only: 02-data-models.md

# === STUB 2: 02-api-contracts.md (85% extractable) ===
extract_stub "02-api-contracts.md" "$KB_DIR/02-api-contracts.md" \
"Scan this $STACK repository. Extract API contracts from:
- PHP Laravel: routes/api.php, routes/web.php → paths, methods, middleware (APIs this service exposes)
- Go: routes/*.go, main.go → http.HandleFunc patterns, gin/chi routes (APIs this service exposes)
- Frontend (Angular/React/Next/Vue): scan service files (*.service.ts, api.js, *.api.ts, *client*.ts) for HTTP client calls → APIs this frontend consumes; list base URL, method, path, response type

For each endpoint found, output format:
\`\`\`
### METHOD /path/to/endpoint
- Auth: [Bearer token | API key | None]
- Request body: [field1: type, field2: type]
- Response: [HTTP 200/400/401/etc with response structure]
\`\`\`

List ALL endpoints found. Output ONLY the endpoint catalog, no explanation." \
"85%"

# === STUB 3: 00-system-context.md (70% extractable) ===
extract_stub "00-system-context.md" "$KB_DIR/00-system-context.md" \
"Scan this $STACK repository. Extract metadata from:
- Package name: composer.json (PHP), go.mod (Go), package.json (Frontend)
- Stack: PHP/Laravel version, Go version, or frontend framework + version
- Key directories: find directories named: models/, services/, handlers/, controllers/, routes/, src/app/, src/features/
- Database: MySQL, PostgreSQL, MongoDB — detect from config files (backend only; N/A for frontend)
- Cache: Redis, Memcached — detect from config files (backend only; N/A for frontend)
- Key libraries: count files in models/, services/, controllers/ (or src/app/ for frontend) to estimate codebase size

Output format (markdown bullets):
\`\`\`
## Service Metadata
- Name: [extracted name]
- Stack: [detected stack with versions]
- Database: [detected type | N/A for frontend]
- Cache: [detected type | N/A for frontend]
- Estimated Models/Services: [count]
- Key Dependencies: [top 5 by usage frequency]
\`\`\`

Output ONLY the metadata section, no explanation." \
"70%"

# === STUB 4: 00-system-architecture.md (60% extractable) ===
extract_stub "00-system-architecture.md" "$KB_DIR/00-system-architecture.md" \
"Scan this $STACK repository. Extract directory structure:
- Generate ASCII tree of main directories (max depth 3)
- Identify layers:
  - Backend (PHP/Go): handlers/controllers → services → models → database
  - Frontend (Angular/React/Next/Vue): modules/features → components → services → shared
- Count files per layer to estimate structure

Output format:
\`\`\`
## Directory Structure
[root]/
├── [dir]/           (N files) — [layer description]
│   ├── [subdir]/
│   └── [subdir]/
\`\`\`

## Layers
- [Layer]: [description of what this layer does]
\`\`\`

Output ONLY the architecture section, no explanation." \
"60%"

# === STUB 5: 04-eng-testing-guide.md (30% extractable) ===
extract_stub "04-eng-testing-guide.md" "$KB_DIR/04-eng-testing-guide.md" \
"Scan this $STACK repository for testing setup:
- PHP Laravel: phpunit.xml, tests/ directory structure
- Go: *_test.go files, go.mod test dependencies
- Frontend (Angular/React/Next/Vue): karma.conf.js, jest.config.js, *.spec.ts, *.test.js — component tests and E2E (Cypress/Playwright)

Extract test framework and organization. Output format:
\`\`\`
## Test Framework
- Primary: [PHPUnit | Go testing | Jest | Karma/Jasmine | Vitest]
- Config: [phpunit.xml | go.mod | karma.conf.js | jest.config.js]
- Test Count: [estimate from file count]
- Coverage: [if coverage config exists]

## Test Organization
- Unit Tests: [location and structure]
- Integration Tests: [if exists]
- E2E Tests: [if exists]
\`\`\`

Output ONLY test framework info, no explanation." \
"30%"

# === STUB 6: 01-system-tech-stack.md (85% extractable) ===
extract_stub "01-system-tech-stack.md" "$KB_DIR/01-system-tech-stack.md" \
"Scan this $STACK repository. Extract dependency and technology stack from lock files first, fall back to manifests:
- Go: go.mod (language version, module name, direct dependencies) + go.sum (confirm versions)
- PHP: composer.json + composer.lock (PHP version, Laravel version, direct dependencies)
- Frontend (Angular/React/Next/Vue): package.json + package-lock.json or yarn.lock (framework version, Node version, direct dependencies)

Rules:
- Include language/runtime version, framework version, test framework
- List top 10 dependencies by usage frequency (not all transitive deps)
- Exclude dev-only transitive dependencies
- Prefer lock file versions over manifest versions for accuracy

Output format:
\`\`\`
## Language & Runtime
- Language: [Go X.XX | PHP X.X | Node X.XX]
- Framework: [gin/chi/buffalo | Laravel X.X | Angular X.X / React X.X / Next.js X.X]

## Top Dependencies

| Package | Version | Purpose |
|---|---|---|
| [pkg] | [version] | [brief purpose] |

## Test Framework
- Runner: [go test | PHPUnit | Jest | Karma/Jasmine | Vitest | Cypress]
- Config: [go.mod | phpunit.xml | karma.conf.js | jest.config.js]
\`\`\`

Output ONLY the tech stack section, no explanation." \
"85%"

# === STUB 7: 01-system-source-tree.md (90% extractable) ===
extract_stub "01-system-source-tree.md" "$KB_DIR/01-system-source-tree.md" \
"Scan this $STACK repository. Generate a source tree and annotate each directory:
- Directory tree: max depth 3, count files per directory
- Exclude: node_modules/, vendor/, .git/, dist/, build/, __pycache__/
- Label each layer with one-line description based on stack conventions:
  - Backend (PHP/Go): handlers/controllers → services → models → database layer
  - Frontend (Angular/React/Next/Vue): modules/features → components → services → shared utilities
- Flag any directory with >200 files

Output format:
\`\`\`
## Source Tree

[service-root]/
├── [dir]/       ([N] files) — [one-line layer description]
│   ├── [subdir]/  ([N] files)
│   └── [subdir]/  ([N] files)
└── [dir]/       ([N] files) — [one-line layer description]

## Oversized Directories (>200 files)
[List or: None detected]
\`\`\`

Output ONLY the source tree section, no explanation." \
"90%"

# === Team-required stubs (write placeholder with intellisense marker) ===
for stub_base in "03-biz-critical-flows" "03-biz-domain-rules" "04-eng-gotchas" "04-eng-conventions" "05-meta-changelog"; do
  stub_file="$KB_DIR/${stub_base}.md"

  # Skip if intellisense already wrote the team-required marker on a previous run
  if [ -f "$stub_file" ] && grep -q "<!-- intellisense: requires team input" "$stub_file"; then
    EMPTY_STUBS="${EMPTY_STUBS}  ${stub_base}.md (0%)\n"
    continue
  fi

  # Non-destructive: if file exists WITHOUT intellisense marker, the team already wrote it — skip.
  # Don't overwrite, don't create a .intellisense-new.md sidecar.
  if [ -f "$stub_file" ] && ! grep -q "<!-- intellisense:" "$stub_file" 2>/dev/null; then
    echo -e "  ${DIM}↷ ${stub_base}.md skipped (team-authored, no intellisense marker)${NC}"
    EMPTY_STUBS="${EMPTY_STUBS}  ${stub_base}.md (team-authored — skipped)\n"
    continue
  fi
  STUB_WRITE_TO="$stub_file"

  # Write team-required marker as .md
  cat > "$STUB_WRITE_TO" << 'TODO_EOF'
<!-- intellisense: requires team input (0% extracted). Claude cannot infer this from code. -->

## TODO

This file requires your team's domain knowledge. Claude extraction cannot infer:
- Why critical flows work the way they do
- Business rules and constraints
- Operational decisions and incident lessons
- Production debugging procedures
- Conventions and standards agreed by the team

Fill this file before the next sprint — assign to team roles listed in knowledge-base/kb-status.md.
TODO_EOF

  EMPTY_STUBS="${EMPTY_STUBS}  ${stub_base}.md (0%)\n"
done

echo ""

# Calculate extraction time
EXTRACTION_END=$(date +%s)
EXTRACTION_ELAPSED=$((EXTRACTION_END - EXTRACTION_START))
EXTRACTION_MIN=$((EXTRACTION_ELAPSED / 60))
EXTRACTION_SEC=$((EXTRACTION_ELAPSED % 60))
echo -e "${DIM}  Extraction completed in ${EXTRACTION_MIN}m ${EXTRACTION_SEC}s${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Knowledge-Base Extraction Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -n "$FILLED_STUBS" ]; then
  echo -e "${GREEN}✅ Auto-filled by Claude (review & enhance):${NC}"
  echo -e "$FILLED_STUBS"
  echo ""
fi

echo -e "${YELLOW}❌ Empty — Requires team input:${NC}"
echo -e "$EMPTY_STUBS"
echo ""
# === EXISTING KNOWLEDGE DISCOVERY ===
# Advisory-only: generates a report + adds notes to empty team-required stubs.
# Never auto-imports content into 03-*/04-*/05-* stubs — empty is safer than incorrect.
discover_existing_sources() {
  ensure_intellisense_state_dir "$REPO_PATH"
  local REPORT_FILE
  REPORT_FILE=$(intellisense_state_path "$REPO_PATH" existing-knowledge-report)
  local SOURCES_FOUND=""
  local REPORT_SECTIONS=""
  local NOW_EPOCH
  NOW_EPOCH=$(date +%s)
  local SIX_MONTHS_AGO=$((NOW_EPOCH - 15552000))

  echo -e "${BLUE}→ Scanning for existing knowledge sources...${NC}"

  # Helper: confidence based on file mtime
  file_confidence() {
    local f="$1"
    local mtime
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$mtime" -gt "$SIX_MONTHS_AGO" ]; then
      echo "medium"
    else
      echo "low (last modified >6 months ago)"
    fi
  }

  # Map source to suggested KB stub
  suggest_stub() {
    local source_path="$1"
    local fname
    fname=$(basename "$source_path" | tr '[:upper:]' '[:lower:]')
    case "$fname" in
      *architect*|*design*|*overview*)  echo "00-system-architecture.md" ;;
      *api*|*contract*|*endpoint*|*route*) echo "02-api-contracts.md" ;;
      *flow*|*journey*|*process*)       echo "03-biz-critical-flows.md" ;;
      *domain*|*rule*|*business*)       echo "03-biz-domain-rules.md" ;;
      *gotcha*|*convention*|*pattern*)  echo "04-eng-gotchas.md" ;;
      *readme*)                          echo "03-biz-domain-rules.md" ;;
      *contributing*)                    echo "04-eng-conventions.md" ;;
      *)                                 echo "03-biz-domain-rules.md" ;;
    esac
  }

  # Scan source 1: pre-intellisense CLAUDE.md original.
  # setup-repos.sh keeps it, write-once, at .intellisense/.backup/CLAUDE.md.original.
  local BACKUP_FILE
  BACKUP_FILE=$(ls -t "$REPO_PATH"/.intellisense/.backup/CLAUDE.md.original* 2>/dev/null | head -1)
  if [ -n "$BACKUP_FILE" ]; then
    local conf
    conf=$(file_confidence "$BACKUP_FILE")
    local stub
    stub=$(suggest_stub "$BACKUP_FILE")
    SOURCES_FOUND="${SOURCES_FOUND}$(basename "$BACKUP_FILE") "
    REPORT_SECTIONS="${REPORT_SECTIONS}
## Source: $(basename "$BACKUP_FILE")

| Field | Value |
|-------|-------|
| Suggested KB target | ${stub} |
| Confidence | ${conf} |
| Reason | Previous CLAUDE.md — may contain team-documented rules and conventions |
| Code supports it | Unverifiable — treat as advisory only |

_Review this file manually before importing any content._

"
  fi

  # Scan source 2: knowledge-base.md (single-file KB format)
  if [ -f "$REPO_PATH/knowledge-base.md" ]; then
    local conf
    conf=$(file_confidence "$REPO_PATH/knowledge-base.md")
    SOURCES_FOUND="${SOURCES_FOUND}knowledge-base.md "
    REPORT_SECTIONS="${REPORT_SECTIONS}
## Source: knowledge-base.md

| Field | Value |
|-------|-------|
| Suggested KB target | Multiple — split by section |
| Confidence | ${conf} |
| Reason | Single-file KB format — contains mixed domain, API, and convention content |
| Code supports it | Unverifiable — treat as advisory only |

_Import section-by-section after verifying facts against current code._

"
  fi

  # Scan source 3: docs/**/*.md (skip files >50KB; max 20 files)
  local DOC_COUNT=0
  if [ -d "$REPO_PATH/docs" ]; then
    while IFS= read -r -d '' doc_file; do
      [ $DOC_COUNT -ge 20 ] && break
      local fsize
      fsize=$(stat -c %s "$doc_file" 2>/dev/null || stat -f %z "$doc_file" 2>/dev/null || echo 0)
      [ "$fsize" -gt 51200 ] && continue  # skip >50KB
      local relpath="${doc_file#$REPO_PATH/}"
      local conf
      conf=$(file_confidence "$doc_file")
      local stub
      stub=$(suggest_stub "$doc_file")
      SOURCES_FOUND="${SOURCES_FOUND}${relpath} "
      REPORT_SECTIONS="${REPORT_SECTIONS}
## Source: ${relpath}

| Field | Value |
|-------|-------|
| Suggested KB target | ${stub} |
| Confidence | ${conf} |
| Reason | Existing documentation — may contain relevant business or technical context |
| Code supports it | Unverifiable — verify facts against current source code before importing |

"
      DOC_COUNT=$((DOC_COUNT + 1))
    done < <(find "$REPO_PATH/docs" -maxdepth 3 -name "*.md" -print0 2>/dev/null)
  fi

  # Scan source 4: README.md
  if [ -f "$REPO_PATH/README.md" ]; then
    local conf
    conf=$(file_confidence "$REPO_PATH/README.md")
    SOURCES_FOUND="${SOURCES_FOUND}README.md "
    REPORT_SECTIONS="${REPORT_SECTIONS}
## Source: README.md

| Field | Value |
|-------|-------|
| Suggested KB target | 03-biz-domain-rules.md |
| Confidence | ${conf} |
| Reason | Project README — may contain service purpose, setup instructions, and domain context |
| Code supports it | Partially — verify business rules against current implementation |

"
  fi

  # Scan source 5: CONTRIBUTING.md
  if [ -f "$REPO_PATH/CONTRIBUTING.md" ]; then
    local conf
    conf=$(file_confidence "$REPO_PATH/CONTRIBUTING.md")
    SOURCES_FOUND="${SOURCES_FOUND}CONTRIBUTING.md "
    REPORT_SECTIONS="${REPORT_SECTIONS}
## Source: CONTRIBUTING.md

| Field | Value |
|-------|-------|
| Suggested KB target | 04-eng-conventions.md |
| Confidence | ${conf} |
| Reason | Contribution guidelines — likely contains PR checklist, naming conventions, workflow rules |
| Code supports it | Partially — verify current practices match documented ones |

"
  fi

  # If no sources found, skip report
  if [ -z "$SOURCES_FOUND" ]; then
    echo -e "  ${DIM}No existing knowledge sources found — nothing to report${NC}"
    return
  fi

  # Write discovery report (advisory only — gitignored)
  {
    echo "# intellisense Existing Knowledge Discovery Report"
    echo ""
    echo "> Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "> Repo: $(basename "$REPO_PATH")"
    echo "> **Advisory only.** Do NOT copy content directly into KB stubs."
    echo "> Verify every fact against current source code before importing."
    echo "> This file is gitignored — not committed."
    echo ""
    echo "---"
    echo ""
    echo "$REPORT_SECTIONS"
  } > "$REPORT_FILE"

  echo -e "  ${GREEN}✓${NC} Discovery report: .intellisense/existing-knowledge-report.md (${DOC_COUNT} docs + $(echo "$SOURCES_FOUND" | wc -w | tr -d ' ') sources)"

  # Add advisory note to empty team-required stubs (idempotent — check before writing)
  local TEAM_STUBS="03-biz-critical-flows.md 03-biz-domain-rules.md 04-eng-gotchas.md 04-eng-conventions.md 05-meta-changelog.md"
  for stub_name in $TEAM_STUBS; do
    local stub_path="$KB_DIR/$stub_name"
    [ -f "$stub_path" ] || continue

    # Never overwrite if advisory note already present (idempotency)
    if grep -q "Potential source found" "$stub_path" 2>/dev/null; then
      continue
    fi

    # Check if stub has been edited by developer (has non-placeholder content)
    local content_lines
    content_lines=$(grep -v "^#\|^>\|^<!--\|^$\|^\s*$\|^---" "$stub_path" 2>/dev/null | wc -l)

    # If stub has real content (>0 non-comment/non-blank lines), it's been edited — preserve as-is
    if [ "$content_lines" -gt 0 ]; then
      continue  # User has added content — do NOT add advisory note
    fi

    # Stub is empty (only headers/comments/blanks) — add advisory note
    local relevant_source=""
    for src in $SOURCES_FOUND; do
      local src_stub
      src_stub=$(suggest_stub "$src")
      if [ "$src_stub" = "$stub_name" ]; then
        relevant_source="$src"
        break
      fi
    done
    [ -z "$relevant_source" ] && relevant_source="$(echo "$SOURCES_FOUND" | awk '{print $1}')"
    if [ -n "$relevant_source" ]; then
      echo "" >> "$stub_path"
      echo "<!-- Potential source found: ${relevant_source} — review .intellisense/existing-knowledge-report.md before importing -->" >> "$stub_path"
    fi
  done
}

discover_existing_sources

TOTAL_AUTO=7
TOTAL_TEAM_REQUIRED=5
TOTAL_STUBS=$((TOTAL_AUTO + TOTAL_TEAM_REQUIRED))

echo -e "${DIM}→ Fill team-required files (03-*, 04-eng-conventions, 05-*) before next sprint${NC}"
echo ""

# Write status JSON for use by setup-repos.sh.
# Deterministic content: the previous "generated_at" timestamp produced a
# spurious diff on every re-run with no functional consumer (setup-repos.sh:1462
# only reads claude_extracted + team_required from this file). First-write
# time is preserved by git history.
ensure_intellisense_state_dir "$REPO_PATH"
STATUS_FILE=$(intellisense_state_path "$REPO_PATH" stubs-status)
cat > "$STATUS_FILE" << EOF
{
  "stack": "$STACK",
  "repo": "$(basename $REPO_PATH)",
  "extraction_summary": {
    "total_stubs": $TOTAL_STUBS,
    "claude_extracted": $TOTAL_FILLED,
    "team_required": $((TOTAL_STUBS - TOTAL_FILLED))
  }
}
EOF

echo -e "${GREEN}✓ Status written to: .intellisense/stubs-status.json${NC}"

INTELLISENSE_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generate .intellisense/kb-status.md — human dashboard under .intellisense/ (not loaded by Claude).
# Deterministic content: the previous "Generated on YYYY-MM-DD" stamp produced a
# spurious diff on every re-run across day boundaries. Generation history lives
# in git log; refresh date is not load-bearing.
cat > "$(intellisense_state_path "$REPO_PATH" kb-status)" << KBSTATUS_EOF
# Knowledge Base Status

> Generated by intellisense. Re-run \`setup-repos.sh\` to refresh.
> **For humans only** — this file is NOT loaded into Claude's context (dotfile, repo root).
> Files are loaded by Claude in 00→05 priority order.

## ✅ Auto-filled by Claude — Review & Enhance

| File | Coverage | What was extracted |
|---|---|---|
| knowledge-base/00-system-context.md | 70% | Service metadata, stack, patterns (auto-loaded every session) |
| knowledge-base/00-system-architecture.md | 60% | Directory structure, layers |
| knowledge-base/01-system-tech-stack.md | 85% | Language version, framework, top dependencies |
| knowledge-base/01-system-source-tree.md | 90% | Depth-3 source tree with layer descriptions |
| knowledge-base/02-api-contracts.md | 85% | HTTP endpoints (exposed by backend / consumed by frontend) |
| knowledge-base/02-data-models.md | 90% | DB tables + relationships (backend) / TypeScript interfaces (frontend) |
| knowledge-base/04-eng-testing-guide.md | 30% | Test framework, structure, CI gates |

## ❌ Requires Team Input — Assign Before Next Sprint

| File | Owner | Est. Time | What to write |
|---|---|---|---|
| knowledge-base/03-biz-critical-flows.md | Senior dev | 45 min | Mission-critical user journeys |
| knowledge-base/03-biz-domain-rules.md | Architect | 30 min | Business rules, domain constraints |
| knowledge-base/04-eng-gotchas.md | Tech lead | 30 min | Production lessons learned |
| knowledge-base/04-eng-conventions.md | Tech lead | 30 min | Naming, error handling, PR checklist |
| knowledge-base/05-meta-changelog.md | All | ongoing | Feature changelog per merge |

**Total effort: ~2.5 hours, split across roles (not per person)**
KBSTATUS_EOF

echo -e "${GREEN}✓ Human dashboard written to: .intellisense/kb-status.md${NC}"

# Ordering validation — warn if any knowledge-base/*.md file falls outside 00-05 prefix pattern
echo ""
echo -e "${BLUE}→ Validating file ordering...${NC}"
ORDERING_ERRORS=""
for kb_file in "$KB_DIR"/*.md; do
  [ -f "$kb_file" ] || continue
  fname="$(basename "$kb_file")"
  [ "$fname" = "README.md" ] && continue
  if ! echo "$fname" | grep -qE '^0[0-5]-'; then
    ORDERING_ERRORS="${ORDERING_ERRORS}  ${fname}\n"
  fi
done
if [ -n "$ORDERING_ERRORS" ]; then
  echo -e "${YELLOW}⚠ Files outside 00→05 prefix pattern (Claude load order undefined):${NC}"
  echo -e "$ORDERING_ERRORS"
else
  echo -e "${GREEN}✓ All KB files follow 00→05 ordering${NC}"
fi
