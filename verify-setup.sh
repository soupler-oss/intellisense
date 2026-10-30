#!/bin/bash

# intellisense Verification Script
# Confirms that setup.sh completed successfully

CLAUDE_HOME="$HOME/.claude"
ISSUES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional integrations recorded by setup.sh: their checks run only when they were chosen.
TRACKER="none"; CODE_INTEL="none"
if [ -f "$HOME/.intellisense/integrations.env" ]; then
    TRACKER="$(sed -n 's/^INTELLISENSE_TRACKER=//p' "$HOME/.intellisense/integrations.env")"
    CODE_INTEL="$(sed -n 's/^INTELLISENSE_CODE_INTEL=//p' "$HOME/.intellisense/integrations.env")"
fi

# Source shared hooks resolution library
source "$SCRIPT_DIR/scripts/lib/hooks.sh"
# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
source "$SCRIPT_DIR/scripts/lib/intellisense-paths.sh"

# Parse command-line arguments for --repo mode
REPO_MODE=false
REPO_PATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      REPO_MODE=true
      REPO_PATH="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Early exit: if --repo mode, run per-repo checks and exit
if [ "$REPO_MODE" = true ]; then
  # Validate repo path
  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH" ]; then
    echo "❌ FAIL: --repo requires a valid directory path"
    exit 1
  fi

  # Check if jq is available (required for --repo mode)
  if ! command -v jq &>/dev/null; then
    echo "❌ FAIL: jq is required for --repo mode (install: brew install jq)"
    exit 1
  fi

  # Get INTELLISENSE_SETUP_DIR from the directory of this script
  INTELLISENSE_SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"

  # Source shared hooks resolution library
  source "$INTELLISENSE_SETUP_DIR/scripts/lib/hooks.sh"

  # Source all check scripts
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-repo.sh"
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-version.sh"
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-hooks.sh"
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-stack-go.sh"
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-stack-php.sh"
  source "$INTELLISENSE_SETUP_DIR/scripts/checks/check-stack-angular.sh"

  echo "=========================================="
  echo "intellisense Verification — Per-Repo Check"
  echo "Repository: $REPO_PATH"
  echo "=========================================="
  echo ""

  # Run repo check (may exit 2 if not initialized)
  REPO_ISSUES=0
  check_repo "$REPO_PATH"
  REPO_CHECK_EXIT=$?

  if [ $REPO_CHECK_EXIT -eq 2 ]; then
    echo ""
    exit 2
  fi

  if [ $REPO_CHECK_EXIT -gt 0 ]; then
    ((REPO_ISSUES += REPO_CHECK_EXIT))
  fi

  # Read stack and components from .intellisense/manifest.json
  MANIFEST_PATH=$(intellisense_state_path "$REPO_PATH" manifest)
  STACK=$(jq -r '.stack' "$MANIFEST_PATH" 2>/dev/null)
  COMPONENTS=$(jq -r '.components[]' "$MANIFEST_PATH" 2>/dev/null)

  # Run version check
  echo "Checking version consistency..."
  check_version "$REPO_PATH" "$INTELLISENSE_SETUP_DIR"

  # Run hooks check only if hooks in components
  if echo "$COMPONENTS" | grep -q "hooks"; then
    echo "Checking git hooks..."
    check_hooks "$REPO_PATH"
  fi

  # Run stack-specific checks
  if [ "$STACK" = "go" ]; then
    echo "Checking Go stack..."
    check_stack_go "$REPO_PATH"
  elif [ "$STACK" = "php" ]; then
    echo "Checking PHP stack..."
    check_stack_php "$REPO_PATH"
  elif [ "$STACK" = "angular" ]; then
    echo "Checking Angular stack..."
    check_stack_angular "$REPO_PATH"
  fi

  # ===== Graph readiness for intellisense-managed supported repos =====
  # Source the graph helpers (idempotent; library has its own guard).
  # shellcheck source=scripts/lib/intellisense-graph.sh
  source "$INTELLISENSE_SETUP_DIR/scripts/lib/intellisense-graph.sh"

  echo ""
  echo "Checking graph readiness..."

  if ! intellisense_is_managed "$REPO_PATH"; then
    echo "  ℹ Repo is not intellisense-managed (no <!-- INTELLISENSE-MANAGED --> in CLAUDE.md and no .intellisense/MANAGED file)"
    echo "  ℹ Skipping graph check (not in scope of graph enforcement)"
  elif intellisense_graph_has_exception "$REPO_PATH"; then
    GRAPH_EXC_REASON="$(intellisense_graph_read_exception_field "$REPO_PATH" reason 2>/dev/null || echo unknown)"
    echo "  ℹ Repo has .intellisense/graph-exception.json (reason=$GRAPH_EXC_REASON) — graph use opted-out"
  else
    STACK_SUPPORT="$(intellisense_graph_stack_support "$STACK")"
    GRAPH_STATUS_PATH="$(intellisense_graph_status_path "$REPO_PATH")"

    case "$STACK_SUPPORT" in
      mandatory-supported|candidate-supported|weak)
        if [ ! -f "$GRAPH_STATUS_PATH" ]; then
          # Graph missing in intellisense-managed supported context.
          echo "  ⚠ Graph missing for intellisense-managed $STACK_SUPPORT repo (.intellisense/graph-status.json not found)"
          BOOTSTRAP_CMD="bash $INTELLISENSE_SETUP_DIR/scripts/graph-bootstrap.sh --repo \"$REPO_PATH\" --stack $STACK"

          # Detect TTY for interactive offer
          if [ -t 0 ] && [ -t 1 ]; then
            echo ""
            read -p "  Run graph bootstrap now? [y/N]: " ANSWER
            case "$ANSWER" in
              y|Y|yes|Yes|YES)
                echo "  → Running: $BOOTSTRAP_CMD --yes"
                if bash "$INTELLISENSE_SETUP_DIR/scripts/graph-bootstrap.sh" \
                     --repo "$REPO_PATH" --stack "$STACK" --yes; then
                  echo "  ✓ Graph bootstrap succeeded"
                else
                  echo "  ✗ Graph bootstrap failed (exit $?)"
                  ((REPO_ISSUES++))
                fi
                ;;
              *)
                echo "  Skipped. To bootstrap manually: $BOOTSTRAP_CMD"
                # In interactive declined mode, treat as warning, not failure.
                ;;
            esac
          else
            # Non-interactive: hard-fail with remediation.
            echo "  ✗ Non-interactive mode — refusing to silently auto-bootstrap"
            echo "  Remediation: $BOOTSTRAP_CMD"
            ((REPO_ISSUES++))
          fi
        else
          # Graph exists; check readiness state.
          GRAPH_READINESS="$(intellisense_graph_read_status_field "$REPO_PATH" readiness 2>/dev/null || echo unknown)"
          GRAPH_NODES="$(intellisense_graph_read_status_field "$REPO_PATH" nodes 2>/dev/null || echo 0)"
          GRAPH_ADVISORY="$(intellisense_graph_read_status_field "$REPO_PATH" advisory 2>/dev/null || echo '')"

          case "$GRAPH_READINESS" in
            ready)
              echo "  ✓ Graph ready (nodes=$GRAPH_NODES, support=$STACK_SUPPORT)"
              [ -n "$GRAPH_ADVISORY" ] && echo "    $GRAPH_ADVISORY"
              ;;
            failed)
              echo "  ✗ Graph readiness FAILED (nodes=$GRAPH_NODES, support=$STACK_SUPPORT)"
              echo "  Remediation: bash $INTELLISENSE_SETUP_DIR/scripts/graph-bootstrap.sh --repo \"$REPO_PATH\" --stack $STACK"
              ((REPO_ISSUES++))
              ;;
            skipped)
              echo "  ℹ Graph build was skipped (likely exception path); status: $GRAPH_READINESS"
              ;;
            *)
              echo "  ⚠ Graph readiness state unknown: $GRAPH_READINESS"
              ;;
          esac
        fi
        ;;
      unsupported)
        echo "  ⚠ Stack '$STACK' is unsupported by code-review-graph"
        if ! intellisense_graph_has_exception "$REPO_PATH"; then
          echo "  ✗ intellisense-managed unsupported-stack repo without .intellisense/graph-exception.json"
          echo "  Remediation: bash $INTELLISENSE_SETUP_DIR/setup-repos.sh --repo \"$REPO_PATH\" --stack $STACK \\"
          echo "                  --migrate --graph-exception unsupported-stack \\"
          echo "                  --owner <email> --expires <YYYY-MM-DD>"
          ((REPO_ISSUES++))
        fi
        ;;
      *)
        echo "  ℹ Stack '$STACK' classification: $STACK_SUPPORT (not gated)"
        ;;
    esac
  fi

  echo ""
  echo "=========================================="
  if [ $REPO_ISSUES -eq 0 ]; then
    echo "✅ Repository check passed"
  else
    echo "❌ Repository check failed with $REPO_ISSUES issue(s)"
  fi
  echo "=========================================="
  echo ""

  exit $REPO_ISSUES
