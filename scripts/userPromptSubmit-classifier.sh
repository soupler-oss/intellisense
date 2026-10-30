#!/usr/bin/env bash
# userPromptSubmit-classifier.sh — Phase 2 of the intellisense mechanized-gate stack.
#
# Hook event : UserPromptSubmit
# Purpose    : Classify the user's prompt → write .intellisense/session/<session_id>.classification.json
#              and inject distilled rule content via additionalContext so Claude has
#              the essentials immediately (no JIT-load reliance).
#
# Cache key  : session_id (NOT branch). Multiple tasks per branch (trunk-based dev)
#              would go stale on branch keying.
#
# Hook IO contract (Claude Code):
#   stdin  : JSON { prompt, session_id, cwd, ... }
#   stdout : JSON { hookSpecificOutput: { hookEventName, additionalContext } } [optional]
#   exit 0 : allow (with optional context injection)
#   exit 2 : block prompt expansion (NOT used here — classifier never blocks)
#
# Override path (manual):
#   bash scripts/userPromptSubmit-classifier.sh --override --tier=N --mode=X --session-id=SID --cwd=PATH

set -uo pipefail

# runtime_ms telemetry only when bash supports EPOCHREALTIME
# (bash 5+, zero-spawn). On bash 3.2 (default macOS) HOOK_START_MS is empty
# and the log block writes runtime_ms: null — no python3 spawn, no overhead
# on the classifier's hot path.
HOOK_START_MS=""
if [ -n "${EPOCHREALTIME:-}" ]; then
    HOOK_START_MS="${EPOCHREALTIME/./}"
    HOOK_START_MS="${HOOK_START_MS%???}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="${INTELLISENSE_CLASSIFIER_RULES:-$SCRIPT_DIR/classifier-rules.json}"

# Shared fast-lane / dangerous-phrase predicates. If unavailable, the triviality
# downgrade and dangerous-phrase escalation below are both skipped (fail-safe:
# tier stays as keyword-assigned — full gating, never silently relaxed).
. "$SCRIPT_DIR/lib/safe-lane.sh" 2>/dev/null || true
# The branch's contract (.intellisense/contracts/<branch>.md) and its JSON view.
. "$SCRIPT_DIR/lib/contract-file.sh" 2>/dev/null || true

# _contract_json_for <cwd> <branch> — prints the path of a temp JSON view of the branch's contract, or fails.
_contract_json_for() {
    local root file out
    root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "$1")"
    file="$(intellisense_contract_file "$root" "$2" 2>/dev/null)" || return 1
    [ -f "$file" ] || return 1
    out="$(mktemp 2>/dev/null)" || return 1
    if intellisense_contract_json "$file" "$out"; then
        printf '%s\n' "$out"
        return 0
    fi
    rm -f "$out"
    return 1
}
CONTENT_DIR="${INTELLISENSE_CLASSIFIER_CONTENT:-$SCRIPT_DIR/classifier-rule-content}"
MAX_ADDITIONAL_CONTEXT=8000  # leave 2k headroom under Claude Code's 10k cap

# ─── Fail-OPEN helpers (classifier should never brick a session) ──────────────

emit_no_context() {
    # Exit 0 with no additional context — Claude proceeds normally.
    exit 0
}

emit_context() {
    local ctx="$1"
    # Truncate defensively to under the cap
    if [ "${#ctx}" -gt "$MAX_ADDITIONAL_CONTEXT" ]; then
        ctx="${ctx:0:$MAX_ADDITIONAL_CONTEXT}"
    fi
    jq -n --arg c "$ctx" '{
        hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: $c
        }
    }'
    exit 0
}

# ─── Manual override mode ─────────────────────────────────────────────────────

if [ "${1:-}" = "--override" ]; then
    # manual override must be human-visible AND
    # logged. Require an explicit --reason= so silent self-downgrade is not
    # possible with a one-arg "--override --tier=0".
    OVR_TIER=""; OVR_MODE=""; OVR_SID=""; OVR_CWD="$PWD"; OVR_REASON=""
    shift
    for arg in "$@"; do
        case "$arg" in
            --tier=*)       OVR_TIER="${arg#--tier=}" ;;
            --mode=*)       OVR_MODE="${arg#--mode=}" ;;
            --session-id=*) OVR_SID="${arg#--session-id=}" ;;
            --cwd=*)        OVR_CWD="${arg#--cwd=}" ;;
            --reason=*)     OVR_REASON="${arg#--reason=}" ;;
        esac
    done
    if [ -z "$OVR_TIER" ] || [ -z "$OVR_MODE" ] || [ -z "$OVR_SID" ]; then
        echo "Usage: $0 --override --tier=N --mode=X --session-id=SID --reason='<human-provided rationale>' [--cwd=PATH]" >&2
        exit 1
    fi
    if [ -z "$OVR_REASON" ]; then
        echo "ERROR: --reason='<rationale>' is required for override. Manual override is an audited escape hatch — record WHY the classifier was wrong (e.g. 'doc-only PR but mentions account')." >&2
        exit 1
    fi
    mkdir -p "$OVR_CWD/.intellisense/session"
    OVR_TS="$(date -u +%FT%TZ)"
    OVR_EPOCH="$(date -u +%s)"
    # Override classification gets its own classification_id so contracts
    # produced after the override re-bind to the new identity. prompt_hash
    # is left empty — manual override has no prompt context.
    OVR_CID="cls_override_${OVR_EPOCH}"
    jq -n --arg t "$OVR_TIER" --arg m "$OVR_MODE" --arg ts "$OVR_TS" \
         --arg reason "$OVR_REASON" --arg cid "$OVR_CID" '{
        tier: $t, mode: $m, confidence: 1.0,
        source: "manual_override",
        timestamp: $ts,
        prompt_hash: "",
        classification_id: $cid,
        reasoning: ["manual override via --override flag", "reason: " + $reason]
    }' >"$OVR_CWD/.intellisense/session/${OVR_SID}.classification.json"

    # Audit log — every override is appended to ~/.claude-intellisense/classifier-overrides.jsonl
    OVR_LOG_DIR="${INTELLISENSE_CLASSIFIER_LOG_DIR:-$HOME/.claude-intellisense}"
    mkdir -p "$OVR_LOG_DIR" 2>/dev/null
    jq -nc \
        --arg ts "$OVR_TS" \
        --arg sid "$OVR_SID" \
        --arg cwd "$OVR_CWD" \
        --arg tier "$OVR_TIER" \
        --arg mode "$OVR_MODE" \
        --arg reason "$OVR_REASON" \
        --arg user "${USER:-unknown}" \
        '{
            ts: $ts, session_id: $sid, cwd: $cwd,
            tier: $tier, mode: $mode, reason: $reason, user: $user,
            event: "manual_override"
        }' >>"$OVR_LOG_DIR/classifier-overrides.jsonl" 2>/dev/null || true

    echo "Override written: tier=$OVR_TIER mode=$OVR_MODE reason=\"$OVR_REASON\"" >&2
    echo "Audit log: $OVR_LOG_DIR/classifier-overrides.jsonl" >&2
    exit 0
