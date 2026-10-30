#!/usr/bin/env bash
# preToolUse-contract-gate.sh — Layer 2 contract enforcement for intellisense
#
# Invoked by Claude Code as a PreToolUse hook on:
#   Edit | Write | MultiEdit | NotebookEdit | Bash
#
# Decides whether a tool call should be allowed or blocked based on:
#   1. .intellisense/session/** + .intellisense/contracts/** allowlist (always pass — prevents /contract deadlock)
#   2. session classification (Tier 0 passes; Tier 1+ requires valid contract)
#   3. gate mode (pilot warns; enforced blocks on missing classification)
#   4. validator result (exit 1|2|3 translated to wrapper exit 2)
#
# Hook IO contract (Claude Code):
#   stdin  : JSON { tool_name, tool_input, session_id, cwd, ... }
#   stdout : JSON { hookSpecificOutput: { ... permissionDecision: "deny", permissionDecisionReason: "..." } }
#   exit 0 : allow
#   exit 2 : block (combined with stdout JSON)
#
# Two-mode rollout via ~/.claude/settings.json `intellisense.gate_mode`:
#   "pilot"    (default) — missing classification → allow + stderr warn
#   "enforced"           — missing classification → block

set -uo pipefail

# ─── Hook performance telemetry ─────────────────────────────────
# Goal: cross-machine p50/p95/p99 for the gate hook. Hard constraint: zero
# measurable overhead on the gate's hot path — devs already feel the gate's
# ~40ms baseline; we must not add to it.
#
# Implementation: EXIT trap installed ONLY when bash supports EPOCHREALTIME
# (bash 5+, zero-spawn time read). On bash 3.2 (default macOS), no trap is
# installed — telemetry is opt-in by upgrading bash. The trap itself uses
# printf (no jq spawn) and backgrounds the file write so the gate exits
# without waiting on IO.
GATE_DECISION="unknown"  # set by die_allow / die_block / warn_allow
if [ -n "${EPOCHREALTIME:-}" ]; then
    GATE_HOOK_START_MS="${EPOCHREALTIME/./}"
    GATE_HOOK_START_MS="${GATE_HOOK_START_MS%???}"

    _gate_perf_log() {
        local rc=$?
        local now_ms="${EPOCHREALTIME/./}"
        now_ms="${now_ms%???}"
        local runtime_ms=$((now_ms - GATE_HOOK_START_MS))
        local log_dir="${INTELLISENSE_GATE_LOG_DIR:-$HOME/.claude-intellisense}"
        local log_file="$log_dir/contract-gate-decisions.jsonl"
        # Tool/decision are internal strings (from Claude Code stdin payload
        # and local assignment); never user-controlled. printf avoids jq spawn.
        # Backgrounded write so gate exits without waiting on IO.
        local ts; ts="$(date -u +%FT%TZ 2>/dev/null)"
        (
            mkdir -p "$log_dir" 2>/dev/null
            printf '{"ts":"%s","hook":"preToolUse-contract-gate","tool":"%s","decision":"%s","runtime_ms":%d,"exit_code":%d}\n' \
                "$ts" "${GATE_TOOL_NAME:-unknown}" "$GATE_DECISION" "$runtime_ms" "$rc" \
                >>"$log_file" 2>/dev/null
        ) &
        disown 2>/dev/null || true
    }
    trap _gate_perf_log EXIT
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

die_allow() {
    # Allow the tool call. No JSON needed.
    GATE_DECISION="allow"
    exit 0
}

die_block() {
    # Block the tool call. Emit JSON; exit 2.
    GATE_DECISION="block"
    local reason="$1"
    jq -n --arg reason "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
    exit 2
}

warn_allow() {
    # Allow but show a stderr warning (pilot mode advisory).
    GATE_DECISION="warn"
    echo "intellisense: $1" >&2
    exit 0
}

block_or_warn() {
    # Mode-aware enforcement helper. In pilot mode: warn + allow. In enforced
    # mode: block. The gate_mode global is set before this function is called.
    # NOTE: audit-chain decisions (missing/invalid
    # contract, wrong classification_id, lifecycle state, scope drift, library
    # missing, BASH+no-classification) MUST use audit_chain_block_or_warn below.
    # This helper now governs only non-audit-chain advisories.
    local reason="$1"
    if [ "$GATE_MODE" = "enforced" ]; then
        die_block "$reason"
    fi
    warn_allow "[pilot] $reason"
}

# ─── Audit-chain enforcement ────────────────────────
# A separate setting `intellisense.audit_chain_enforcement` (default 'enforced')
# governs audit-chain decisions independently of `intellisense.gate_mode`, so
# gate_mode=pilot never degrades audit-chain failures to warn-and-allow on
# Tier 1+ work. Pilot mode is appropriate for heuristic
# signals (graph freshness, impact analysis, settings freshness, Tier 0
# missing-classification advisory). Audit-chain controls are the integrity
# backbone of intellisense and must enforce regardless of pilot status on advisories.

audit_chain_mode() {
    # Read intellisense.audit_chain_enforcement; default 'enforced'.
    # Defaults to enforced on: missing key, invalid value, missing/unreadable
    # settings file (tested by tests/test_contract_gate.sh::Test 43a-c).
    local mode='enforced'
    if [ -f "$SETTINGS_FILE" ]; then
        local from_file
        from_file=$(jq -r '.intellisense.audit_chain_enforcement // empty' "$SETTINGS_FILE" 2>/dev/null)
        if [ "$from_file" = "warn" ] || [ "$from_file" = "enforced" ]; then
            mode="$from_file"
        fi
    fi
    printf '%s' "$mode"
}

