#!/bin/bash
# intellisense-graph.sh — graph-integration shared library (code intelligence code-review-graph). Source this file;
# do not execute directly.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/intellisense-graph.sh"  (from scripts/)
#        source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-graph.sh"  (from repo root)
#
# Scope:
#   - Stack classification (machine-readable; mirrors graph-supported-stacks.md)
#   - Min-node threshold lookup
#   - intellisense-managed marker detection (CLAUDE.md OR .intellisense/MANAGED)
#   - .intellisense/graph-status.json + .intellisense/graph-exception.json path helpers
#   - Universal [INTELLISENSE-WEAK-STACK: ...] advisory marker composition
#   - code-review-graph install detection (independent of setup.sh shell state)
#   - Defensive .gitignore writes (.code-review-graph/, .intellisense/graph-status.json)
#
# Discipline (mirrors intellisense-paths.sh):
#   - Pure functions: no I/O beyond stdout/stderr; no file/dir creation.
#   - Read functions: read files; no writes.
#   - Side-effect functions MUST have ensure_/write_ prefix.
#
# Returns: 0 on success, non-zero on failure. Errors → stderr. Values → stdout.
# Do NOT call exit; let callers decide.

# Guard against double-source
if [ -n "${INTELLISENSE_GRAPH_LIB_SOURCED:-}" ]; then
  return 0
fi
INTELLISENSE_GRAPH_LIB_SOURCED=1

# ============================================================================
# PURE: version pin (single source of truth for the floor)
# ============================================================================

# intellisense_graph_required_version — print the pinned version of code-review-graph.
# Floor bumps require: verify-setup.sh per supported stack + Platform Owner approval.
# Update this constant + the pin in setup.sh + intelligence-sources.md together.
intellisense_graph_required_version() {
  echo "2.3.2"
}

# ============================================================================
# PURE: stack classification (mirrors rules/operational/graph-supported-stacks.md)
# ============================================================================

# intellisense_graph_stack_support <stack> — print classification for a stack name.
# Output: one of: mandatory-supported | candidate-supported | weak | unsupported | case-by-case
# Returns: 0 always (case-by-case is the catch-all for unknown stacks).
#
# No stack is mandatory-supported by default. code-review-graph is a
# single-maintainer, third-party tool (github.com/tirth8205/code-review-graph)
# — this framework doesn't hard-depend any organization on it without that
# organization choosing to. An org that has vetted it and wants hard
# enforcement (setup-repos.sh fails without the binary) opts in explicitly:
#   INTELLISENSE_GRAPH_MANDATORY_STACKS="go python" bash setup-repos.sh ...
# Document a standing choice in rules/organization/ rather than passing the
# env var by hand every time. See "Candidate → Mandatory Promotion" in
# rules/operational/graph-supported-stacks.md for the validation bar we
# recommend clearing before opting in.
intellisense_graph_stack_support() {
  local stack="${1:-}"
  local stack_lc mandatory_list settings_file
  stack_lc="$(echo "$stack" | tr '[:upper:]' '[:lower:]')"
  # Opt-in sources, checked in order — pattern-match rather than a
  # `for x in $VAR` word-split loop: robust regardless of the caller's IFS.
  #   1. INTELLISENSE_GRAPH_MANDATORY_STACKS env var (CI / scripted runs), space- or
  #      comma-separated: "go,python" or "go python".
  #   2. intellisense.graph_mandatory_stacks in ~/.claude/settings.json (or
  #      $INTELLISENSE_SETTINGS_FILE) — the standing org-level choice, same pattern
  #      as intellisense.gate_mode / intellisense.graph_enforcement elsewhere in this repo.
  if [ -n "${INTELLISENSE_GRAPH_MANDATORY_STACKS:-}" ]; then
    mandatory_list=" $(echo "$INTELLISENSE_GRAPH_MANDATORY_STACKS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ') "
    case "$mandatory_list" in
      *" $stack_lc "*)
        echo "mandatory-supported"
        return 0
        ;;
    esac
  fi
  settings_file="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
  if [ -f "$settings_file" ] && command -v jq >/dev/null 2>&1; then
    if jq -e --arg s "$stack_lc" \
      '(.intellisense.graph_mandatory_stacks // []) | map(ascii_downcase) | index($s) != null' \
      "$settings_file" >/dev/null 2>&1; then
      echo "mandatory-supported"
      return 0
    fi
  fi
  case "$stack" in
    go|python|typescript|javascript|node|nestjs|react|java|csharp|kotlin|rust)
      echo "candidate-supported" ;;
    php|laravel|angular)
      echo "weak" ;;
    vue)
      echo "unsupported" ;;
    flutter)
      echo "weak" ;;
    *)
      echo "case-by-case" ;;
  esac
}

