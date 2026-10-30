#!/bin/bash
# intellisense-ticket-eval.sh
# Setup structure for comparing native vs intellisense performance on tickets
# Usage: ./scripts/intellisense-ticket-eval.sh [ticket-name]

set -euo pipefail

TICKET_NAME="${1:-test-ticket-$(date +%Y%m%d-%H%M%S)}"
EVAL_DIR="intellisense-ticket-eval"

echo "Setting up ticket evaluation structure for: $TICKET_NAME"

# Create directory structure
mkdir -p "$EVAL_DIR"/{runs,metrics,prompts,reports}

# Create runs.csv
cat > "$EVAL_DIR/runs.csv" << 'EOF'
run_id,ticket_name,approach,timestamp,duration_seconds,prompt_count,tool_calls,files_read,files_modified,files_created,tests_added,tests_passed,manual_corrections,context_misses,wrong_pattern_events,gate_violations,estimated_tokens,cost_usd,native_vs_intellisense_verdict
EOF

# Create metrics.csv
cat > "$EVAL_DIR/metrics.csv" << 'EOF'
metric_name,native_value,intellisense_value,improvement
mode_detection,n/a,seconds,faster if <30s
design_review_completeness,n/a,percent,higher is better
exploration_accuracy,n/a,percent,higher is better
scope_creep,n/a,file_count,lower is better
rework_cycles,n/a,count,lower is better
final_code_quality,n/a,score_0_to_100,higher is better
token_efficiency,n/a,tokens_per_file,lower is better
test_coverage,n/a,percent,higher is better
time_to_first_commit,n/a,seconds,lower is better
total_session_time,n/a,seconds,lower is better
EOF

# Create prompt templates
cat > "$EVAL_DIR/prompts/native.md" << 'EOF'
# Native Approach Prompt

For the reference catalog-service repo, use this prompt:

```
Requirement: [TICKET DESCRIPTION]

You have access to catalog-service (Laravel, multi-tenancy, Redis, MySQL).
Use the repo's native setup: CLAUDE.md, .claude/agents/, .claude/skills/, KNOWLEDGE_BASE.md, specs/dev-protocol.md.

Implement this as the repo's conventions dictate.
```

**Track**:
- Mode declaration time
- Design review gate output
- Change contract generation
- Files explored (MCP vs grep)
- Scope drift
- Test runs
- Final confidence score

EOF

# Create intellisense prompt template
cat > "$EVAL_DIR/prompts/intellisense.md" << 'EOF'
# intellisense Approach Prompt

For the same repo (or a copy), use intellisense rules instead:

```
Requirement: [TICKET DESCRIPTION]

You have intellisense rules (rules/baseline/, rules/operational/, rules/language-specific/).
You have intellisense templates and agents.
You have knowledge-base/ initialized from intellisense.

Implement this using intellisense governance and protocols.
```

**Track**:
- Mode declaration time
- Governance validation output
- Change contract generation
- Files explored (intellisense detection vs manual)
- Scope drift
- Test runs
- Final confidence score

EOF

# Create report template
cat > "$EVAL_DIR/reports/summary.md" << 'EOF'
# Ticket Evaluation Summary

## Ticket
- **ID**: [TICKET_ID]
- **Title**: [TICKET_TITLE]
- **Description**: [TICKET_DESC]
- **Complexity**: [Low/Medium/High]

## Native Approach Results

### Setup Phase
- Mode declared in: [TIME]s
- Design review completed: [Y/N]
- Design review findings: [SUMMARY]
- Change contract generated: [Y/N]
- Time to approval: [TIME]s

### Implementation Phase
- Files explored: [COUNT]
- Files modified: [COUNT]
- Files created: [COUNT]
- Scope creep: [NONE/MINOR/MAJOR]
- Exploration tool usage: [MCP usage %, grep %, read %]

### Verification Phase
- Tests added: [COUNT]
- Test runs: [COUNT]
- Manual corrections: [COUNT]
- Test pass rate: [PERCENT]

### Outcomes
- Session duration: [TIME]s
- Total token usage: [TOKENS]
- Estimated cost: $[COST]
- Code quality score: [0-100]
- Confidence score: [0.0-1.0]
- PR label applied: [LABEL]

## intellisense Approach Results

[Same structure as native]

## Comparative Analysis

### Efficiency Gains
- Mode detection: [native] vs [intellisense] (+[PERCENT]% intellisense)
- Exploration efficiency: [native] vs [intellisense]
- Scope discipline: [native] vs [intellisense]
- Rework cycles: [native] vs [intellisense]

### Quality Metrics
- Test coverage: [native] vs [intellisense]
- Code quality: [native] vs [intellisense]
- Confidence score: [native] vs [intellisense]
- Security gate violations: [native] vs [intellisense]

### Token Efficiency
- Total tokens: [native] vs [intellisense] (intellisense: [PERCENT]% savings)
- Tokens per file: [native] vs [intellisense]
- Cost: [native] vs [intellisense] (intellisense: $[SAVINGS] savings)

### User Experience
- Sessions felt guided: [Y/N] both
- Protocol clarity: [native] vs [intellisense]
- Error prevention: [native] vs [intellisense]

## Verdict

**Winner**: [NATIVE / intellisense / TIE]

**Why**: [EXPLANATION]

**Key insight**: [ONE KEY FINDING]

## Recommendations

1. [Action item]
2. [Action item]
3. [Action item]

EOF

echo "✓ Evaluation structure created in $EVAL_DIR/"
echo ""
echo "Next steps:"
echo "  1. Create a copy/branch of the test repo"
echo "  2. Run with native approach:"
echo "     cd [repo]; cat $EVAL_DIR/prompts/native.md"
echo "  3. Track metrics in $EVAL_DIR/runs.csv"
echo "  4. Run with intellisense approach:"
echo "     cd [repo]; cat $EVAL_DIR/prompts/intellisense.md"
echo "  5. Compare results in $EVAL_DIR/reports/summary.md"
echo ""
echo "Evaluation template ready at: $EVAL_DIR/reports/summary.md"