fi

check_symlinks() {
  local failed=0
  local managed_symlinks=(
    "$HOME/.claude/rules/baseline"
    "$HOME/.claude/skills"
    "$HOME/.claude/agents"
    "$HOME/.claude/templates"
    "$HOME/.claude/infrastructure"
    "$HOME/.claude/service-map.md"
    "$HOME/.intellisense/rules/language-specific"
    "$HOME/.intellisense/rules/operational"
  )
  for link in "${managed_symlinks[@]}"; do
    if [ -L "$link" ] && [ ! -e "$link" ]; then
      echo "WARN: dangling symlink: $link → $(readlink "$link")"
      failed=1
    fi
  done
  return $failed
}

echo "=========================================="
echo "intellisense Verification — Checking Installation"
echo "=========================================="
echo ""

# Check 0: Dangling symlinks (BLOCKING)
echo -n "✓ Checking for dangling symlinks... "
SYMLINK_OUTPUT=$(check_symlinks 2>&1)
SYMLINK_STATUS=$?
if [ $SYMLINK_STATUS -eq 0 ]; then
    echo "✓"
else
    echo "✗ FAILED"
    echo "$SYMLINK_OUTPUT"
    ((ISSUES++))
fi
echo ""

# Check 1: ~/.claude directory exists
echo -n "✓ Checking ~/.claude directory... "
if [ -d "$CLAUDE_HOME" ]; then
    echo "✓"
else
    echo "✗ FAILED"
    ((ISSUES++))
fi

# Check 2: Rules files present
# ~/.claude/rules/baseline/ is a symlink to INTELLISENSE_SETUP/rules/baseline (auto-loaded by Claude Code)
# On-demand rules live in ~/.intellisense/rules/
echo -n "✓ Checking rule files... "
INTELLISENSE_HOME="$HOME/.intellisense"
BASELINE_COUNT=$(find -L "$CLAUDE_HOME/rules/baseline" -type f 2>/dev/null | wc -l)
ONDEMAND_COUNT=$(find -L "$INTELLISENSE_HOME/rules" -type f 2>/dev/null | wc -l)
RULE_COUNT=$((BASELINE_COUNT + ONDEMAND_COUNT))
if [ "$BASELINE_COUNT" -ge 2 ] && [ "$ONDEMAND_COUNT" -ge 8 ]; then
    echo "✓ ($BASELINE_COUNT baseline + $ONDEMAND_COUNT on-demand)"
else
    echo "✗ FAILED (baseline: $BASELINE_COUNT/2+, on-demand: $ONDEMAND_COUNT/8+)"
    ((ISSUES++))
fi

# Check 2.5: Named baseline files exist (not just count)
echo -n "✓ Checking required baseline files... "
MISSING_BASELINE=0
for f in security.md reasoning-integrity.md; do
    if [ ! -f "$CLAUDE_HOME/rules/baseline/$f" ]; then
        echo ""
        echo "  ✗ Missing required baseline file: $f"
        MISSING_BASELINE=$((MISSING_BASELINE + 1))
    fi
done
if [ "$MISSING_BASELINE" -eq 0 ]; then
    echo "✓ (security.md, reasoning-integrity.md)"
else
    ((ISSUES++))
fi

# Check 2.6: CLAUDE.md exists, has intellisense markers, no broken rule references
echo -n "✓ Checking ~/.claude/CLAUDE.md... "
if [ ! -f "$CLAUDE_HOME/CLAUDE.md" ]; then
    echo "✗ FAILED (not found — run setup.sh)"
    ((ISSUES++))
elif ! grep -q "intellisense" "$CLAUDE_HOME/CLAUDE.md"; then
    echo "⚠ Warning: exists but missing intellisense markers — run setup.sh"
else
    # Check for the known broken path: rules/baseline/coding-style.md doesn't exist
    BROKEN_PATHS=0
    if grep -q 'rules/baseline/coding-style\.md' "$CLAUDE_HOME/CLAUDE.md" && \
       [ ! -f "$CLAUDE_HOME/rules/baseline/coding-style.md" ]; then
        BROKEN_PATHS=$((BROKEN_PATHS + 1))
    fi
    if [ "$BROKEN_PATHS" -gt 0 ]; then
        echo "⚠ Warning: $BROKEN_PATHS broken rule path(s) in CLAUDE.md (rules/baseline/coding-style.md missing)"
        echo "  Fix: bash setup.sh --refresh-global-claude"
    else
        echo "✓"
    fi
fi

# Check 2.7: config.json exists and has required fields
echo -n "✓ Checking ~/.claude/config.json... "
if [ ! -f "$CLAUDE_HOME/config.json" ]; then
    echo "✗ FAILED (not found — run setup.sh)"
    ((ISSUES++))
elif ! command -v jq &>/dev/null; then
    echo "⚠ Warning (jq not found — cannot validate fields)"
else
    INTELLISENSE_PATH=$(jq -r '.intellisense_setup_path // ""' "$CLAUDE_HOME/config.json" 2>/dev/null)
    if [ -z "$INTELLISENSE_PATH" ]; then
        echo "✗ FAILED (intellisense_setup_path field missing — run setup.sh)"
        ((ISSUES++))
    elif [ ! -d "$INTELLISENSE_PATH" ]; then
        echo "✗ FAILED (intellisense_setup_path '$INTELLISENSE_PATH' not found — repo moved? run setup.sh)"
        ((ISSUES++))
    else
        echo "✓ ($INTELLISENSE_PATH)"
    fi
fi

# Check 3: Skill files present
echo -n "✓ Checking skill files... "
SKILL_COUNT=$(find -L "$CLAUDE_HOME/skills" -type f 2>/dev/null | wc -l)
if [ "$SKILL_COUNT" -ge 20 ]; then
    echo "✓ ($SKILL_COUNT files)"