# intellisense_graph_min_nodes <stack> — print the min-node threshold for a stack.
# Output: integer (50 for known stacks where readiness is enforced or advisory; 0 for case-by-case).
# Weak stacks return 50 too — readiness is advisory, but the threshold is still useful for the advisory marker.
intellisense_graph_min_nodes() {
  local stack="${1:-}"
  case "$stack" in
    go|python|typescript|javascript|node|nestjs|react|java|csharp|kotlin|rust|php|laravel|angular|flutter)
      echo "50" ;;
    vue|*)
      echo "0" ;;
  esac
}

# ============================================================================
# PURE: per-repo path helpers
# ============================================================================

# intellisense_graph_status_path <repo> — print absolute path to .intellisense/graph-status.json
intellisense_graph_status_path() {
  echo "${1%/}/.intellisense/graph-status.json"
}

# intellisense_graph_exception_path <repo> — print absolute path to .intellisense/graph-exception.json
intellisense_graph_exception_path() {
  echo "${1%/}/.intellisense/graph-exception.json"
}

# intellisense_graph_managed_path <repo> — print absolute path to .intellisense/MANAGED
intellisense_graph_managed_path() {
  echo "${1%/}/.intellisense/MANAGED"
}

# intellisense_graph_db_path <repo> — print absolute path to <repo>/.code-review-graph
intellisense_graph_db_path() {
  echo "${1%/}/.code-review-graph"
}

# intellisense_graph_claude_md_path <repo> — print absolute path to repo's CLAUDE.md
intellisense_graph_claude_md_path() {
  echo "${1%/}/CLAUDE.md"
}

# ============================================================================
# READ: intellisense-managed marker detection 
# ============================================================================

# intellisense_is_managed <repo> — returns 0 if repo is intellisense-managed, 1 otherwise.
# A repo is intellisense-managed iff EITHER:
#   - .intellisense/MANAGED exists (committed file), OR
#   - CLAUDE.md contains the literal line "<!-- INTELLISENSE-MANAGED -->"
intellisense_is_managed() {
  local repo="${1:?repo required}"
  local managed_file
  managed_file="$(intellisense_graph_managed_path "$repo")"
  local claude_md
  claude_md="$(intellisense_graph_claude_md_path "$repo")"

  if [ -f "$managed_file" ]; then
    return 0
  fi
  if [ -f "$claude_md" ] && grep -qF '<!-- INTELLISENSE-MANAGED -->' "$claude_md" 2>/dev/null; then
    return 0
  fi
  return 1
}

# intellisense_graph_has_exception <repo> — returns 0 if .intellisense/graph-exception.json exists, 1 otherwise.
intellisense_graph_has_exception() {
  local repo="${1:?repo required}"
  [ -f "$(intellisense_graph_exception_path "$repo")" ]
}

