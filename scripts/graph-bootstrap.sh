#!/bin/bash
# graph-bootstrap.sh — canonical "build-or-refresh-the-graph" script.
#
# Non-interactive by design. The skill / assistant flow asks for user consent;
# this script just runs when called. It does not prompt.
#
# Five intended callers (all pass --yes to make consent explicit):
#   1. setup-repos.sh (per-repo build during onboarding / --migrate / --repair)
#   2. bash scripts/graph-bootstrap.sh ... (manual, on demand)
#   3. /code-review skill (after the assistant obtains user consent)
#   (the pre-push hook and CI only read graph-status.json; they never build)
#
# Readiness criteria:
#   1. code-review-graph build exit code 0
#   2. nodes >= minimal_stack_threshold (mandatory & candidate stacks; advisory for weak)
#   3. built_at_utc fresh (within 10 minutes of build completion)
#
# Exit codes:
#   0   success — graph ready (or built best-effort for weak stacks)
#   1   prerequisite failed (no binary, wrong version, repo not intellisense-managed, etc.)
#   2   bad arguments
#   3   build or readiness failed for a mandatory-supported stack

set -o pipefail

# ============================================================================
# Locate library
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/intellisense-graph.sh
source "$SCRIPT_DIR/lib/intellisense-graph.sh"
# shellcheck source=lib/intellisense-paths.sh
source "$SCRIPT_DIR/lib/intellisense-paths.sh"

# Defense-in-depth: when invoked directly (not via setup.sh / setup-repos.sh),
# the inherited PATH may not include ~/.local/bin where pipx / pip --user / uv
# tool install code-review-graph. Normalize before the binary check below.
_ensure_local_bin_on_path

# ============================================================================
# Argument parsing
# ============================================================================

REPO=""
STACK=""
YES=false
MIN_NODES_OVERRIDE=""
SKIP_FLOWS=false

print_usage() {
  cat <<EOF
Usage: $0 --repo <path> --stack <stack> [--yes] [--min-nodes <N>] [--skip-flows]

Required:
  --repo <path>    Absolute path to the target intellisense-managed repo.
  --stack <stack>  Stack key: go, python, typescript, javascript, node, nestjs,
                   react, java, csharp, kotlin, rust, php, laravel, angular, vue.

Optional:
  --yes            Acknowledge consent flag (script is non-interactive anyway;
                   present for explicit caller intent).
  --min-nodes <N>  Per-repo readiness threshold override. Recorded in
                   .intellisense/graph-status.json; triggers advisory marker if below
                   the stack default.
  --skip-flows     Pass --skip-flows to upstream code-review-graph build (faster
                   incremental builds; used in PostToolUse hooks).

Exit codes:
  0  success   1  prereq failed   2  bad args   3  build/readiness failed
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="$2";               shift 2 ;;
    --stack)       STACK="$2";              shift 2 ;;
    --yes)         YES=true;                shift ;;
    --min-nodes)   MIN_NODES_OVERRIDE="$2"; shift 2 ;;
    --skip-flows)  SKIP_FLOWS=true;         shift ;;
    -h|--help)     print_usage; exit 0 ;;
    *)
      echo "graph-bootstrap.sh: unknown arg: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$STACK" ]; then
  echo "graph-bootstrap.sh: --repo and --stack are required" >&2
  print_usage >&2
  exit 2
fi

if [ ! -d "$REPO" ]; then
  echo "graph-bootstrap.sh: --repo $REPO is not a directory" >&2
  exit 2
fi

# Resolve to absolute path
REPO="$(cd "$REPO" && pwd)"

# ============================================================================
# Step 1: install detection (independent of setup.sh shell state)
# ============================================================================

REQUIRED_VERSION="$(intellisense_graph_required_version)"
ACTUAL_VERSION="$(intellisense_graph_detect_version || echo "")"

if [ -z "$ACTUAL_VERSION" ]; then
  cat >&2 <<EOF
✗ code-review-graph not found on PATH.
  graph-bootstrap.sh requires code-review-graph==$REQUIRED_VERSION installed globally.

  Remediation:
    bash setup.sh

  This will try uvx → pipx → pip --user install paths.
EOF
  exit 1
fi

if [ "$ACTUAL_VERSION" != "$REQUIRED_VERSION" ]; then
  cat >&2 <<EOF
✗ code-review-graph version mismatch.
  Installed: $ACTUAL_VERSION
  Required:  $REQUIRED_VERSION (pinned)

  Remediation:
    bash setup.sh    # reinstalls/upgrades to required version

  Note: floor bumps are intentional. If $ACTUAL_VERSION is genuinely the new
  intended floor, the intellisense Platform Owner must update the pin in
  scripts/lib/intellisense-graph.sh + setup.sh + intelligence-sources.md together.