else
    echo "✗ FAILED (found $SKILL_COUNT, expected 20+)"
    ((ISSUES++))
fi

# Check 4: Agent specs present
echo -n "✓ Checking agent specifications... "
AGENT_COUNT=$(find -L "$CLAUDE_HOME/agents" -type f 2>/dev/null | wc -l)
if [ "$AGENT_COUNT" -ge 3 ]; then
    echo "✓ ($AGENT_COUNT files)"
else
    echo "✗ FAILED (found $AGENT_COUNT, expected 3+)"
    ((ISSUES++))
fi

# Check 5: Template files present
echo -n "✓ Checking template files... "
TEMPLATE_COUNT=$(find -L "$CLAUDE_HOME/templates" -type f 2>/dev/null | wc -l)
if [ "$TEMPLATE_COUNT" -ge 2 ]; then
    echo "✓ ($TEMPLATE_COUNT files)"
else
    echo "✗ FAILED (found $TEMPLATE_COUNT, expected 2+)"
    ((ISSUES++))
fi

# Check 6: Infrastructure docs present (service-map.md + knowledge-base.md)
echo -n "✓ Checking infrastructure documentation... "
INFRA_COUNT=$(find -L "$CLAUDE_HOME/infrastructure" -type f 2>/dev/null | wc -l)
if [ "$INFRA_COUNT" -ge 2 ]; then
    echo "✓ ($INFRA_COUNT files)"
else
    echo "✗ FAILED (found $INFRA_COUNT, expected 2+)"
    ((ISSUES++))
fi

# Check 7: service-map.md synced
echo -n "✓ Checking service-map.md... "
if [ -f "$CLAUDE_HOME/service-map.md" ]; then
    LINES=$(wc -l < "$CLAUDE_HOME/service-map.md")
    echo "✓ ($LINES lines)"
else
    echo "✗ FAILED"
    ((ISSUES++))
fi

# Check 8: MEMORY.md initialized
echo -n "✓ Checking MEMORY.md... "
if [ -f "$CLAUDE_HOME/MEMORY.md" ]; then
    echo "✓"
else
    echo "✗ FAILED"
    ((ISSUES++))
fi

# Check 9: Core directories exist (agents, infrastructure, templates, teams, projects)
# Note: rules/ and skills/ are symlinks to master directories; subdirs don't need to exist in ~/.claude/
echo -n "✓ Checking core directories... "
DIRS=(
    "agents"
    "infrastructure"
    "templates"
    "teams"
    "projects"
)

MISSING_DIRS=0
for DIR in "${DIRS[@]}"; do
    if [ ! -d "$CLAUDE_HOME/$DIR" ]; then
        ((MISSING_DIRS++))
    fi
done

if [ "$MISSING_DIRS" -eq 0 ]; then
    echo "✓"
else
    echo "✗ FAILED ($MISSING_DIRS missing)"
    ((ISSUES++))
fi

# Check 10: File permissions correct
echo -n "✓ Checking file permissions... "
PERMS_OK=0
if [ -r "$CLAUDE_HOME/rules" ] && [ -r "$CLAUDE_HOME/skills" ] && [ -r "$CLAUDE_HOME/MEMORY.md" ]; then
    PERMS_OK=1
fi

if [ "$PERMS_OK" -eq 1 ]; then
    echo "✓"
else
    echo "✗ FAILED"
    ((ISSUES++))
fi

# Check 11: INITIALIZED marker
echo -n "✓ Checking initialization marker... "
if [ -f "$CLAUDE_HOME/.intellisense-initialized" ]; then
    INIT_TIME=$(head -1 "$CLAUDE_HOME/.intellisense-initialized")
    echo "✓ ($INIT_TIME)"
else
    echo "✗ FAILED (.intellisense-initialized marker missing — setup.sh did not complete; run: bash setup.sh)"
    ((ISSUES++))
fi

# Check 11.5: .intellisense-version present and matches repo VERSION
echo -n "✓ Checking .intellisense-version... "
INTELLISENSE_VERSION_FILE="$CLAUDE_HOME/.intellisense-version"
if [ ! -f "$INTELLISENSE_VERSION_FILE" ]; then
    echo "⚠ Warning: .intellisense-version not found — run setup.sh"