# intellisense_graph_read_status_field <repo> <field> — read a top-level field from .intellisense/graph-status.json.
# Output: field value (raw, including quotes for strings) or empty if missing/no-jq.
intellisense_graph_read_status_field() {
  local repo="${1:?repo required}"
  local field="${2:?field required}"
  local status
  status="$(intellisense_graph_status_path "$repo")"
  [ -f "$status" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '.[$f] // empty' "$status" 2>/dev/null
  else
    # Fallback: line-based grep for "field": value (cosmetic; jq is preferred)
    grep -E "\"${field}\"\s*:" "$status" 2>/dev/null | head -1 | sed -E "s/.*\"${field}\"\s*:\s*//; s/,\s*$//; s/^\"//; s/\"$//"
  fi
}

# intellisense_graph_read_exception_field <repo> <field> — read a top-level field from .intellisense/graph-exception.json.
intellisense_graph_read_exception_field() {
  local repo="${1:?repo required}"
  local field="${2:?field required}"
  local exc
  exc="$(intellisense_graph_exception_path "$repo")"
  [ -f "$exc" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '.[$f] // empty' "$exc" 2>/dev/null
  else
    grep -E "\"${field}\"\s*:" "$exc" 2>/dev/null | head -1 | sed -E "s/.*\"${field}\"\s*:\s*//; s/,\s*$//; s/^\"//; s/\"$//"
  fi
}

# ============================================================================
# READ: install detection (independent — no inter-process state)
# ============================================================================

# intellisense_graph_detect_version — print currently-installed code-review-graph version,
# or empty string if not installed. Returns 0 if installed (version captured), 1 if not.
intellisense_graph_detect_version() {
  if ! command -v code-review-graph >/dev/null 2>&1; then
    return 1
  fi
  # `code-review-graph --version` typically prints "code-review-graph X.Y.Z" or just "X.Y.Z"
  local raw
  raw="$(code-review-graph --version 2>&1 | head -1)"
  # Extract semver-looking token (NN.NN.NN, with optional pre-release)
  echo "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)?' | head -1
}

# intellisense_graph_detect_install — verify code-review-graph is installed at the required version.
# Returns: 0 = installed at required version
#          1 = binary not on PATH
#          2 = installed but wrong version (current version printed to stderr)
intellisense_graph_detect_install() {
  local required actual
  required="$(intellisense_graph_required_version)"
  actual="$(intellisense_graph_detect_version)" || return 1

  if [ -z "$actual" ]; then
    return 1
  fi
  if [ "$actual" = "$required" ]; then
    return 0
  fi
  echo "code-review-graph version mismatch: installed=$actual, required=$required" >&2
  return 2
}

# ============================================================================
# READ: universal [INTELLISENSE-WEAK-STACK: ...] advisory marker composition
# ============================================================================

# intellisense_graph_advisory_marker <repo> — print the [INTELLISENSE-WEAK-STACK: ...] marker if applicable,
# empty string otherwise. Composed from .intellisense/graph-status.json and .intellisense/graph-exception.json.
# Order of precedence (most specific first):
#   1. exception present → "[INTELLISENSE-WEAK-STACK: <stack> — exception mode (reason: <r>, owner: <o>, expires: <e>)]"
#   2. min_nodes_override below stack default → "[INTELLISENSE-WEAK-STACK: empty-graph — --min-nodes override active]"
#   3. stack_support == weak → "[INTELLISENSE-WEAK-STACK: <stack> — <weak-reason>]"
#   4. stack_support == candidate-supported → "[INTELLISENSE-WEAK-STACK: <stack> — candidate stack, not yet validated for intellisense]"
#   5. otherwise → "" (empty; no marker)
intellisense_graph_advisory_marker() {
  local repo="${1:?repo required}"

  # 1. Exception mode wins
  if intellisense_graph_has_exception "$repo"; then
    local r o e s
    r="$(intellisense_graph_read_exception_field "$repo" reason)"
    o="$(intellisense_graph_read_exception_field "$repo" owner)"
    e="$(intellisense_graph_read_exception_field "$repo" expires)"
    s="$(intellisense_graph_read_exception_field "$repo" stack)"
    echo "[INTELLISENSE-WEAK-STACK: ${s:-unknown} — exception mode (reason: ${r:-unknown}, owner: ${o:-unset}, expires: ${e:-unset})]"
    return 0
  fi

  # Need status file for the rest
  local status
  status="$(intellisense_graph_status_path "$repo")"
  [ -f "$status" ] || { echo ""; return 0; }

  local stack support override threshold
  stack="$(intellisense_graph_read_status_field "$repo" stack)"
  support="$(intellisense_graph_read_status_field "$repo" stack_support)"
  override="$(intellisense_graph_read_status_field "$repo" min_nodes_override)"
  threshold="$(intellisense_graph_read_status_field "$repo" min_nodes_threshold)"

  # 2. min_nodes override active and below default
  if [ -n "$override" ] && [ "$override" != "null" ] && [ -n "$threshold" ] && [ "$threshold" != "null" ]; then
    if [ "$override" -lt "$threshold" ] 2>/dev/null; then
      echo "[INTELLISENSE-WEAK-STACK: empty-graph — --min-nodes override active (override=$override, default=$threshold)]"
      return 0
    fi
  fi

  # 3. weak stack
  case "$support" in
    weak)
      case "$stack" in
        php|laravel)
          echo "[INTELLISENSE-WEAK-STACK: $stack — magic methods + facades reduce parser coverage]" ;;
        angular)
          echo "[INTELLISENSE-WEAK-STACK: angular — heavy DI + RxJS dynamic chains reduce confidence]" ;;
        *)
          echo "[INTELLISENSE-WEAK-STACK: ${stack:-unknown} — stack classified weak]" ;;
      esac
      return 0 ;;
    candidate-supported)
      echo "[INTELLISENSE-WEAK-STACK: ${stack:-unknown} — candidate stack, not yet validated for intellisense]"
      return 0 ;;
  esac

  # 5. No marker applies
  echo ""
}