EOF
  exit 1
fi

# ============================================================================
# Step 2: intellisense-managed check
# ============================================================================

if ! intellisense_is_managed "$REPO"; then
  cat >&2 <<EOF
✗ Repo is not intellisense-managed: $REPO
  graph-bootstrap.sh refuses to build a graph for non-intellisense-managed repos.

  Remediation (if this repo SHOULD be intellisense-managed):
    bash setup-repos.sh --repo "$REPO" --stack $STACK --migrate

  This will write the <!-- INTELLISENSE-MANAGED --> marker, set up the intellisense layout,
  and call this script to build the graph.
EOF
  exit 1
fi

# ============================================================================
# Step 3: defensive .gitignore writes (must precede any code path that
# emits .intellisense/graph-status.json so the runtime artifact is never tracked,
# including the unsupported-stack-with-exception skip path below).
# ============================================================================

intellisense_graph_ensure_gitignore "$REPO"

# ============================================================================
# Step 4: stack classification + exception path
# ============================================================================

STACK_SUPPORT="$(intellisense_graph_stack_support "$STACK")"
STACK_MIN_NODES="$(intellisense_graph_min_nodes "$STACK")"

# Unsupported stacks: must have explicit exception, otherwise refuse
if [ "$STACK_SUPPORT" = "unsupported" ]; then
  if ! intellisense_graph_has_exception "$REPO"; then
    cat >&2 <<EOF
✗ Stack '$STACK' is classified 'unsupported' and the repo has no
  .intellisense/graph-exception.json.

  graph-bootstrap.sh will not build a graph for an unsupported stack
  without an explicit opt-out.

  Remediation:
    bash setup-repos.sh --repo "$REPO" --stack $STACK --migrate \\
        --graph-exception unsupported-stack \\
        --owner <your-email> --expires <YYYY-MM-DD>

  This writes .intellisense/graph-exception.json (committed) and skips graph build.
  See @rules/operational/graph-supported-stacks.md for classification.
EOF
    exit 1
  fi

  # Exception present → don't build; just emit a status indicating skipped
  echo "ℹ Repo opted out of graph use via .intellisense/graph-exception.json. Skipping build."
  STATUS_JSON=$(cat <<JSON
{
  "stack": "$STACK",
  "stack_support": "$STACK_SUPPORT",
  "nodes": 0,
  "built_at_utc": "$(intellisense_graph_iso8601_utc)",
  "upstream_last_updated": null,
  "build_exit_code": null,
  "readiness": "skipped",
  "build_time_ms": 0,
  "min_nodes_threshold": $STACK_MIN_NODES,
  "min_nodes_override": null,
  "advisory": "$(intellisense_graph_advisory_marker "$REPO" | sed 's/"/\\"/g')"
}
JSON
)
  intellisense_graph_write_status --repo "$REPO" --content "$STATUS_JSON"
  echo "✓ Wrote .intellisense/graph-status.json (readiness=skipped, advisory present)"
  exit 0
fi

# Determine effective threshold (override may lower it; never raise it)
EFFECTIVE_MIN_NODES="$STACK_MIN_NODES"
MIN_NODES_OVERRIDE_JSON="null"
if [ -n "$MIN_NODES_OVERRIDE" ]; then
  if ! [[ "$MIN_NODES_OVERRIDE" =~ ^[0-9]+$ ]]; then
    echo "graph-bootstrap.sh: --min-nodes must be a non-negative integer" >&2
    exit 2
  fi
  EFFECTIVE_MIN_NODES="$MIN_NODES_OVERRIDE"
  MIN_NODES_OVERRIDE_JSON="$MIN_NODES_OVERRIDE"
fi

# ============================================================================
# Step 5: build
# ============================================================================

echo "→ Building code-review-graph for $REPO (stack: $STACK, support: $STACK_SUPPORT)"
echo "  This may take 30-180s on first build; subsequent updates are fast."

# Portable millisecond timestamp.
# `date +%s%3N` is GNU-only — on macOS it returns "<seconds>N" literal.
# Use python3 (which the code-review-graph install already requires).
_now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}
BUILD_START_MS=$(_now_ms)

BUILD_FLAGS=""
[ "$SKIP_FLOWS" = true ] && BUILD_FLAGS="--skip-flows"

# Run build from inside the repo so .code-review-graph/ lands in the right place.
# Stream output so devs see progress.
BUILD_EXIT=0
( cd "$REPO" && code-review-graph build $BUILD_FLAGS ) || BUILD_EXIT=$?

BUILD_END_MS=$(_now_ms)
BUILD_TIME_MS=$((BUILD_END_MS - BUILD_START_MS))
# Defensive: if anything went sideways, fall back to 0 so JSON stays valid.
[[ "$BUILD_TIME_MS" =~ ^-?[0-9]+$ ]] || BUILD_TIME_MS=0