else
    INSTALLED_VER=$(grep 'INTELLISENSE_VERSION=' "$INTELLISENSE_VERSION_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    INTELLISENSE_SETUP_PATH=""
    if [ -f "$CLAUDE_HOME/config.json" ] && command -v jq &>/dev/null; then
        INTELLISENSE_SETUP_PATH=$(jq -r '.intellisense_setup_path // ""' "$CLAUDE_HOME/config.json" 2>/dev/null)
    fi
    if [ -n "$INTELLISENSE_SETUP_PATH" ] && [ -f "$INTELLISENSE_SETUP_PATH/VERSION" ]; then
        REPO_VER=$(cat "$INTELLISENSE_SETUP_PATH/VERSION" | tr -d '[:space:]')
        if [ "$INSTALLED_VER" = "$REPO_VER" ]; then
            echo "✓ (v$INSTALLED_VER, up to date)"
        else
            echo "⚠ Warning: version mismatch (installed: v$INSTALLED_VER, repo: v$REPO_VER) — run setup.sh"
        fi
    else
        echo "✓ (v$INSTALLED_VER)"
    fi
fi

# Check 11.6: INTELLISENSE_README.md installed
# setup.sh writes this on fresh installs (one-shot, not idempotent — won't
# re-create if removed). Missing usually means setup.sh aborted or the file
# was deleted; either way the developer lost their entry-point doc.
echo -n "✓ Checking INTELLISENSE_README.md... "
if [ -f "$CLAUDE_HOME/INTELLISENSE_README.md" ]; then
    echo "✓"
else
    echo "✗ FAILED (~/.claude/INTELLISENSE_README.md missing — run: bash setup.sh)"
    ((ISSUES++))
fi

# Check 12: Service repos (auto-read from manifest, optional)
echo -n "✓ Checking service repos... "
MANIFEST="$CLAUDE_HOME/repos-manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "⚠ Skipped (no repos configured — run setup.sh to set up repos)"
else
    REPO_ISSUES=0
    REPO_COUNT=0
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        ((REPO_COUNT++))
        if [ ! -f "$repo_path/CLAUDE.md" ]; then
            echo ""
            echo "  ✗ Missing CLAUDE.md: $repo_path"
            ((REPO_ISSUES++))
        fi
        if [ ! -d "$repo_path/knowledge-base" ]; then
            echo ""
            echo "  ✗ Missing knowledge-base/: $repo_path (run setup-repos.sh)"
            ((REPO_ISSUES++))
        else
            # Check for required auto-filled KB files (numbered structure).
            REPO_STACK=$(grep 'STACK=' "$(intellisense_state_path "$repo_path" version)" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
            if [[ "$REPO_STACK" == "angular" || "$REPO_STACK" == "react" || "$REPO_STACK" == "next" || "$REPO_STACK" == "vue" ]]; then
                KB_REQUIRED=(
                    "00-system-context.md"
                    "00-system-architecture.md"
                    "01-system-tech-stack.md"
                    "01-system-source-tree.md"
                    "02-api-contracts.md"
                    "04-eng-testing-guide.md"
                )
            else
                KB_REQUIRED=(
                    "00-system-context.md"
                    "00-system-architecture.md"
                    "01-system-tech-stack.md"
                    "01-system-source-tree.md"
                    "02-api-contracts.md"
                    "02-data-models.md"
                    "04-eng-testing-guide.md"
                )
            fi
            KB_MISSING=0
            for kb_file in "${KB_REQUIRED[@]}"; do
                if [ ! -f "$repo_path/knowledge-base/$kb_file" ]; then
                    ((KB_MISSING++))
                fi
            done
            if [ "$KB_MISSING" -gt 0 ]; then
                echo ""
                echo "  ✗ knowledge-base/ missing $KB_MISSING required files: $repo_path (run generate-kb-stubs.sh)"
                ((REPO_ISSUES++))
            fi
        fi
        if [ ! -f "$(intellisense_state_path "$repo_path" version)" ]; then
            echo ""
            echo "  ✗ Missing .intellisense/version: $repo_path (run setup-repos.sh)"
            ((REPO_ISSUES++))
        fi
        if [ "$TRACKER" = "beads" ] && [ ! -f "$repo_path/.beads/config.yaml" ]; then
            echo ""
            echo "  ✗ Missing .beads/config.yaml: $repo_path (tracker is beads: run setup-repos.sh)"
            ((REPO_ISSUES++))
        fi
        _REPO_HOOK=$(resolve_pre_push_hook_path "$repo_path" 2>/dev/null || echo "")
        if [ -z "$_REPO_HOOK" ] || [ ! -f "$_REPO_HOOK" ]; then
            echo ""
            echo "  ⚠ Missing pre-push hook: $repo_path (run setup-repos.sh)"
        fi
    done < <(grep '"path"' "$MANIFEST" | sed 's/.*"path": *"\(.*\)".*/\1/')

    if [ "$REPO_ISSUES" -eq 0 ]; then
        echo "✓ ($REPO_COUNT repos configured)"
    else
        echo "✗ FAILED ($REPO_ISSUES issues across $REPO_COUNT repos)"
        ((ISSUES++))
    fi
fi

# Check 13: Total size
echo -n "✓ Checking total installation size... "
SIZE="unknown"
if [ -d "$CLAUDE_HOME" ]; then
    SIZE=$(du -sh "$CLAUDE_HOME" 2>/dev/null | cut -f1)
    echo "✓ ($SIZE)"
else
    echo "✗ FAILED"
    ((ISSUES++))
fi

# Check 13.9: the intellisense engine — every Live-mode hook asks it for tiers.
echo -n "✓ Checking intellisense engine... "
_engine=""
for _c in "${INTELLISENSE_BIN:-}" "$HOME/.intellisense/bin/intellisense" "$(command -v intellisense 2>/dev/null)"; do
    if [ -n "$_c" ] && [ -x "$_c" ]; then _engine="$_c"; break; fi
done
if [ -z "$_engine" ]; then
    echo "✗ FAILED (not installed: pushes are blocked until it is; install: brew install soupler-oss/tap/intellisense, then bash setup.sh)"
    ((ISSUES++))
else
    echo "✓ ($("$_engine" version 2>/dev/null) at $_engine)"
fi

# Check 14: code-review-graph MCP — exact version pin ==2.3.2 (only when chosen)
if [ "$CODE_INTEL" != "code-review-graph" ]; then echo "✓ code-review-graph: not selected (code intelligence: $CODE_INTEL) — skipped"; else
echo -n "✓ Checking code-review-graph MCP... "
SETTINGS="$HOME/.claude/settings.json"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin:$PATH"

# Source the graph library to keep the pin in one place.
# shellcheck source=scripts/lib/intellisense-graph.sh
source "$SCRIPT_DIR/scripts/lib/intellisense-graph.sh"
CRG_REQUIRED_VERSION="$(intellisense_graph_required_version)"

# Strict once chosen: a developer who chose the graph must have code-review-graph
# installed AND directly callable on PATH. Any deviation fails this check.
if ! command -v jq &>/dev/null; then
    echo "✗ FAILED (jq required for graph verification; install: brew install jq)"
    ((ISSUES++))
else
    # jq is available — check settings.json
    if [ ! -f "$SETTINGS" ]; then
        echo "✗ FAILED (settings.json not found — code-review-graph MCP not configured; run: bash setup.sh)"
        ((ISSUES++))
    elif ! jq -e '.mcpServers["code-review-graph"]' "$SETTINGS" &>/dev/null; then
        echo "✗ FAILED (not configured in settings.json — run: bash setup.sh)"
        ((ISSUES++))
    else
        # Config exists — validate command type and args
        CONFIG_CMD=$(jq -r '.mcpServers["code-review-graph"].command' "$SETTINGS" 2>/dev/null)
        CONFIG_ARGS=$(jq -r '.mcpServers["code-review-graph"].args | @json' "$SETTINGS" 2>/dev/null)

        # Check for broken/stale config (e.g., "npx")
        if [ "$CONFIG_CMD" = "npx" ]; then
            echo "✗ FAILED (stale config: npx is not valid; run setup.sh to repair)"
            ((ISSUES++))
        elif [ -z "$CONFIG_CMD" ]; then
            echo "✗ FAILED (config.command is missing or invalid)"
            ((ISSUES++))
        elif ! echo "$CONFIG_ARGS" | grep -q "serve"; then
            echo "✗ FAILED (config.args missing 'serve' — stale or broken config; run setup.sh to repair)"
            ((ISSUES++))
        elif [ "$CONFIG_CMD" = "code-review-graph" ]; then
            if command -v code-review-graph &>/dev/null; then
                # Verify version pin
                ACTUAL_VER="$(intellisense_graph_detect_version 2>/dev/null || echo '')"
                if [ "$ACTUAL_VER" = "$CRG_REQUIRED_VERSION" ]; then
                    echo "✓ (code-review-graph $ACTUAL_VER, matches the pin)"
                elif [ -n "$ACTUAL_VER" ]; then
                    echo "✗ FAILED (version drift: installed=$ACTUAL_VER, required=$CRG_REQUIRED_VERSION; run setup.sh to upgrade)"
                    ((ISSUES++))
                else
                    echo "✗ FAILED (code-review-graph --version returned no parseable version; run: bash setup.sh)"
                    ((ISSUES++))
                fi
            else
                echo "✗ FAILED (command: code-review-graph configured but not in PATH; run: bash setup.sh)"
                ((ISSUES++))
            fi
        elif [ "$CONFIG_CMD" = "uvx" ]; then
            # Graph scripts (setup-repos.sh, graph-bootstrap.sh) call the
            # code-review-graph binary directly. The MCP config shape itself
            # is not what they consume — they consume PATH. So uvx in the MCP
            # entry is acceptable PROVIDED the binary is independently
            # resolvable on PATH at the pinned version. (setup.sh's
            # configure_mcp() prefers the direct shape and will rewrite uvx
            # → direct when the binary is available; this branch handles the
            # case where the user deliberately kept uvx but the binary still
            # satisfies the graph scripts.)
            if command -v code-review-graph &>/dev/null; then
                ACTUAL_VER="$(intellisense_graph_detect_version 2>/dev/null || echo '')"
                if [ "$ACTUAL_VER" = "$CRG_REQUIRED_VERSION" ]; then
                    echo "✓ (uvx MCP shape; binary on PATH at $ACTUAL_VER — graph scripts satisfied)"
                elif [ -n "$ACTUAL_VER" ]; then
                    echo "✗ FAILED (uvx MCP shape but binary version drift: installed=$ACTUAL_VER, required=$CRG_REQUIRED_VERSION; run setup.sh to upgrade)"
                    ((ISSUES++))
                else
                    echo "✗ FAILED (uvx MCP shape but code-review-graph --version unparseable; run: bash setup.sh)"
                    ((ISSUES++))
                fi
            else
                echo "✗ FAILED (uvx MCP shape AND code-review-graph not on PATH — graph scripts will break; run: bash setup.sh)"
                ((ISSUES++))
            fi
        else
            echo "✗ FAILED (config.command is '$CONFIG_CMD', not 'code-review-graph'; run: bash setup.sh to repair)"
            ((ISSUES++))
        fi

        # Warn on other stale npx MCP entries (advisory only, not a failure)
        WARNINGS=0
        while IFS= read -r server_name; do
            [ "$server_name" = "code-review-graph" ] && continue
            cmd=$(jq -r --arg n "$server_name" '.mcpServers[$n].command // ""' "$SETTINGS" 2>/dev/null)
            if [ "$cmd" = "npx" ]; then
                echo "  ⚠ MCP '$server_name': uses stale 'npx' command — run setup.sh to repair"
                ((WARNINGS++))
            fi
        done < <(jq -r '.mcpServers | keys[]' "$SETTINGS" 2>/dev/null)
    fi
fi

fi  # code intelligence = code-review-graph

# Check 15: Pre-push hook installed in INTELLISENSE_SETUP repo
echo -n "✓ Checking INTELLISENSE_SETUP pre-push hook... "
INTELLISENSE_SETUP_PATH=""
if [ -f "$CLAUDE_HOME/config.json" ] && command -v jq &>/dev/null; then
    INTELLISENSE_SETUP_PATH=$(jq -r '.intellisense_setup_path // ""' "$CLAUDE_HOME/config.json" 2>/dev/null)
fi
if [ -z "$INTELLISENSE_SETUP_PATH" ]; then
    echo "⚠ Skipped (intellisense_setup_path not found in config.json)"
else
    HOOK_PATH=$(resolve_pre_push_hook_path "$INTELLISENSE_SETUP_PATH" 2>/dev/null) || true
    if [ -z "$HOOK_PATH" ]; then
        echo "⚠ Warning: could not resolve hooks directory for INTELLISENSE_SETUP — run setup.sh"
    elif [ ! -f "$HOOK_PATH" ]; then
        echo "⚠ Warning: pre-push hook not installed in INTELLISENSE_SETUP — run setup.sh"
    elif [ ! -x "$HOOK_PATH" ]; then
        echo "⚠ Warning: pre-push hook not executable in INTELLISENSE_SETUP — run setup.sh"
    else
        echo "✓"
    fi
fi

# Check 15.1: INTELLISENSE_SETUP .beads/ initialized + chain block in pre-push
if [ "$TRACKER" != "beads" ]; then echo "✓ INTELLISENSE_SETUP .beads/: not selected (tracker: $TRACKER) — skipped"; else
# setup.sh's bd-onboarding block runs `bd init` in INTELLISENSE_SETUP and appends
# an intellisense INTEGRATION block to .beads/hooks/pre-push so beads' pre-push
# chains into intellisense's. If either is missing, Tier 1+ pushes from INTELLISENSE_SETUP
# may skip the contract gate.
echo -n "✓ Checking INTELLISENSE_SETUP .beads/ + chain block... "
if [ -z "$INTELLISENSE_SETUP_PATH" ]; then
    echo "⚠ Skipped (intellisense_setup_path not in config.json)"
elif [ ! -d "$INTELLISENSE_SETUP_PATH/.beads" ]; then
    echo "✗ FAILED ($INTELLISENSE_SETUP_PATH/.beads/ missing — run: bash setup.sh)"
    ((ISSUES++))
elif [ ! -f "$INTELLISENSE_SETUP_PATH/.beads/hooks/pre-push" ]; then
    echo "✗ FAILED (.beads/hooks/pre-push missing in INTELLISENSE_SETUP — run: bash setup.sh)"
    ((ISSUES++))
elif ! grep -qF "BEGIN intellisense INTEGRATION" "$INTELLISENSE_SETUP_PATH/.beads/hooks/pre-push"; then
    echo "✗ FAILED (.beads/hooks/pre-push lacks intellisense INTEGRATION chain block — run: bash setup.sh)"
    ((ISSUES++))
else
    echo "✓"
fi

fi  # tracker = beads

# Check 15.2: INTELLISENSE_SETUP post-merge git hook (heartbeat refresh on git pull)
# setup.sh's _hb_install_post_merge_hook() drops an intellisense HEARTBEAT POST-MERGE
# block into INTELLISENSE_SETUP's post-merge hook (honoring core.hooksPath). Without
# it, `git pull` in INTELLISENSE_SETUP leaves the heartbeat runtime stale.
echo -n "✓ Checking INTELLISENSE_SETUP post-merge hook... "
if [ -z "$INTELLISENSE_SETUP_PATH" ]; then
    echo "⚠ Skipped (intellisense_setup_path not in config.json)"
else
    PM_HOOKS_DIR=$(resolve_hooks_dir "$INTELLISENSE_SETUP_PATH" 2>/dev/null) || PM_HOOKS_DIR=""
    PM_PATH="$PM_HOOKS_DIR/post-merge"
    if [ -z "$PM_HOOKS_DIR" ]; then
        echo "⚠ Warning: could not resolve hooks directory for INTELLISENSE_SETUP — run setup.sh"
    elif [ ! -f "$PM_PATH" ]; then
        echo "✗ FAILED (post-merge hook missing at $PM_PATH — run: bash setup.sh)"
        ((ISSUES++))
    elif ! grep -qF "BEGIN intellisense HEARTBEAT POST-MERGE" "$PM_PATH"; then
        echo "✗ FAILED (post-merge hook lacks intellisense HEARTBEAT block — run: bash setup.sh)"
        ((ISSUES++))
    else
        echo "✓"
    fi
fi

# Check 16: Beads (bd CLI) — only when the tracker is beads.
if [ "$TRACKER" != "beads" ]; then echo "✓ Beads: not selected (tracker: $TRACKER) — skipped"; else
# Strict once chosen, like Check 14 (code-review-graph): every developer
# must run the BD_REQUIRED_VERSION pin so artifact validation in the pre-push
# hook is consistent across the fleet. Source the pin from setup.sh rather
# than duplicate-defining it here.
echo -n "Check 16: Beads (bd CLI)... "
BD_REQUIRED_VERSION="$(grep -E '^BD_REQUIRED_VERSION=' "$SCRIPT_DIR/setup.sh" | head -1 | cut -d'"' -f2)"
if [ -z "$BD_REQUIRED_VERSION" ]; then
    echo "✗ FAILED (could not read BD_REQUIRED_VERSION from setup.sh — internal error)"
    ISSUES=$((ISSUES + 1))
elif command -v bd >/dev/null 2>&1; then
    # stderr dropped: bd may emit "Warning: multiple 'bd' binaries found in
    # PATH" first, which would zero out the parse.
    BD_ACTUAL_VER="$(bd version 2>/dev/null | head -1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)?' \
        | head -1)"
    if [ "$BD_ACTUAL_VER" = "$BD_REQUIRED_VERSION" ]; then
        echo "✓ bd $BD_ACTUAL_VER at $(command -v bd) (matches intellisense pin)"
    elif [ -n "$BD_ACTUAL_VER" ]; then
        echo "✗ FAILED (version drift: installed=$BD_ACTUAL_VER, required=$BD_REQUIRED_VERSION; run setup.sh to upgrade)"
        ISSUES=$((ISSUES + 1))
    else
        echo "✗ FAILED (bd installed at $(command -v bd) but version could not be parsed)"
        ISSUES=$((ISSUES + 1))
    fi
else
    echo "✗ not found"
    echo "    macOS / Linuxbrew: brew install beads"
    echo "    Linux (no brew):   bash setup.sh   (uses SHA256-verified tarball download to ~/.local/bin/)"
    echo "    Upstream installer: https://github.com/gastownhall/beads"
    ISSUES=$((ISSUES + 1))
fi

fi  # tracker = beads

# Check 17: intellisense Phase 1/2/3 hooks installed in ~/.claude/settings.json
# (PreToolUse contract gate + UserPromptSubmit classifier + intellisense.gate_mode + intellisense.graph_enforcement)
# verify-setup must catch missing hooks so
# developers don't run with stale 1.1.0 config thinking they have 1.2.0 enforcement.
echo -n "Check 17: intellisense hooks + settings (Phase 1/2/3)... "
if [ ! -f "$SETTINGS" ]; then
    echo "✗ FAILED (~/.claude/settings.json missing — run: bash setup.sh)"
    ISSUES=$((ISSUES + 1))
elif ! command -v jq >/dev/null 2>&1; then
    echo "⚠ SKIPPED (jq required to validate settings.json structure)"
else
    HOOK_ISSUES=()
    # PreToolUse matcher MUST include all 5 of Edit, Write, MultiEdit,
    # NotebookEdit, Bash (a partial matcher like "Bash" would leave
    # Edit/Write/etc. unprotected). Locate the intellisense-owned PreToolUse entry by its command,
    # then verify the matcher pipe-separated list contains every required
    # tool exactly.
    REQUIRED_TOOLS=("Edit" "Write" "MultiEdit" "NotebookEdit" "Bash")
    GATE_HOOK_MATCHER=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("preToolUse-contract-gate")) | .matcher' "$SETTINGS" 2>/dev/null | head -1)
    if [ -z "$GATE_HOOK_MATCHER" ]; then
        HOOK_ISSUES+=("PreToolUse contract gate hook missing (no entry references preToolUse-contract-gate.sh)")
    else
        # Split matcher by | and check each required tool appears
        IFS='|' read -ra MATCHER_PARTS <<<"$GATE_HOOK_MATCHER"
        for tool in "${REQUIRED_TOOLS[@]}"; do
            FOUND=false
            for part in "${MATCHER_PARTS[@]}"; do
                if [ "$part" = "$tool" ]; then
                    FOUND=true
                    break
                fi
            done
            if [ "$FOUND" = "false" ]; then
                HOOK_ISSUES+=("PreToolUse matcher missing '$tool' (got: '$GATE_HOOK_MATCHER'; required: ${REQUIRED_TOOLS[*]})")
            fi
        done
    fi
    # UserPromptSubmit classifier must be present AND installed under the
    # GLOBAL matcher (matcher == ""). A classifier under a
    # non-global-matcher makes it inert for normal prompts, so command
    # presence alone is not enough.
    if ! jq -e '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | test("userPromptSubmit-classifier"))' "$SETTINGS" >/dev/null 2>&1; then
        HOOK_ISSUES+=("UserPromptSubmit classifier hook missing")
    else
        # Does ANY entry that contains the classifier have matcher == ""?
        CLASSIFIER_HAS_GLOBAL=$(jq '[.hooks.UserPromptSubmit[]? | select(.hooks[]?.command | test("userPromptSubmit-classifier")) | .matcher] | map(. == "") | any' "$SETTINGS" 2>/dev/null)
        if [ "$CLASSIFIER_HAS_GLOBAL" != "true" ]; then
            CLASSIFIER_MATCHERS_CSV=$(jq -r '[.hooks.UserPromptSubmit[]? | select(.hooks[]?.command | test("userPromptSubmit-classifier")) | .matcher] | join(",")' "$SETTINGS" 2>/dev/null)
            HOOK_ISSUES+=("UserPromptSubmit classifier installed but ONLY under non-global matcher(s): [$CLASSIFIER_MATCHERS_CSV]. It must be under a global matcher (matcher==\"\") to fire for normal prompts. Run setup.sh to repair.")
        fi
    fi
    # PostToolUse Skill|Agent usage tracker.
    # The original Check 17 missed this hook entirely — the exact reason the PostToolUse usage tracker
    # was dormant on every upgraded dev. Verify the
    # matcher exists AND covers both Skill and Agent tools.
    POSTTOOL_MATCHER=$(jq -r '.hooks.PostToolUse[]? | select(.hooks[]?.command | test("postToolUse-usage-tracker")) | .matcher' "$SETTINGS" 2>/dev/null | head -1)
    if [ -z "$POSTTOOL_MATCHER" ]; then
        HOOK_ISSUES+=("PostToolUse usage-tracker hook missing — Intellisense-Skills/Intellisense-Agents trailers will be empty until installed. Run setup.sh to repair.")
    else
        # Matcher should be pipe-separated and contain both Skill and Agent.
        IFS='|' read -ra POSTTOOL_PARTS <<<"$POSTTOOL_MATCHER"
        REQUIRED_POSTTOOL=("Skill" "Agent")
        for tool in "${REQUIRED_POSTTOOL[@]}"; do
            FOUND=false
            for part in "${POSTTOOL_PARTS[@]}"; do
                if [ "$part" = "$tool" ]; then
                    FOUND=true; break
                fi
            done
            if [ "$FOUND" = "false" ]; then
                HOOK_ISSUES+=("PostToolUse usage-tracker matcher missing '$tool' (got: '$POSTTOOL_MATCHER'; required: Skill|Agent)")
            fi
        done
    fi
    # intellisense.gate_mode must be either pilot or enforced
    GATE_MODE=$(jq -r '.intellisense.gate_mode // empty' "$SETTINGS" 2>/dev/null)
    if [ "$GATE_MODE" != "pilot" ] && [ "$GATE_MODE" != "enforced" ]; then
        HOOK_ISSUES+=("intellisense.gate_mode missing or invalid (got: '$GATE_MODE'; expected 'pilot' or 'enforced')")
    fi
    # intellisense.graph_enforcement must be either warn or block
    GRAPH_ENF=$(jq -r '.intellisense.graph_enforcement // empty' "$SETTINGS" 2>/dev/null)
    if [ "$GRAPH_ENF" != "warn" ] && [ "$GRAPH_ENF" != "block" ]; then
        HOOK_ISSUES+=("intellisense.graph_enforcement missing or invalid (got: '$GRAPH_ENF'; expected 'warn' or 'block')")
    fi
    # intellisense.audit_chain_enforcement must be either enforced or warn (default enforced per gate doc)
    AUDIT_ENF=$(jq -r '.intellisense.audit_chain_enforcement // empty' "$SETTINGS" 2>/dev/null)
    if [ "$AUDIT_ENF" != "enforced" ] && [ "$AUDIT_ENF" != "warn" ]; then
        HOOK_ISSUES+=("intellisense.audit_chain_enforcement missing or invalid (got: '$AUDIT_ENF'; expected 'enforced' or 'warn')")
    fi
    # intellisense.config_version must be a positive integer (template ships 1)
    CFG_VER=$(jq -r '.intellisense.config_version // empty' "$SETTINGS" 2>/dev/null)
    if ! [[ "$CFG_VER" =~ ^[1-9][0-9]*$ ]]; then
        HOOK_ISSUES+=("intellisense.config_version missing or not a positive integer (got: '$CFG_VER'; run: bash setup.sh to refresh from template)")
    fi

    if [ "${#HOOK_ISSUES[@]}" -eq 0 ]; then
        echo "✓ (gate_mode=$GATE_MODE, graph_enforcement=$GRAPH_ENF, audit_chain=$AUDIT_ENF, config_version=$CFG_VER, PreToolUse + PostToolUse + classifier all present)"
    else
        echo "✗ FAILED — run: bash setup.sh"
        for h in "${HOOK_ISSUES[@]}"; do
            echo "    - $h"
        done
        ISSUES=$((ISSUES + 1))
    fi
fi

# Check 18: intellisense heartbeat install state
# Reports state but doesn't fail the suite — --no-heartbeat is a legitimate
# opt-out by design, and a missing token is recoverable via
# `bash setup.sh --rotate-token`. Surface what we find so the dev can decide.
echo -n "Check 18: intellisense heartbeat (token + cron + queue health)... "
HEARTBEAT_TOKEN_FILE="$HOME/.intellisense/heartbeat-token"
HEARTBEAT_QUEUE_DIR="$HOME/.claude-intellisense/heartbeat-queue"
HEARTBEAT_ERROR_LOG="$HOME/.claude-intellisense/heartbeat-errors.log"
HEARTBEAT_PLIST="$HOME/Library/LaunchAgents/in.intellisense.heartbeat.plist"
HEARTBEAT_WARNINGS=()

# Token presence + permissions
HEARTBEAT_TOKEN_PRESENT=false
if [ -f "$HEARTBEAT_TOKEN_FILE" ]; then
    HEARTBEAT_TOKEN_PRESENT=true
    # Permissions check — token file MUST be mode 600
    TOKEN_PERMS=$(stat -c '%a' "$HEARTBEAT_TOKEN_FILE" 2>/dev/null || stat -f '%A' "$HEARTBEAT_TOKEN_FILE" 2>/dev/null || echo "")
    if [ -n "$TOKEN_PERMS" ] && [ "$TOKEN_PERMS" != "600" ]; then
        HEARTBEAT_WARNINGS+=("token file mode=$TOKEN_PERMS (expected 600). Fix: chmod 600 $HEARTBEAT_TOKEN_FILE")
    fi
fi

# Cron / launchd presence
HEARTBEAT_CRON_PRESENT=false
case "$(uname -s 2>/dev/null)" in
    Darwin)
        [ -f "$HEARTBEAT_PLIST" ] && HEARTBEAT_CRON_PRESENT=true
        ;;
    Linux)
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'intellisense-heartbeat'; then
            HEARTBEAT_CRON_PRESENT=true
        elif [ -f /etc/anacrontab.d/intellisense-heartbeat ]; then
            HEARTBEAT_CRON_PRESENT=true
        fi
        ;;