# ============================================================================
# SIDE-EFFECT: defensive .gitignore writes (idempotent)
# ============================================================================

# intellisense_graph_ensure_gitignore <repo> — append graph runtime artifacts to .gitignore
# if not already present. Idempotent; never duplicates entries.
# Files added: .code-review-graph/ and .intellisense/graph-status.json
# Files NOT added: .intellisense/graph-exception.json, .intellisense/MANAGED (these are committed)
intellisense_graph_ensure_gitignore() {
  local repo="${1:?repo required}"
  local gitignore="${repo%/}/.gitignore"
  local needed=(".code-review-graph/" ".intellisense/graph-status.json")
  local entry added=0

  # Create .gitignore if missing
  if [ ! -f "$gitignore" ]; then
    touch "$gitignore"
  fi

  for entry in "${needed[@]}"; do
    # Match exact line (anchored), tolerating leading/trailing whitespace
    if ! grep -qE "^[[:space:]]*${entry}[[:space:]]*$" "$gitignore" 2>/dev/null; then
      # Add a marker comment block on first addition only
      if [ "$added" -eq 0 ]; then
        # Ensure file ends with newline before appending
        if [ -s "$gitignore" ] && [ "$(tail -c 1 "$gitignore" | wc -l)" -eq 0 ]; then
          echo "" >> "$gitignore"
        fi
        echo "" >> "$gitignore"
        echo "# intellisense: code-review-graph runtime artifacts (committed: .intellisense/MANAGED, .intellisense/graph-exception.json)" >> "$gitignore"
      fi
      echo "$entry" >> "$gitignore"
      added=1
    fi
  done

  return 0
}

# intellisense_graph_write_managed_marker <repo> — write .intellisense/MANAGED file with content "INTELLISENSE-MANAGED".
# Used when --skip-claude-md was set during onboarding (CLAUDE.md is not modified).
# Idempotent.
intellisense_graph_write_managed_marker() {
  local repo="${1:?repo required}"
  local marker
  marker="$(intellisense_graph_managed_path "$repo")"
  mkdir -p "$(dirname "$marker")"
  if [ ! -f "$marker" ]; then
    echo "INTELLISENSE-MANAGED" > "$marker"
  fi
}