fi

# ─── Read stdin payload ───────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
    emit_no_context
fi

PAYLOAD=$(cat)
[ -z "$PAYLOAD" ] && emit_no_context

PROMPT=$(jq -r '.prompt // empty' <<<"$PAYLOAD")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$PAYLOAD")
CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD")

[ -z "$PROMPT" ] && emit_no_context
[ -z "$SESSION_ID" ] && emit_no_context
[ -z "$CWD" ] && emit_no_context
[ ! -f "$RULES_FILE" ] && emit_no_context

# ─── Cache check ──────────────────────────────────────────────────────────────

INTELLISENSE_SESSION_DIR="$CWD/.intellisense/session"
mkdir -p "$INTELLISENSE_SESSION_DIR"
CACHE_FILE="$INTELLISENSE_SESSION_DIR/${SESSION_ID}.classification.json"

# ─── emit session pointer + initialize usage.json ───────────────
# - current-session-id   : tells prepare-commit-msg (prepare-commit-msg) which session is active.
# - <sid>.usage.json     : seeded empty; the PostToolUse usage tracker's PostToolUse hook appends skill/agent
#                          names; prepare-commit-msg reads it at commit time.
# Both files live under the gitignored .intellisense/session/ directory.
{
    printf '%s' "$SESSION_ID" > "$INTELLISENSE_SESSION_DIR/current-session-id.tmp" \
        && mv "$INTELLISENSE_SESSION_DIR/current-session-id.tmp" "$INTELLISENSE_SESSION_DIR/current-session-id"
} 2>/dev/null || true

USAGE_FILE="$INTELLISENSE_SESSION_DIR/${SESSION_ID}.usage.json"
if [ ! -f "$USAGE_FILE" ]; then
    jq -n --arg sid "$SESSION_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{session_id: $sid, skills_used: [], agents_spawned: [], first_prompt_ts: $ts}' \
        > "$USAGE_FILE.tmp" 2>/dev/null \
        && mv "$USAGE_FILE.tmp" "$USAGE_FILE" || true
fi

# Lowercase prompt for case-insensitive matching
PROMPT_LC=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Compute the prompt hash up-front (lifted out of decision-log block) so it
# can drive cache invalidation AND be persisted to classification.json for
# the contract gate to bind against.
PROMPT_HASH=""
if command -v shasum >/dev/null 2>&1; then
    PROMPT_HASH=$(printf '%s' "$PROMPT" | shasum -a 256 2>/dev/null | cut -c1-8)
elif command -v sha256sum >/dev/null 2>&1; then
    PROMPT_HASH=$(printf '%s' "$PROMPT" | sha256sum 2>/dev/null | cut -c1-8)
fi

# ─── Approval / continuation prompt detection ─────────────────────────────────
# When the user types a pure approval phrase ("proceed", "yes", "go ahead",
# ...), the prompt is NOT a new task — it's authorization to advance the
# CURRENT task. Treating it as a new task would overwrite classification.json's
# classification_id and break R7 task binding to the contract just approved.
#
# Detection: lowercase + strip whitespace + strip trailing punctuation, then
# exact-match against rules['approval_prompts']. Conservative by design —
# any prompt carrying additional scope ("yes, also fix Z") does NOT match.
# the harness injects wrapper context into `.prompt` (e.g.
# <ide_opened_file>…</ide_opened_file>, <ide_selection>…</ide_selection>,
# <system-reminder>…</system-reminder>). Confirmed in session fb02f996: a bare
# "proceed" arrived as a 210-char prompt because an <ide_opened_file> block was
# prepended, so is_approval_prompt's exact-match + 40-char cap rejected it and
# the approval was misread as a new task (breaking R7). Strip those injected
# blocks BEFORE approval detection only — hashing/identity logic is unchanged.
# Blocks may span newlines, so strip multiline + NON-GREEDY (.*?) so two
# same-name tags bracketing a real word don't get coalesced — a greedy .*
# matched from the first open tag to the LAST close tag and deleted the word
# in between ("<ide_selection>a</ide_selection>proceed<ide_selection>b…" → "").
# Coverage spans every harness wrapper, not just the ide_* / system-reminder
# ones: command-name / command-message / command-args / local-command-stdout /
# local-command-stderr survived the old filter and pushed a bare "proceed"
# past the 40-char approval cap. A \1 backreference keeps open/close paired.
# Safety: this can only make a genuine approval MORE detectable; it never
# creates a false approval (wrapper tags are not approval phrases), and the
# 40-char cap below still backstops anything unexpected.
# perl handles multiline (-0777/s) + non-greedy (.*?) + alternation+backref in
# one pass. Fallback to a tr|sed pipeline when perl is unavailable
# (degraded: greedy, ide_*/system-reminder only — but still better than no
# stripping, and the 40-char cap remains the backstop).
_strip_injected_context() {
    local tags='ide_selection|ide_opened_file|system-reminder|command-name|command-message|command-args|local-command-stdout|local-command-stderr'
    if command -v perl >/dev/null 2>&1; then
        printf '%s' "$1" \
            | perl -0777 -pe "s{<($tags)>.*?</\\1>}{}gs" \
            | tr '\n\r' '  '
    else
        printf '%s' "$1" \
            | tr '\n\r' '  ' \
            | sed -E 's#<ide_selection>.*</ide_selection>##g; s#<ide_opened_file>.*</ide_opened_file>##g; s#<system-reminder>.*</system-reminder>##g'
    fi
}

