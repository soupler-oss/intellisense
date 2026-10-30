---
name: contract
description: Use before editing a Tier 1+ change in Live mode, to write the machine-checked change contract that unlocks edits and satisfies the push gate.
---

# /contract — Layer 1 Change Contract Artifact

## Purpose
Produce a machine-validatable Change Contract for the current task. Writes
`.intellisense/contracts/<safe-branch>.md` — one Markdown file, committed with the change, whose YAML front
matter holds the fields. The same file is checked three times: the PreToolUse gate (edit time) and the pre-push
hook validate it against schema + Gate Rules R1–R7 + scope drift, and the intellisense gate (push and CI)
accepts it as the change's contract evidence (its `scope` and `risk` fields, per `.intellisense.yml`). R6 enforces the contract's
lifecycle state; R7 enforces task binding so a contract approved for one
task cannot silently permit edits for a different task on the same branch.

## Current state (post 1.2.0; pilot foundation, not final architecture)

- **Layer 1 (SHIPPED)**: the contract file + pre-push validates it against schema + Gate Rules R1–R5 + scope drift.
  - At **edit time** (Layer 2 PreToolUse gate): the contract is REQUIRED when `intellisense.gate_mode = enforced` for Tier 1+ work. In `pilot` (default) it is RECOMMENDED — missing or invalid contract produces a `[pilot]` stderr warning and the edit proceeds.
  - At **push time**: the intellisense gate needs a change contract for Tier 1+ — this file, or a `Change Contract:` commit line — and a task trailer on every Tier 1+ commit. When the file is present, pre-push also validates its Live fields and policy violations BLOCK the push.
- **Layer 2 (SHIPPED)**: PreToolUse hook on `Edit|Write|MultiEdit|NotebookEdit|Bash`. Two-mode rollout:
  - `intellisense.gate_mode=pilot` (default): warns and allows. No blocking. Generates audit data in `~/.claude-intellisense/classifier-decisions.jsonl`.
  - `intellisense.gate_mode=enforced`: blocks Tier 1+ edits without valid contract + file-in-scope validation.
- **Turning on `enforced` for a team** is a setting (`intellisense.gate_mode` in `~/.claude/settings.json`). Run `pilot` first and read the audit data (false positives, skipped edits) before switching; the push and CI gates enforce the evidence in either mode.

## Visibility Rule (Non-Negotiable)
- The contract file is committed, so reviewers see it in the pull request — it IS the visible contract.
- It **never** replaces the task trailer (`Task:` / `Refs:` / `Beads:` …, per `.intellisense.yml`): every Tier 1+
  commit still carries its own.
- Tier 2 still gets second-party approval at merge (branch protection).

## When to Use
- BEFORE any Edit/Write on Tier 1+ work (rules, skills, agents, hooks, infrastructure, financial, security, migrations)
- Optional but encouraged for Tier 0 work — generates baseline data
- After scope changes (re-run to update files_affected, rerun gate validation)

## Workflow

### 1. Detect mode (per development-workflow.md §0.5)
Output the standard block:
```
Detected mode: [MODE]
Signals: [2-3 specific signals from requirement]
Scope: [phases that run]
```

### 2. Gather evidence (do not skip)
- `git remote -v` — confirm fork (origin) + upstream
- the team's tracker — find or open the task this change belongs to (avoid duplicates)
- `rg` / `Read` for affected files; with the code graph chosen and `/code-review`
  involved, follow graph-policy.md §"When the graph applies"
- Identify high_risk_files_touched (per knowledge-base/risk-register.md when present)
- Identify protected_files_touched (migrations, .env, vendor/, config files,
  native dotfiles outside .intellisense/)

### 3. Produce the contract
The fields are defined by `skills/contract/schema.json` (JSON Schema draft-07); they go in the file's YAML front
matter. `scope` and `risk` are the names the intellisense gate checks (it fills `requirement` and `risk_level`
from them when those are absent), so write both sets or just `scope`/`risk`.
The validator at `scripts/validate-contract-schema.sh` reads its required-fields
list from `required[]` in that schema — single source of truth.

Required fields (16 — validator enforces presence):
`branch`, `mode`, `requirement`, `files_affected`, `estimated_lines`,
`confidence_score`, `risk_level`, `financial_impact`, `high_risk_files_touched`,
`protected_files_touched`, `rollback_strategy`, `test_strategy`,
`session_id`, `prompt_hash`, `classification_id`, `state`.

Conditional: `approval_received_at` (ISO timestamp; required only if
`protected_files_touched` is non-empty, per Gate Rule R2).

Documentation-only (recommended for human review, not validator-enforced):
`evidence_used`, `knowledge_base_files_read`, `repo_patterns_checked`,
`why_scope_is_limited`, `impact_analysis`, `impact_analysis_dismissed_suggestions`.

