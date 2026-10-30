# Enforcement Internals (deep reference — NOT always-loaded)

On-demand reference for the runtime machinery behind the Phase 0–1 gates.
This content was extracted from `development-workflow.md` because it documents
**system state and script behavior** (what the hooks do, independently of
whether Claude reads it) rather than **operative instructions to Claude**.
Load this only when debugging a gate failure or changing the enforcement
scripts themselves.

Source of truth for the gates remains the scripts and schema:
`scripts/preToolUse-contract-gate.sh`, `scripts/validate-contract-schema.sh`,
`hooks/pre-push`, `skills/contract/schema.json`.

---

## Merge-Method Policy Tripwire {#merge-method}

intellisense-onboarded repos MUST use **rebase merge only**. Plain merge and squash
both destroy or hide `Intellisense-Metadata:` trailers on `main`: `git merge --squash` defeats
`git interpret-trailers --parse`, and GitHub's squash inserts lines that split the trailer block.

**Tripwire rule:** Enabling GitHub **merge queue** at any onboarded repo
INVALIDATES the merge-method enforcement assumptions until the merge-queue verification
matrix has been re-run for that repo (merge queue was verified NOT to
preserve trailers; that finding decays the moment any repo opts in).

If you are about to enable merge queue: re-verify that synthetic merge-queue
commits preserve trailers, OR opt the repo out via
`.intellisense/manifest.json: {"merge_policy_override": "merge-queue"}` and accept
the dashboard accuracy hit.

---

## Mechanized validation (current runtime state — pilot foundation) {#mechanized-validation}

`/contract` writes `.intellisense/contracts/<safe-branch>.md`, committed with the change: its front matter holds the fields. The pre-push hook validates it against the schema + Gate Rules R1–R5 + scope drift and BLOCKS the push on policy failure, and the intellisense gate accepts the same file as the change's contract evidence.

**Runtime status:** Contract file + pre-push validation are SHIPPED. The PreToolUse hook on `Edit|Write|MultiEdit|NotebookEdit|Bash` is SHIPPED in two modes — `intellisense.gate_mode=pilot` (default; warns and allows, generates audit data) and `intellisense.gate_mode=enforced` (blocks on missing/invalid/out-of-scope). Org-wide flip to `enforced` is gated on classifier reliability work; see CHANGELOG / Beads for tracking issues.

**Honest framing:** runtime enforcement is in pilot. The prose gates in `development-workflow.md` remain truthful and self-contained — do not depend on classifier-injected content for safety-critical guidance until pilot data + architectural blockers prove reliable.

### Audit-chain enforcement detail

Governed by `intellisense.audit_chain_enforcement` (default `enforced`) and runs in `scripts/preToolUse-contract-gate.sh` **independently of `intellisense.gate_mode`**:

- **Blocks regardless of `gate_mode`:** missing classification on a Tier 1+ path (path/policy tier computed *before* the classification check), missing contract, validator failure (R1–R7, scope drift, schema invalidation), unscopeable Bash mutation combined with missing classification, missing `scripts/lib/effective-tier.sh` (fail-closed — cannot prove Tier 0 without the source-of-truth library), out-of-scope edit.
- **`gate_mode=pilot` still governs advisory signals only:** Tier 0 missing-classification advisory, graph freshness, impact analysis, settings freshness.
- **Opt-out (incident recovery only):** `intellisense.audit_chain_enforcement=warn` restores warn-and-allow. Each opt-out emits a `[audit-chain warn]` stderr prefix AND appends a row to `~/.claude-intellisense/audit-chain-warnings.jsonl` (timestamp, cwd, branch, session_id, tool_name, reason). Audit-log write failures emit a secondary stderr but never block the edit (break-glass stays break-glass).
- **Reviewer-evidence contracts** (`state: retroactive` / `state: evidence_only`) and the validator's `--context={edit|evidence}` lifecycle semantics: see `scripts/validate-contract-schema.sh` header and `skills/contract/schema.json` (state-machine source of truth). R2 (protected-files approval) and R7 (classification_id binding) fire in both contexts.

**Operational invariant for `.intellisense/session/**`:** these files (classification.json, usage.json, token-cursor.json, current-session-id) — and the contract under `.intellisense/contracts/`, read through `intellisense contract show` — are trusted operational state for the gate and validator. They are read as **JSON only** (via `jq`); they MUST NEVER be `source`d into a shell or otherwise interpreted as executable code.