is_approval_prompt() {
    local p="$1"
    # Normalize: lowercase, strip leading/trailing whitespace, strip trailing
    # punctuation (.!? combinations).
    local norm
    norm=$(printf '%s' "$p" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g; s/[.!?]+$//; s/[[:space:]]+$//')
    [ -z "$norm" ] && return 1
    # Hard cap: approval phrases are short. Refuse to even check long prompts.
    if [ "${#norm}" -gt 40 ]; then
        return 1
    fi
    # Read approval_prompts from rules and check exact match.
    local phrase
    while IFS= read -r phrase; do
        [ -z "$phrase" ] && continue
        if [ "$norm" = "$phrase" ]; then
            return 0
        fi
    done < <(jq -r '.approval_prompts[]? // empty' "$RULES_FILE" 2>/dev/null)
    return 1
}

# Returns 0 (success) iff there is a contract on the current branch AND its
# classification_id equals the supplied current classification_id (typically
# read from the cached classification.json before any re-classification).
#
# This is the safety guard for two related bugs:
#   1. "Review this PR" -> "do it" — without a contract bound to the review
#      task, "do it" is NOT approval of the review; it's a separate request.
#      Re-classifying it is the safer interpretation.
#   2. Draft contract for task A on disk + classifier reclassifies to task B
#      + user types "proceed" — that "proceed" cannot be approval of the
#      stale A contract; advancing its state to "approved" would corrupt the
#      lifecycle. The check refuses to fire when contract.classification_id
#      != current.classification_id.
#
# Returns non-zero in all other cases (no contract, mismatched binding,
# unreadable git state, missing jq).
_contract_matches_current_task() {
    local cwd="$1"
    local current_cid="$2"
    [ -n "$current_cid" ] || return 1
    git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local branch safe_branch contract_file contract_cid
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null) || return 1
    [ -n "$branch" ] || return 1
    safe_branch="${branch//\//__}"
    contract_file="$(_contract_json_for "$cwd" "$branch")" || return 1
    contract_cid=$(jq -r '.classification_id // empty' "$contract_file" 2>/dev/null)
    rm -f "$contract_file"
    [ -n "$contract_cid" ] || return 1
    [ "$contract_cid" = "$current_cid" ]
}

# prompt-time contract heads-up. When the active
# tier is 1+ and no contract is bound to the current task, echo a one-line
# directive to append to the classifier header. This shifts the contract signal
# from an edit-time gate BLOCK to an upfront notification — the developer runs
# /contract before editing instead of getting stopped mid-edit. Enforcement is
# unchanged: this only adds text; the gate still blocks exactly as before if the
# heads-up is ignored. Echoes empty (no directive) for Tier 0 or when a matching
# contract already exists (so it never nags after /contract has been run).
_contract_heads_up() {
    local tier="$1" current_cid="$2"
    case "$tier" in
        1|2) ;;
        *) return 0 ;;
    esac
    if _contract_matches_current_task "$CWD" "$current_cid"; then
        # A contract is bound to this task. Suppress the directive only when
        # its state is approved/active (edit-ready). A matching contract still
        # in draft/presented does NOT suppress: edits stay R6-blocked until the
        # contract is approved, so suppressing here would leave the developer
        # with neither the heads-up nor an approved contract — a silent
        # dead-end. In that case, nudge toward approval instead.
        local branch safe_branch contract_file state
        branch=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null)
        if [ -n "$branch" ]; then
            safe_branch="${branch//\//__}"
            state=""
            if contract_file="$(_contract_json_for "$CWD" "$branch")"; then
                state=$(jq -r '.state // empty' "$contract_file" 2>/dev/null)
                rm -f "$contract_file"
            fi
            case "$state" in
                approved|active) return 0 ;;
                *)
                    printf ' ⚠ Tier %s — a contract is bound to this task but not yet approved (state=%s); approve it BEFORE editing or the gate will block edits.' "$tier" "${state:-unknown}"
                    return 0
                    ;;
            esac
        fi
        # Could not resolve branch/state; fall through to the generic directive.
    fi
    printf ' ⚠ Tier %s + no contract bound to this task yet — run /contract BEFORE editing; the gate will block edits until a valid contract exists.' "$tier"
}