**Impact Discovery — `impact_analysis`:** For Tier 1/2 work, copy
the Impact Discovery block produced by `/plan` into `impact_analysis`. The
validator emits a warn-only stderr message (never blocks) for modes that ship
code (`full_feature`, `bug_fix`, `refactor`, `hotfix`, `fix_pr_comments`) when
this field is empty. Clear the warning cleanly with `n/a — <reason>` (e.g.
`n/a — graph unavailable`, `n/a — weak stack`). Place per-suggestion dismissal
or verified_unchanged reasons in `impact_analysis_dismissed_suggestions`, one
line per suggestion: `<file>: <reason>`.

**Task binding (required for new contracts):**
`session_id`, `prompt_hash`, `classification_id` together pin the contract to
a specific TASK, not just a branch. The classifier writes the same fields to
`.intellisense/session/<session_id>.classification.json` at prompt time; copy them
into the contract verbatim. Without binding, an old contract from yesterday's
work on the same branch would silently validate today's unrelated edits.

Read the live values from the classifier output:
```bash
CLF="$REPO_ROOT/.intellisense/session/<session_id>.classification.json"
PROMPT_HASH=$(jq -r '.prompt_hash' "$CLF")
CLASSIFICATION_ID=$(jq -r '.classification_id' "$CLF")
SESSION_ID="<session_id>"   # the Claude Code session_id, same as the filename stem
```

**State lifecycle (required for new contracts):**
The `state` field tracks human approval, separately from file presence on disk.

| state | meaning | gate allows edits? |
|---|---|---|
| `draft` | /contract just produced the file; user has not yet seen it | NO (R6 fires) |
| `presented` | shown to user; user has not yet said "proceed" | NO (R6 fires) |
| `approved` | user explicitly said "proceed"; first valid edit is now permitted | YES |
| `active` | at least one edit has succeeded under this contract | YES (auto-transitioned by PreToolUse gate from `approved` on first edit) |

Write `state: "draft"` initially. After step 4 (explicit user "proceed"),
update the file in place with `state: "approved"`. Do NOT skip step 4 to
write `state: "approved"` directly — that defeats the lifecycle gate.

Example file (`.intellisense/contracts/feature__refunds.md`):
```markdown
---
scope: One sentence — what the user asked for
risk: low
branch: feature/refunds            # output of: git symbolic-ref --short HEAD
mode: full_feature
files_affected: [path/one, path/two]
estimated_lines: 120
confidence_score: 0.85
financial_impact: false
high_risk_files_touched: []
protected_files_touched: []
approval_received_at: ""
rollback_strategy: Exact steps to undo
test_strategy: What tests + why they verify
session_id: <Claude Code session_id>
prompt_hash: <copied from classification.json>
classification_id: <copied from classification.json>
state: draft
evidence_used: [grep/rg results, git log findings]
knowledge_base_files_read: [docs/X.md]
repo_patterns_checked: [pattern A, pattern B]
why_scope_is_limited: One sentence justification
impact_analysis: "Stack: go. Changed: Debit() in account/debit.go:42. Callers: handlers/payment-handler.go. Downstream: none."
impact_analysis_dismissed_suggestions: n/a — no dismissals this contract
---
# Change Contract: refunds

## What changes
## Risk and rollback
## How it is verified
```

**Gate rule reminders the validator will enforce:**
- R1: `high_risk_files_touched` non-empty → `risk_level` ∈ {medium, high}
- R2: `protected_files_touched` non-empty → `approval_received_at` must be ISO timestamp
- R3: `confidence_score` ≥ 0.75
- R4: `mode = bug_fix` → `len(files_affected)` ≤ 3
- R5: `financial_impact = true` → `mode = full_feature`
- R6 (lifecycle): `state` must be `approved` or `active` for edits to be permitted
- R7 (task binding): when invoked with `--current-classification-id`, contract.classification_id must match — mismatch indicates wrong-task reuse

Schema-only requirements (also enforced):
- `branch` field must equal `git symbolic-ref --short HEAD` at validation time
- All listed required fields must be present and well-typed

### 4. Wait for explicit "proceed"
Do NOT advance `state` past `draft` before the user replies "proceed" (or
equivalent). Inferring approval from context summaries is forbidden by
`development-workflow.md`.

Recommended sequence:
1. Write the file with `state: "draft"`. The PreToolUse gate's R6 will block
   any edit (in enforced) or warn (in pilot) — this is the desired signal
   that no real work has been approved yet.
2. Show the contract content to the user (state = "presented" if you want
   to capture the in-between step, or skip directly to step 3).
3. After the user says "proceed", the **UserPromptSubmit classifier
   detects approval prompts** ("proceed", "yes", "ok", "go ahead",
   "implement", "lgtm", ...) and auto-advances the contract from
   `draft|presented` → `approved`. You do not have to write `state:
   "approved"` by hand in that case. Approval prompts also **preserve the
   active task identity** — the classifier does NOT mint a new
   `classification_id`, so R7 (task binding) keeps holding for the work
   the user just approved. Full list: see `scripts/classifier-rules.json`
   under `approval_prompts`.

