---
applies_to: [all]
phase: [0, 1]
priority: CRITICAL
enforcement: blocking
load_when: always
---

# Unified Development Workflow

Decision sheet for Phases 0–1 (always loaded). Phases 2–6: development-workflow-impl.md.
Fork workflow + commit format: git-workflow.md.

## Risk Tiers (canonical — single source of truth for tier → required artifacts)

| Tier | When | Required artifacts |
|------|------|--------------------|
| **Tier 0** | local low-risk: doc-only, dep bump (no advisory), cosmetic frontend, no-behavior refactor, test-only, non-service CI/build | none — no task trailer or Change Contract. Still obey destructive-action approval + mode/read-only gates. |
| **Tier 1** | cross-repo · infra · rules · skills · agents · templates | task trailer on each commit + one Change Contract |
| **Tier 2** | financial · security · auth · migration · PII | Tier 1 **plus** the user's explicit approval of the plan before editing (recorded in the contract's `state`) and PR review at merge |

The repository's `.intellisense.yml` is authoritative for which paths are which tier and what each tier needs; `intellisense classify` shows it.

**Escalate Tier 0 → 1+ if** the change touches API response shape, DB query/migration, auth/payment/security, sandbox/prod path divergence, or a cross-service contract. **If uncertain, Tier 1+.**

Tier (risk) is independent of mode (below). One coupling: a financial `bug_fix` escalates to `full_feature` (Gate Rule R5).

## Investigate Before Theorizing (all modes)

Find the **actual code path the failing case runs** — not the default one. Identify which branch its flags/config select, investigate *that*. For "only N of many worked" symptoms, check both a hidden default limit (pagination, SQL LIMIT, chunking) AND an alternate path selected by a feature flag / per-account setting.

## Approval Checkpoints: Destructive Actions

**Non-negotiable, every task/phase.** Before ANY destructive action (delete, reset, force-push, overwrite, drop table): present the analysis → state the action explicitly → ask "proceed? (yes/no)" → wait for an explicit user reply (do NOT infer approval from context summaries) → execute only after confirmation. Never skip, even if told "continue without asking".

## Phase 0.5: Auto Mode Detection

Read requirement → infer mode → confirm. No menu.

- **Context signals (first):** "production down"/"incident"/"P0" or /incident → `hotfix` · PR# + "fix"/"address" → `fix_pr_comments` · PR#, no fix → `pr_review` · test/coverage artifact → `qa`
- **Intent signals:** "broken"/"error"/"not working"/"crash" → `bug_fix` · "refactor"/"rename"/"split"/"clean up" → `refactor` · "build"/"add"/"implement"/"create" → `full_feature` · "understand"/"explain"/"design only" → `design_review_only`
- **Escalation:** `bug_fix` + financial signal (payment/account/balance/refund…; exhaustive list = `tier_2_keywords` in `scripts/classifier-rules.json`, do not copy here) → `full_feature` · `bug_fix` + >3 files → `full_feature`
- **Ambiguous:** ask ONE clarifying question; if still unclear → `design_review_only`. Do NOT default to `full_feature`.

**Output (mandatory):**
```
Detected mode: [MODE]
Signals: [2-3 specific signals]
Scope: [phases run / skipped]
```

**Confirmation:** coding modes — show block, proceed (user can correct). Ambiguous — pause, ask one question. Read-only modes (`pr_review`/`qa`/`design_review_only`) — show silently, proceed.

### Mode Definitions

| Mode | Phases Active | Scope Limit (files · total lines) |
|------|-------------|-------------|
| `full_feature` | 0→1→2→3→4→5→6 | ≤15 files · ≤800 lines |
| `bug_fix` | 0→1(minimal)→**2(regression)**→3→4→5→6 | ≤3 files · ≤800 lines |
| `refactor` | 0→1(minimal)→3→4→5→6 | ≤10 files · ≤800 lines |
| `hotfix` | 0→3→4→5→6 (expedited) | ≤2 files · ≤800 lines |
| `pr_review` | Read-only analysis | 0 files changed |
| `qa` | Read-only + tests | No source mods; git-ignored artifacts OK |
| `design_review_only` | 0→1 (questions only) | 0 files changed |
| `fix_pr_comments` | 3→4→5→6 (no re-plan) | Per comment scope |

**Phase 2 by mode:** `bug_fix` — write/run a failing regression test when feasible, else document the skip reason. `refactor` — Phase 2 SKIPPED, all existing tests stay green (a revealed failure is a bug, not a refactor). `hotfix` — Phase 2 SKIPPED, write the regression test in Phase 4 before commit.