# When the prompt is approval, advance the active branch's contract from
# draft|presented to approved. Failure-isolated: any error must not block
# the classifier or the user's prompt.
#
# Defense in depth: this function ALSO checks classification_id match
# internally, in case the caller's gating was bypassed. A stale contract
# bound to a different task must NOT have its state mutated by an approval
# event for a different task identity.
_advance_contract_to_approved() {
    local cwd="$1"
    local current_cid="$2"
    git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local branch contract_file contract_json state new_state contract_cid approved_at root
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null) || return 0
    [ -n "$branch" ] || return 0
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
    contract_file="$(intellisense_contract_file "$root" "$branch" 2>/dev/null)" || return 0
    contract_json="$(_contract_json_for "$cwd" "$branch")" || return 0
    contract_cid=$(jq -r '.classification_id // empty' "$contract_json" 2>/dev/null)
    state=$(jq -r '.state // empty' "$contract_json" 2>/dev/null)
    approved_at=$(jq -r '.approval_received_at // empty' "$contract_json" 2>/dev/null)
    rm -f "$contract_json"
    if [ -n "$current_cid" ] && [ -n "$contract_cid" ] && [ "$contract_cid" != "$current_cid" ]; then
        # Stale contract — do NOT mutate its state on an approval event for
        # a different task. Pre-existing R7 will block any edit against it.
        echo "intellisense: approval received but contract at $contract_file binds to a different task (contract=$contract_cid, current=$current_cid). Contract state NOT advanced. Re-run /contract on the current task before editing." >&2
        return 0
    fi
    case "$state" in
        draft|presented) new_state="approved" ;;
        *) return 0 ;;
    esac
    local set_args=("state=$new_state")
    [ -n "$approved_at" ] || set_args+=("approval_received_at=$(date -u +%FT%TZ)")
    if intellisense_contract_set "$contract_file" "${set_args[@]}"; then
        echo "intellisense: contract state advanced $state -> $new_state on approval prompt" >&2
    fi
}

context_shift_detected() {
    local p="$1"
    local shifts
    shifts=$(jq -r '.context_shift_signals[]' "$RULES_FILE" 2>/dev/null)
    while IFS= read -r sig; do
        [ -z "$sig" ] && continue
        if [[ "$p" == *"$sig"* ]]; then
            return 0
        fi
    done <<<"$shifts"
    return 1
}

# Cache staleness across implicit context shifts.
# When cached classification is Tier 0 or design_review_only, but the new
# prompt contains tier-escalating keywords or action-mode keywords, the cache
# is stale even if no explicit context_shift_signal matches. Return 0 to
# trigger re-classification.
tier_escalation_in_new_prompt() {
    local p="$1"
    local cache="$2"
    local cached_tier cached_mode
    cached_tier=$(jq -r '.tier // empty' "$cache" 2>/dev/null)
    cached_mode=$(jq -r '.mode // empty' "$cache" 2>/dev/null)

    # If cached tier < 2, check for Tier 2 keywords in new prompt.
    # Mirror the contextual logic from initial classification.
    if [ "$cached_tier" != "2" ]; then
        local t2_pattern t2_ctx t2_neigh
        t2_pattern=$(jq -r '.tier_signals.tier_2_keywords | join("|")' "$RULES_FILE" 2>/dev/null)
        t2_ctx=$(jq -r '.tier_signals.tier_2_contextual_keywords // [] | join("|")' "$RULES_FILE" 2>/dev/null)
        t2_neigh=$(jq -r '.tier_signals.tier_2_contextual_strong_neighbors // [] | join("|")' "$RULES_FILE" 2>/dev/null)
        if [ -n "$t2_pattern" ] && echo "$p" | grep -qiE "$t2_pattern"; then
            return 0
        fi
        if [ -n "$t2_ctx" ] && [ -n "$t2_neigh" ] \
           && echo "$p" | grep -qiE "$t2_ctx" \
           && echo "$p" | grep -qiE "$t2_neigh"; then
            return 0
        fi
    fi
    # If cached tier = 0, check for Tier 1 keywords
    if [ "$cached_tier" = "0" ]; then
        local t1_pattern
        t1_pattern=$(jq -r '.tier_signals.tier_1_keywords | join("|")' "$RULES_FILE" 2>/dev/null)
        if [ -n "$t1_pattern" ] && echo "$p" | grep -qiE "$t1_pattern"; then
            return 0
        fi
    fi
    # If cached mode is read-only (design_review_only/pr_review/qa) and prompt
    # has implementation-mode signals, cache is stale.
    case "$cached_mode" in
        design_review_only|pr_review|qa)
            local action_pattern
            action_pattern=$(jq -r '(.mode_signals.bug_fix + .mode_signals.full_feature + .mode_signals.refactor + .mode_signals.hotfix) | join("|")' "$RULES_FILE" 2>/dev/null)
            if [ -n "$action_pattern" ] && echo "$p" | grep -qiE "$action_pattern"; then
                return 0
            fi
            ;;
    esac
    return 1
}

# Cache invalidation: if the cached classification's prompt_hash differs from
# the current prompt's hash, the cached entry belongs to a DIFFERENT TASK on
# the same session_id. Force a fresh classification + emit a new
# classification_id so the contract gate can detect task drift.
#
# IMPORTANT: this function compares against the cached TASK-ORIGIN hash
# (prompt_hash field), NOT against last_prompt_hash. Approval prompts update
# last_prompt_hash but leave prompt_hash unchanged — so they don't churn
# classification_id and don't break R7 binding to the active task.
prompt_hash_mismatch() {
    local cache="$1"
    [ -n "$PROMPT_HASH" ] || return 1
    local cached_hash
    cached_hash=$(jq -r '.prompt_hash // empty' "$cache" 2>/dev/null)
    # No cached hash → nothing to compare; treat as match (the context_shift
    # heuristics still apply).
    [ -z "$cached_hash" ] && return 1
    [ "$cached_hash" != "$PROMPT_HASH" ]
}

# ─── Approval-prompt fast path ────────────────────────────────────────────────
# If the current prompt is a pure approval phrase AND a cache exists for this
# session AND there is a contract on the current branch that binds to the
# cached classification_id, treat it as a continuation of the active task.
# The classification identity (classification_id / prompt_hash / task fields)
# is preserved; only the latest-event fields (last_prompt_*) are updated.
# Side effect: advance the active contract from draft|presented to approved.
#
# The "matching active contract" gate covers two cases:
#   (a) "Review this PR" -> "do it" does not preserve the
#       design_review_only classification, because no contract was ever
#       written for that Tier 0 task. "do it" instead re-classifies.
#   (b) A draft contract bound to task A + a later reclassification to
#       task B + "proceed" does not advance A's state. The fast-path
#       refuses to fire, the prompt re-classifies, and gate R7 surfaces
#       the stale binding the next time the developer edits a file.
CURRENT_CID_CACHED=""
if [ -f "$CACHE_FILE" ]; then
    CURRENT_CID_CACHED=$(jq -r '.classification_id // empty' "$CACHE_FILE" 2>/dev/null)