# ============================================================================
# Step 6: readiness check + status emission
# ============================================================================

BUILT_AT="$(intellisense_graph_iso8601_utc)"
NODES="$(intellisense_graph_extract_nodes "$REPO" 2>/dev/null || echo "")"
NODES="${NODES:-0}"
UPSTREAM_LAST_UPDATED="$(intellisense_graph_extract_upstream_last_updated "$REPO" 2>/dev/null || echo "")"

# Determine readiness per the criteria above
READINESS="failed"
READINESS_REASON=""

if [ "$BUILD_EXIT" -ne 0 ]; then
  READINESS_REASON="build exit code $BUILD_EXIT"
elif [ "$NODES" -lt "$EFFECTIVE_MIN_NODES" ] 2>/dev/null; then
  if [ "$STACK_SUPPORT" = "weak" ]; then
    # Weak stacks: readiness is advisory; don't fail
    READINESS="ready"
    READINESS_REASON="below threshold but stack is weak — advisory only"
  else
    READINESS_REASON="nodes=$NODES below threshold $EFFECTIVE_MIN_NODES for stack=$STACK ($STACK_SUPPORT)"
  fi
else
  READINESS="ready"
fi

# Write status
ADVISORY_RAW=""
# Build a transient status file first so intellisense_graph_advisory_marker can read stack/support fields
TRANSIENT_STATUS=$(cat <<JSON
{
  "stack": "$STACK",
  "stack_support": "$STACK_SUPPORT",
  "nodes": $NODES,
  "built_at_utc": "$BUILT_AT",
  "upstream_last_updated": $([ -n "$UPSTREAM_LAST_UPDATED" ] && echo "\"$UPSTREAM_LAST_UPDATED\"" || echo "null"),
  "build_exit_code": $BUILD_EXIT,
  "readiness": "$READINESS",
  "build_time_ms": $BUILD_TIME_MS,
  "min_nodes_threshold": $STACK_MIN_NODES,
  "min_nodes_override": $MIN_NODES_OVERRIDE_JSON,
  "advisory": null
}
JSON
)
intellisense_graph_write_status --repo "$REPO" --content "$TRANSIENT_STATUS"

# Now compute the advisory marker (function reads the just-written status)
ADVISORY_RAW="$(intellisense_graph_advisory_marker "$REPO")"
ADVISORY_JSON="null"
if [ -n "$ADVISORY_RAW" ]; then
  # Escape for JSON
  ADVISORY_JSON="\"$(printf '%s' "$ADVISORY_RAW" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
fi

# Final status with advisory populated
FINAL_STATUS=$(cat <<JSON
{
  "stack": "$STACK",
  "stack_support": "$STACK_SUPPORT",
  "nodes": $NODES,
  "built_at_utc": "$BUILT_AT",
  "upstream_last_updated": $([ -n "$UPSTREAM_LAST_UPDATED" ] && echo "\"$UPSTREAM_LAST_UPDATED\"" || echo "null"),
  "build_exit_code": $BUILD_EXIT,
  "readiness": "$READINESS",
  "build_time_ms": $BUILD_TIME_MS,
  "min_nodes_threshold": $STACK_MIN_NODES,
  "min_nodes_override": $MIN_NODES_OVERRIDE_JSON,
  "advisory": $ADVISORY_JSON
}
JSON
)
intellisense_graph_write_status --repo "$REPO" --content "$FINAL_STATUS"

# ============================================================================
# Step 7: report + Graph: artifact line
# ============================================================================

if [ "$READINESS" = "ready" ]; then
  echo "✓ Graph build succeeded: nodes=$NODES, time=${BUILD_TIME_MS}ms, stack=$STACK ($STACK_SUPPORT)"
  if [ -n "$ADVISORY_RAW" ]; then
    echo "  $ADVISORY_RAW"
  fi
  echo ""
  echo "  Graph: nodes=$NODES, last_updated=$BUILT_AT, readiness=$READINESS, stack=$STACK"
  echo ""
  exit 0
else
  cat >&2 <<EOF
✗ Graph readiness check FAILED: $READINESS_REASON

  .intellisense/graph-status.json written with readiness=failed for diagnostic purposes.

  Common remediations:
    - Build exit non-zero: review build output; consider 'rm -rf .code-review-graph/'
      and re-run 'bash setup-repos.sh --repo $REPO --stack $STACK --repair'.
    - nodes below threshold: parser may have failed on most files; verify the
      repo has substantial source code matching the stack.
    - Lower the threshold (small repo): re-run with --min-nodes <N>. The override
      will be recorded and the universal advisory marker will fire.
EOF
  exit 3
fi