**Mode Enforcement (mode-keyed and BLOCKING — do not borrow `full_feature`'s 15-file allowance):**
- `bug_fix`: 4th file touched → STOP, ask to escalate to `full_feature`
- `refactor`: 11th file → STOP, split into separate PRs
- `hotfix`: 3rd file → STOP, escalate + on-call approval before PR
- `design_review_only`: code change requested → STOP, read-only
- `pr_review`/`qa`: source-file modification requested → STOP, read-only

---

## Write Protection Rule

No file modifications **for Tier 1+** until ALL three gates pass (genuine Tier 0 exempt; a Tier-0 prompt editing a Tier 1+ path escalates — see Risk Tiers):
1. **Spec Design Review Gate** (`full_feature` / `design_review_only` only)
2. **Change Contract** (`/contract` writes `.intellisense/contracts/<safe-branch>.md`, committed with the change)
3. **Explicit user approval** — "proceed" or equivalent (see Approval Checkpoints)

Enforced at edit time by `scripts/preToolUse-contract-gate.sh`: `enforced` blocks Tier 1+ edits without a valid contract, `pilot` (default) warns. `--no-verify` does NOT bypass the prose rule.

## Spec Design Review Gate (`full_feature` / `design_review_only`)

Before Phase 1, output the JSON; proceed only when `implementation_ready=true` AND `clarifying_questions` is empty:
```json
{ "critical_issues": [], "major_concerns": [], "clarifying_questions": [], "security_risks": [], "implementation_ready": false, "confidence_score": 0.0 }
```

## Task Tracking (Tier 1+, always-loaded — do not rely on classifier injection)

Every Tier 1+ commit carries its own task trailer; `hooks/pre-push` and CI block one without it (Tier 0 exempt). The
accepted keys are `evidence.task_trailers` in `.intellisense.yml`; the tracker is the team's choice (GitHub, Jira,
Linear, Beads or none). Open or pick the issue before the first Tier 1+ edit. With Beads: task-tracking-beads.md.

**Evidence (Tier 1+ push):**
```
Refs: #123                  # on each Tier 1+ commit (or Task: PROJ-12, Beads: <id> — per the policy)
Change Contract: scope=…, risk=low|medium|high   # once per change — or the committed .intellisense/contracts/<branch>.md
```

## Merge-Method Policy

intellisense repos use **rebase merge only** — plain/squash merge destroys `Intellisense-Metadata:` trailers; enabling merge queue invalidates this until re-verified. Detail: enforcement-internals.md#merge-method.

---

## Phase 0: Fork Check (before Phase 1)

**Gate — do not proceed until:** personal fork confirmed · `origin`→fork, `upstream`→main (verify `git remote -v`) · fork workflow (git-workflow.md) done. All work flows through fork + PR — never a direct push to upstream.

## Phase 1: Plan

**Required reading:** `@rules/operational/proof-standards.md` — every plan declares Risk Tier + Proof Type.

- **1 service (Path A):** run `/plan` (affected files, tests, risks, deploy order) → present → wait for "proceed".
- **2+ services (Path B):** spawn strategic-architect → `/multi-service-plan` Step 0 discovers repos → per-repo breakdown + deploy sequence → present → wait for "proceed".

**STOP — Gate Phase 1 → Phase 2:** plan presented with a Change Contract (limits: full_feature ≤15, bug_fix ≤3, refactor ≤10, hotfix ≤2; **≤800 lines total**) AND user said "proceed". >15 files or >800 lines → escalate to multi-service planning.

### Mechanized validation

`/contract` writes `.intellisense/contracts/<safe-branch>.md` (committed; front matter = the fields). Three blocking layers:
- **Pre-push hook** — validates schema + Gate Rules R1–R5 + scope drift; BLOCKS the push on policy failure.
- **PreToolUse contract gate** — `enforced` blocks / `pilot` (default) warns.
- **Audit chain** (`intellisense.audit_chain_enforcement`, default `enforced`) — blocks missing-classification / missing-contract / validator-failure on Tier 1+ paths, independent of gate_mode.

**Visibility rule (BLOCKING):** the contract counts only when it is committed with the change (the `.md` file, or a `Change Contract:` line); a contract that exists only locally does not. The contract never replaces the task trailer: each Tier 1+ commit still carries its own. **`.intellisense/session/**` is read as JSON only — never `source`d as shell.** Runtime detail: enforcement-internals.md#mechanized-validation.

### Change Contract Structure

Schema + 16 required fields (incl. `session_id`/`prompt_hash`/`classification_id`/`state`) are owned by `skills/contract/schema.json` — **do NOT enumerate fields here** (`jq '.required' skills/contract/schema.json`). **Conditional gate (R2):** `approval_received_at` is required only when `protected_files_touched` is non-empty. Workflow + doc-only fields: `skills/contract/SKILL.md`.

### Change Contract Gate Rules (apply before Phase 2)

- **R1:** `high_risk_files_touched` non-empty → `risk_level` must be medium/high, else STOP.
- **R2:** `protected_files_touched` non-empty → STOP, ask the user before continuing.
- **R3:** `confidence_score` < 0.75 → STOP, clarify before continuing.
- **R4:** `bug_fix` AND `files_affected` > 3 → STOP, split or escalate to `full_feature`.
- **R5: Financial Impact Requires Full Feature** — `financial_impact` true AND `bug_fix` → escalate to `full_feature` automatically, resume Phase 1.

---

## Before Writing Code

Phases 2–6 (TDD → Implement → Review → Commit → Push/PR): development-workflow-impl.md.

## Codebase Exploration

**Code graph (only when the team chose `code-review-graph`; required when ALL hold):** repo is intellisense-managed (`.intellisense/MANAGED`) · the organization made the stack mandatory · a graph-native workflow is active (e.g. `/code-review` Impact Analysis). Structural queries (who-calls, change-spread, type hierarchy) → use code-review-graph; regex/string/raw-text → `rg`. Bootstrap command, stack table, full conditions: graph-policy.md. Opt out: drop `.intellisense/graph-exception.json` with a reason.