esac

# Queue depth — local payloads waiting to retry
QUEUE_DEPTH=0
if [ -d "$HEARTBEAT_QUEUE_DIR" ]; then
    QUEUE_DEPTH=$(find "$HEARTBEAT_QUEUE_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
fi
if [ "$QUEUE_DEPTH" -gt 5 ]; then
    HEARTBEAT_WARNINGS+=("heartbeat queue depth=$QUEUE_DEPTH (≥5 suggests sustained delivery failure — check $HEARTBEAT_ERROR_LOG)")
fi

# Recent errors — non-200 responses in the last 7 days
RECENT_ERRORS=0
if [ -f "$HEARTBEAT_ERROR_LOG" ]; then
    # Cheap heuristic: count entries from the last 7 days by ISO-date prefix
    # (entries are timestamped [YYYY-MM-DDThh:mm:ssZ ...])
    for i in 0 1 2 3 4 5 6; do
        D=$(date -u -v-${i}d +%Y-%m-%d 2>/dev/null || date -u --date="$i days ago" +%Y-%m-%d 2>/dev/null)
        [ -n "$D" ] && RECENT_ERRORS=$((RECENT_ERRORS + $(grep -c "^\[$D" "$HEARTBEAT_ERROR_LOG" 2>/dev/null || echo 0)))
    done
fi
if [ "$RECENT_ERRORS" -gt 0 ]; then
    HEARTBEAT_WARNINGS+=("heartbeat error log has $RECENT_ERRORS entry/entries in the last 7 days: $HEARTBEAT_ERROR_LOG")
fi

# Decide overall state — informational, not blocking
if [ "$HEARTBEAT_TOKEN_PRESENT" = false ] && [ "$HEARTBEAT_CRON_PRESENT" = false ]; then
    echo "⚪ NOT INSTALLED (--no-heartbeat or never configured; enable: bash setup.sh --rotate-token)"
elif [ "$HEARTBEAT_TOKEN_PRESENT" = true ] && [ "$HEARTBEAT_CRON_PRESENT" = true ] && [ "${#HEARTBEAT_WARNINGS[@]}" -eq 0 ]; then
    echo "✓ (token + cron installed, queue=$QUEUE_DEPTH, no recent errors)"
elif [ "$HEARTBEAT_TOKEN_PRESENT" = true ] && [ "$HEARTBEAT_CRON_PRESENT" = false ]; then
    echo "⚠ PARTIAL — token installed but cron missing. Fix: bash setup.sh --non-interactive --yes"
elif [ "$HEARTBEAT_TOKEN_PRESENT" = false ] && [ "$HEARTBEAT_CRON_PRESENT" = true ]; then
    echo "⚠ PARTIAL — cron installed but token missing (every fire will 401). Fix: bash setup.sh --rotate-token"
else
    echo "⚠ WARNINGS:"
fi
for w in "${HEARTBEAT_WARNINGS[@]}"; do
    echo "    - $w"
done

# Check 19: TCC-safe runtime install (v8 TCC plan)
# Hard-fails on: missing runtime, missing python3/jq/curl execution,
# MANIFEST mismatch (installed vs. repo). VERSION drift = warn only.
HEARTBEAT_BIN_DIR="$HOME/.intellisense/bin"
HEARTBEAT_INSTALLED_SCRIPT="$HEARTBEAT_BIN_DIR/intellisense-heartbeat.sh"
HEARTBEAT_MANIFEST="$HEARTBEAT_BIN_DIR/MANIFEST.sha256"

# Only run this check if the heartbeat was set up at all (token present)
if [ "$HEARTBEAT_TOKEN_PRESENT" = true ]; then
    echo -n "Check 19: TCC-safe heartbeat runtime (copied install + manifest + binaries)... "

    CHECK19_FAILS=()

    # 19a: copied runtime exists
    if [ ! -x "$HEARTBEAT_INSTALLED_SCRIPT" ]; then
        CHECK19_FAILS+=("heartbeat runtime not installed at $HEARTBEAT_INSTALLED_SCRIPT — run 'bash setup.sh'")
    fi
    for lib in lib/heartbeat-payload.sh lib/heartbeat_usage_parser.py lib/heartbeat-prices.json lib/hash.sh; do
        if [ ! -f "$HEARTBEAT_BIN_DIR/$lib" ]; then
            CHECK19_FAILS+=("missing $HEARTBEAT_BIN_DIR/$lib — run 'bash setup.sh' to refresh")
        fi
    done

    # 19b: real-execution preflight (catches corp-shimmed binaries)
    for cmd in jq curl python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            CHECK19_FAILS+=("$cmd not on PATH — heartbeat will fail under cron")
            continue
        fi
        case "$cmd" in
            jq)      jq --version >/dev/null 2>&1 || CHECK19_FAILS+=("jq found but won't run (corp shim?)") ;;
            curl)    curl --version >/dev/null 2>&1 || CHECK19_FAILS+=("curl found but won't run (corp shim?)") ;;
            python3) python3 -c 'print(1)' >/dev/null 2>&1 || CHECK19_FAILS+=("python3 found but won't run (corp shim?)") ;;
        esac
    done

    # 19c: manifest exists and matches installed runtime
    if [ ! -f "$HEARTBEAT_MANIFEST" ]; then
        CHECK19_FAILS+=("manifest missing at $HEARTBEAT_MANIFEST — run 'bash setup.sh' to regenerate")
    elif [ -f "$HEARTBEAT_BIN_DIR/lib/hash.sh" ]; then
        # Re-compute installed hashes and diff against manifest
        # shellcheck source=/dev/null
        source "$HEARTBEAT_BIN_DIR/lib/hash.sh" 2>/dev/null
        if command -v hb_sha256 >/dev/null 2>&1; then
            INSTALLED_TMP=$(mktemp)
            # heartbeat-prices.json excluded: hb_refresh_prices
            # swaps it at runtime from the repo, so its hash legitimately drifts
            # from the install-time manifest. Integrity covers executables only.
            for f in intellisense-heartbeat.sh lib/heartbeat-payload.sh lib/heartbeat_usage_parser.py; do
                if [ -f "$HEARTBEAT_BIN_DIR/$f" ]; then
                    H=$(hb_sha256 "$HEARTBEAT_BIN_DIR/$f")
                    printf '%s  %s\n' "$H" "$f" >> "$INSTALLED_TMP"
                fi
            done
            if ! diff -q "$INSTALLED_TMP" "$HEARTBEAT_MANIFEST" >/dev/null 2>&1; then
                CHECK19_FAILS+=("installed runtime hashes diverge from manifest — runtime tampered or partially overwritten; run 'bash setup.sh' to refresh")
            fi
            rm -f "$INSTALLED_TMP"

            # 19d: compare against repo (catches "git pull, didn't re-run setup.sh")
            if [ -f "$CLAUDE_HOME/config.json" ] && command -v jq >/dev/null 2>&1; then
                REPO_PATH=$(jq -r '.intellisense_setup_path // ""' "$CLAUDE_HOME/config.json" 2>/dev/null)
                if [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ]; then
                    REPO_DRIFT=false
                    # heartbeat-prices.json excluded: after a model release the
                    # refreshed runtime copy is intentionally NEWER than the
                    # dev's local repo clone (until they pull), so a hash diff
                    # here is expected, not drift.
                    for pair in \
                        "scripts/intellisense-heartbeat.sh:intellisense-heartbeat.sh" \
                        "scripts/lib/heartbeat-payload.sh:lib/heartbeat-payload.sh" \
                        "scripts/lib/heartbeat_usage_parser.py:lib/heartbeat_usage_parser.py"; do
                        REPO_FILE="${pair%%:*}"
                        BIN_FILE="${pair##*:}"
                        if [ -f "$REPO_PATH/$REPO_FILE" ] && [ -f "$HEARTBEAT_BIN_DIR/$BIN_FILE" ]; then
                            REPO_H=$(hb_sha256 "$REPO_PATH/$REPO_FILE")
                            BIN_H=$(hb_sha256 "$HEARTBEAT_BIN_DIR/$BIN_FILE")
                            if [ "$REPO_H" != "$BIN_H" ]; then
                                REPO_DRIFT=true
                                break
                            fi
                        fi
                    done
                    if [ "$REPO_DRIFT" = true ]; then
                        CHECK19_FAILS+=("runtime hashes diverge from repo — run 'bash setup.sh' to refresh, then re-verify")
                    fi
                fi
            fi
        fi
    fi

    # 19e: VERSION drift (warn only, not blocking)
    if [ -f "$CLAUDE_HOME/config.json" ] && command -v jq >/dev/null 2>&1; then
        REPO_PATH=$(jq -r '.intellisense_setup_path // ""' "$CLAUDE_HOME/config.json" 2>/dev/null)
        if [ -n "$REPO_PATH" ] && [ -f "$REPO_PATH/VERSION" ] && [ -f "$HOME/.intellisense/VERSION" ]; then
            REPO_VERSION=$(head -1 "$REPO_PATH/VERSION" | tr -d '[:space:]')
            INSTALLED_VERSION=$(head -1 "$HOME/.intellisense/VERSION" | tr -d '[:space:]')
            if [ "$REPO_VERSION" != "$INSTALLED_VERSION" ]; then
                HEARTBEAT_WARNINGS+=("VERSION metadata stale (installed=$INSTALLED_VERSION, repo=$REPO_VERSION); will refresh on next setup.sh")
            fi
        fi
    fi

    # 19f: copied-runtime isolation grep — must not reference repo paths
    if [ -d "$HEARTBEAT_BIN_DIR" ]; then
        if grep -RnE 'INTELLISENSE_SETUP_PATH/(scripts|hooks)' "$HEARTBEAT_BIN_DIR/" >/dev/null 2>&1; then
            CHECK19_FAILS+=("installed runtime references INTELLISENSE_SETUP_PATH/scripts or /hooks — runtime is not self-contained")
        fi
    fi

    if [ "${#CHECK19_FAILS[@]}" -eq 0 ]; then
        echo "✓ (runtime + manifest + binaries OK)"
    else
        echo "❌ FAIL"
        for f in "${CHECK19_FAILS[@]}"; do
            echo "    - $f"
        done
        ISSUES=$((ISSUES + 1))
    fi