_json_escape() {
    # Minimal JSON string escaper for the jq-free audit fallback: backslash
    # and double-quote. Values here are paths/branch/tool names — control
    # characters are out of threat model (sed is guaranteed cheaper than jq).
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_audit_chain_log_warn() {
    # Append a JSONL row to ~/.claude-intellisense/audit-chain-warnings.jsonl so every
    # explicit opt-out (audit_chain_enforcement=warn) is auditable. Best-effort
    # but LOUD on failure: if writing the audit row fails (unwritable dir, disk
    # full), emit a secondary stderr line so the developer + any log scraper
    # sees that the audit row was attempted-but-not-persisted.
    # We still return 0 because warn-mode is break-glass and must not turn into
    # a hard block on a logging fault.
    #
    # jq-free fallback: the warn-allow hint
    # promises every break-glass allow is JSONL-audited. That must hold on
    # exactly the machines where jq is MISSING (the no-jq fail-closed path
    # calls this), so the row is printf-built when jq is unavailable.
    # INTELLISENSE_TEST_SIMULATE_NO_JQ=1 forces the fallback for tests.
    local reason="$1"
    local log_dir="${INTELLISENSE_AUDIT_CHAIN_LOG_DIR:-$HOME/.claude-intellisense}"
    local log_file="$log_dir/audit-chain-warnings.jsonl"
    local logged=0
    if mkdir -p "$log_dir" 2>/dev/null; then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if [ "${INTELLISENSE_TEST_SIMULATE_NO_JQ:-0}" != "1" ] && command -v jq >/dev/null 2>&1; then
            if jq -nc \
                --arg ts "$ts" \
                --arg cwd "${CWD:-}" \
                --arg branch "${CURRENT_BRANCH:-}" \
                --arg sid "${SESSION_ID:-}" \
                --arg tool "${TOOL_NAME:-}" \
                --arg reason "$reason" \
                '{ts: $ts, cwd: $cwd, branch: $branch, session_id: $sid, tool_name: $tool, reason: $reason}' \
                >> "$log_file" 2>/dev/null; then
                logged=1
            fi
        else
            if printf '{"ts":"%s","cwd":"%s","branch":"%s","session_id":"%s","tool_name":"%s","reason":"%s"}\n' \
                "$(_json_escape "$ts")" \
                "$(_json_escape "${CWD:-}")" \
                "$(_json_escape "${CURRENT_BRANCH:-}")" \
                "$(_json_escape "${SESSION_ID:-}")" \
                "$(_json_escape "${TOOL_NAME:-}")" \
                "$(_json_escape "$reason")" \
                >> "$log_file" 2>/dev/null; then
                logged=1
            fi
        fi
    fi
    if [ "$logged" = "0" ]; then
        # Loud secondary signal — the audit trail is best-effort, not silent.
        echo "intellisense: [audit-chain warn] audit log write failed (path: $log_file). Warn-mode allows the edit, but the JSONL audit row was NOT persisted." >&2
    fi
    return 0
}

audit_chain_block_or_warn() {
    # Audit-chain enforcement helper. Default: BLOCK regardless of gate_mode.
    # Opt-out (audit_chain_enforcement=warn): warn-and-allow, loud + audited.
    # Every reason string carries the setting name so developers know what
    # knob is in play.
    local reason="$1"
    local hint=" (controlled by intellisense.audit_chain_enforcement; default=enforced. Set to 'warn' ONLY for break-glass incident recovery — every warn is JSONL-audited at ~/.claude-intellisense/audit-chain-warnings.jsonl.)"
    if [ "$(audit_chain_mode)" = "warn" ]; then
        echo "intellisense: [audit-chain warn] $reason" >&2
        _audit_chain_log_warn "$reason"
        exit 0
    fi
    die_block "$reason$hint"
}

# ─── Routing telemetry writer ─────────
# Append per-escalation events to .intellisense/session/<sid>.routing.jsonl whenever
# path-tier or policy-tier raises the effective tier above the prompt tier.
# Best-effort: never fails the gate, never blocks an edit, no stderr on
# internal failures. Reader is hooks/prepare-commit-msg (per-commit trailer)
# plus scripts/lib/heartbeat-payload.sh (daily aggregate).
#
# Event schema (one JSON object per line):
#   {event_id, ts, kind:"escalation", from_tier, to_tier, trigger, reason, phase}
# trigger enum: "path_pattern" | "policy_floor"
# reason enum:  the reason of a Tier 2+ rule in the policy, "tier1_infra", "policy_minimum_tier"
# phase  enum:  "implement" | "commit" | "unknown"
#
# Dedup: repeated edits to the same Tier 2 file within one
# session must not generate duplicate rows. event_id is a stable hash over
# {session_id, from_tier, to_tier, trigger, reason} — same logical escalation
# yields the same id, so we use the existing JSONL as the dedup state. A
# stronger later escalation (Tier 0→1 then Tier 0→2) hashes to a different id
# and is appended normally. `phase` and `ts` deliberately NOT in the dedup key
# (they're observational metadata, not event identity).

_routing_path_reason() {
    # Echo the reason of the first Tier 2+ rule the engine matched for AFFECTED_PATHS, else
    # "tier1_infra" when the paths are Tier 1, else "none". The engine holds the rules.
    local paths="$1" engine json
    engine="$(intellisense_engine 2>/dev/null)"
    [ -n "$engine" ] || { echo "none"; return 0; }
    set --
    while IFS= read -r p; do
        [ -n "$p" ] && set -- "$@" "$p"
    done <<<"$paths"
    [ "$#" -gt 0 ] || { echo "none"; return 0; }
    json="$("$engine" classify --dir "${INTELLISENSE_TIER_DIR:-.}" --format json "$@" 2>/dev/null)" || { echo "none"; return 0; }
    printf '%s' "$json" | jq -r '
        ([.files[] | select(.tier >= 2)] | first | .reason) //
        (if ([.files[] | select(.tier == 1)] | length) > 0 then "tier1_infra" else "none" end)' 2>/dev/null || echo "none"
}

_routing_infer_phase() {
    # Coarse phase inference from the gated tool. Bash with `git commit` is
    # the only meaningful split today; finer per-skill phase tracking is a
    # separate work item (out-of-scope notes).
    case "${TOOL_NAME:-}" in
        Edit|Write|MultiEdit|NotebookEdit) echo "implement" ;;
        Bash)
            if [[ "${BASH_CMD_STRIPPED:-}" =~ (^|[[:space:]])git[[:space:]]+commit ]]; then
                echo "commit"
            else
                echo "implement"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

_routing_event_id() {
    # Stable per-session event id: sha1(session_id|from|to|trigger|reason),
    # truncated to 16 hex chars. Same logical escalation re-hashes to the same
    # id; a stronger escalation (different to_tier or trigger) re-hashes
    # differently. shasum is in /usr/bin on macOS and in perl-core on Linux;
    # sha1sum is the GNU coreutils alternative. If both are missing we
    # degrade to an empty event_id and the row is still written — readers
    # then fall back to the {session_file, from, to, trigger, reason} key.
    local sid="$1" from="$2" to="$3" trigger="$4" reason="$5"
    local raw
    raw=$(printf '%s|%s|%s|%s|%s' "$sid" "$from" "$to" "$trigger" "$reason")
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$raw" | shasum -a 1 2>/dev/null | awk '{print substr($1,1,16)}'
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$raw" | sha1sum 2>/dev/null | awk '{print substr($1,1,16)}'
    fi
    # No hasher available → caller receives empty stdout.
}