fi

if [ -f "$CACHE_FILE" ] \
   && is_approval_prompt "$(_strip_injected_context "$PROMPT")" \
   && _contract_matches_current_task "$CWD" "$CURRENT_CID_CACHED"; then
    EVENT_TS="$(date -u +%FT%TZ)"
    # Write the updated cache: keep task identity, refresh last-event fields.
    TMP_CACHE=$(mktemp 2>/dev/null)
    if [ -n "$TMP_CACHE" ] && jq \
        --arg lp "$PROMPT_HASH" \
        --arg ev "approval" \
        --arg ts "$EVENT_TS" \
        '.last_prompt_hash = $lp
         | .last_prompt_event = $ev
         | .last_prompt_ts = $ts' \
        "$CACHE_FILE" >"$TMP_CACHE" 2>/dev/null && [ -s "$TMP_CACHE" ]; then
        mv "$TMP_CACHE" "$CACHE_FILE" 2>/dev/null || rm -f "$TMP_CACHE" 2>/dev/null
    else
        rm -f "$TMP_CACHE" 2>/dev/null
    fi
    # Advance contract state to approved (idempotent if already approved/active).
    # Pass current classification_id so the helper's internal classification_id
    # match check (defense in depth) can refuse stale contracts even if this
    # fast-path's gating ever diverges in the future.
    _advance_contract_to_approved "$CWD" "$CURRENT_CID_CACHED"

    # Emit cached classification's content so the developer/Claude still sees
    # the task's tier/mode rules — same as the regular cache-hit path.
    CACHED_TIER=$(jq -r '.tier // empty' "$CACHE_FILE" 2>/dev/null)
    CACHED_MODE=$(jq -r '.mode // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$CACHED_TIER" ] && [ -n "$CACHED_MODE" ]; then
        CONTENT_KEY="tier_${CACHED_TIER}_${CACHED_MODE}"
        FALLBACK_KEY="tier_${CACHED_TIER}_default"
        FALLBACK_KEY2="tier_${CACHED_TIER}"
        CONTENT_FILES=$(jq -r ".load_files_by_classification[\"$CONTENT_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY2\"] // [] | .[]" "$RULES_FILE" 2>/dev/null)
        COMBINED=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            [ -f "$CONTENT_DIR/$f" ] && COMBINED+="$(cat "$CONTENT_DIR/$f")"$'\n\n'
        done <<<"$CONTENT_FILES"
        HEADER="[intellisense classifier — approval] preserved Tier=$CACHED_TIER mode=$CACHED_MODE (session $SESSION_ID). Active task identity retained; contract state may have been advanced draft|presented -> approved. Override path: /intellisense reclassify or scripts/userPromptSubmit-classifier.sh --override with --reason=."
        if [ -n "$COMBINED" ]; then
            emit_context "${HEADER}"$'\n\n'"${COMBINED}"
        fi
    fi
    emit_no_context
fi

if [ -f "$CACHE_FILE" ] \
   && ! prompt_hash_mismatch "$CACHE_FILE" \
   && ! context_shift_detected "$PROMPT_LC" \
   && ! tier_escalation_in_new_prompt "$PROMPT_LC" "$CACHE_FILE"; then
    # Cache hit — emit cached classification's content but do not re-classify
    CACHED_TIER=$(jq -r '.tier // empty' "$CACHE_FILE" 2>/dev/null)
    CACHED_MODE=$(jq -r '.mode // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$CACHED_TIER" ] && [ -n "$CACHED_MODE" ]; then
        # Build content from cached values
        CONTENT_KEY="tier_${CACHED_TIER}_${CACHED_MODE}"
        FALLBACK_KEY="tier_${CACHED_TIER}_default"
        FALLBACK_KEY2="tier_${CACHED_TIER}"
        CONTENT_FILES=$(jq -r ".load_files_by_classification[\"$CONTENT_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY2\"] // [] | .[]" "$RULES_FILE" 2>/dev/null)
        COMBINED=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            [ -f "$CONTENT_DIR/$f" ] && COMBINED+="$(cat "$CONTENT_DIR/$f")"$'\n\n'
        done <<<"$CONTENT_FILES"
        if [ -n "$COMBINED" ]; then
            CACHED_CID=$(jq -r '.classification_id // empty' "$CACHE_FILE" 2>/dev/null)
            HEADS_UP=$(_contract_heads_up "$CACHED_TIER" "$CACHED_CID")
            HEADER="[intellisense classifier — cached] Tier=$CACHED_TIER mode=$CACHED_MODE (session $SESSION_ID). Override (human-driven, audited): if this classification is wrong, the developer (not Claude) can run \`/intellisense reclassify\` or the override script with --reason='<rationale>'; every override is logged to ~/.claude-intellisense/classifier-overrides.jsonl. Claude must NOT silently self-downgrade.${HEADS_UP}"
            emit_context "${HEADER}"$'\n\n'"${COMBINED}"
        fi
        emit_no_context
    fi
fi

# ─── Classification (fresh) ───────────────────────────────────────────────────

REASONING=()

# Step 1: tier from keywords
# noisy generic terms (session, checkout, points,
# login, cart) moved to tier_2_contextual_keywords. They escalate to Tier 2
# only when co-occurring with a tier_2_contextual_strong_neighbor.
TIER="0"
T2_STRONG_PATTERN=$(jq -r '.tier_signals.tier_2_keywords | join("|")' "$RULES_FILE")
T2_CTX_PATTERN=$(jq -r '.tier_signals.tier_2_contextual_keywords // [] | join("|")' "$RULES_FILE")
T2_NEIGHBOR_PATTERN=$(jq -r '.tier_signals.tier_2_contextual_strong_neighbors // [] | join("|")' "$RULES_FILE")

if [ -n "$T2_STRONG_PATTERN" ] && echo "$PROMPT_LC" | grep -qiE "$T2_STRONG_PATTERN"; then
    TIER="2"
    REASONING+=("matched tier_2 keyword (strong/unconditional)")
elif [ -n "$T2_CTX_PATTERN" ] && [ -n "$T2_NEIGHBOR_PATTERN" ] \
     && echo "$PROMPT_LC" | grep -qiE "$T2_CTX_PATTERN" \
     && echo "$PROMPT_LC" | grep -qiE "$T2_NEIGHBOR_PATTERN"; then
    TIER="2"
    REASONING+=("matched tier_2 contextual keyword + strong neighbor")
elif echo "$PROMPT_LC" | grep -qiE "$(jq -r '.tier_signals.tier_1_keywords | join("|")' "$RULES_FILE")"; then
    TIER="1"
    REASONING+=("matched tier_1 keyword")
fi

# Step 2: mode from keywords (priority order: hotfix > bug_fix > refactor > full_feature > design_review_only > pr_review > qa)
MODE=""
for candidate in hotfix bug_fix refactor full_feature design_review_only pr_review qa; do
    PATTERN=$(jq -r ".mode_signals.$candidate | join(\"|\")" "$RULES_FILE")
    if [ -n "$PATTERN" ] && [ "$PATTERN" != "null" ] && echo "$PROMPT_LC" | grep -qiE "$PATTERN"; then
        MODE="$candidate"
        REASONING+=("matched $candidate mode keyword")
        break
    fi
done

# Default mode if no keyword matched
if [ -z "$MODE" ]; then
    MODE="design_review_only"
    REASONING+=("no mode keyword matched — defaulted to design_review_only per workflow rule")
fi

# ── Corroboration: a bare Tier-1 keyword is not enough (Kind-2 ceremony fix) ───
# A Tier-1 keyword (setup/config/hook/rule/...) with NO action verb is a passing
# mention or a read-only question ("what does setup do?", "explain the hook"),
# not an infra change. Require an action mode to KEEP Tier 1; otherwise it is
# discussion → Tier 0, so the ceremony (Beads/contract/proceed) does NOT fire on
# simple mentions. Tier 2 (financial/security/migration) is matched separately
# above and is deliberately NOT downgraded here — fail-safe for high-stakes work.
# Fail-SAFE: downgrade ONLY when there is a POSITIVE read-only signal
# (design_review_only KEYWORD matched: explain / what does / how does /
# understand / review the design) AND no action mode won. A merely *defaulted*
# design_review_only (nothing matched, e.g. "change the config") is NOT
# downgraded — it could be a real edit verb absent from the mode lists. Better
# to over-gate an ambiguous prompt than to fail open on a real change.
DRO_INTENT_PATTERN=$(jq -r '.mode_signals.design_review_only | join("|")' "$RULES_FILE" 2>/dev/null)
if [ "$TIER" = "1" ] && [ "$MODE" = "design_review_only" ] \
   && [ -n "$DRO_INTENT_PATTERN" ] && echo "$PROMPT_LC" | grep -qiE "$DRO_INTENT_PATTERN"; then
    TIER="0"
    REASONING+=("Tier-1 keyword but explicit read-only intent (explain/what/how/understand) — discussion, downgraded to Tier 0")
fi

# ── Dangerous-phrase escalation + guarded triviality downgrade ──
# Two COUPLED rules. The "dangerous phrase" set lives in scripts/lib/safe-lane.sh
# so all three enforcement layers agree on what can never be cosmetic.
#
# (1) ESCALATE — a dangerous phrase ("comment out", "disable", "bypass",
#     "skip check", "remove validation", ...) is a BEHAVIOR change, never a typo.
#     It RAISES a minimum tier (it does not merely block the downgrade):
#       • floor Tier 1 always (it alters a control / check), AND
#       • floor Tier 2 if it touches a security/financial surface — any tier_2
#         strong OR contextual keyword (auth/payment/token/session/...).
#     Hence "comment out config validation" → Tier 1 (no tier_2 surface) and
#     "comment out the auth check" → Tier 2 ('auth' is a tier_2 surface word).
#
# (2) DOWNGRADE — ONLY when no dangerous phrase is present may a trivial-edit
#     keyword (typo/comment/docstring/rename/format/lint/readme/changelog) relax
#     a bare Tier-1 prompt to Tier 0. Gated on TIER==1 so Tier 2 is untouched.
#     Word-ish boundaries (^|[^a-z])...([^a-z]|$) avoid substring false matches
#     ('format' inside 'information'). PROMPT_LC is already lowercased.
#
# PROMPT-ONLY: "typo in setup.sh" downgrades HERE, but the actual edit still
# classifies Tier 1 by PATH at the gate/pre-push layers (setup.sh is an explicit
# Tier-1 path). Path-tier — not the classifier — protects real infra files.
#
# FAIL-SAFE: if safe-lane.sh did not load, neither rule runs and TIER stays as
# keyword-assigned (full gating, never silently relaxed).
if type intellisense_has_dangerous_phrase >/dev/null 2>&1; then
    if intellisense_has_dangerous_phrase "$PROMPT_LC"; then
        if [ "$TIER" -lt 1 ]; then
            TIER="1"
            REASONING+=("dangerous phrase (comment out/disable/bypass/...) — behavior change, floored to Tier 1")
        fi
        if echo "$PROMPT_LC" | grep -qiE "$T2_STRONG_PATTERN" \
           || { [ -n "$T2_CTX_PATTERN" ] && echo "$PROMPT_LC" | grep -qiE "$T2_CTX_PATTERN"; }; then
            if [ "$TIER" -lt 2 ]; then
                TIER="2"
                REASONING+=("dangerous phrase on a security/financial surface (auth/payment/token/...) — floored to Tier 2")
            fi
        fi
    else
        TIER0_NEG_PATTERN=$(jq -r '.tier_signals.tier_0_negative_keywords // [] | join("|")' "$RULES_FILE" 2>/dev/null)
        if [ "$TIER" = "1" ] && [ -n "$TIER0_NEG_PATTERN" ] \
           && echo "$PROMPT_LC" | grep -qiE "(^|[^a-z])($TIER0_NEG_PATTERN)([^a-z]|\$)"; then
            TIER="0"
            REASONING+=("trivial-edit keyword (comment/typo/rename/docstring/format/lint/readme/changelog) — downgraded to Tier 0")
        fi
    fi
fi

# Step 3: escalations
# L48: financial bug_fix → full_feature
if [ "$MODE" = "bug_fix" ] && [ "$TIER" = "2" ]; then
    FIN_KW=$(jq -r '.keyword_classes.financial | join("|")' "$RULES_FILE")
    if [ -n "$FIN_KW" ] && echo "$PROMPT_LC" | grep -qiE "$FIN_KW"; then
        MODE="full_feature"
        REASONING+=("L48 escalation: financial+bug_fix → full_feature")
    fi
fi

# Security + bug_fix at tier 2 → full_feature
if [ "$MODE" = "bug_fix" ] && [ "$TIER" = "2" ]; then
    SEC_KW=$(jq -r '.keyword_classes.security | join("|")' "$RULES_FILE")
    if [ -n "$SEC_KW" ] && echo "$PROMPT_LC" | grep -qiE "$SEC_KW"; then
        MODE="full_feature"
        REASONING+=("security+bug_fix → full_feature")
    fi
fi

# Multi-service scope → full_feature
if echo "$PROMPT_LC" | grep -qiE "(across|all|every|each)[[:space:]]+(service|repo|microservice)"; then
    if [ "$MODE" != "full_feature" ] && [ "$MODE" != "hotfix" ]; then
        MODE="full_feature"
        REASONING+=("multi-service scope → full_feature")
    fi
fi

# Step 4: confidence
# Confidence reflects how much INDEPENDENT evidence matched, not merely "tier>0".
# NOTE: this value is informational (printed in the header). It does NOT control
# any gate or enforcement — the contract's separate confidence_score (Gate Rule
# R3) is unaffected by this. Honest-but-non-authoritative by design.
CONFIDENCE="0.6"
if [ "${#REASONING[@]}" -ge 2 ]; then CONFIDENCE="0.8"; fi
if [ "${#REASONING[@]}" -ge 3 ]; then CONFIDENCE="0.9"; fi

# ─── Write cache ──────────────────────────────────────────────────────────────

REASONING_JSON=$(printf '%s\n' "${REASONING[@]}" | jq -R . | jq -s .)
DECISION_TS="$(date -u +%FT%TZ)"
DECISION_EPOCH="$(date -u +%s)"

# classification_id: stable identifier for THIS classification event. The
# contract gate (R7) compares contract.classification_id against
# the current classification.json's classification_id to detect task drift.
# Format: cls_<epoch>_<prompt_hash> — collision-resistant in practice and
# carries the prompt_hash inline for human inspection of audit logs.
CLASSIFICATION_ID="cls_${DECISION_EPOCH}_${PROMPT_HASH:-unknown}"

jq -n \
    --arg tier "$TIER" \
    --arg mode "$MODE" \
    --argjson confidence "$CONFIDENCE" \
    --arg source "classifier-rules.json" \
    --arg ts "$DECISION_TS" \
    --arg phash "$PROMPT_HASH" \
    --arg cid "$CLASSIFICATION_ID" \
    --argjson reasoning "$REASONING_JSON" \
    '{
        tier: $tier,
        mode: $mode,
        confidence: $confidence,
        source: $source,
        timestamp: $ts,
        classification_id: $cid,
        active_task_id: $cid,
        prompt_hash: $phash,
        task_origin_prompt_hash: $phash,
        last_prompt_hash: $phash,
        last_prompt_event: "task",
        last_prompt_ts: $ts,
        reasoning: $reasoning
    }' >"$CACHE_FILE"

# ─── Decision log (for pilot-mode accuracy audit) ──────
# Raw prompt logging is a privacy risk on 200+ dev
# machines. Prompts can contain incident details, customer IDs, tokens,
# private repo context. Default is now METADATA ONLY:
#   - prompt_hash (SHA256, 8 chars)
#   - prompt_length (chars)
#   - matched_reasoning_codes (from classifier reasoning, no raw matched text)
#   - tier, mode, confidence, timestamp, session_id, cwd
# Raw prompt preview is opt-in via INTELLISENSE_CLASSIFIER_LOG_PROMPT=on for
# developers who explicitly want it (e.g., during classifier tuning).
# Entire logger disabled via INTELLISENSE_CLASSIFIER_LOG=off.
if [ "${INTELLISENSE_CLASSIFIER_LOG:-on}" != "off" ]; then
    LOG_DIR="${INTELLISENSE_CLASSIFIER_LOG_DIR:-$HOME/.claude-intellisense}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    LOG_FILE="$LOG_DIR/classifier-decisions.jsonl"

    # PROMPT_HASH was computed at the top of this script (used for cache
    # invalidation + classification.json binding). Reuse it here so we don't
    # double-spawn shasum just for the log.
    PROMPT_LEN="${#PROMPT}"

    # Opt-in raw prompt preview (default: empty)
    PROMPT_PREVIEW=""
    if [ "${INTELLISENSE_CLASSIFIER_LOG_PROMPT:-off}" = "on" ]; then
        PROMPT_PREVIEW="${PROMPT:0:120}"
    fi

    # capture decision-time runtime for p50/p95/p99 telemetry.
    # Uses EPOCHREALTIME (zero-spawn). null when bash < 5 (no timing rather
    # than fork python3 — that fork dominated the hook's own runtime).
    HOOK_RUNTIME_MS_STR="null"
    if [ -n "$HOOK_START_MS" ] && [ -n "${EPOCHREALTIME:-}" ]; then
        NOW_MS="${EPOCHREALTIME/./}"
        NOW_MS="${NOW_MS%???}"
        HOOK_RUNTIME_MS_STR=$((NOW_MS - HOOK_START_MS))
    fi

    jq -nc \
        --arg ts "$DECISION_TS" \
        --arg sid "$SESSION_ID" \
        --arg cwd "$CWD" \
        --arg hash "$PROMPT_HASH" \
        --argjson plen "$PROMPT_LEN" \
        --arg preview "$PROMPT_PREVIEW" \
        --arg tier "$TIER" \
        --arg mode "$MODE" \
        --argjson confidence "$CONFIDENCE" \
        --argjson reasoning "$REASONING_JSON" \
        --argjson runtime_ms "$HOOK_RUNTIME_MS_STR" \
        '{
            ts: $ts,
            session_id: $sid,
            cwd: $cwd,
            prompt_hash: $hash,
            prompt_length: $plen,
            prompt_preview: (if $preview == "" then null else $preview end),
            tier: $tier,
            mode: $mode,
            confidence: $confidence,
            reasoning: $reasoning,
            runtime_ms: $runtime_ms
        }' >>"$LOG_FILE" 2>/dev/null || true
