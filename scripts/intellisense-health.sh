#!/bin/bash
# intellisense-health.sh
# Unified health assessment: generates scorecard (0-100), maturity level (0-4),
# graph health, or graph-exception roster (graph modes apply when code intelligence is code-review-graph).
#
# Usage:
#   ./scripts/intellisense-health.sh [--format score|maturity|graph] [--json] [path]
#   ./scripts/intellisense-health.sh --exceptions [path]
#
# Graph modes:
#   --format graph   Show graph readiness for repo at <path> (reads
#                    .intellisense/graph-status.json + .intellisense/graph-exception.json).
#                    Reports "not-chosen" when code intelligence is not code-review-graph.
#   --exceptions     Recursively scan <path> for .intellisense/graph-exception.json
#                    and list the roster (reason, owner, expiry, stack).

set -euo pipefail

# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
source "$(dirname "${BASH_SOURCE[0]}")/lib/intellisense-paths.sh"
# Source graph integration helpers (stack support, advisory marker, etc.)
source "$(dirname "${BASH_SOURCE[0]}")/lib/intellisense-graph.sh"

REPO_PATH="."
FORMAT="score"
OUTPUT_JSON=0
SHOW_EXCEPTIONS=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
      ;;
    --exceptions)
      SHOW_EXCEPTIONS=1
      shift
      ;;
    *)
      REPO_PATH="$1"
      shift
      ;;
  esac
done

# Validate format
if [[ ! "$FORMAT" =~ ^(score|maturity|graph)$ ]]; then
  echo "Error: --format must be 'score', 'maturity', or 'graph'" >&2
  exit 1
fi

# Normalize path
REPO_PATH="$(cd "$REPO_PATH" 2>/dev/null && pwd)" || {
  echo "Error: Repository path not found" >&2
  exit 1
}