fi

# Summary
echo ""
echo "=========================================="
if [ "$ISSUES" -eq 0 ]; then
    echo "✅ SUCCESS: intellisense setup is complete!"
    echo "=========================================="
    echo ""
    echo "Installation Summary:"
    echo "  Location: $CLAUDE_HOME"
    echo "  Rule files: $RULE_COUNT"
    echo "  Skill files: $SKILL_COUNT"
    echo "  Agent specs: $AGENT_COUNT"
    echo "  Template files: $TEMPLATE_COUNT"
    echo "  Infrastructure docs: $INFRA_COUNT"
    echo "  Total size: $SIZE"
    echo ""
    echo "Next Steps:"
    echo "  1. Read: cat README.md"
    echo "  2. Read: cat docs/live-mode.md"
    echo "  3. Read: cat QUICK_START.md"
    echo "  4. Start: /where-to-start [your requirement]"
    echo ""
    echo "=========================================="
    exit 0
else
    echo "❌ FAILED: Setup incomplete ($ISSUES issues found)"
    echo "=========================================="
    echo ""
    echo "Please address the issues above and rerun:"
    echo "  bash setup.sh"
    echo "  bash verify-setup.sh"
    echo ""
    echo "For detailed help, see INSTALLATION.md"
    echo ""
    echo "=========================================="
    exit 1
fi