fi

# ─── Build additionalContext payload ──────────────────────────────────────────

CONTENT_KEY="tier_${TIER}_${MODE}"
FALLBACK_KEY="tier_${TIER}_default"
FALLBACK_KEY2="tier_${TIER}"
CONTENT_FILES=$(jq -r ".load_files_by_classification[\"$CONTENT_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY\"] // .load_files_by_classification[\"$FALLBACK_KEY2\"] // [] | .[]" "$RULES_FILE" 2>/dev/null)

COMBINED=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -f "$CONTENT_DIR/$f" ]; then
        COMBINED+="$(cat "$CONTENT_DIR/$f")"$'\n\n'
    fi
done <<<"$CONTENT_FILES"

# ─── Settings staleness warning ─────────────────────────
# When ~/.claude/settings.json is older than the source template, existing
# install hasn't picked up the latest hook config. Emit a warning prepended
# to additionalContext so it's visible to the developer. ONCE PER SESSION:
# every distinct prompt is a cache-miss, so the previous "naturally rate-limited"
# assumption was false and the banner fired on nearly every prompt. A per-session
# marker dedupes it to a single appearance. If the marker can't be written, it
# safely falls back to the old behaviour (warn each time).
STALE_WARNING=""
STALE_MARKER="${TMPDIR:-/tmp}/intellisense-stale-warned-${SESSION_ID:-nosession}"
SETTINGS_FILE_CHECK="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
TEMPLATE_FILE_CHECK="${INTELLISENSE_SETUP_PATH:-$HOME/intellisense}/.claude/settings.json.template"
if [ ! -f "$STALE_MARKER" ] && [ -f "$SETTINGS_FILE_CHECK" ] && [ -f "$TEMPLATE_FILE_CHECK" ]; then
    # Cross-platform mtime: GNU `stat -c %Y` first — GNU `stat -f` means "filesystem status" and
    # prints garbage instead of failing; BSD rejects -c cleanly, so the fallback is safe
    SET_MTIME=$(stat -c %Y "$SETTINGS_FILE_CHECK" 2>/dev/null || stat -f %m "$SETTINGS_FILE_CHECK" 2>/dev/null)
    TPL_MTIME=$(stat -c %Y "$TEMPLATE_FILE_CHECK" 2>/dev/null || stat -f %m "$TEMPLATE_FILE_CHECK" 2>/dev/null)
    if [ -n "$SET_MTIME" ] && [ -n "$TPL_MTIME" ] && [ "$TPL_MTIME" -gt "$SET_MTIME" ]; then
        STALE_WARNING="[intellisense NOTICE] Your ~/.claude/settings.json is older than the intellisense template ($TEMPLATE_FILE_CHECK). Run \`bash ${INTELLISENSE_SETUP_PATH:-/path/to/intellisense}/setup.sh --non-interactive --yes\` to refresh hooks and pick up the latest gate behavior."$'\n\n'
        : > "$STALE_MARKER" 2>/dev/null || true
    fi
fi

# ─── Build additionalContext payload ──────────────────────────────────────────
# (CONTENT_KEY/FALLBACK_KEY/CONTENT_FILES/COMBINED already computed above)

if [ -n "$COMBINED" ] || [ -n "$STALE_WARNING" ]; then
    REASONING_TEXT=$(printf -- '- %s\n' "${REASONING[@]}")
    HEADS_UP=$(_contract_heads_up "$TIER" "$CLASSIFICATION_ID")
    HEADER="[intellisense classifier] Detected: Tier=$TIER mode=$MODE confidence=$CONFIDENCE
Reasoning:
$REASONING_TEXT
Override (human-driven, audited): if this classification is wrong, the developer (not Claude) can run \`/intellisense reclassify\` or the override script with --reason='<rationale>'; every override is logged to ~/.claude-intellisense/classifier-overrides.jsonl. Claude must NOT silently self-downgrade.${HEADS_UP}"
    emit_context "${STALE_WARNING}${HEADER}"$'\n\n'"${COMBINED}"
fi

emit_no_context