# ===== --exceptions roster =====
# Scans <path> recursively for .intellisense/graph-exception.json and prints a roster.
# Lightweight governance: roster + owner + expiry, no central database.
if [[ $SHOW_EXCEPTIONS -eq 1 ]]; then
  # Find exception files; cap depth at 4 to avoid pathological scans.
  exc_files=()
  while IFS= read -r exc; do
    [ -n "$exc" ] && exc_files+=("$exc")
  done < <(find "$REPO_PATH" -maxdepth 4 -type f -name "graph-exception.json" -path '*/.intellisense/*' 2>/dev/null | sort)

  if [[ $OUTPUT_JSON -eq 1 ]]; then
    printf '{\n  "scanned_path": "%s",\n  "count": %d,\n  "exceptions": [' \
      "$REPO_PATH" "${#exc_files[@]}"
    sep=""
    for exc in "${exc_files[@]}"; do
      repo_dir="$(dirname "$(dirname "$exc")")"
      reason="$(intellisense_graph_read_exception_field "$repo_dir" reason 2>/dev/null || echo unknown)"
      stack="$(intellisense_graph_read_exception_field "$repo_dir" stack 2>/dev/null || echo unknown)"
      owner="$(intellisense_graph_read_exception_field "$repo_dir" owner 2>/dev/null || echo unset)"
      expires="$(intellisense_graph_read_exception_field "$repo_dir" expires 2>/dev/null || echo unset)"
      printf '%s\n    {"repo": "%s", "reason": "%s", "stack": "%s", "owner": "%s", "expires": "%s"}' \
        "$sep" "$repo_dir" "$reason" "$stack" "$owner" "$expires"
      sep=","
    done
    printf '\n  ]\n}\n'
  else
    echo "intellisense graph-exception roster (scanning $REPO_PATH, depth ≤ 4)"
    echo ""
    if [[ ${#exc_files[@]} -eq 0 ]]; then
      echo "  (no .intellisense/graph-exception.json files found)"
    else
      printf "  %-50s  %-22s  %-12s  %-30s  %s\n" "REPO" "REASON" "STACK" "OWNER" "EXPIRES"
      printf "  %-50s  %-22s  %-12s  %-30s  %s\n" "----" "------" "-----" "-----" "-------"
      today="$(date -u +%Y-%m-%d)"
      for exc in "${exc_files[@]}"; do
        repo_dir="$(dirname "$(dirname "$exc")")"
        reason="$(intellisense_graph_read_exception_field "$repo_dir" reason 2>/dev/null || echo unknown)"
        stack="$(intellisense_graph_read_exception_field "$repo_dir" stack 2>/dev/null || echo unknown)"
        owner="$(intellisense_graph_read_exception_field "$repo_dir" owner 2>/dev/null || echo unset)"
        expires="$(intellisense_graph_read_exception_field "$repo_dir" expires 2>/dev/null || echo unset)"
        # Mark expired entries
        expiry_marker=""
        if [[ "$expires" != "unset" ]] && [[ "$expires" < "$today" ]]; then
          expiry_marker=" (EXPIRED)"
        fi
        # Truncate repo path for display
        display_repo="${repo_dir#$HOME/}"
        [[ "$display_repo" != "$repo_dir" ]] && display_repo="~/$display_repo"
        [[ ${#display_repo} -gt 50 ]] && display_repo="…${display_repo: -49}"
        printf "  %-50s  %-22s  %-12s  %-30s  %s%s\n" \
          "$display_repo" "$reason" "$stack" "$owner" "$expires" "$expiry_marker"
      done
      echo ""
      echo "  Total: ${#exc_files[@]} repos opting out of graph use."
    fi
  fi
  exit 0
fi

# ===== --format graph (per-repo graph health) =====
if [[ "$FORMAT" == "graph" ]]; then
  status_path="$(intellisense_graph_status_path "$REPO_PATH")"
  exc_path="$(intellisense_graph_exception_path "$REPO_PATH")"
  managed=0
  intellisense_is_managed "$REPO_PATH" && managed=1

  # Decide overall state
  state="ok"
  state_reason=""
  code_intel="${INTELLISENSE_CODE_INTEL:-}"
  if [[ -z "$code_intel" && -f "$HOME/.intellisense/integrations.env" ]]; then
    code_intel="$(sed -n 's/^INTELLISENSE_CODE_INTEL=//p' "$HOME/.intellisense/integrations.env" | head -1)"
  fi
  if [[ "${code_intel:-none}" != "code-review-graph" ]]; then
    state="not-chosen"
    state_reason="code intelligence is ${code_intel:-none}; the graph is optional (choose it with --code-intel code-review-graph)"
  elif [[ $managed -eq 0 ]]; then
    state="not-managed"
    state_reason="repo has no <!-- INTELLISENSE-MANAGED --> marker or .intellisense/MANAGED file"
  elif [[ -f "$exc_path" ]]; then
    state="exception"
    state_reason="repo opts out of graph use via .intellisense/graph-exception.json"
  elif [[ ! -f "$status_path" ]]; then
    state="graph-missing"
    state_reason=".intellisense/graph-status.json missing — run: bash scripts/graph-bootstrap.sh"
  else
    readiness="$(intellisense_graph_read_status_field "$REPO_PATH" readiness 2>/dev/null || echo unknown)"
    if [[ "$readiness" == "failed" ]]; then
      state="failed"
      state_reason="graph build failed; see .intellisense/graph-status.json"
    elif [[ "$readiness" == "skipped" ]]; then
      state="skipped"
      state_reason="graph build skipped (likely exception path)"
    fi
  fi

  if [[ $OUTPUT_JSON -eq 1 ]]; then
    printf '{\n  "repo_path": "%s",\n  "intellisense_managed": %s,\n  "state": "%s",\n  "reason": "%s"' \
      "$REPO_PATH" \
      "$([ $managed -eq 1 ] && echo true || echo false)" \
      "$state" \
      "$state_reason"
    if [[ -f "$status_path" ]]; then
      stack="$(intellisense_graph_read_status_field "$REPO_PATH" stack 2>/dev/null || echo unknown)"
      stack_support="$(intellisense_graph_read_status_field "$REPO_PATH" stack_support 2>/dev/null || echo unknown)"
      nodes="$(intellisense_graph_read_status_field "$REPO_PATH" nodes 2>/dev/null || echo 0)"
      built_at="$(intellisense_graph_read_status_field "$REPO_PATH" built_at_utc 2>/dev/null || echo unknown)"
      readiness="$(intellisense_graph_read_status_field "$REPO_PATH" readiness 2>/dev/null || echo unknown)"
      advisory="$(intellisense_graph_read_status_field "$REPO_PATH" advisory 2>/dev/null || echo '')"
      printf ',\n  "stack": "%s",\n  "stack_support": "%s",\n  "nodes": %s,\n  "built_at_utc": "%s",\n  "readiness": "%s",\n  "advisory": "%s"' \
        "$stack" "$stack_support" "$nodes" "$built_at" "$readiness" "$advisory"
    fi
    printf '\n}\n'
  else
    echo "intellisense graph health: $REPO_PATH"
    echo ""
    echo "  intellisense-managed:   $([ $managed -eq 1 ] && echo YES || echo NO)"
    echo "  State:          $state"
    echo "  Reason:         $state_reason"
    if [[ -f "$status_path" ]]; then
      echo ""
      echo "  --- .intellisense/graph-status.json ---"
      cat "$status_path" | sed 's/^/  /'
    fi
    if [[ -f "$exc_path" ]]; then
      echo ""
      echo "  --- .intellisense/graph-exception.json ---"
      cat "$exc_path" | sed 's/^/  /'
    fi
  fi

  # Exit code: 0 only when state is ok or exception or skipped (those are
  # legitimate operational states); 1 for graph-missing and failed.
  case "$state" in
    ok|exception|skipped|not-managed|not-chosen) exit 0 ;;
    graph-missing|failed)                         exit 1 ;;
    *)                                 exit 1 ;;
  esac
fi

# ===== Shared Component Detection =====
# These checks must match exactly across both scorecard and detect-maturity

has_claude_md=0
has_agents=0
has_skills=0
has_hooks=0
has_mcp=0
has_knowledge_base=0

# Check for CLAUDE.md (identical logic from both scripts)
[[ -f "$REPO_PATH/CLAUDE.md" ]] && has_claude_md=1

# Check for .claude/agents (identical: at least one .md file)
if [[ -d "$REPO_PATH/.claude/agents" ]] && find "$REPO_PATH/.claude/agents" -maxdepth 1 -name "*.md" -type f | grep -q .; then
  has_agents=1
fi

# Check for .claude/skills (identical: at least one .md file or SKILL.md structure)
if [[ -d "$REPO_PATH/.claude/skills" ]] && (find "$REPO_PATH/.claude/skills" -maxdepth 2 -name "*.md" -type f | grep -q . || [[ -f "$REPO_PATH/.claude/skills/SKILL.md" ]]); then
  has_skills=1
fi

# Check for hooks (identical: directory or config file)
[[ -d "$REPO_PATH/.claude/hooks" ]] || [[ -f "$REPO_PATH/.intellisense-hooks.json" ]] && has_hooks=1

# Check for MCP config (identical: either location)
[[ -f "$REPO_PATH/.mcp.json" ]] || [[ -f "$REPO_PATH/.claude/mcp.json" ]] && has_mcp=1

# Check for knowledge base (identical: file or directory with .md files)
if [[ -f "$REPO_PATH/KNOWLEDGE_BASE.md" ]] || [[ -d "$REPO_PATH/knowledge-base" && -n "$(find "$REPO_PATH/knowledge-base" -name "*.md" -type f 2>/dev/null | head -1)" ]]; then
  has_knowledge_base=1
fi

# ===== Mode: Score (0-100 across 7 dimensions) =====
if [[ "$FORMAT" == "score" ]]; then
  score_governance=0
  score_knowledge=0
  score_health=0
  score_tooling=0
  score_tests=0
  score_risk=0
  score_tokens=0

  # 1. CLAUDE.md Governance (0-20)
  if [[ $has_claude_md -eq 1 ]]; then
    score_governance=10
    # Bonus for execution modes
    grep -q "execution.*mode\|Execution.*[Mm]ode" "$REPO_PATH/CLAUDE.md" && score_governance=$((score_governance + 3))
    # Bonus for change contract
    grep -q "change.*contract\|Change.*[Cc]ontract" "$REPO_PATH/CLAUDE.md" && score_governance=$((score_governance + 3))
    # Bonus for write protection
    grep -q "write.*protection\|Write.*[Pp]rotection" "$REPO_PATH/CLAUDE.md" && score_governance=$((score_governance + 2))
    # Bonus for risk assessment
    grep -q "risk.*assessment\|Risk.*[Ss]core" "$REPO_PATH/CLAUDE.md" && score_governance=$((score_governance + 2))
  fi

  # 2. Knowledge Base Quality (0-20)
  if [[ -f "$REPO_PATH/KNOWLEDGE_BASE.md" ]]; then
    score_knowledge=15
    # Check for required sections
    grep -q "Architecture\|architecture" "$REPO_PATH/KNOWLEDGE_BASE.md" && score_knowledge=$((score_knowledge + 2))
    grep -q "Known.*Gotchas\|known.*gotchas" "$REPO_PATH/KNOWLEDGE_BASE.md" && score_knowledge=$((score_knowledge + 3))
  elif [[ -d "$REPO_PATH/knowledge-base" ]]; then
    score_knowledge=10
    [[ -f "$REPO_PATH/knowledge-base/architecture.md" ]] && score_knowledge=$((score_knowledge + 3))
    [[ -f "$REPO_PATH/knowledge-base/known-gotchas.md" ]] && score_knowledge=$((score_knowledge + 3))
    [[ -f "$REPO_PATH/knowledge-base/risk-register.md" ]] && score_knowledge=$((score_knowledge + 2))
    [[ -f "$REPO_PATH/knowledge-base/protected-files.md" ]] && score_knowledge=$((score_knowledge + 2))
  fi

  # 3. Setup Health (0-15)
  [[ -f "$REPO_PATH/.claude/settings.json" ]] && score_health=$((score_health + 5))
  [[ -f "$REPO_PATH/.intellisense-setup-marker" ]] || [[ -f "$(intellisense_state_path "$REPO_PATH" version)" ]] && score_health=$((score_health + 5))
  [[ -d "$REPO_PATH/.claude" ]] && score_health=$((score_health + 5))

  # 4. MCP/Tooling (0-10)
  [[ -f "$REPO_PATH/.mcp.json" ]] && score_tooling=$((score_tooling + 5))
  [[ -f "$REPO_PATH/.claude/settings.json" ]] && grep -q "hooks\|mcp" "$REPO_PATH/.claude/settings.json" && score_tooling=$((score_tooling + 5))

  # 5. Test/Build Commands Known (0-10)
  if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
    grep -q "go test\|npm test\|php.*test\|pytest\|mocha\|jest" "$REPO_PATH/CLAUDE.md" && score_tests=$((score_tests + 5))
    grep -q "build.*command\|Build.*[Cc]ommand\|make.*build" "$REPO_PATH/CLAUDE.md" && score_tests=$((score_tests + 5))
  fi

  # 6. Repo-Specific Risk Rules (0-15)
  if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
    # Check for high-risk file list
    grep -q "high.*risk\|protected.*file" "$REPO_PATH/CLAUDE.md" && score_risk=$((score_risk + 8))
    # Check for domain-specific rules
    grep -q "database\|api\|queue\|cache\|tenancy" "$REPO_PATH/CLAUDE.md" && score_risk=$((score_risk + 5))
    # Check for integration points
    grep -q "integration\|critical.*flow" "$REPO_PATH/CLAUDE.md" && score_risk=$((score_risk + 2))
  fi

  # 7. Token Discipline (0-10)
  if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
    # Check for response style guidelines
    grep -q "token\|word.*limit\|concise\|brief" "$REPO_PATH/CLAUDE.md" && score_tokens=$((score_tokens + 5))
    # Check for skill compression targets
    grep -q "token.*budget\|300 token\|200 token" "$REPO_PATH/CLAUDE.md" && score_tokens=$((score_tokens + 5))
  fi

  # Calculate totals
  total=$((score_governance + score_knowledge + score_health + score_tooling + score_tests + score_risk + score_tokens))

  # Identify gaps
  p0_gaps=()
  p1_gaps=()

  [[ $score_governance -lt 10 ]] && p0_gaps+=("CLAUDE.md governance incomplete")
  [[ $score_knowledge -lt 10 ]] && p1_gaps+=("Knowledge base missing or incomplete")
  [[ $score_health -lt 10 ]] && p1_gaps+=("Setup health (settings, markers) incomplete")
  [[ $score_tooling -lt 5 ]] && p1_gaps+=("MCP/tooling configuration missing")
  [[ $score_tests -lt 5 ]] && p1_gaps+=("Build/test commands not documented")
  [[ $score_risk -lt 8 ]] && p1_gaps+=("Risk rules (high-risk files, domains) not defined")
  [[ $score_tokens -lt 5 ]] && p1_gaps+=("Token discipline not established")

  # Output score mode
  if [[ $OUTPUT_JSON -eq 1 ]]; then
    cat <<EOF
{
  "repo_path": "$REPO_PATH",
  "total_score": $total,
  "total_possible": 100,
  "percentage": $(( total * 100 / 100 )),
  "dimensions": {
    "governance": $score_governance,
    "knowledge_base": $score_knowledge,
    "setup_health": $score_health,
    "mcp_tooling": $score_tooling,
    "test_build": $score_tests,
    "risk_rules": $score_risk,
    "token_discipline": $score_tokens
  },
  "gaps": {
    "p0": [$([ ${#p0_gaps[@]} -gt 0 ] && { for i in "${!p0_gaps[@]}"; do echo -n "\"${p0_gaps[$i]}\""; [[ $i -lt $((${#p0_gaps[@]}-1)) ]] && echo -n ","; done; } || echo "")],
    "p1": [$([ ${#p1_gaps[@]} -gt 0 ] && { for i in "${!p1_gaps[@]}"; do echo -n "\"${p1_gaps[$i]}\""; [[ $i -lt $((${#p1_gaps[@]}-1)) ]] && echo -n ","; done; } || echo "")]
  }
}
EOF
  else
    cat <<EOF
🎯 intellisense Scorecard
Repo: $REPO_PATH

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Score: $total/100 ($(printf "%.0f%%" $((total * 100 / 100))))

Breakdown:
  CLAUDE.md Governance   [$(printf "%2d/20" $score_governance)]  $(printf "%${score_governance}s" | tr ' ' '█')
  Knowledge Base         [$(printf "%2d/20" $score_knowledge)]  $(printf "%${score_knowledge}s" | tr ' ' '█')
  Setup Health           [$(printf "%2d/15" $score_health)]  $(printf "%${score_health}s" | tr ' ' '█')
  MCP/Tooling            [$(printf "%2d/10" $score_tooling)]  $(printf "%${score_tooling}s" | tr ' ' '█')
  Test/Build Commands    [$(printf "%2d/10" $score_tests)]  $(printf "%${score_tests}s" | tr ' ' '█')
  Risk Rules             [$(printf "%2d/15" $score_risk)]  $(printf "%${score_risk}s" | tr ' ' '█')
  Token Discipline       [$(printf "%2d/10" $score_tokens)]  $(printf "%${score_tokens}s" | tr ' ' '█')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

P0 Gaps (Critical):
$([ ${#p0_gaps[@]} -gt 0 ] && printf '  • %s\n' "${p0_gaps[@]}" || echo "  (none)")

P1 Improvements:
$([ ${#p1_gaps[@]} -gt 0 ] && printf '  • %s\n' "${p1_gaps[@]}" || echo "  (none)")
EOF
  fi

# ===== Mode: Maturity (0-4 level detection) =====
else
  # Determine maturity level
  maturity_level=0
  if [[ $has_claude_md -eq 1 ]]; then
    maturity_level=1
  fi
  if [[ $maturity_level -eq 1 ]] && [[ $has_knowledge_base -eq 1 ]]; then
    maturity_level=2
  fi
  if [[ $maturity_level -eq 2 ]] && ([[ $has_agents -eq 1 ]] || [[ $has_skills -eq 1 ]]); then
    maturity_level=3
  fi
  if [[ $maturity_level -eq 3 ]] && [[ $has_hooks -eq 1 ]] && [[ $has_mcp -eq 1 ]]; then
    maturity_level=4
  fi

  # Determine recommended action
  recommended_action="validate_only"
  case $maturity_level in
    0) recommended_action="replace" ;;
    1) recommended_action="adopt" ;;
    2) recommended_action="adopt" ;;
    3) recommended_action="inject" ;;
    4) recommended_action="validate_only" ;;
  esac

  # Build reasons array
  reasons=()
  [[ $has_claude_md -eq 0 ]] && reasons+=("Missing CLAUDE.md")
  [[ $has_agents -eq 0 ]] && reasons+=("Missing .claude/agents")
  [[ $has_skills -eq 0 ]] && reasons+=("Missing .claude/skills")
  [[ $has_hooks -eq 0 ]] && reasons+=("Missing hooks configuration")
  [[ $has_mcp -eq 0 ]] && reasons+=("Missing MCP config")
  [[ $has_knowledge_base -eq 0 ]] && reasons+=("Missing knowledge base")

  # Get maturity level name
  get_level_name() {
    case $1 in
      0) echo "None" ;;
      1) echo "Basic" ;;
      2) echo "Documented" ;;
      3) echo "Native Setup" ;;
      4) echo "Intellisense-Adopted" ;;
      *) echo "Unknown" ;;
    esac
  }

  # Output maturity mode
  if [[ $OUTPUT_JSON -eq 1 ]]; then
    # Build JSON reasons array
    json_reasons="["
    for i in "${!reasons[@]}"; do
      json_reasons+="\"${reasons[$i]}\""
      [[ $i -lt $((${#reasons[@]}-1)) ]] && json_reasons+=","
    done
    json_reasons+="]"

    cat <<EOF
{
  "repo_path": "$REPO_PATH",
  "maturity_level": $maturity_level,
  "has_claude_md": $has_claude_md,
  "has_agents": $has_agents,
  "has_skills": $has_skills,
  "has_hooks": $has_hooks,
  "has_mcp": $has_mcp,
  "has_knowledge_base": $has_knowledge_base,
  "recommended_action": "$recommended_action",
  "reasons": $json_reasons
}
EOF
  else
    level_name="$(get_level_name $maturity_level)"
    cat <<EOF
📊 intellisense Maturity Detection
Repo: $REPO_PATH
Level: $maturity_level/4 ($level_name)

Components:
  ✓ CLAUDE.md: $([ $has_claude_md -eq 1 ] && echo "YES" || echo "NO")
  ✓ .claude/agents: $([ $has_agents -eq 1 ] && echo "YES" || echo "NO")
  ✓ .claude/skills: $([ $has_skills -eq 1 ] && echo "YES" || echo "NO")
  ✓ Hooks: $([ $has_hooks -eq 1 ] && echo "YES" || echo "NO")
  ✓ MCP: $([ $has_mcp -eq 1 ] && echo "YES" || echo "NO")
  ✓ Knowledge Base: $([ $has_knowledge_base -eq 1 ] && echo "YES" || echo "NO")

Recommended Action: $recommended_action

Gaps:
$([ ${#reasons[@]} -gt 0 ] && printf '  • %s\n' "${reasons[@]}" || echo "  (none)")
EOF
  fi
fi