_record_routing_event() {
    # Append one JSONL event. Returns 0 on every path; on any failure (missing
    # SESSION_ID, missing jq, unwritable dir, mkdir fail) the function exits
    # silently. Telemetry must never block an edit.
    #
    # Dedup contract: if an event with the same event_id already
    # exists in this session's routing.jsonl, the function returns without
    # appending. Failure modes (corrupt file, grep error, missing hasher) all
    # degrade to "write anyway" — over-counting is preferable to dropping
    # genuinely new events.
    local kind="$1" from="$2" to="$3" trigger="$4" reason="$5" phase="$6"
    [ -z "${SESSION_ID:-}" ] && return 0
    [ -z "${INTELLISENSE_DIR:-}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0
    mkdir -p "$INTELLISENSE_DIR" 2>/dev/null || return 0
    local routing_file="$INTELLISENSE_DIR/${SESSION_ID}.routing.jsonl"

    local event_id
    event_id=$(_routing_event_id "$SESSION_ID" "$from" "$to" "$trigger" "$reason" 2>/dev/null)

    # Dedup: same event_id already on file → skip. Best-effort: any grep
    # failure falls through to the write path, which is the safe direction.
    if [ -n "$event_id" ] && [ -f "$routing_file" ]; then
        if grep -Fq "\"event_id\":\"$event_id\"" "$routing_file" 2>/dev/null; then
            return 0
        fi
    fi

    local line
    line=$(jq -nc \
        --arg event_id "$event_id" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg kind "$kind" \
        --argjson from "$from" \
        --argjson to "$to" \
        --arg trigger "$trigger" \
        --arg reason "$reason" \
        --arg phase "$phase" \
        '{event_id:$event_id, ts:$ts, kind:$kind, from_tier:$from, to_tier:$to, trigger:$trigger, reason:$reason, phase:$phase}' 2>/dev/null) || return 0
    printf '%s\n' "$line" >> "$routing_file" 2>/dev/null || true
    return 0
}

_check_settings_freshness() {
    # Compares intellisense.config_version in local settings.json against the central
    # template. On mismatch, prints a throttled stderr warning so the developer
    # re-runs setup.sh to pick up the latest policy values (gate_mode,
    # graph_enforcement, etc.). Solves the propagation problem where central
    # template edits don't reach 200+ dev machines via git pull alone.
    #
    # Failure-isolated: any internal error short-circuits to return 0 — a
    # broken freshness check MUST NEVER block an edit. The check is purely
    # informational (stderr), never blocking.
    #
    # Overrides (for tests + per-dev escape hatch):
    #   INTELLISENSE_SKIP_FRESHNESS_CHECK=1   silence the check entirely
    #   INTELLISENSE_TEMPLATE_FILE            override template path
    #   INTELLISENSE_FRESHNESS_TIMESTAMP_FILE override throttle state file
    #   INTELLISENSE_FRESHNESS_THROTTLE_SECONDS override throttle window (default 14400 = 4h)
    [ "${INTELLISENSE_SKIP_FRESHNESS_CHECK:-0}" = "1" ] && return 0

    local template_file settings_file timestamp_file throttle_seconds
    template_file="${INTELLISENSE_TEMPLATE_FILE:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/.claude/settings.json.template}"
    settings_file="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
    timestamp_file="${INTELLISENSE_FRESHNESS_TIMESTAMP_FILE:-$HOME/.claude-intellisense/last-freshness-warning}"
    throttle_seconds="${INTELLISENSE_FRESHNESS_THROTTLE_SECONDS:-14400}"

    [ -f "$template_file" ] || return 0
    [ -f "$settings_file" ] || return 0

    local template_version local_version
    template_version=$(jq -r '.intellisense.config_version // empty' "$template_file" 2>/dev/null) || return 0
    local_version=$(jq -r '.intellisense.config_version // empty' "$settings_file" 2>/dev/null) || return 0

    # Template has no version → nothing authoritative to compare; silent.
    [ -n "$template_version" ] || return 0

    # Versions match → no drift.
    [ "$local_version" = "$template_version" ] && return 0

    # Drift detected. Apply throttle if a recent warning exists.
    if [ -f "$timestamp_file" ]; then
        local last_warned now elapsed
        last_warned=$(cat "$timestamp_file" 2>/dev/null)
        now=$(date +%s 2>/dev/null)
        if [[ "$last_warned" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]]; then
            elapsed=$((now - last_warned))
            [ "$elapsed" -lt "$throttle_seconds" ] && return 0
        fi
    fi

    # Emit warning to stderr and update throttle timestamp.
    echo "intellisense: your ~/.claude/settings.json (intellisense.config_version='${local_version:-absent}') is older than the central template (intellisense.config_version='$template_version'). Run: cd \$INTELLISENSE_SETUP_PATH && git pull && bash setup.sh   (silence: export INTELLISENSE_SKIP_FRESHNESS_CHECK=1)" >&2

    mkdir -p "$(dirname "$timestamp_file")" 2>/dev/null
    date +%s > "$timestamp_file" 2>/dev/null

    return 0
}

# ─── Branch-freshness check (plan v7) ──────────────────────
# Pre-edit half of the sync gate. Detects whether the working branch is behind
# the branch it will merge INTO, on the FIRST structured-tool edit of a session.
#
# FAILURE-ISOLATED: this returns 0 on ANY internal problem (no git tree, no
# session, lib missing, resolve/fetch failure). The ONLY non-return outcomes are
# deliberate die_block (exit 2) calls:
#   - enforced mode + behind on a blockable-confidence target, OR
#   - enforced mode + a malformed EXPLICIT manifest integration_ref (config
#     error, I7 — distinct from an infra failure, which always fails open).
#
# It NEVER calls die_allow/warn_allow — those would exit 0 and SKIP the contract
# enforcement that follows. The warn path echoes to stderr and returns 0 so the
# rest of the gate runs normally.
_sync_write_marker() {
    # _sync_write_marker <status> <target> <confidence> — atomic temp+rename
    # (prevents corruption, not double-fetch). Best-effort; never fails caller.
    local mstatus="$1" target="$2" conf="$3"
    [ -n "$SESSION_ID" ] || return 0
    local dir="$CWD/.intellisense/session"
    mkdir -p "$dir" 2>/dev/null || return 0
    local now tmp marker="$dir/${SESSION_ID}.sync-freshness-checked"
    now=$(date +%s 2>/dev/null) || return 0
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    tmp=$(mktemp 2>/dev/null) || return 0
    if printf '{"status":"%s","ts":%s,"target":"%s","confidence":"%s"}\n' \
         "$mstatus" "$now" "$target" "$conf" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

_check_branch_freshness() {
    [ "${INTELLISENSE_SKIP_SYNC_CHECK:-0}" = "1" ] && return 0
    case "$TOOL_NAME" in
        Edit|Write|MultiEdit|NotebookEdit) ;;
        *) return 0 ;;
    esac
    [ -n "$SESSION_ID" ] || return 0
    [ -n "$CWD" ] || return 0

    # Skip intellisense session bookkeeping writes (superset of the G4 exact-marker skip:
    # the contract, the freshness marker itself, classification.json, etc. are
    # operational state, not source edits).
    local target_path
    target_path=$(jq -r '.tool_input.file_path // empty' <<<"$PAYLOAD" 2>/dev/null)
    case "$target_path" in
        .intellisense/session/*|*/.intellisense/session/*|.intellisense/contracts/*|*/.intellisense/contracts/*) return 0 ;;
    esac

    git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local settings lib
    settings="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
    lib="${INTELLISENSE_SYNC_REF_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib/sync-ref.sh}"
    [ -f "$lib" ] || return 0
    # shellcheck source=lib/sync-ref.sh
    . "$lib" 2>/dev/null || return 0

    local mode; mode=$(sync_enforcement_mode "$settings")
    [ "$mode" = "off" ] && return 0

    # Per-status TTL skip (G5): once-per-session within the marker's TTL.
    local marker="$CWD/.intellisense/session/${SESSION_ID}.sync-freshness-checked"
    if [ -f "$marker" ] && command -v jq >/dev/null 2>&1; then
        local mst mts ttl now age
        mst=$(jq -r '.status // empty' "$marker" 2>/dev/null)
        mts=$(jq -r '.ts // empty' "$marker" 2>/dev/null)
        case "$mts" in ''|*[!0-9]*) mts="" ;; esac
        if [ -n "$mst" ] && [ -n "$mts" ]; then
            ttl=$(sync_ttl_minutes "$settings" "$mst")
            now=$(date +%s 2>/dev/null)
            case "$now" in ''|*[!0-9]*) now="" ;; esac
            if [ -n "$now" ]; then
                age=$(( (now - mts) / 60 ))
                [ "$age" -le "$ttl" ] && return 0
            fi
        fi
    fi

    local rec st conf remote branch eoi
    rec=$(sync_resolve_integration_ref "$CWD" 1)   # pre-edit always allows live gh
    st=$(sync_rec_status "$rec")
    conf=$(sync_rec_confidence "$rec")
    remote=$(sync_rec_remote "$rec")
    branch=$(sync_rec_branch "$rec")
    eoi=$(sync_enforce_on_inferred "$settings")

    case "$st" in
        config_error)
            local shown="${remote}${branch:+/$branch}"
            local cmsg="intellisense sync: .intellisense/manifest.json integration_ref is invalid ('$shown'). This is a CONFIG error, not a network problem — fix it to a valid remote/branch that passes 'git check-ref-format', or remove the key to fall back to inference."
            if [ "$mode" = "enforced" ]; then
                die_block "$cmsg"
            fi
            echo "$cmsg" >&2
            _sync_write_marker fail_open "$shown" "explicit"
            return 0
            ;;
        infra|none)
            echo "intellisense sync: could not resolve/verify an integration ref (status=$st); skipping freshness check (fail-open)." >&2
            _sync_write_marker fail_open "${remote}/${branch}" "${conf:-unknown}"
            return 0
            ;;
    esac

    # Targeting nudge (once/session): when the integration branch was only
    # inferred/guessed (no explicit integration_ref or PR base), tell the dev how
    # to pin it. This is the safety net for release-branch workflows where
    # inference would otherwise silently target the repo default (Case 3).
    if [ "$conf" != "explicit" ]; then
        echo "intellisense sync: integration target '$remote/$branch' was resolved by $conf. If you merge into a non-default branch (e.g. a release branch), set \".intellisense/manifest.json\" integration_ref so freshness targets the right branch." >&2
    fi

    local behind
    behind=$(sync_fetch_and_behind "$CWD" "$remote" "$branch")
    if [ "$behind" = "infra" ]; then
        echo "intellisense sync: bounded fetch/verify of $remote/$branch failed; skipping freshness check (fail-open)." >&2
        _sync_write_marker fail_open "$remote/$branch" "$conf"
        return 0
    fi
    if [ "$behind" = "0" ]; then
        _sync_write_marker fresh "$remote/$branch" "$conf"
        return 0
    fi

    # behind > 0
    local decision dirty="" dirtyline=""
    decision=$(sync_should_block "$mode" "$conf" "$eoi")
    git -C "$CWD" diff --quiet 2>/dev/null || dirty=1
    git -C "$CWD" diff --cached --quiet 2>/dev/null || dirty=1
    [ -n "$dirty" ] && dirtyline=" If your working tree is dirty, commit or stash manually first, then run fetch/rebase."
    local msg="intellisense sync: your branch is $behind commit(s) behind $remote/$branch (the branch you will merge INTO). Pull before continuing: run \`git fetch $remote $branch\` then \`git rebase $remote/$branch\`.${dirtyline}"

    if [ "$decision" = "block" ]; then
        # No marker on block: after you pull, the retried edit re-checks, finds
        # behind=0, and allows.
        die_block "$msg (confidence=$conf, mode=enforced; set intellisense.sync_enforcement=warn to downgrade)"
    fi
    echo "$msg" >&2
    _sync_write_marker warned_behind "$remote/$branch" "$conf"
    return 0
}

# ─── Read stdin payload ───────────────────────────────────────────────────────

# jq missing → fail CLOSED. Allowing here would silently disable ALL gate
# enforcement on a degraded install. Without jq the gate
# cannot classify tier or validate contracts, so missing jq is an audit-chain
# integrity failure: block with remediation. audit_chain_enforcement=warn
# remains the audited break-glass (read jq-free via grep, since
# audit_chain_mode() itself needs jq). Remediation is trivial: install jq.
# INTELLISENSE_TEST_SIMULATE_NO_JQ=1 is a test-only switch that forces this path; it
# can only make the gate stricter (block) or reach the same warn-allow the
# break-glass already grants, never weaker than the jq-present flow.
if [ "${INTELLISENSE_TEST_SIMULATE_NO_JQ:-0}" = "1" ] || ! command -v jq >/dev/null 2>&1; then
    _jq_missing_reason="intellisense contract gate: jq not on PATH — the gate cannot classify tier or validate contracts, so edits are blocked (fail-closed). Fix: install jq (macOS: brew install jq | Debian/Ubuntu: apt-get install jq), then retry. Break-glass for incident recovery ONLY: set intellisense.audit_chain_enforcement to warn in ~/.claude/settings.json (every warn-allow is JSONL-audited)."
    _jq_settings="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
    if [ -f "$_jq_settings" ] \
        && grep -Eq '"audit_chain_enforcement"[[:space:]]*:[[:space:]]*"warn"' "$_jq_settings"; then
        echo "intellisense: [audit-chain warn] $_jq_missing_reason" >&2
        _audit_chain_log_warn "jq missing on PATH (break-glass warn-mode allow)"
        GATE_DECISION="warn"
        exit 0
    fi
    # die_block emits its deny JSON via jq, which is unavailable here; build
    # the payload with printf. The reason is a fixed string above (no user
    # input); escape embedded double-quotes for JSON safety.
    GATE_DECISION="block"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "$(printf '%s' "$_jq_missing_reason" | sed 's/"/\\"/g')"
    exit 2
fi

PAYLOAD=$(cat)
if [ -z "$PAYLOAD" ]; then
    die_allow
fi

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")
GATE_TOOL_NAME="$TOOL_NAME"  # expose to perf log trap
SESSION_ID=$(jq -r '.session_id // empty' <<<"$PAYLOAD")
CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD")

if [ -z "$TOOL_NAME" ]; then
    die_allow
fi

# Settings-freshness check: informational stderr warning when local settings.json
# is older than the central template. Never blocks the edit (failure-isolated).
# Placed BEFORE path extraction so it fires for all tool invocations including
# read-only Bash that would otherwise exit early via the mutation-pattern check.
_check_settings_freshness || true

# Branch-freshness check (plan v7): structured-tool edits only,
# fail-open. May die_block (exit 2) in enforced mode when behind, or on a
# malformed explicit manifest ref (config error, I7); otherwise returns 0 and
# the normal contract logic below proceeds. Bare call (no `|| true`): the
# function only returns 0 or exits via die_block on its own terms.
_check_branch_freshness

# ─── Path / command extraction ────────────────────────────────────────────────

# AFFECTED_PATHS is a newline-separated list (may be empty for read-only bash).
AFFECTED_PATHS=""
BASH_CMD=""

case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        AFFECTED_PATHS=$(jq -r '.tool_input.file_path // empty' <<<"$PAYLOAD")
        ;;
    MultiEdit)
        AFFECTED_PATHS=$(jq -r '.tool_input.file_path // empty' <<<"$PAYLOAD")
        ;;
    Bash)
        BASH_CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
        if [ -z "$BASH_CMD" ]; then
            die_allow
        fi
        # Strip quoted regions BEFORE pattern matching, so literals inside
        # double or single quotes (e.g. `echo "use sed -i to fix"`) don't
        # false-positive. Replace with a sentinel placeholder (not deletion)
        # to PRESERVE token position — critical for sed expression parsing.
        # Without the sentinel, `sed -i 's/foo/bar/' file1.txt file2.txt`
        # becomes `sed -i  file1.txt file2.txt`, awk treats file1.txt as
        # the expression, file2.txt as the only file. With the sentinel,
        # `sed -i __INTELLISENSE_QUOTED__ file1.txt file2.txt` → both files extracted.
        # Limitation: doesn't handle escaped quotes; good enough for v1 —
        # the goal is defense against Claude's normal output, not adversarial
        # bypass.
        # collapse newlines/CR to spaces BEFORE the line-based
        # quote strip. sed matches per line, so a multi-line quoted region
        # (e.g. `bd create --description="## Why<newline>...mentions a/path.json
        # in prose<newline>..."`) was never stripped — its prose, including any
        # filename, leaked to the path extractor and produced a bogus
        # out-of-scope-write block. Collapsing first lets `"[^"]*"` span what
        # were separate lines. Path extraction is whitespace-tokenized, so
        # newline->space changes nothing downstream for legitimate targets.
        BASH_CMD_ONELINE=$(printf '%s' "$BASH_CMD" | tr '\n\r' '  ')
        BASH_CMD_STRIPPED=$(printf '%s' "$BASH_CMD_ONELINE" | sed -E "s/\"[^\"]*\"/__INTELLISENSE_QUOTED__/g; s/'[^']*'/__INTELLISENSE_QUOTED__/g")

        # after quote-stripping, neutralize two further sources of
        # path-extraction false-positives that blocked legitimate commands:
        #   - inline/trailing shell comments (' #...' to EOL) — comment prose is
        #     never a mutation target.
        #   - code arrows '->' and '=>' — their '>' was mis-read as a redirect
        #     operator by the extractor below, capturing the next token (e.g.
        #     'a -> b' wrongly captured 'b'). Replaced with a space.
        # Quoted regions are already sentinel-replaced above, so a '#' or '->'
        # inside a string is untouched here.
        BASH_CMD_STRIPPED=$(echo "$BASH_CMD_STRIPPED" \
            | sed -E 's/(^|[[:space:]])#.*$//' \
            | sed -E 's/->/ /g; s/=>/ /g')

        # gh (GitHub CLI) is a network/API tool that never mutates local files.
        # Its args routinely carry PR/issue BODIES — often multi-line heredocs —
        # whose prose the single-line quote-stripper cannot neutralize, leaking
        # '>' redirects and words like 'touch'/'rm' into path extraction and
        # producing bogus "not in contract.files_affected" / no-path blocks
        # Exempt commands that START with `gh`. Known limitation
        # (same posture as the documented eval bypass, Test 11): `gh ... && rm
        # real` chained to a TRAILING local mutation is allowed here; the
        # pre-push hook is the backstop for committed scope drift.
        # Match only the FIRST non-blank line: grep is line-based, so anchoring
        # on the whole (possibly multi-line) command would also fire when `gh`
        # leads a LATER line — wrongly exempting a LEADING mutation like
        # `rm secret.go<newline>gh pr create ...`. First-line-only keeps the
        # exemption to commands that actually START with gh.
        _first_cmd_line=$(printf '%s' "$BASH_CMD_STRIPPED" | grep -vE '^[[:space:]]*$' | head -n1)
        if printf '%s' "$_first_cmd_line" | grep -qE '^[[:space:]]*gh([[:space:]]|$)'; then
            die_allow
        fi

        # Run mutation classifier against stripped command
        PATTERNS_FILE="${INTELLISENSE_BASH_PATTERNS:-$(dirname "${BASH_SOURCE[0]}")/bash-mutation-patterns.txt}"
        if [ ! -f "$PATTERNS_FILE" ]; then
            # Patterns file missing: fail-OPEN with stderr (do not brick developer).
            echo "intellisense contract gate: pattern file not found at $PATTERNS_FILE; allowing bash" >&2
            die_allow
        fi
        TMP_PATTERNS=$(mktemp)
        grep -vE '^[[:space:]]*(#|$)' "$PATTERNS_FILE" >"$TMP_PATTERNS"
        if ! grep -qE -f "$TMP_PATTERNS" <<<"$BASH_CMD_STRIPPED" 2>/dev/null; then
            rm -f "$TMP_PATTERNS"
            die_allow
        fi
        rm -f "$TMP_PATTERNS"

        # Mutation pattern matched. Extract affected paths.
        # Command-specific extraction. Previous
        # implementation passed ALL args through one regex, so `sed -i s/x/y/
        # declared.txt` treated `s/x/y/` as a path; `chmod +x file` treated
        # `+x` as a path; package managers emitted every lockfile variant.
        # Now: per-command parsing that knows which args are paths vs
        # script-expressions vs modes vs package-spec.
        _extract_paths_for_bash() {
            local cmd="$1"
            # Redirects (> path, >> path) — already correct.
            # `;` is in the negated class so `> file; other_cmd` doesn't
            # capture the semicolon (chained-command bug: `/dev/null;` would
            # fail exact-match against the `/dev/null` exempt entry).
            grep -oE '>>?[[:space:]]*[^[:space:]&|<>;]+' <<<"$cmd" | sed -E 's/^>>?[[:space:]]*//'

            # now strip ALL redirect constructs from the command so
            # the per-command arg extractors below never see them. The redirect
            # extractor above already captured redirect TARGETS (including
            # FD-prefixed ones like `2>/dev/null`, which the exempt-filter then
            # drops). Without this strip, a command extractor's `[^|&;]+` class
            # (which includes `>`) swallows a trailing `2>/dev/null` / `2>&1` as a
            # bogus path argument — the false-positive that blocked `rm x 2>/dev/null`.
            cmd=$(sed -E 's/[0-9]*>>?[[:space:]]*[^[:space:]&|<>;]+//g; s/[0-9]+>&[0-9-]+//g' <<<"$cmd")

            # sed -i 'expr' file [file...] — first NON-FLAG arg after -i is
            # the script expression; ALL remaining non-flag args are files.
            # Taking only $NF (last token) would lose files 1..N-1 in
            # multi-file invocations.
            #
            # Known limitation: `sed -i -e expr1 -e expr2 file` will
            # incorrectly treat expr2 as a file (we only mark the FIRST
            # non-flag arg as the expression). Pre-push backstop catches
            # this if the falsely-classified expression isn't in
            # files_affected[].
            if grep -qE '(^|[[:space:]])sed[[:space:]]+-[A-Za-z]*i' <<<"$cmd"; then
                # Extract from `sed` to end-of-command. awk parses tokens:
                #   - Any -flag (-i, -i.bak, -ie, -E, -e, -f, etc.) is skipped.
                #   - -e <expr> and -f <scriptfile>: the NEXT non-flag token
                #     is the expression / script-file ARGUMENT to that flag,
                #     NOT a target file. Skip it too (otherwise
                #     `sed -i -e expr1 -e expr2 file` false-blocks on expr2).
                #   - First remaining non-flag is the sed expression
                #     (literal `s/x/y/` or `__INTELLISENSE_QUOTED__` sentinel).
                #   - All remaining non-flag tokens are files.
                #
                # Defensive fallback: if exactly ONE non-flag token remains
                # (malformed sed with no expression), treat it as the file.
                grep -oE 'sed[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{
                        n = 0
                        expect_flag_arg = 0
                        for (i = 2; i <= NF; i++) {
                            # -e EXPR / -f FILE: expect NEXT token as the arg
                            if ($i == "-e" || $i == "-f") { expect_flag_arg = 1; continue }
                            # Any other -flag (skip silently; no following arg expected)
                            if ($i ~ /^-/) continue
                            # If previous flag was -e or -f, this is its arg (NOT a file)
                            if (expect_flag_arg) { expect_flag_arg = 0; continue }
                            n++; tok[n] = $i
                        }
                        if (n == 1) {
                            print tok[1]                  # malformed-sed fallback
                        } else {
                            for (j = 2; j <= n; j++) print tok[j]  # tok[1] = expr, rest = files
                        }
                    }'
            fi

            # chmod MODE file [file...] / chown OWNER file [file...] — skip
            # the first arg after the command (mode/owner), take the rest.
            if grep -qE '(^|[[:space:]])(chmod|chown)[[:space:]]' <<<"$cmd"; then
                grep -oE '(chmod|chown)[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=3;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # ln -s SRC DST → take DST (the link being created; SRC is read-only)
            # ln SRC DST → same
            if grep -qE '(^|[[:space:]])ln[[:space:]]+(-s[[:space:]]+)?' <<<"$cmd"; then
                grep -oE 'ln[[:space:]]+(-s[[:space:]]+)?[^|&;]+' <<<"$cmd" \
                    | awk '{print $NF}'
            fi

            # mv / cp — non-flag args. mv/cp safely treat first arg as source
            # (read-only) and last as dest (mutation), but mv A B C/ pattern
            # exists. Conservative: include all non-flag args.
            if grep -qE '(^|[[:space:]])(mv|cp)[[:space:]]' <<<"$cmd"; then
                grep -oE '(mv|cp)[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=2;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # rm / rmdir / unlink — all non-flag args
            if grep -qE '(^|[[:space:]])(rm|rmdir|unlink)[[:space:]]' <<<"$cmd"; then
                grep -oE '(rm|rmdir|unlink)[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=2;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # mkdir / touch — all non-flag args
            if grep -qE '(^|[[:space:]])(mkdir|touch)[[:space:]]' <<<"$cmd"; then
                grep -oE '(mkdir|touch)[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=2;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # Formatters/linters — all args that aren't --flags or short flags
            if grep -qE '(^|[[:space:]])(gofmt|prettier|ruff|eslint|black|isort)[[:space:]]' <<<"$cmd"; then
                grep -oE '(gofmt|prettier|ruff|eslint|black|isort)[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=2;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # tee — all non-flag args
            if grep -qE '(^|[[:space:]])tee[[:space:]]' <<<"$cmd"; then
                grep -oE 'tee[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=2;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # Package managers — emit ONLY the manager-specific lockfile +
            # manifest. npm uses package-lock.json (NOT yarn.lock or pnpm).
            if grep -qE '(^|[[:space:]])npm[[:space:]]+(install|i|update|uninstall|remove|audit)' <<<"$cmd"; then
                echo "package.json"
                echo "package-lock.json"
            fi
            if grep -qE '(^|[[:space:]])yarn[[:space:]]+(add|install|upgrade|remove)' <<<"$cmd"; then
                echo "package.json"
                echo "yarn.lock"
            fi
            if grep -qE '(^|[[:space:]])pnpm[[:space:]]+(install|add|update|remove)' <<<"$cmd"; then
                echo "package.json"
                echo "pnpm-lock.yaml"
            fi
            if grep -qE '(^|[[:space:]])composer[[:space:]]+(install|update|require|remove)' <<<"$cmd"; then
                echo "composer.json"
                echo "composer.lock"
            fi
            if grep -qE '(^|[[:space:]])cargo[[:space:]]+(update|add|remove)' <<<"$cmd"; then
                echo "Cargo.toml"
                echo "Cargo.lock"
            fi
            if grep -qE '(^|[[:space:]])bundle[[:space:]]+(install|update)' <<<"$cmd"; then
                echo "Gemfile"
                echo "Gemfile.lock"
            fi
            if grep -qE '(^|[[:space:]])pip[[:space:]]+install' <<<"$cmd"; then
                echo "requirements.txt"
            fi
            if grep -qE '(^|[[:space:]])go[[:space:]]+mod[[:space:]]+(tidy|edit|download)' <<<"$cmd"; then
                echo "go.mod"
                echo "go.sum"
            fi

            # git rm — non-flag args (skip -r, -f etc)
            if grep -qE '(^|[[:space:]])git[[:space:]]+rm[[:space:]]' <<<"$cmd"; then
                grep -oE 'git[[:space:]]+rm[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=3;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi

            # git checkout HEAD -- file [file...] — files after `--`
            if grep -qE '(^|[[:space:]])git[[:space:]]+checkout[[:space:]]+HEAD[[:space:]]+--' <<<"$cmd"; then
                echo "$cmd" \
                    | sed -E 's/.*git[[:space:]]+checkout[[:space:]]+HEAD[[:space:]]+--[[:space:]]+//' \
                    | awk -F'[|&;]' '{print $1}' \
                    | tr ' ' '\n' \
                    | grep -vE '^$|^-'
            fi

            # git restore [--source=X] [--staged] file [file...] — non-flag args
            if grep -qE '(^|[[:space:]])git[[:space:]]+restore[[:space:]]' <<<"$cmd"; then
                grep -oE 'git[[:space:]]+restore[[:space:]]+[^|&;]+' <<<"$cmd" \
                    | awk '{for(i=3;i<=NF;i++) print $i}' \
                    | grep -vE '^-'
            fi
        }
        AFFECTED_PATHS_RAW=$(_extract_paths_for_bash "$BASH_CMD_STRIPPED" 2>/dev/null | sort -u)

        # Filter out non-real-mutation targets: /dev/null, /dev/stderr,
        # /dev/stdout, and anywhere under /tmp/ (ephemeral working files).
        # If ALL extracted paths fall in these exempt locations, treat as
        # no-mutation (read-only effect) and allow.
        AFFECTED_PATHS=""
        ALL_EXEMPT=true
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            case "$p" in
                /dev/null|/dev/stderr|/dev/stdout|/tmp/*|/var/folders/*|/var/tmp/*)
                    # Exempt path; skip
                    ;;
                *)
                    ALL_EXEMPT=false
                    AFFECTED_PATHS+="$p"$'\n'
                    ;;
            esac
        done <<<"$AFFECTED_PATHS_RAW"
        # If we found mutation patterns but every target was exempt, allow.
        if [ "$ALL_EXEMPT" = "true" ] && [ -n "$AFFECTED_PATHS_RAW" ]; then
            die_allow
        fi
        # Strip trailing newline
        AFFECTED_PATHS="${AFFECTED_PATHS%$'\n'}"
        # A bash mutation pattern matched but no path
        # could be extracted (uncommon command shape). Mark this state so the
        # file-in-scope check below treats it as "unknown scope" → block in
        # enforced mode.
        if [ -z "$AFFECTED_PATHS" ]; then
            BASH_MUTATION_NO_PATH=1
        else
            BASH_MUTATION_NO_PATH=0
        fi
        ;;
    *)
        # Unknown tool — allow (matcher should prevent this anyway).
        die_allow
        ;;
esac

# ─── Allowlist check: .intellisense/session/** and .intellisense/contracts/** are always allowed ──

# A path is allowlisted if it begins with .intellisense/session/ or .intellisense/contracts/ (relative) or
# contains them (absolute): writing the contract itself must never need a contract (/contract deadlock). Empty AFFECTED_PATHS means we couldn't extract —
# fall through to tier check, since the bash command IS mutating.
if [ -n "$AFFECTED_PATHS" ]; then
    ALL_IN_ALLOWLIST=true
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            .intellisense/session/*|*/.intellisense/session/*|.intellisense/contracts/*|*/.intellisense/contracts/*)
                ;;
            *)
                ALL_IN_ALLOWLIST=false
                break
                ;;
        esac
    done <<<"$AFFECTED_PATHS"
    if [ "$ALL_IN_ALLOWLIST" = "true" ]; then
        die_allow
    fi
fi

# ─── Read gate mode from ~/.claude/settings.json ──────────────────────────────

SETTINGS_FILE="${INTELLISENSE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
GATE_MODE="pilot"  # default to safe-mode when settings file is unreadable
if [ -f "$SETTINGS_FILE" ]; then
    MODE_FROM_FILE=$(jq -r '.intellisense.gate_mode // empty' "$SETTINGS_FILE" 2>/dev/null)
    if [ "$MODE_FROM_FILE" = "pilot" ] || [ "$MODE_FROM_FILE" = "enforced" ]; then
        GATE_MODE="$MODE_FROM_FILE"
    fi
fi

# ─── Effective-tier library (single source of truth) ─────────────────────────
# effective_tier = max(prompt_tier, changed_path_tier, policy_tier)
# Single shared library; pre-push uses the same definitions. Without this, a
# vague Tier 0 prompt could authorize account/auth/migration edits because the
# gate never inspected the file path.
#
# Audit-chain hardening: if the library is
# unavailable, we cannot prove the path is Tier 0. Falling back to the prompt
# tier would be a silent audit-chain bypass on degraded installs. Fail closed via audit_chain_block_or_warn: enforced
# blocks; opt-out warn allows + writes a JSONL audit row. .intellisense/session/**
# allowlist (above) still passes through so /contract can be run as part of
# recovery without bouncing on this check.

EFFECTIVE_TIER_LIB="${INTELLISENSE_EFFECTIVE_TIER_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib/effective-tier.sh}"
if [ ! -f "$EFFECTIVE_TIER_LIB" ]; then
    audit_chain_block_or_warn "Effective-tier library unavailable at $EFFECTIVE_TIER_LIB; cannot prove this mutation is Tier 0. Re-run setup.sh."
fi
# shellcheck source=lib/effective-tier.sh
. "$EFFECTIVE_TIER_LIB"
# shellcheck source=lib/contract-file.sh
. "$(dirname "$EFFECTIVE_TIER_LIB")/contract-file.sh"
# Tier patterns are anchored to repo-relative paths (^rules/baseline/...), but
# Edit/Write payloads carry absolute paths. Relativize against the repo root
# (and CWD) before tiering, or rules/baseline/security.md reads as Tier 0 and
# the .md fast lane below waves it through.
_tier_root="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "")"
TIER_PATHS=""
while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    for _r in "$_tier_root" "$CWD"; do
        [ -n "$_r" ] || continue
        case "$_p" in "$_r"/*) _p="${_p#"$_r"/}"; break ;; esac
    done
    TIER_PATHS+="$_p"$'\n'
done <<<"$AFFECTED_PATHS"
TIER_PATHS="${TIER_PATHS%$'\n'}"
# The engine resolves paths against the session's repository.
export INTELLISENSE_TIER_DIR="${_tier_root:-$CWD}"
PATH_TIER=$(printf '%s\n' "$TIER_PATHS" | intellisense_changed_path_tier_from_lines)
POLICY_TIER=$(intellisense_policy_tier "$CWD")

# ─── Read classification (file-based; NOT env-var-based) ──────────────────────
# CWD is the repo root for the session; .intellisense lives under it.
INTELLISENSE_DIR="${INTELLISENSE_DIR_OVERRIDE:-$CWD/.intellisense/session}"
CLASSIFICATION_FILE=""
PROMPT_TIER=""
CURRENT_CLASSIFICATION_ID=""

if [ -n "$SESSION_ID" ] && [ -f "$INTELLISENSE_DIR/${SESSION_ID}.classification.json" ]; then
    CLASSIFICATION_FILE="$INTELLISENSE_DIR/${SESSION_ID}.classification.json"
    PROMPT_TIER=$(jq -r '.tier // empty' "$CLASSIFICATION_FILE" 2>/dev/null)
    CURRENT_CLASSIFICATION_ID=$(jq -r '.classification_id // empty' "$CLASSIFICATION_FILE" 2>/dev/null)
fi

# Effective tier = max(prompt_or_0, path, policy). Substituting 0 for empty
# PROMPT_TIER lets path/policy still drive escalation when classification is
# absent (audit-chain hardening: the path-tier early check is the core
# defense against the missing-classification bypass on Tier 1+ paths).
PROMPT_TIER_FOR_EFFECTIVE="${PROMPT_TIER:-0}"
TIER=$(intellisense_effective_tier "$PROMPT_TIER_FOR_EFFECTIVE" "$PATH_TIER" "$POLICY_TIER")
if [ -n "$PROMPT_TIER" ] && [ "$TIER" != "$PROMPT_TIER" ]; then
    # Tier was escalated by path or policy. Surface this so the developer
    # understands why a Tier 0 prompt is asking for a contract.
    echo "intellisense: effective tier=$TIER (prompt=$PROMPT_TIER path=$PATH_TIER policy=$POLICY_TIER). The changed file(s) or repo policy raised the requirement." >&2
fi

# ── Exhibit-D fix: documentation edits are tiered by PATH, not by conversation ──
# A Tier-2 *prompt* (e.g. financial words quoted in the chat) must not force a
# contract on an unrelated doc edit — documentation carries no executable logic.
# When every affected path is an inert doc type, drop the prompt-tier escalation
# and fall back to PATH_TIER. This is FAIL-SAFE: security.md, reasoning-integrity
# .md, migrations/*.sql, and rules/** files are Tier 1-2 BY PATH, so capping at
# PATH_TIER keeps them fully gated — only the spurious prompt-driven escalation
# of genuinely inert docs is removed. Applies only when paths are known and the
# prompt actually escalated the tier above the path tier.
if [ -n "$AFFECTED_PATHS" ] && [ "$TIER" -gt "$PATH_TIER" ]; then
    _doc_only=1
    while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        # Must live under a docs/ directory AND have a doc extension. The
        # docs/ requirement EXCLUDES sensitive markdown outside docs/ (e.g.
        # rules/baseline/security.md, rules/baseline/reasoning-integrity.md) —
        # those are never exempted, even though the path-tier patterns are
        # relative-anchored and may read 0 for an absolute path.
        case "$_p" in
            docs/*|*/docs/*) : ;;
            *) _doc_only=0; break ;;
        esac
        case "$_p" in
            *.md|*.markdown|*.txt|*.rst) : ;;
            *) _doc_only=0; break ;;
        esac
    done <<< "$TIER_PATHS"
    if [ "$_doc_only" = "1" ]; then
        # Remove ONLY the prompt-tier contribution; preserve path AND policy
        # floors. A repo with .intellisense/manifest.json policy_minimum_tier=1 must
        # still gate a docs edit at Tier 1 (code review). Using
        # PATH_TIER alone here was a fail-open that dropped POLICY_TIER.
        TIER=$(intellisense_effective_tier 0 "$PATH_TIER" "$POLICY_TIER")
        echo "intellisense: documentation-only edit not escalated by prompt tier $PROMPT_TIER; effective tier=$TIER (max of path=$PATH_TIER, policy=$POLICY_TIER) ($AFFECTED_PATHS)." >&2
    fi
fi

# ── Fast lane (safe-lane.sh): generalizes Exhibit-D to all SAFE paths ──────────
# Drop the prompt-tier escalation for a trivial doc/cosmetic edit, falling back
# to max(path=0, policy). Mirrors Exhibit-D's preserve-floors rule but covers
# README/CHANGELOG/.txt/.rst/test+spec scripts, not just docs/*.md.
#
# DELIBERATELY NARROW so it never weakens the gate's other duties:
#   • Structured edits ONLY (TOOL_NAME != Bash). Bash mutations keep FULL gating
#     — scope / out-of-scope detection lives there and must not be relaxed.
#   • Only when NO contract is in play. If a contract exists, its state (R6),
#     scope, and task-binding (R7) checks below MUST run unchanged.
#   • Dangerous-phrase preservation: do NOT relax if the classifier recorded a
#     dangerous-phrase floor, or this Edit's own old/new text carries one — so
#     "comment out ..." escalations survive even on a safe-looking path.
_fl_branch="$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null || echo "")"
_fl_contract="$(intellisense_contract_file "${_tier_root:-$CWD}" "$_fl_branch")"
if [ -n "$AFFECTED_PATHS" ] && [ "$TIER" -gt "$PATH_TIER" ] && [ "$PATH_TIER" = "0" ] \
   && [ "$TOOL_NAME" != "Bash" ] && [ ! -f "$_fl_contract" ]; then
    _safe_lane_lib="${INTELLISENSE_SAFE_LANE_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib/safe-lane.sh}"
    if [ -f "$_safe_lane_lib" ]; then
        . "$_safe_lane_lib"
        _all_safe=1
        while IFS= read -r _p; do
            [ -z "$_p" ] && continue
            intellisense_is_safe_path "$_p" || { _all_safe=0; break; }
        done <<< "$TIER_PATHS"

        _danger=0
        if [ -n "$CLASSIFICATION_FILE" ] \
           && jq -e '.reasoning[]? | select(contains("dangerous phrase"))' "$CLASSIFICATION_FILE" >/dev/null 2>&1; then
            _danger=1   # classifier already floored this for a dangerous phrase
        fi
        if [ "$_danger" = "0" ]; then
            _os=$(jq -r '.tool_input.old_string // empty' <<<"$PAYLOAD")
            _ns=$(jq -r '.tool_input.new_string // empty' <<<"$PAYLOAD")
            intellisense_has_dangerous_phrase "$_os
$_ns" && _danger=1
        fi

        if [ "$_all_safe" = "1" ] && [ "$_danger" = "0" ]; then
            TIER=$(intellisense_effective_tier 0 "$PATH_TIER" "$POLICY_TIER")
            echo "intellisense: fast-lane — cosmetic/doc edit, no contract, no dangerous signal; effective tier=$TIER (path=$PATH_TIER policy=$POLICY_TIER)." >&2
        fi
    fi
fi
unset _fl_branch _fl_contract

# Routing telemetry: record path/policy escalations regardless of
# whether prompt classification was present. Empty PROMPT_TIER is treated as 0
# for from_tier — the event still describes a real escalation (something raised
# the effective tier above the prompt's baseline). Path-tier takes precedence
# over policy when both contributed; classifier-only tiers (no path/policy bump)
# are NOT recorded here — they're already captured in the trailer's `tier` field.
if [ "$PATH_TIER" -gt "$PROMPT_TIER_FOR_EFFECTIVE" ] && [ "$PATH_TIER" = "$TIER" ]; then
    _record_routing_event "escalation" "$PROMPT_TIER_FOR_EFFECTIVE" "$TIER" "path_pattern" "$(_routing_path_reason "$AFFECTED_PATHS")" "$(_routing_infer_phase)"
elif [ "$POLICY_TIER" -gt "$PROMPT_TIER_FOR_EFFECTIVE" ] && [ "$POLICY_TIER" = "$TIER" ]; then
    _record_routing_event "escalation" "$PROMPT_TIER_FOR_EFFECTIVE" "$TIER" "policy_floor" "policy_minimum_tier" "$(_routing_infer_phase)"
fi

# ─── Audit-chain checks for missing/unknown tier signals ──────────────────────

# (a) BASH_MUTATION_NO_PATH=1 + no classification: AFFECTED_PATHS is empty so
# PATH_TIER is 0, and PROMPT_TIER is missing. We cannot determine the tier of
# this Bash mutation. The audit chain enforces — block by default; warn-mode
# allows + JSONL audit.
if [ "${BASH_MUTATION_NO_PATH:-0}" = "1" ] && [ -z "$PROMPT_TIER" ]; then
    audit_chain_block_or_warn "Bash mutation with unextractable path AND no classification. Cannot prove this is Tier 0. Use Edit/Write with an explicit file_path, or run /intellisense classify + /contract and retry."
fi

# (b) Classification missing AND TIER >= 1 (escalated by path or policy):
# audit chain requires a contract for Tier 1+ work. Block via audit-chain.
# (user correction #1)
#
# Defensive: match TIER as an explicit "1" or "2" pattern instead of using
# `-ge 1` with `2>/dev/null`. The error-suppression form fails-OPEN if
# intellisense_effective_tier ever returned empty (library bug); pattern match
# requires TIER to be a known-valid value before firing the audit-chain check.
# Code review finding (self-applied).
if [ -z "$PROMPT_TIER" ] && [[ "$TIER" =~ ^[12]$ ]]; then
    audit_chain_block_or_warn "Classification missing for Tier $TIER path. Run /intellisense classify and /contract before editing $AFFECTED_PATHS."
fi

# (c) Classification missing AND TIER == 0: genuinely ambiguous — no path or
# policy escalation, no prompt tier. Fall back to existing gate_mode behavior
# (warn under pilot, block under enforced). This is an advisory check, NOT an
# audit-chain check.
if [ -z "$PROMPT_TIER" ]; then
    case "$GATE_MODE" in
        enforced)
            die_block "Classification missing for this session. Run /intellisense classify or restart the session. (gate_mode=enforced)"
            ;;
        pilot|*)
            warn_allow "no classification found — proceeding without contract enforcement. Run /intellisense classify to enable. (gate_mode=$GATE_MODE)"
            ;;
    esac
fi

# Tier 0 → no contract required.
if [ "$TIER" = "0" ]; then
    die_allow
fi

# ─── Tier 1+ → contract required ──────────────────────────────────────────────

CURRENT_BRANCH=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CURRENT_BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null || echo "")
fi

# Convention: branch slashes → '__' (double underscore). MUST stay in sync with
# `_contract_safe_branch` in hooks/pre-push and the path the /contract skill
# writes to in .intellisense/session/. DO NOT replace with `tr '/' '_'` (single
# underscore) — silently breaks contract path lookup (bug shipped in c0f68cb,
# now pinned by tests/test_contract_gate.sh::test_branch_slug_parity).
#
# Sourcing alternative considered (scripts/lib/contract-paths.sh via
# ${INTELLISENSE_SETUP_PATH}) and rejected: parity test is more robust than runtime
# dependency on env vars across hook invocation contexts, and matches the
# codebase's existing "inline + cross-reference" pattern.
SAFE_BRANCH="${CURRENT_BRANCH//\//__}"
# One contract per branch, committed with the change: .intellisense/contracts/<branch>.md. Its front matter
# approves the edit here and is the push gate's evidence (scripts/lib/contract-file.sh).
CONTRACT_FILE="$(intellisense_contract_file "${_tier_root:-$CWD}" "$CURRENT_BRANCH")"
CONTRACT_JSON="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/intellisense-contract.$$")"

if [ ! -f "$CONTRACT_FILE" ]; then
    # Audit-chain decision: missing contract on Tier 1+ work
    # blocks regardless of gate_mode. Opt-out via audit_chain_enforcement=warn.
    audit_chain_block_or_warn "Tier $TIER work requires a Change Contract. Expected: $CONTRACT_FILE. Run /contract to produce one, then retry."
elif ! intellisense_contract_json "$CONTRACT_FILE" "$CONTRACT_JSON"; then
    audit_chain_block_or_warn "The Change Contract at $CONTRACT_FILE has no readable front matter (or the intellisense engine is missing). Re-run /contract."
fi

# ─── Run validator and translate exit codes ───────────────────────────────────

VALIDATOR_SCRIPT="${INTELLISENSE_VALIDATOR:-$(dirname "${BASH_SOURCE[0]}")/validate-contract-schema.sh}"
if [ ! -x "$VALIDATOR_SCRIPT" ]; then
    # Validator missing: this is a setup bug, not a developer error. Block in
    # both modes — degrading to no-op would silently disable enforcement.
    die_block "intellisense validator script not found at $VALIDATOR_SCRIPT. Re-run setup.sh."
fi

# Run validator from the session's CWD so its `git symbolic-ref` matches the
# branch the developer is on (NOT this script's process CWD). Pass the
# current classification_id so the validator can enforce R7 (task binding)
#  and R6 (lifecycle) under the SAME exit-code
# contract used in both pilot and enforced modes.
VALIDATOR_ARGS=("$CONTRACT_FILE")
# Explicit --context=edit (defense-in-depth): the validator
# default IS edit, but naming it explicitly prevents a future default-flip
# from silently weakening the edit gate.
VALIDATOR_ARGS+=("--context=edit")
if [ -n "$CURRENT_CLASSIFICATION_ID" ]; then
    VALIDATOR_ARGS+=("--current-classification-id=$CURRENT_CLASSIFICATION_ID")
fi
VALIDATOR_STDERR=$(cd "$CWD" 2>/dev/null && bash "$VALIDATOR_SCRIPT" "${VALIDATOR_ARGS[@]}" 2>&1 >/dev/null)
VALIDATOR_EXIT=$?

if [ "$VALIDATOR_EXIT" -ne 0 ]; then
    # Audit-chain decision: validator failure on Tier 1+ blocks
    # regardless of gate_mode. R6 (lifecycle), R7 (task-binding), scope-drift,
    # and all schema errors surface here as exit 1|2 → audit-chain enforces.
    audit_chain_block_or_warn "Change Contract validation failed (validator exit $VALIDATOR_EXIT):
$VALIDATOR_STDERR
Fix the contract at $CONTRACT_FILE (re-run /contract if needed)."
fi

# ─── Lifecycle auto-transition: approved → active ───────────────
# Once a contract has passed validation under state=approved AND we're about
# to permit a real Edit/Write, advance the state to "active" so subsequent
# edits see the natural lifecycle progression. Failure-isolated: state-write
# errors must never block the edit (gate is about contract presence + validity,
# not about successful state mutation).
CONTRACT_STATE=$(jq -r '.state // empty' "$CONTRACT_JSON" 2>/dev/null)
if [ "$CONTRACT_STATE" = "approved" ]; then
    intellisense_contract_set "$CONTRACT_FILE" state=active || true
fi

# ─── file-in-scope check ───────────────────────────────────────────────
# Contract is valid for this branch. Now verify the SPECIFIC file/path being
# affected is in contract.files_affected[]. Without this check, a valid
# contract acts as a branch-wide permission for any file edit.
#
# A bash mutation pattern matched but path extraction
# returned empty → cannot verify scope. Audit-chain enforces:
# block regardless of gate_mode. Distinct from the earlier check (a) above,
# which fires when classification is ALSO missing; this check fires when
# classification is present (we know it's Tier 1+) but we still can't extract
# the affected path.
if [ "${BASH_MUTATION_NO_PATH:-0}" = "1" ]; then
    audit_chain_block_or_warn "Bash mutation detected but file path could not be extracted automatically (e.g. via subshell, eval, or unsupported syntax). The gate cannot verify file-in-scope. Either: (a) use the Edit/Write tool which makes the path explicit, or (b) rewrite the command so the target file is a direct argument the gate can read."
fi

# AFFECTED_PATHS holds the path(s) extracted earlier (Edit/Write file_path or
# Bash mutation target).
if [ -n "$AFFECTED_PATHS" ]; then
    DECLARED_FILES_TMP=$(mktemp)
    jq -r '.files_affected[]' "$CONTRACT_JSON" 2>/dev/null >"$DECLARED_FILES_TMP"
    OUT_OF_SCOPE=()
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        # Normalize to repo-relative if absolute path under CWD
        rel="$p"
        case "$p" in
            "$CWD"/*) rel="${p#$CWD/}" ;;
        esac
        # Allowlist already passed for .intellisense/session/** and contracts/** above; safe to skip
        case "$rel" in
            .intellisense/session/*|.intellisense/contracts/*) continue ;;
        esac
        if ! grep -Fxq "$rel" "$DECLARED_FILES_TMP" 2>/dev/null; then
            OUT_OF_SCOPE+=("$rel")
        fi
    done <<<"$AFFECTED_PATHS"
    rm -f "$DECLARED_FILES_TMP"

    if [ "${#OUT_OF_SCOPE[@]}" -gt 0 ]; then
        # File(s) NOT in declared scope. Audit-chain enforces:
        # block regardless of gate_mode.
        msg="File(s) not in contract.files_affected[]: ${OUT_OF_SCOPE[*]}. Either update the contract (re-run /contract with expanded files_affected) or use a file that is in scope."
        audit_chain_block_or_warn "$msg"
    fi
fi

# All checks passed.
die_allow
