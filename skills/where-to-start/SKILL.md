---
name: where-to-start
description: Use at the start of a task, to find which repository owns a symptom or requirement, ranked with reasons.
---

# /where-to-start — Find the Right Repo

Takes a symptom or requirement and returns ranked repo list with reasoning.

**When**: Starting new task (entry point), wrong-repo situation, or diagnostic ambiguity
**Input**: Symptom or requirement ("account balance showing wrong amount", "add reconciliation feature")
**Output**: Ranked repo list with confidence scores

## Process

1. **Read service-map.md** — your organization's services and relationships. If its tables are empty (the shipped template), say so, ask the user which repository owns the change, and suggest filling `infrastructure/service-map.md` — never guess a repo
2. **Parse input for keywords** — Match against service-map.md keyword columns
3. **Search CLAUDE.md Domain Terms** — keyword-to-service mapping
4. **Match to service stack** — Go? PHP? Angular?
5. **Score by relevance** — 100%=primary, 75%=secondary, 50%=tertiary
6. **Return ranked list** — Top 3 with reasoning

## Output (REQUIRED FORMAT)

```
## Requirement Analysis
Input: "[user requirement text]"

## Ranked Repos

### 1. [service-a] — PRIMARY (95% confidence)
**Why**: Owns `[table-name]` table; primary data source
**What**: `~/projects/[service-a]` | [Stack] | [Language]
**Evidence**:
- Service-map lists [service-a] as "[ownership description]"
- CLAUDE.md Domain Terms: "[keyword]" maps to [service-a]
- Only service directly mutating [table-name]
**Action**: Start here. Check [table-name], concurrent locks, soft-delete markers.
**Next if needed**: If [service-a] data is correct, escalate to [service-b].

### 2. [service-b] — SECONDARY (75% confidence)
**Why**: Reads from [service-a]; downstream logic may cause inconsistency
**What**: `~/projects/[service-b]` | [Stack]
**Evidence**:
- Service-map lists [service-b] as "downstream consumer of [service-a]"
**Action**: Check only if [service-a] data is correct but [service-b] calculations are wrong.

### 3. [service-c] — TERTIARY (40% confidence)
**Why**: May cache stale data; API response layer
**What**: `~/projects/[service-c]` | [Stack]
**Evidence**:
- Service-map lists as downstream of [service-b]
**Action**: Check only if both [service-a] and [service-b] are correct but API returns wrong value.

## Decision
**Correct repo**: [service-a] (start here)
**Why not [service-b]**: [reasoning]
**Why not [service-c]**: [reasoning]

## Next Steps
1. `cd ~/projects/[service-a]` // dynamic repo path
2. Run `/plan` or `/diagnose` to analyze issue
3. If uncertain: run `/cross-service-diagnose` to trace full call chain
```

## Quick Reference (Keywords → Repos)

Read `infrastructure/service-map.md` for your organization's keyword-to-service mapping.

The service-map.md `Domain Terms` column maps symptoms to owner services. Example structure:
| Symptom | Primary Repo | Reasoning |
|---------|-------------|-----------|
| [your symptom] | [your-service] | Owns [table-name] |

Populate service-map.md during org setup — /where-to-start reads it dynamically.

## Constraints
1. Never return just one repo — always give top 3 ranked options
2. Confidence scores are estimates, not facts — reasoning matters more
3. Keyword matching is case-insensitive and substring-based
4. Service-map.md is the source of truth for relationships
5. If keyword not found: search CLAUDE.md Domain Terms in each repo
6. If top 2 repos score within 10 confidence points, mark as AMBIGUOUS: Output both with "disambiguation required" flag. Example: keyword "[term-name]" scores [service-a] (85%) and [service-b] (80%) — open both CLAUDE.md Domain Terms sections before routing. Ask clarifying question: "Does '[term-name]' refer to [definition-1] or [definition-2]?"