# intellisense_graph_ensure_managed_in_claude_md <repo> — add the <!-- INTELLISENSE-MANAGED --> marker
# line to repo's CLAUDE.md if not already present. Idempotent. Caller is responsible for
# CLAUDE.md existing.
intellisense_graph_ensure_managed_in_claude_md() {
  local repo="${1:?repo required}"
  local claude_md
  claude_md="$(intellisense_graph_claude_md_path "$repo")"

  if [ ! -f "$claude_md" ]; then
    echo "intellisense_graph_ensure_managed_in_claude_md: $claude_md not found" >&2
    return 1
  fi

  if grep -qF '<!-- INTELLISENSE-MANAGED -->' "$claude_md" 2>/dev/null; then
    return 0
  fi

  # Insert marker after the first H1 line, or at the top if no H1
  if grep -qE '^# ' "$claude_md" 2>/dev/null; then
    # Use awk to insert one blank line + marker right after the first H1
    local tmp
    tmp="$(mktemp "${claude_md}.XXXX")"
    awk '
      !inserted && /^# / {
        print
        print ""
        print "<!-- INTELLISENSE-MANAGED -->"
        inserted=1
        next
      }
      { print }
    ' "$claude_md" > "$tmp" && mv "$tmp" "$claude_md"
  else
    # No H1; prepend marker
    local tmp
    tmp="$(mktemp "${claude_md}.XXXX")"
    {
      echo "<!-- INTELLISENSE-MANAGED -->"
      echo ""
      cat "$claude_md"
    } > "$tmp" && mv "$tmp" "$claude_md"
  fi
}

# intellisense_graph_write_status — write .intellisense/graph-status.json with the given JSON content.
# Args: --repo <path> --content <json-string>
# Caller composes the JSON; this function just writes it.
intellisense_graph_write_status() {
  local repo="" content=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)    repo="$2";    shift 2 ;;
      --content) content="$2"; shift 2 ;;
      *)
        echo "intellisense_graph_write_status: unknown arg: $1" >&2
        return 2
        ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$content" ] || {
    echo "intellisense_graph_write_status: --repo and --content required" >&2
    return 2
  }

  local status
  status="$(intellisense_graph_status_path "$repo")"
  mkdir -p "$(dirname "$status")"

  # Atomic write
  local tmp
  tmp="$(mktemp "${status}.XXXX")"
  printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$status"
}

# ============================================================================
# Helpers for status JSON composition
# ============================================================================

# intellisense_graph_iso8601_utc — print current UTC time in ISO 8601 (YYYY-MM-DDTHH:MM:SSZ).
# Authoritative source for built_at_utc .
intellisense_graph_iso8601_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# intellisense_graph_extract_nodes — extract `nodes` count from `code-review-graph status` output.
# Defensive parsing: tries JSON first (if upstream supports `--json`), else greps text.
# Args: <repo>
# Output: integer node count, or empty if not parseable.
intellisense_graph_extract_nodes() {
  local repo="${1:?repo required}"
  if ! command -v code-review-graph >/dev/null 2>&1; then
    return 1
  fi

  # Run status from within the repo so it picks up the right .code-review-graph
  local out
  out="$(cd "$repo" && code-review-graph status 2>&1)" || return 1

  # Try JSON-y parse first (some versions emit "nodes": N)
  local n
  n="$(echo "$out" | grep -oE '"nodes"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')"
  if [ -n "$n" ]; then
    echo "$n"
    return 0
  fi

  # Try text parse: lines like "nodes: 24881" or "Nodes: 24881" or "24881 nodes"
  n="$(echo "$out" | grep -iE '(nodes[[:space:]]*[:=]|^[[:space:]]*[0-9]+[[:space:]]+nodes)' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$n" ]; then
    echo "$n"
    return 0
  fi

  return 1
}

# intellisense_graph_extract_upstream_last_updated — pull last_updated from upstream status.
# Diagnostic only; intellisense's freshness logic uses built_at_utc, not this.
# Output: raw string from upstream (may be empty).
intellisense_graph_extract_upstream_last_updated() {
  local repo="${1:?repo required}"
  if ! command -v code-review-graph >/dev/null 2>&1; then
    return 1
  fi
  local out
  out="$(cd "$repo" && code-review-graph status 2>&1)" || return 1
  echo "$out" | grep -oE '"last_updated"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"last_updated"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}
