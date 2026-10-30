#!/bin/bash
# intellisense-knowledge-base-health.sh
# Unified knowledge base health: generate risk files and/or audit drift
# Usage: ./scripts/intellisense-knowledge-base-health.sh [--generate] [--audit] [path]
# Default (no flags): Run both --generate and --audit in sequence

set -euo pipefail

REPO_PATH="."
MODE_GENERATE=0
MODE_AUDIT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate)
      MODE_GENERATE=1
      shift
      ;;
    --audit)
      MODE_AUDIT=1
      shift
      ;;
    *)
      REPO_PATH="$1"
      shift
      ;;
  esac
done

# Default: if no mode specified, run both
if [[ $MODE_GENERATE -eq 0 && $MODE_AUDIT -eq 0 ]]; then
  MODE_GENERATE=1
  MODE_AUDIT=1
fi

# Normalize path
REPO_PATH="$(cd "$REPO_PATH" 2>/dev/null && pwd)" || {
  echo "Error: Repository path not found" >&2
  exit 1
}

KB_DIR="$REPO_PATH/knowledge-base"

# ===== MODE: GENERATE (scan code, create risk files) =====
if [[ $MODE_GENERATE -eq 1 ]]; then
  mkdir -p "$KB_DIR"

  # Find large files (>500 lines)
  declare -a large_files
  declare -a risky_files
  declare -a protected_files

  echo "Scanning repository for risk indicators..."

  # Find files > 500 lines
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      line_count=$(wc -l < "$file" 2>/dev/null || echo 0)
      if [[ $line_count -gt 500 ]]; then
        size_kb=$(($(stat -c '%s' "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0) / 1024))
        large_files+=("$file|$line_count|$size_kb")
      fi
    fi
  done < <(find "$REPO_PATH" -type f \( -name "*.php" -o -name "*.go" -o -name "*.ts" -o -name "*.js" \) 2>/dev/null | grep -v node_modules | grep -v vendor | grep -v .git)

  # Find risky files by name pattern
  while IFS= read -r file; do
    [[ -f "$file" ]] && risky_files+=("$file")
  done < <(find "$REPO_PATH" -type f \( \
    -iname "*auth*.php" -o -iname "*auth*.go" \
    -o -iname "*pay*.php" -o -iname "*pay*.go" \
    -o -iname "*payment*.php" -o -iname "*payment*.go" \
    -o -iname "*finance*.php" -o -iname "*finance*.go" \
    -o -iname "*migration*.php" -o -iname "*migration*.go" \
  \) 2>/dev/null | grep -v node_modules | grep -v vendor | grep -v .git | head -20)

  # Find protected files/directories
  while IFS= read -r file; do
    [[ -e "$file" ]] && protected_files+=("$file")
  done < <(find "$REPO_PATH" \( \
    -path "*/migrations" -o -path "*/config" -o -path "*/vendor" -o -path "*/node_modules" \
    -o -name ".env*" -o -name "*.key" -o -name "secrets*" \
    -o -path "*/.git" \
  \) -type d 2>/dev/null | head -20)

  # Generate risk-register.md
  cat > "$KB_DIR/risk-register.md" << 'EOF'
# Risk Register

## High-Risk Files (Large or Complex)

Files over 500 lines indicate complexity and warrant extra care during modifications.

EOF

  if [[ ${#large_files[@]} -gt 0 ]]; then
    cat >> "$KB_DIR/risk-register.md" << 'EOF'
| File | Lines | Size (KB) | Risk Reason |
|------|-------|-----------|-------------|
EOF
    for file_info in "${large_files[@]}"; do
      IFS='|' read -r file lines size_kb <<< "$file_info"
      # Remove repo path prefix
      rel_file="${file#$REPO_PATH/}"
      cat >> "$KB_DIR/risk-register.md" << EOF
| \`$rel_file\` | $lines | $size_kb | Large file requires full test coverage |
EOF
    done
  else
    cat >> "$KB_DIR/risk-register.md" << 'EOF'
(No large files found)
EOF
  fi

  cat >> "$KB_DIR/risk-register.md" << 'EOF'

## Critical Domain Files

Files with auth, payment, finance, or migration logic are critical and require special handling.

EOF

  if [[ ${#risky_files[@]} -gt 0 ]]; then
    cat >> "$KB_DIR/risk-register.md" << 'EOF'
| File | Risk Type | Notes |
|------|-----------|-------|
EOF
    for file in "${risky_files[@]}"; do
      rel_file="${file#$REPO_PATH/}"
      # Determine risk type from filename
      risk_type="Unknown"
      [[ "$rel_file" =~ [Aa]uth ]] && risk_type="Authentication"
      [[ "$rel_file" =~ [Pp]ay ]] && risk_type="Payment"
      [[ "$rel_file" =~ [Ff]inance ]] && risk_type="Financial"
      [[ "$rel_file" =~ [Mm]igration ]] && risk_type="Database"
      cat >> "$KB_DIR/risk-register.md" << EOF
| \`$rel_file\` | $risk_type | Requires security review |
EOF
    done
  else
    cat >> "$KB_DIR/risk-register.md" << 'EOF'
(No critical domain files found)
EOF
  fi

  cat >> "$KB_DIR/risk-register.md" << 'EOF'

## Known Fragile Areas

[Document any areas that have caused incidents]

## Access Control

Some resources require special permissions or approval before modification:
- Database migrations
- Authentication and payment processing
- Configuration and secrets
- Third-party integrations
EOF

  # Generate protected-files.md
  cat > "$KB_DIR/protected-files.md" << 'EOF'
# Protected Files

Protected files require extra care, approval, or cannot be edited without special handling.

## Never Edit Without Approval

These files have production impact and must be reviewed carefully:

EOF

  if [[ ${#protected_files[@]} -gt 0 ]]; then
    cat >> "$KB_DIR/protected-files.md" << 'EOF'
- Database migrations (changes are permanent)
- Configuration files (affects production behavior)
- Environment variable templates
- Secret credential files (never commit credentials)

## Protected Directories

| Directory | Policy |
|-----------|--------|
EOF
    for file in "${protected_files[@]}"; do
      if [[ -d "$file" ]]; then
        rel_file="${file#$REPO_PATH/}"
        policy="Review before editing"
        [[ "$rel_file" =~ migrations ]] && policy="Requires migration review process"
        [[ "$rel_file" =~ vendor|node_modules ]] && policy="Auto-generated, do not edit"
        [[ "$rel_file" =~ \.env ]] && policy="Never commit, use .env.example"
        cat >> "$KB_DIR/protected-files.md" << EOF
| \`$rel_file\` | $policy |
EOF
      fi
    done
  else
    cat >> "$KB_DIR/protected-files.md" << 'EOF'
- Migrations directory (schema changes)
- Config directory (production settings)
- vendor/ and node_modules/ (auto-generated dependencies)
- .env files (secrets — never commit)
EOF
  fi

  cat >> "$KB_DIR/protected-files.md" << 'EOF'

## Generated or Compiled Files

Do not edit these files directly:

- Build output directories (dist/, build/)
- npm/composer/pip vendor files
- Compiled binaries
- Database migrations history

## Require Full Test Coverage Before Touching

Before modifying these, ensure:
- Unit tests pass
- Integration tests pass (if applicable)
- Database tests pass (if schema touched)
- Security review passed (if auth/payment touched)

Files in the risk-register.md "High-Risk Files" section always require this level of scrutiny.
EOF

  echo "✓ Generated $KB_DIR/risk-register.md"
  echo "✓ Generated $KB_DIR/protected-files.md"
  echo "  - Found ${#large_files[@]} large files"
  echo "  - Found ${#risky_files[@]} critical domain files"
  echo "  - Found ${#protected_files[@]} protected directories"
fi

# ===== MODE: AUDIT (check drift between code and KB) =====
if [[ $MODE_AUDIT -eq 1 ]]; then
  # Check if knowledge-base exists
  if [[ ! -d "$KB_DIR" ]]; then
    echo "⚠️  knowledge-base/ not found, skipping drift check"
    exit 0
  fi

  found_issues=0
  issues=()

  echo "Checking knowledge-base drift..."

  # Check 1: Look for routes not documented in api-contracts.md
  if [[ -f "$KB_DIR/api-contracts.md" ]]; then
    # Find route definitions (Laravel/Go style)
    route_count=0
    [[ -d "$REPO_PATH/routes" ]] && route_count=$(find "$REPO_PATH/routes" -name "*.php" -o -name "*.go" 2>/dev/null | wc -l)

    if [[ $route_count -gt 0 ]]; then
      # Count documented endpoints (lines with "Path:" or "GET/POST/etc")
      documented=$(grep -c "Path\|GET\|POST\|PUT\|DELETE" "$KB_DIR/api-contracts.md" 2>/dev/null || echo 0)
      if [[ $documented -lt 2 ]]; then
        found_issues=$((found_issues + 1))
        issues+=("api-contracts.md may be incomplete — found $route_count route files but < 2 documented endpoints")
      fi
    fi
  fi

  # Check 2: Look for queue jobs not documented in queues-and-jobs.md
  if [[ -f "$KB_DIR/queues-and-jobs.md" ]]; then
    job_count=0
    [[ -d "$REPO_PATH/app/Jobs" ]] && job_count=$(find "$REPO_PATH/app/Jobs" -name "*.php" 2>/dev/null | wc -l)
    [[ -d "$REPO_PATH/internal" ]] && job_count=$((job_count + $(find "$REPO_PATH/internal" -name "*job*.go" 2>/dev/null | wc -l)))

    if [[ $job_count -gt 0 ]]; then
      documented=$(grep -c "Queue\|Job" "$KB_DIR/queues-and-jobs.md" 2>/dev/null || echo 0)
      if [[ $documented -lt 1 ]]; then
        found_issues=$((found_issues + 1))
        issues+=("queues-and-jobs.md may be incomplete — found $job_count job files but no documented queues")
      fi
    fi
  fi

  # Check 3: Look for Redis usage not documented
  if [[ -f "$KB_DIR/redis-and-cache.md" ]]; then
    redis_usage=$(grep -r "Redis::\|redis\|cache" "$REPO_PATH" --include="*.php" --include="*.go" --include="*.js" 2>/dev/null | grep -v node_modules | grep -v vendor | wc -l)
    if [[ $redis_usage -gt 5 ]]; then
      documented=$(grep -c "key\|Key" "$KB_DIR/redis-and-cache.md" 2>/dev/null || echo 0)
      if [[ $documented -lt 3 ]]; then
        found_issues=$((found_issues + 1))
        issues+=("redis-and-cache.md may be incomplete — found $redis_usage Redis usages but < 3 documented keys")
      fi
    fi
  fi

  # Check 4: Large files not in risk-register.md
  if [[ -f "$KB_DIR/risk-register.md" ]]; then
    large_file_count=$(find "$REPO_PATH" -type f \( -name "*.php" -o -name "*.go" \) -size +100k 2>/dev/null | grep -v vendor | grep -v node_modules | wc -l)
    if [[ $large_file_count -gt 0 ]]; then
      documented=$(grep -c "File\|file" "$KB_DIR/risk-register.md" 2>/dev/null || echo 0)
      if [[ $documented -lt $((large_file_count + 1)) ]]; then
        found_issues=$((found_issues + 1))
        issues+=("risk-register.md may be incomplete — found $large_file_count large files (>100KB)")
      fi
    fi
  fi

  # Check 5: CLAUDE.md protocol blocks outside intellisense governance
  if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
    suspicious_headings=(
      "Execution Mode"
      "Change Contract"
      "Agent Pipeline"
      "Dev Protocol"
      "Write Protection"
      "Risk & Confidence"
    )

    for heading in "${suspicious_headings[@]}"; do
      if grep -q "## $heading" "$REPO_PATH/CLAUDE.md" 2>/dev/null; then
        found_issues=$((found_issues + 1))
        issues+=("CLAUDE.md contains unmanaged protocol block: '$heading' (should be in knowledge-base/)")
      fi
    done
  fi

  if [[ $found_issues -gt 0 ]]; then
    echo "⚠️  DRIFT: Found $found_issues drift issue(s):"
    printf '  • %s\n' "${issues[@]}"
    echo ""
    echo "Recommended actions:"
    echo "  1. Review the flagged knowledge-base/ files"
    echo "  2. Update documentation to match current code"
    echo "  3. Run again to verify drift is resolved"
    exit 1
  else
    echo "✓ Knowledge-base drift check passed"
    exit 0
  fi
fi
