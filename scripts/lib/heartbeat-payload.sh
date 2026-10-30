#!/usr/bin/env bash
# scripts/lib/heartbeat-payload.sh
#
# Pure-function library for building the intellisense heartbeat JSON payload (the heartbeat).
# Each function returns a JSON value on stdout; no network, no side effects,
# easy to unit-test by sourcing this file and calling functions directly.
#
# The full payload schema is defined in docs/telemetry-contract.md.
# The collector's owners confirmed "schema is ours to define, ships as-is" — so omitting
# optional fields when their data source is missing is acceptable (and better
# than emitting nulls or zeros that look real).
#

# ─── github_login ───────────────────────────────────────────────────────────
# Resolves the developer's identity with a multi-source fallback chain.
# Relying on gh alone would emit github_login="unknown" whenever gh is missing
# or unauthenticated, collapsing those devs into one dashboard row.
# INTELLISENSE_GH_LOGIN comes first: gh returns whatever account it is
# authenticated against — often a GitHub Enterprise login that differs from the
# handle setup.sh baked into the launchd plist / crontab — and the documented
# "admin override / CI injection" must beat it.
#
# Resolution order (first non-empty wins):
#   1. INTELLISENSE_GH_LOGIN env var             (admin override / CI injection — wins)
#   2. gh api user --jq .login           (authenticated GH CLI)
#   3. git config --global user.email    (strip the @domain portion)
#   4. $USER                              (shell user — last good signal)
#   5. "" (caller falls back to "unknown" — single visible failure mode)
#
# This is per-dev best-effort identity, not auth. The shared bearer token
# at the network boundary is what gates writes; the identity here is what
# rows up to. We accept that two devs sharing $USER on the same machine
# would collide — that's an acceptable failure mode for an internal metrics
# pipeline, and the earlier sources in the chain cover the typical case.
hb_github_login() {
    local login=""

    # 1. explicit env-var override (CI / admin) — checked first so it wins
    #    over whatever the gh CLI returns (e.g. GitHub Enterprise logins that
    #    differ from the developer's preferred github.com handle).
    if [[ -n "${INTELLISENSE_GH_LOGIN:-}" ]]; then
        echo "$INTELLISENSE_GH_LOGIN"
        return 0
    fi

    # 2. gh CLI
    if command -v gh >/dev/null 2>&1; then
        login="$(gh api user --jq .login 2>/dev/null || true)"
    fi
    if [[ -n "$login" ]]; then
        echo "$login"
        return 0
    fi

    # 3. git config user.email → take portion before @
    if command -v git >/dev/null 2>&1; then
        local email
        email="$(git config --global --get user.email 2>/dev/null || true)"
        if [[ -n "$email" && "$email" == *"@"* ]]; then
            login="${email%%@*}"
            # sanity: alnum + . _ - only, no whitespace
            if [[ "$login" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo "$login"
                return 0
            fi
        fi
    fi

    # 4. $USER
    if [[ -n "${USER:-}" && "$USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "$USER"
        return 0
    fi

    # 5. empty — caller will substitute "unknown"
    return 0
}

# ─── intellisense_version ───────────────────────────────────────────────────────────
# Read order: HB_VERSION_FILE → INTELLISENSE_SETUP_PATH/VERSION → "unknown".
# Never fails the heartbeat; version is diagnostic metadata only.
hb_intellisense_version() {
    local intellisense_setup="${1:-${INTELLISENSE_SETUP_PATH:-}}"
    if [[ -n "${HB_VERSION_FILE:-}" && -r "$HB_VERSION_FILE" ]]; then
        head -1 "$HB_VERSION_FILE" 2>/dev/null | tr -d '[:space:]'
        return 0
    fi
    if [[ -n "$intellisense_setup" && -r "$intellisense_setup/VERSION" ]]; then
        head -1 "$intellisense_setup/VERSION" 2>/dev/null | tr -d '[:space:]'
        return 0
    fi
    echo "unknown"
}

# ─── platform ───────────────────────────────────────────────────────────────
hb_platform() {
    uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown"
}

# ─── gate_mode ──────────────────────────────────────────────────────────────
# pilot (default) or enforced. Read from ~/.claude/settings.json intellisense.gate_mode.
hb_gate_mode() {
    local settings="${1:-$HOME/.claude/settings.json}"
    if [[ -f "$settings" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.intellisense.gate_mode // "pilot"' "$settings" 2>/dev/null || echo "pilot"
    else
        echo "pilot"
    fi
}

# ─── onboarded_repos ────────────────────────────────────────────────────────
# Returns [{repo, stack, path, claude_md_present}] for every repo this dev
# has onboarded with `setup-repos.sh`.
#
# Data source priority:
#   1. $HOME/.intellisense/onboarded-repos.tsv   (intellisense-managed, primary)
#      Format: <path>\t<stack>  (one repo per line)
#      Written by setup-repos.sh at the end of every onboarding run.
#   2. $HOME/.code-review-graph/registry.json       (CRG-managed, fallback)
#      Only populated for devs who actively invoke CRG; not a reliable
#      onboard signal.
#
# Field rules:
#   repo                 — basename of path (stable across machines)
#   stack                — from the tsv (or registry .stack/.language)
#   path                 — absolute filesystem path on this dev's machine
#   claude_md_present    — tests file existence ($path/CLAUDE.md) on disk
hb_onboarded_repos() {
    local primary="${1:-$HOME/.intellisense/onboarded-repos.tsv}"
    local fallback="${2:-$HOME/.code-review-graph/registry.json}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "[]"
        return 0
    fi

    # Collect (path, stack) pairs. Primary source first, then fallback.
    # Dedup by path: primary entries win. We avoid `local -A` (associative
    # arrays require bash 4+; macOS ships 3.2) — use a "seen paths" file
    # checked via grep.
    local entries_file seen_file
    entries_file="$(mktemp)"
    seen_file="$(mktemp)"

    _hb_add_repo() {
        local p="$1" stack="$2" repo="$3"
        # skip entries whose path no longer exists on disk.
        # setup-repos.sh appends to the tsv on every onboarding run, including
        # throwaway test dirs that get deleted — those would otherwise show
        # up forever as "onboarded repos" in the analytics payload.
        [[ -d "$p" ]] || return 0
        # Dedup: grep -Fx returns 0 if exact line already in seen_file
        if grep -Fxq "$p" "$seen_file" 2>/dev/null; then
            return 0
        fi
        echo "$p" >> "$seen_file"
        local claude_md=false
        [[ -f "$p/CLAUDE.md" ]] && claude_md=true
        jq -nc \
            --arg path  "$p" \
            --arg repo  "$repo" \
            --arg stack "$stack" \
            --argjson claude_md_present "$claude_md" \
            '{repo: $repo, stack: $stack, path: $path, claude_md_present: $claude_md_present}' \
            >> "$entries_file"
    }

    if [[ -f "$primary" ]]; then
        while IFS=$'\t' read -r path stack; do
            [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
            _hb_add_repo "$path" "${stack:-unknown}" "${path##*/}"
        done < "$primary"
    fi

    if [[ -f "$fallback" ]]; then
        local raw_fb
        raw_fb="$(
            jq -r '
                (.projects // [])
                | .[]
                | [
                    (.path // ""),
                    (.repo // .name // (.path // "" | split("/") | last // "unknown")),
                    (.stack // .language // "unknown")
                  ] | @tsv
            ' "$fallback" 2>/dev/null || true
        )"
        if [[ -n "$raw_fb" ]]; then
            while IFS=$'\t' read -r path repo stack; do
                [[ -z "$path" ]] && continue
                _hb_add_repo "$path" "$stack" "$repo"
            done <<< "$raw_fb"
        fi
    fi

    rm -f "$seen_file"

    if [[ ! -s "$entries_file" ]]; then
        rm -f "$entries_file"
        echo "[]"
        return 0
    fi

    jq -sc '.' "$entries_file" 2>/dev/null || echo "[]"
    rm -f "$entries_file"
}

# ─── idempotency_key ────────────────────────────────────────────────────────
# "<github_login>_<YYYY-MM-DD>". Server-side dedup means re-runs same day are
# no-ops, which is what we want — laptop wakes up multiple times, queue drains,
# server sees the same key, returns 200, evicted from queue.
hb_idempotency_key() {
    local login="$1"
    local date="${2:-$(date -u +%Y-%m-%d)}"
    [[ -z "$login" ]] && login="unknown"
    echo "${login}_${date}"
}

# ─── price-table runtime refresh ──────────────────────────────
# Refreshes the RUNTIME copy of heartbeat-prices.json from the intellisense repo so
# a model release / price change reaches devs WITHOUT a `git pull`. Data-only:
# it reads exactly one file from the remote ref — it never checks out, merges,
# or runs repo code (that stays a deliberate `git pull`).
#
# Auth: git over SSH (key file) works under cron where the gh keyring does not
# (verified: BatchMode, no agent -> exit 0). Both transports are timeout-bounded
# so a slow network can never hang the heartbeat. Fail-soft: ANY failure keeps
# the existing cached/bundled copy and records a reason in HB_PRICES_STALE_REASON
# (consumed by hb_prices_stale_reason -> the prices_stale warning).
#
# Caller (intellisense-heartbeat.sh) runs this BEFORE building the payload and skips it
# in --dry-run (unless INTELLISENSE_HEARTBEAT_REFRESH_IN_DRYRUN is set) so tests and
# manual inspection never touch the network.
hb_validate_prices() {
    # A parseable-but-garbage file must NOT replace a good cached one.
    local f="$1"
    command -v jq >/dev/null 2>&1 || return 1
    jq -e '
        (.models | type == "array" and length > 0)
        and (all(.models[];
              (.canonical | type == "string")
              and (.aliases | type == "array")
              and (.input_per_mtok | type == "number")
              and (.output_per_mtok | type == "number")
              and (.cache_creation_per_mtok | type == "number")
              and (.cache_read_per_mtok | type == "number")))
    ' "$f" >/dev/null 2>&1
}

# Pick the git remote to fetch the price table from — robust to fork vs non-fork.
# Order: (1) explicit INTELLISENSE_PRICES_REMOTE override; (2) the remote whose URL points
# at the canonical repo (INTELLISENSE_PRICES_REPO_SLUG, default "soupler-oss/intellisense") — so a fork
# user reaches canonical even if `upstream` is misnamed or absent; (3) `upstream`
# by name; (4) `origin`. The fetch hits the remote live, so freshness never depends
# on the dev's local clone being pulled.
hb_pick_prices_remote() {
    local repo="$1"
    if [[ -n "${INTELLISENSE_PRICES_REMOTE:-}" ]]; then
        echo "$INTELLISENSE_PRICES_REMOTE"; return 0
    fi
    local slug="${INTELLISENSE_PRICES_REPO_SLUG:-soupler-oss/intellisense}"
    local r url
    while read -r r; do
        [[ -z "$r" ]] && continue
        url="$(git -C "$repo" remote get-url "$r" 2>/dev/null || true)"
        if [[ "$url" == *"$slug"* ]]; then echo "$r"; return 0; fi
    done < <(git -C "$repo" remote 2>/dev/null)
    if git -C "$repo" remote 2>/dev/null | grep -qx upstream; then
        echo "upstream"
    else
        echo "origin"
    fi
}

hb_refresh_prices() {
    export HB_PRICES_STALE_REASON=""

    # Destination = the runtime prices file this lib reads (next to us).
    local lib_dir dest
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dest="$lib_dir/heartbeat-prices.json"

    # Resolve the source repo: explicit env (plist exports it) -> config.json.
    local repo="${INTELLISENSE_SETUP_PATH:-}"
    if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
        repo="$(jq -r '.intellisense_setup_path // empty' "$HOME/.claude/config.json" 2>/dev/null || true)"
    fi
    if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
        export HB_PRICES_STALE_REASON="repo_not_found"; return 0
    fi

    # NEVER mutate a repo working tree. If dest lives inside the repo (running
    # from a clone, not the installed runtime copy), skip — the dev's `git pull`
    # owns that file. Benign skip, not a staleness failure.
    case "$dest" in
        "$repo"/*) export HB_PRICES_STALE_REASON="in_repo_skip"; return 0 ;;
    esac

    command -v git >/dev/null 2>&1 || { export HB_PRICES_STALE_REASON="git_missing"; return 0; }

    local remote branch
    remote="$(hb_pick_prices_remote "$repo")"
    branch="${INTELLISENSE_PRICES_BRANCH:-master}"

    # Fetch (bounded both transports), then read ONE file from FETCH_HEAD —
    # FETCH_HEAD is set by the fetch we just ran, so it needs no remote-tracking
    # ref and reflects exactly what we fetched.
    if ! GIT_TERMINAL_PROMPT=0 \
         GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 \
         GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new' \
         git -C "$repo" fetch -q "$remote" "$branch" 2>/dev/null; then
        export HB_PRICES_STALE_REASON="fetch_failed"; return 0
    fi

    local tmp="$dest.tmp.$$"
    if ! git -C "$repo" show "FETCH_HEAD:scripts/lib/heartbeat-prices.json" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; export HB_PRICES_STALE_REASON="show_failed"; return 0
    fi
    if ! hb_validate_prices "$tmp"; then
        rm -f "$tmp"; export HB_PRICES_STALE_REASON="schema_invalid"; return 0
    fi
    if ! mv "$tmp" "$dest" 2>/dev/null; then
        rm -f "$tmp"; export HB_PRICES_STALE_REASON="swap_failed"; return 0
    fi
    # Record the successful sync time (absolute staleness signal for the
    # dashboard). Best-effort — a write failure here must not fail the refresh.
    date -u +%Y-%m-%dT%H:%M:%SZ > "$lib_dir/.prices-last-synced" 2>/dev/null || true
    return 0
}

# Last successful price-table sync time (ISO8601), or empty if never synced
# (e.g. maintainer running in-repo, or a dev whose fetch has never succeeded).
hb_prices_last_synced_at() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local f="$lib_dir/.prices-last-synced"
    [[ -f "$f" ]] && head -1 "$f" | tr -d '[:space:]' || true
}

# Effective staleness reason for the prices_stale warning, or "" if fresh.
# Combines a refresh failure (HB_PRICES_STALE_REASON, excluding benign skips)
# with an age check on the table's _last_verified date.
hb_prices_stale_reason() {
    local prices="$1"
    local r="${HB_PRICES_STALE_REASON:-}"
    case "$r" in
        ""|in_repo_skip) ;;            # benign — fall through to age check
        *) echo "$r"; return 0 ;;
    esac
    local lv
    lv="$(jq -r '._last_verified // empty' "$prices" 2>/dev/null || true)"
    [[ -z "$lv" ]] && { echo "no_last_verified"; return 0; }
    local lv_epoch now_epoch
    lv_epoch="$(date -j -f %Y-%m-%d "$lv" +%s 2>/dev/null || date -d "$lv" +%s 2>/dev/null || echo "")"
    now_epoch="$(date +%s 2>/dev/null || echo "")"
    if [[ -n "$lv_epoch" && -n "$now_epoch" ]]; then
        local days max
        days=$(( (now_epoch - lv_epoch) / 86400 ))
        max="${INTELLISENSE_PRICES_MAX_AGE_DAYS:-14}"
        if (( days > max )); then echo "cache_age_${days}d"; return 0; fi
    fi
    echo ""
}

# ─── usage_summary (Python parser, self-contained) ──────────────────────────
# Reads ~/.claude/projects/**/*.jsonl, aggregates yesterday by event
# timestamp (NOT mtime), applies the price table, emits the usage_summary contract.
# Always emits a usage_summary object — never empty. State A/B/C/D model.
hb_usage_summary() {
    local target_date="${1:-$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)}"
    local script_dir
    # When sourced from the installed copy, BASH_SOURCE[0] resolves to the
    # installed lib path; when sourced from the repo, it resolves to the
    # repo path. Either way, the python parser + prices.json sit next to us.
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local parser="$script_dir/heartbeat_usage_parser.py"
    local prices="$script_dir/heartbeat-prices.json"

    if [[ ! -f "$parser" || ! -f "$prices" ]]; then
        # Sibling files missing — should never happen post-install.
        # Emit a fatal usage_summary so the dashboard sees the failure
        # rather than an empty payload.
        jq -nc --arg p "$target_date" '{
            period: $p,
            sessions: 0,
            input_tokens: 0, output_tokens: 0,
            cache_creation_tokens: 0, cache_read_tokens: 0,
            total_tokens: 0, total_cost: 0,
            models_used: [], model_breakdowns: [], unknown_models: [],
            cost_estimation_status: "unavailable",
            warnings: [{type: "fatal_parse_failure"}],
            error: "parse_failed",
            parse_error_detail: "internal:io_error"
        }'
        return 0
    fi

    # Python missing at runtime → emit State D rather than abort the whole
    # heartbeat. The rest of the payload still
    # sends because the caller doesn't treat empty stdout from this
    # function as fatal. Setup-time enforcement (verify-setup Check 19)
    # is the right layer for hard-failing on missing python3.
    if ! command -v python3 >/dev/null 2>&1; then
        jq -nc --arg p "$target_date" '{
            period: $p,
            sessions: 0,
            input_tokens: 0, output_tokens: 0,
            cache_creation_tokens: 0, cache_read_tokens: 0,
            total_tokens: 0, total_cost: 0,
            models_used: [], model_breakdowns: [], unknown_models: [],
            cost_estimation_status: "unavailable",
            warnings: [{type: "fatal_parse_failure"}],
            error: "parse_failed",
            parse_error_detail: "internal:missing_field file=python3"
        }'
        return 0
    fi

    local transcripts_dir="${HB_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

    # Surface a stale price table (failed refresh or over-age cache) as a
    # data-only warning so the stale tail is visible, not silent.
    local stale_reason
    stale_reason="$(hb_prices_stale_reason "$prices")"

    # Python parser always exits 0 and emits a valid usage_summary JSON
    # object (one of states A/B/C/D). Stderr is discarded — sanitization
    # is enforced inside the parser via build_parse_error_detail().
    python3 "$parser" \
        --period "$target_date" \
        --prices "$prices" \
        --transcripts-dir "$transcripts_dir" \
        --prices-stale-reason "$stale_reason" 2>/dev/null
}

# ─── behavior_stats ─────────────────────────────────────────────────────────
# 5 governed quick-win fields aggregated from yesterday's local artifacts.
#
# A single workspace ($PWD) is not enough: under launchd the daily 09:00 cron
# runs from $HOME, which has no .intellisense/session/, so mode_mix,
# top_skills_used and plan_to_commit_ratio would always be empty.
#
# So it iterates over ALL onboarded repo paths from the CRG registry and
# aggregates yesterday's session artifacts across them. A single explicit
# workspace path is also accepted.
#
# Args:
#   $1 — JSON array of repo paths (e.g. ["/path/a","/path/b"]) OR a single
#        path string. Empty array = use $HOME/.code-review-graph
#        registry. Default: registry lookup.
#   $2 — period date (YYYY-MM-DD); default: yesterday UTC.
#
# Sources by field:
#   classifier_overrides_today  — ~/.claude-intellisense/classifier-overrides.jsonl  (global)
#   local_trailer_drift_count    — ~/.claude-intellisense/trailer-drift.log          (global)
#   mode_mix                     — union of *.classification.json across all repos
#   top_skills_used              — union of *.usage.json across all repos
#   plan_to_commit_ratio         — sum(plan) / sum(commits) across all repos
hb_behavior_stats() {
    local workspaces_arg="${1:-}"
    local period="${2:-$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)}"

    # Resolve the list of workspace paths to iterate.
    local -a workspaces=()
    if [[ -z "$workspaces_arg" ]]; then
        # Default: read from registry
        local registry="${HB_REGISTRY:-$HOME/.code-review-graph/registry.json}"
        if [[ -f "$registry" ]] && command -v jq >/dev/null 2>&1; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && workspaces+=("$p")
            done < <(jq -r '(.projects // []) | .[] | .path // empty' "$registry" 2>/dev/null)
        fi
    elif [[ "${workspaces_arg:0:1}" == "[" ]]; then
        # JSON array form
        while IFS= read -r p; do
            [[ -n "$p" ]] && workspaces+=("$p")
        done < <(echo "$workspaces_arg" | jq -r '.[]' 2>/dev/null)
    else
        # Single explicit path
        workspaces+=("$workspaces_arg")
    fi

    # 1. classifier overrides yesterday (global file)
    local overrides_log="$HOME/.claude-intellisense/classifier-overrides.jsonl"
    local overrides_today=0
    if [[ -f "$overrides_log" ]] && command -v jq >/dev/null 2>&1; then
        # Logger writes `"ts":"<iso>"` not `"date":"<ymd>"`. Match the
        # ISO prefix.
        overrides_today=$(grep -c "\"ts\":\"${period}T" "$overrides_log" 2>/dev/null || echo 0)
        overrides_today="${overrides_today//[!0-9]/}"
        : "${overrides_today:=0}"
    fi

    # 2. trailer-drift count from yesterday (global file)
    local drift_log="$HOME/.claude-intellisense/trailer-drift.log"
    local drift_count=0
    if [[ -f "$drift_log" ]]; then
        drift_count=$(grep -c "^\[$period" "$drift_log" 2>/dev/null || echo 0)
        drift_count="${drift_count//[!0-9]/}"
        : "${drift_count:=0}"
    fi

    # 2b. audit-chain warn-mode events yesterday (global file). Counts
    # intellisense.audit_chain_enforcement=warn break-glass bypasses emitted by
    # scripts/preToolUse-contract-gate.sh::_audit_chain_log_warn. Same
    # ISO-prefix grep pattern as overrides_today.
    local audit_warnings_log="$HOME/.claude-intellisense/audit-chain-warnings.jsonl"
    local audit_warnings_today=0
    if [[ -f "$audit_warnings_log" ]] && command -v jq >/dev/null 2>&1; then
        audit_warnings_today=$(grep -c "\"ts\":\"${period}T" "$audit_warnings_log" 2>/dev/null || echo 0)
        audit_warnings_today="${audit_warnings_today//[!0-9]/}"
        : "${audit_warnings_today:=0}"
    fi

    # Collect every relevant classification.json and usage.json across all
    # workspaces. Files have unique session-id names so simple concatenation
    # is safe.
    local mode_lines=""
    local skill_lines=""
    local routing_lines=""
    local plan_count=0 commit_count=0
    local ws session_dir
    for ws in "${workspaces[@]}"; do
        session_dir="$ws/.intellisense/session"
        [[ -d "$session_dir" ]] || continue
        if command -v jq >/dev/null 2>&1; then
            # 3. mode_mix contribution
            while IFS= read -r f; do
                [[ -n "$f" ]] && mode_lines+="$(jq -r --arg d "$period" '
                    select((.timestamp // "") | startswith($d))
                    | .mode // empty
                ' "$f" 2>/dev/null)"$'\n'
            done < <(find "$session_dir" -maxdepth 1 -name '*.classification.json' -type f 2>/dev/null)

            # 4. top_skills + 5. plan_count contribution
            while IFS= read -r f; do
                [[ -n "$f" ]] && skill_lines+="$(jq -r --arg d "$period" '
                    select((.first_prompt_ts // "") | startswith($d))
                    | (.skills_used // [])[]
                ' "$f" 2>/dev/null)"$'\n'
                # plan count specifically
                local p
                p=$(jq -r --arg d "$period" '
                    select((.first_prompt_ts // "") | startswith($d))
                    | (.skills_used // [])
                    | map(select(. == "plan")) | length
                ' "$f" 2>/dev/null)
                plan_count=$((plan_count + ${p:-0}))
            done < <(find "$session_dir" -maxdepth 1 -name '*.usage.json' -type f 2>/dev/null)

            # 6. routing events. Each line in a *.routing.jsonl
            # is one event; we collect only events whose ts falls inside the
            # period. Lines retain {session_file_path} so we can derive a
            # unique-session count for degraded_sessions.
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                routing_lines+="$(jq -c --arg d "$period" --arg sf "$f" '
                    select(.kind == "escalation"
                           and ((.ts // "") | startswith($d)))
                    | . + {_session_file: $sf}
                ' "$f" 2>/dev/null)"$'\n'
            done < <(find "$session_dir" -maxdepth 1 -name '*.routing.jsonl' -type f 2>/dev/null)
        fi

        # commit count contribution
        if [[ -d "$ws/.git" ]] && command -v git >/dev/null 2>&1; then
            local c
            c=$(git -C "$ws" log --since="$period 00:00:00 UTC" --until="$period 23:59:59 UTC" --oneline 2>/dev/null | wc -l | tr -d ' ')
            commit_count=$((commit_count + ${c:-0}))
        fi
    done

    # Reduce mode lines → {"bug_fix": N, "full_feature": M, ...}
    local mode_mix='{}'
    if [[ -n "$mode_lines" ]]; then
        mode_mix=$(
            echo "$mode_lines" | grep -v '^$' | sort | uniq -c \
                | awk '{printf "{\"%s\":%d}\n", $2, $1}' \
                | jq -s 'reduce .[] as $x ({}; . + $x)' 2>/dev/null
        )
        [[ -z "$mode_mix" || "$mode_mix" == "null" ]] && mode_mix='{}'
    fi

    # Reduce skill lines → top 5 [{skill, count}, ...]
    local top_skills='[]'
    if [[ -n "$skill_lines" ]]; then
        top_skills=$(
            echo "$skill_lines" | grep -v '^$' | sort | uniq -c | sort -rn | head -5 \
                | awk '{printf "{\"skill\":\"%s\",\"count\":%d}\n", $2, $1}' \
                | jq -s '.' 2>/dev/null
        )
        [[ -z "$top_skills" || "$top_skills" == "null" ]] && top_skills='[]'
    fi

    # plan_to_commit_ratio
    local ratio=0
    if (( plan_count > 0 )); then
        ratio=$(awk -v p="$plan_count" -v c="$commit_count" \
            'BEGIN { if (p==0) print 0; else printf "%.2f", (c/p > 1 ? 1 : c/p) }')
    fi

    # ─── routing_stats aggregate ───
    # Reduce routing_lines into the schema required by telemetry-contract.md.
    # Counters at 0 are emitted honestly when the day produced no escalations
    # (the daily heartbeat is a presence-of-counters contract — empty days
    # still surface the schema so dashboards can tell "we measured" from
    # "we don't track this"). Fields without a current source are emitted
    # as 0 with a doc note in telemetry-contract.md governance section.
    #
    # Dedup contract: every counter below reflects UNIQUE
    # escalation events, not raw lines. Same {session_file, event_id} only
    # counts once. Rows with an empty event_id (the writer had no shasum/sha1sum)
    # are deduped on {session_file, from_tier, to_tier, trigger, reason}.
    # scripts/preToolUse-contract-gate.sh avoids duplicates at write time; the
    # reader dedupes as well so a writer regression cannot inflate counters.
    local routing_stats='{}'
    if command -v jq >/dev/null 2>&1; then
        local routing_agg promo_tier_2=0 promo_high_risk=0 total_escalations=0 degraded_sessions=0
        if [[ -n "$routing_lines" ]]; then
            routing_agg=$(echo "$routing_lines" | grep -v '^$' | jq -sc '
                # Dedup: prefer event_id (already session-bound by its hash
                # input); fall back to (_session_file, from, to, trigger,
                # reason) when event_id is empty.
                group_by(
                    if ((.event_id // "") | length > 0)
                    then [._session_file, .event_id]
                    else [._session_file, .from_tier, .to_tier, .trigger, (.reason // "")]
                    end
                )
                | map(.[0])
                | {
                    tier_2: (map(select((.to_tier // 0) == 2)) | length),
                    high_risk_file: (map(select(.trigger == "path_pattern"
                        and ((.reason // "")
                             | IN("auth/identity","financial","database migration",
                                  "security rule","reasoning-integrity rule"))))
                        | length),
                    total: length,
                    degraded_sessions: (map(._session_file) | unique | length)
                }
            ' 2>/dev/null)
            if [[ -n "$routing_agg" ]]; then
                promo_tier_2=$(echo "$routing_agg" | jq -r '.tier_2 // 0')
                promo_high_risk=$(echo "$routing_agg" | jq -r '.high_risk_file // 0')
                total_escalations=$(echo "$routing_agg" | jq -r '.total // 0')
                degraded_sessions=$(echo "$routing_agg" | jq -r '.degraded_sessions // 0')
            fi
        fi
        routing_stats=$(jq -nc \
            --argjson tier_2 "${promo_tier_2:-0}" \
            --argjson high_risk "${promo_high_risk:-0}" \
            --argjson total "${total_escalations:-0}" \
            --argjson degraded "${degraded_sessions:-0}" \
            '{
                promotions_count: {tier_2: $tier_2, high_risk_file: $high_risk, low_confidence: 0},
                demotions_count: {tier_0_mechanical: 0},
                escalations_today: $total,
                escalation_to_replan_ratio: 0,
                degraded_sessions: $degraded,
                model_pinning_overrides: 0
            }')
    fi

    jq -nc \
        --arg period "$period" \
        --argjson overrides "${overrides_today:-0}" \
        --argjson drift "${drift_count:-0}" \
        --argjson audit_warnings "${audit_warnings_today:-0}" \
        --argjson mode_mix "$mode_mix" \
        --argjson top_skills "$top_skills" \
        --argjson ratio "${ratio:-0}" \
        --argjson routing_stats "$routing_stats" \
        '{
            period: $period,
            classifier_overrides_today: $overrides,
            local_trailer_drift_count: $drift,
            audit_chain_warnings_today: $audit_warnings,
            mode_mix: $mode_mix,
            top_skills_used: $top_skills,
            plan_to_commit_ratio: $ratio,
            routing_stats: $routing_stats
        }'
}

# ─── tool_decision_counts ───────────────────────────────────────────────────
# Verified against the transcript format: Claude Code transcripts contain
# tool_result records with `is_error: true` AND a content prefix indicating
# user rejection. This function counts:
#   accepted          — tool_result records with is_error: false (or absent)
#   rejected_by_user  — tool_result records with content prefix
#                       "The user doesn't want to proceed"
#   tool_errors       — is_error: true AND no such content prefix
# Returns "" when no transcripts found (caller omits field).
hb_tool_decision_counts() {
    local period="${1:-$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)}"
    # Honor HB_CLAUDE_PROJECTS_DIR like hb_usage_summary/hb_behavior_stats do,
    # so backfill + tests resolve the same transcript root.
    local transcripts_dir="${HB_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    if [[ ! -d "$transcripts_dir" ]] || ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    python3 - "$transcripts_dir" "$period" <<'PY' 2>/dev/null || true
import os, sys, json, glob, datetime

root = sys.argv[1]
period = sys.argv[2]   # YYYY-MM-DD
accepted = 0
rejected = 0
errors   = 0
seen_any = False

for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    try:
        # Skip files not touched on the target date — cheap mtime check first
        mtime = datetime.datetime.utcfromtimestamp(os.path.getmtime(path))
        if mtime.strftime("%Y-%m-%d") < period:
            continue
        with open(path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ts = rec.get("timestamp", "")
                if not ts.startswith(period):
                    continue
                # tool_result records live in user messages (Claude Code's
                # turn-by-turn schema). We look at message.content[*].
                msg = rec.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") != "tool_result":
                        continue
                    seen_any = True
                    is_err = c.get("is_error", False)
                    # content can be a string or a list of {"type":"text","text":"..."}
                    body = c.get("content", "")
                    if isinstance(body, list):
                        body = " ".join(
                            (b.get("text", "") if isinstance(b, dict) else str(b))
                            for b in body
                        )
                    body = str(body)
                    if is_err and body.startswith("The user doesn't want to proceed"):
                        rejected += 1
                    elif is_err:
                        errors += 1
                    else:
                        accepted += 1
    except Exception:
        continue

if not seen_any:
    sys.exit(0)
print(json.dumps({
    "period": period,
    "accepted": accepted,
    "rejected_by_user": rejected,
    "tool_errors": errors
}))
PY
}

# ─── build_payload ──────────────────────────────────────────────────────────
# Assemble all the pieces into one JSON object. Optional fields (usage_summary,
# tool_decision_counts) are omitted when their function returns empty rather
# than emitting null — keeps payload tight and avoids "we don't have data" looking
# like "data is zero."
hb_build_payload() {
    local intellisense_setup="${1:-${INTELLISENSE_SETUP_PATH:-}}"
    # Explicit workspace: used for behavior_stats only when the registry lists
    # no onboarded repos (the daily cron fires from $HOME).
    local workspace="${2:-$PWD}"
    # Explicit REPORTED period (YYYY-MM-DD UTC). Catch-up backfill passes the
    # day being reported so idempotency_key + usage_summary + behavior_stats all
    # reflect that day, not the send date. Defaults to yesterday UTC (the daily
    # single-fire case) when omitted.
    local period="${3:-$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)}"

    local login version platform gate_mode repos idem ts
    login="$(hb_github_login)"
    [[ -z "$login" ]] && login="unknown"
    version="$(hb_intellisense_version "$intellisense_setup")"
    platform="$(hb_platform)"
    gate_mode="$(hb_gate_mode)"
    repos="$(hb_onboarded_repos)"
    [[ -z "$repos" ]] && repos="[]"
    idem="$(hb_idempotency_key "$login" "$period")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Pass the registry-derived paths to behavior_stats so it aggregates
    # across all onboarded repos, not just $PWD (which is $HOME under
    # launchd). With no registered repos, use the explicit workspace.
    local behavior usage decisions ws_arg
    if [[ "$(echo "$repos" | jq 'length' 2>/dev/null)" -gt 0 ]]; then
        ws_arg="$(echo "$repos" | jq -c '[.[].path // empty]' 2>/dev/null)"
    else
        ws_arg="$workspace"
    fi
    behavior="$(hb_behavior_stats "$ws_arg" "$period")"
    usage="$(hb_usage_summary "$period")"
    decisions="$(hb_tool_decision_counts "$period")"

    # prices_last_synced_at: when this dev's price table last synced from the
    # repo (null if never — maintainer in-repo, or fetch never succeeded).
    local synced synced_json
    synced="$(hb_prices_last_synced_at)"
    if [[ -n "$synced" ]]; then synced_json="$(printf '%s' "$synced" | jq -R .)"; else synced_json="null"; fi

    # Build payload with optional fields conditionally included
    local jq_args=()
    jq_args+=(--arg event_type "developer_heartbeat")
    jq_args+=(--argjson schema 1)
    jq_args+=(--arg ts "$ts")
    jq_args+=(--arg login "$login")
    jq_args+=(--arg version "$version")
    jq_args+=(--arg platform "$platform")
    jq_args+=(--arg gate_mode "$gate_mode")
    jq_args+=(--argjson repos "$repos")
    jq_args+=(--argjson behavior "$behavior")
    jq_args+=(--arg idem "$idem")
    jq_args+=(--argjson prices_synced "$synced_json")

    local base
    base='{
        event_type: $event_type,
        schema: $schema,
        timestamp: $ts,
        github_login: $login,
        intellisense_version: $version,
        platform: $platform,
        gate_mode: $gate_mode,
        onboarded_repos: $repos,
        behavior_stats: $behavior,
        prices_last_synced_at: $prices_synced,
        idempotency_key: $idem
    }'

    if [[ -n "$usage" ]]; then
        jq_args+=(--argjson usage "$usage")
        base="$base | .usage_summary = \$usage"
    fi
    if [[ -n "$decisions" ]]; then
        jq_args+=(--argjson decisions "$decisions")
        base="$base | .tool_decision_counts = \$decisions"
    fi

    jq -nc "${jq_args[@]}" "$base"
}

# ─── hb_wrap_for_api ──────────────────────────────────────────
# Wrap a single heartbeat object (from hb_build_payload) into the new
# {org_id, heartbeats:[<inner>]} envelope the collector's owners published 2026-05-19.
#
# org_id source order:
#   1. $INTELLISENSE_HEARTBEAT_ORG_ID env var (test override / future rotation)
#   2. INTELLISENSE_HEARTBEAT_ORG_ID_DEFAULT below (empty: no organisation id is compiled in)
#
# Single-heartbeat array for now; queue-drain batching can stuff multiple
# entries later by calling jq with an array literal instead.
INTELLISENSE_HEARTBEAT_ORG_ID_DEFAULT=""
hb_wrap_for_api() {
    local inner_json="$1"
    local org_id="${INTELLISENSE_HEARTBEAT_ORG_ID:-$INTELLISENSE_HEARTBEAT_ORG_ID_DEFAULT}"
    jq -nc \
        --arg org_id "$org_id" \
        --argjson inner "$inner_json" \
        '{org_id: $org_id, heartbeats: [$inner]}'
}
