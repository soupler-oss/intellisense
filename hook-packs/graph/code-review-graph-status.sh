#!/bin/bash
# hook-packs/graph/code-review-graph-status.sh
# Check code-review-graph MCP status (informational)
#
# Install with:
#   cp hook-packs/graph/code-review-graph-status.sh .claude/hooks/pre-commit-graph-status.sh
#   chmod +x .claude/hooks/pre-commit-graph-status.sh

set -euo pipefail

# Only run if .mcp.json exists and mentions code-review-graph
[[ ! -f ".mcp.json" ]] && exit 0
grep -q "code-review-graph" .mcp.json 2>/dev/null || exit 0

echo "ℹ️  code-review-graph MCP is configured"
echo "Use MCP tools for semantic exploration:"
echo "  - semantic_search_nodes for concept lookup"
echo "  - query_graph pattern=callers_of for relationships"
echo "  - get_impact_radius before touching shared files"