The gate auto-transitions `approved` → `active` on the first successful
Edit/Write. You do not need to flip `active` yourself.

#### Why approval prompts must preserve task identity

Without this rule the flow would be: classify account task (id A), write an
approved contract bound to A, user types "proceed" → classifier sees a new
prompt hash → writes a fresh classification_id B over A → R7 mismatch →
the gate blocks the very edit the user just approved.

The fix keeps `classification_id` stable across approval prompts while
recording the event in separate fields (`last_prompt_hash`,
`last_prompt_event = "approval"`, `last_prompt_ts`). The contract gate
binds to the stable identity; auditors can still see the approval event
in classification.json.

### 5. On approval — write the file
Filename encoding: replace `/` with `__` in branch name.
- `feature/foo` → `.intellisense/contracts/feature__foo.md`
- `master` → `.intellisense/contracts/master.md`

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
BRANCH="$(git symbolic-ref --short HEAD)"
SAFE="${BRANCH//\//__}"
mkdir -p "$REPO_ROOT/.intellisense/contracts"
# write the file with the Write tool to:
#   $REPO_ROOT/.intellisense/contracts/$SAFE.md
# change a field later without rewriting it:
#   intellisense contract set "$REPO_ROOT/.intellisense/contracts/$SAFE.md" state=approved
```
Writing under `.intellisense/contracts/` never needs a contract itself (the gate allowlists it).

### 6. Commit it with the change
The contract is part of the change: `git add .intellisense/contracts/$SAFE.md` in the same commit (or the first
commit of the branch). Reviewers read it in the pull request; the gate finds it there.

### 7. Show the user the trailer they STILL need
The contract file covers the change; each Tier 1+ commit still names its task. Output the copy-paste line,
using a key from `evidence.task_trailers` in `.intellisense.yml` (`intellisense policy get task_trailers`):

```
Task: <task id>
```

### 8. Self-validate immediately
Before declaring step 5 done, run:
```bash
bash ~/.intellisense/platform/current/scripts/validate-contract-schema.sh \
    "$REPO_ROOT/.intellisense/contracts/$SAFE.md"      # Live fields, R1–R7
intellisense contract check "$REPO_ROOT/.intellisense/contracts/$SAFE.md"   # the gate's fields
```
Both exit 0 = ready. Otherwise fix the contract before continuing.

## Failure Modes (Layer 1)

| Symptom | Cause | Fix |
|---|---|---|
| validator exit 1 "missing required field" | typo or omission in the front matter | re-run `/contract` with full schema |
| validator exit 1 "stale contract" | reused branch name with stale state | delete the file, re-run `/contract` |
| validator exit 2 "R1–R5" | policy violation | revise risk/mode/scope; do not bypass |
| validator exit 2 "R6: contract state=..." | lifecycle: contract is `draft` or `presented` | ask user to approve, then write `state: "approved"` |
| validator exit 2 "R7: contract.classification_id does not match" | contract was approved for a different task than the current prompt | re-run `/contract` to rebind to the current task |
| validator exit 2 "scope drift" at push | edited a file not in `files_affected[]` | re-run `/contract` to declare the new file before pushing |
| validator exit 3 at push | jq or the engine missing, or front matter that is not YAML | install them / fix the front matter; pre-push falls through to the gate |
| gate blocks "has no task trailer" | a Tier 1+ commit lacks its own task trailer | `git commit --amend` (or `git rebase -i`) to add `Task: <id>` |
| gate blocks "invalid-contract" | `scope` or `risk` missing or out of range | `intellisense contract check FILE` shows the field |

## Division of responsibility

What `/contract` itself does:
- Produces the contract at `.intellisense/contracts/<safe-branch>.md` (committed with the change).
- Documents scope, risk, rollback, test strategy for the current task.

What the Layer 2 PreToolUse gate does (uses the artifact `/contract` produces):
- Reads the contract at Edit/Write/Bash time.
- In `gate_mode=enforced`: blocks edits when contract is missing, invalid,
  or the affected file is not in `files_affected[]`.
- In `gate_mode=pilot` (default): emits `[pilot]` stderr warning and allows.
- Implemented in `scripts/preToolUse-contract-gate.sh`.

What `/contract` does NOT do:
- Does NOT auto-add commit trailers — developer / Claude adds the task trailer to each commit.
- Does NOT classify Tier — the Phase 2 UserPromptSubmit classifier
  (`scripts/userPromptSubmit-classifier.sh`) writes the tier+mode to
  `.intellisense/session/<session_id>.classification.json`.
- Does NOT create or update tracker issues — that stays with the team's tracker.
