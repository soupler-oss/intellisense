#!/usr/bin/env bash
# scripts/intellisense-heartbeat.sh
#
# the heartbeat — intellisense daily heartbeat reporter. POSTs developer state to your
# organization's own telemetry collector (endpoint configured at setup
# time — see ~/.intellisense/heartbeat-endpoint; no default is bundled here).
#
# Triggers (installed by setup.sh / setup-repos.sh):
#   - On `bash setup.sh` first install
#   - On `bash setup-repos.sh` per-repo onboard
#   - Hourly via launchd StartInterval (Mac) / systemd --user timer
#     OnCalendar=hourly + Persistent=true (Linux; falls back to anacron, then
#     plain crontab w/ 09:00 + @reboot + hourly probe). The app-level watermark
#     makes runs with nothing due near-free (no POST, no git fetch), so hourly
#     firing recovers a transient outage within the hour instead of next day.
#
# Failure handling:
#   - POST fails (5xx, network) → write payload to ~/.claude-intellisense/heartbeat-queue/
#   - POST 401 → log to ~/.claude-intellisense/heartbeat-errors.log (token bad)
#   - POST 400 → log + alert admin (script bug)
#   - POST 429 → drop silently (next cron will retry fresh)
#   - POST 200 → drain matching queue entry
#
# Flags:
#   --dry-run       Build the payload and print to stdout; do NOT POST.
#                   No queue side-effect, no token required for this mode.
#   --drain-only    Try to drain the local queue but don't generate a new
#                   payload. Used by the cron's bookkeeping pass.
#   --allow-http    Permit INTELLISENSE_HEARTBEAT_URL with http:// (for local
#                   collector testing only — production uses HTTPS).
#
# Token discipline (per plan + user lock):
#   - Token is NEVER read from this script's args (would leak in `ps`).
#   - Token comes from $INTELLISENSE_HEARTBEAT_TOKEN env var (set by setup.sh) OR
#     from ~/.intellisense/heartbeat-token (mode 0600).
#   - Never logged. Never echoed.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve INTELLISENSE_SETUP — if this script lives at .../intellisense/scripts/, the
# parent is the INTELLISENSE_SETUP root.
INTELLISENSE_SETUP_PATH="${INTELLISENSE_SETUP_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source the pure-function payload builder.
# shellcheck source=lib/heartbeat-payload.sh
source "$SCRIPT_DIR/lib/heartbeat-payload.sh"

# ─── Defaults + flag parsing ────────────────────────────────────────────────
DRY_RUN=false
DRAIN_ONLY=false
ALLOW_HTTP=false
# No bundled default endpoint: every organization configures its own
# collector during setup.sh (written to ~/.intellisense/heartbeat-endpoint). Falling
# back to a hardcoded URL here would silently POST another org's telemetry
# to whichever server happened to ship as the "default" — never do that.
ENDPOINT_FILE="${INTELLISENSE_HEARTBEAT_ENDPOINT_FILE:-$HOME/.intellisense/heartbeat-endpoint}"
HEARTBEAT_URL="${INTELLISENSE_HEARTBEAT_URL:-$(cat "$ENDPOINT_FILE" 2>/dev/null)}"
TOKEN_FILE="${INTELLISENSE_HEARTBEAT_TOKEN_FILE:-$HOME/.intellisense/heartbeat-token}"
QUEUE_DIR="${INTELLISENSE_HEARTBEAT_QUEUE_DIR:-$HOME/.claude-intellisense/heartbeat-queue}"
ERROR_LOG="${INTELLISENSE_HEARTBEAT_ERROR_LOG:-$HOME/.claude-intellisense/heartbeat-errors.log}"
# Queue cap is env-overridable (mainly for tests); non-numeric or <1 falls back
# to 30 so a typo can't disable the bound or trim everything.
QUEUE_MAX_ENTRIES="${INTELLISENSE_HEARTBEAT_QUEUE_MAX:-30}"
if ! [[ "$QUEUE_MAX_ENTRIES" =~ ^[0-9]+$ ]] || (( QUEUE_MAX_ENTRIES < 1 )); then
    QUEUE_MAX_ENTRIES=30
fi
# App-level catch-up: launchd/systemd coalesce multiple missed
# daily fires into ONE wake, so we backfill every missing UTC period ourselves.
# STATE_FILE holds the last successfully-sent period (YYYY-MM-DD UTC).
STATE_FILE="${INTELLISENSE_HEARTBEAT_STATE_FILE:-$HOME/.claude-intellisense/heartbeat-state}"
# Cap replay so a long outage can't fan out unboundedly; also the parser can
# only reconstruct days whose transcripts still exist (retention bound).
MAX_BACKFILL_DAYS="${INTELLISENSE_HEARTBEAT_MAX_BACKFILL_DAYS:-14}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --drain-only) DRAIN_ONLY=true; shift ;;
        --allow-http) ALLOW_HTTP=true; shift ;;
        *)            shift ;;
    esac
done

# Dry-run never POSTs, so it's the one mode that works with no endpoint
# configured yet. Every other mode needs a real, org-configured collector.
if [[ "$DRY_RUN" != true && -z "$HEARTBEAT_URL" ]]; then
    echo "ERROR: no heartbeat endpoint configured." >&2
    echo "       Set INTELLISENSE_HEARTBEAT_URL, or run setup.sh to configure" >&2
    echo "       your organization's collector at $ENDPOINT_FILE." >&2
    exit 2
fi

# ─── Pre-flight ─────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for heartbeat payload assembly." >&2
    exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required for heartbeat POST." >&2
    exit 2
fi
# python3 is intentionally NOT preflighted here. It's only needed for the
# usage_summary block; if missing, hb_usage_summary() emits a State D
# block instead, and the rest of the payload (behavior_stats, gate_mode,
# onboarded_repos, tool_decision_counts) still sends. Aborting the entire
# heartbeat for a single-block dependency would violate the usage_summary contract.
# Setup-time enforcement lives in verify-setup.sh (Check 19) — that's the
# right layer for hard-failing on missing python3, where the dev can act
# on the message.

# Debug mode: emit effective PATH (with $HOME redacted) so tests can
# verify the scheduled PATH reaches subprocesses. Off by default —
# production cron runs never set INTELLISENSE_HEARTBEAT_DEBUG.
if [[ -n "${INTELLISENSE_HEARTBEAT_DEBUG:-}" ]]; then
    echo "[hb-debug] effective PATH=${PATH//$HOME/\~}" >&2
fi

# HTTPS-only by default (security baseline). Local collector testing
# is the only case http:// is acceptable, and it requires --allow-http.
if [[ "$HEARTBEAT_URL" =~ ^http:// ]] && [[ "$ALLOW_HTTP" != true ]]; then
    echo "ERROR: INTELLISENSE_HEARTBEAT_URL is http:// but --allow-http not set." >&2
    echo "       Production endpoint is HTTPS. Refusing to send token over plaintext." >&2
    exit 2
fi

mkdir -p "$QUEUE_DIR" "$(dirname "$ERROR_LOG")" "$(dirname "$STATE_FILE")" 2>/dev/null || true

# ─── Date helpers (portable: macOS BSD date -v / GNU date -d) ────────────────
_hb_yesterday() {
    date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null
}
_hb_date_to_epoch() {
    date -u -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}
_hb_epoch_to_date() {
    date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d 2>/dev/null
}

# Advance the sent-watermark to $1, but NEVER regress (guards against stale /
# old-format queue entries older than the current watermark). Lexical > on
# YYYY-MM-DD is chronological. Used by both the catch-up loop and drain so a
# queued day that drains successfully isn't re-sent by the loop.
_hb_advance_watermark() {
    local p="$1" cur=""
    [[ ! "$p" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && return 0
    [[ -f "$STATE_FILE" ]] && cur="$(head -1 "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$cur" || "$p" > "$cur" ]]; then
        printf '%s\n' "$p" > "$STATE_FILE"
    fi
}

# Extract the trailing YYYY-MM-DD from an idempotency_key (login_<date>).
# Regex-anchored so an underscore-containing login can't corrupt the parse.
_hb_period_from_idem() {
    [[ "$1" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Emit the missing UTC periods in (watermark, end], oldest→newest, one per line.
# Caps to the most-recent MAX_BACKFILL_DAYS entries (older days are unrecoverable
# anyway once transcripts rotate) and logs what it drops — no silent truncation.
hb_missing_periods() {
    local watermark="$1" end="$2"
    local we ee
    we="$(_hb_date_to_epoch "$watermark")"
    ee="$(_hb_date_to_epoch "$end")"
    if [[ -z "$we" || -z "$ee" ]]; then
        # Date math unavailable — degrade to the single most-recent day.
        printf '%s\n' "$end"
        return 0
    fi
    local -a list=()
    local cur=$(( we + 86400 ))
    while (( cur <= ee )); do
        list+=("$(_hb_epoch_to_date "$cur")")
        cur=$(( cur + 86400 ))
    done
    local n=${#list[@]}
    if (( n > MAX_BACKFILL_DAYS )); then
        local dropped=$(( n - MAX_BACKFILL_DAYS ))
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] backfill capped: dropping $dropped day(s) older than ${MAX_BACKFILL_DAYS}d window" \
            >> "$ERROR_LOG" 2>/dev/null || true
        list=("${list[@]:$dropped}")
    fi
    (( ${#list[@]} > 0 )) && printf '%s\n' "${list[@]}"
    return 0
}

# ─── Token loading (NEVER echo, NEVER log) ──────────────────────────────────
# Loads into a local var. Caller's environment never sees it leak.
load_token() {
    if [[ -n "${INTELLISENSE_HEARTBEAT_TOKEN:-}" ]]; then
        printf '%s' "$INTELLISENSE_HEARTBEAT_TOKEN"
        return 0
    fi
    if [[ -f "$TOKEN_FILE" ]]; then
        # Sanity-check file permissions (warn but proceed; rejecting on perms
        # would brick devs whose umask isn't strict)
        if command -v stat >/dev/null 2>&1; then
            local perms
            perms="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%A' "$TOKEN_FILE" 2>/dev/null || echo "")"
            if [[ -n "$perms" && "$perms" != "600" ]]; then
                echo "WARN: $TOKEN_FILE mode is $perms (expected 600). Fix: chmod 600 $TOKEN_FILE" >&2
            fi
        fi
        head -1 "$TOKEN_FILE" | tr -d '[:space:]'
        return 0
    fi
    return 1
}

# ─── POST one payload, return curl exit code + http status via globals ──────
# Sets HTTP_STATUS and CURL_RC. Token is read inside this function; never
# written to disk, never echoed.
post_payload() {
    local payload_file="$1"
    local token
    if ! token="$(load_token)" || [[ -z "$token" ]]; then
        HTTP_STATUS="000"
        CURL_RC=99   # synthetic: no token
        return
    fi

    local response_file
    response_file="$(mktemp)"
    # -sS: silent but show errors. -o: write body to file. -w: write status to stdout.
    # --max-time: bound the curl call so a hung cron doesn't pile up.
    HTTP_STATUS="$(
        curl -sS -X POST "$HEARTBEAT_URL" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -H "User-Agent: intellisense-heartbeat/$(hb_intellisense_version "$INTELLISENSE_SETUP_PATH")" \
            --data-binary "@$payload_file" \
            --max-time 15 \
            -o "$response_file" \
            -w "%{http_code}" 2>/dev/null
    )"
    CURL_RC=$?
    # Wipe the token from the local var ASAP (defense in depth)
    token=""
    rm -f "$response_file"
}

# ─── Queue handling ─────────────────────────────────────────────────────────
enqueue() {
    local payload_file="$1" idem="$2"
    # Dedup by reported period: a queued payload for this idempotency_key is
    # superseded by this one — drop stale copies so an outage can't pile up
    # multiple entries for the same day.
    if [[ -n "$idem" ]]; then
        find "$QUEUE_DIR" -maxdepth 1 -name "*__${idem}.json" -type f -delete 2>/dev/null || true
    fi
    # Trim queue to QUEUE_MAX_ENTRIES, oldest dropped first. Each drop is a real
    # data-loss event, so LOG it (full idempotency_key — not split on '_', which
    # the login can contain) rather than shedding days silently.
    local entries
    entries=$(find "$QUEUE_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    if (( entries >= QUEUE_MAX_ENTRIES )); then
        local drop_f drop_idem
        while IFS= read -r drop_f; do
            [[ -z "$drop_f" || ! -f "$drop_f" ]] && continue
            drop_idem="$(jq -r '.idempotency_key // "unknown"' "$drop_f" 2>/dev/null || echo unknown)"
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] queue_full_trim dropped idem=$drop_idem (cap=$QUEUE_MAX_ENTRIES)" \
                >> "$ERROR_LOG" 2>/dev/null || true
            rm -f "$drop_f" 2>/dev/null || true
        done < <(find "$QUEUE_DIR" -maxdepth 1 -name '*.json' -type f -print 2>/dev/null \
                    | sort | head -n $(( entries - QUEUE_MAX_ENTRIES + 1 )))
    fi
    # Filename = ISO timestamp so sort = chronological
    local fname
    fname="$QUEUE_DIR/$(date -u +%Y%m%dT%H%M%S)__${idem}.json"
    cp "$payload_file" "$fname" 2>/dev/null || true
}

drain_queue() {
    [[ -d "$QUEUE_DIR" ]] || return 0
    local f wrapped_tmp
    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        # Queue stores INNER heartbeat objects; API expects the wrapper.
        # Wrap at send time so the envelope picks up the current org_id.
        wrapped_tmp="$(mktemp)"
        hb_wrap_for_api "$(cat "$f")" > "$wrapped_tmp" 2>/dev/null
        post_payload "$wrapped_tmp"
        rm -f "$wrapped_tmp"
        case "$HTTP_STATUS" in
            2*) # delivered → drop file AND advance the watermark so the
                # catch-up loop below doesn't re-send this same period.
                _hb_advance_watermark "$(_hb_period_from_idem "$(jq -r '.idempotency_key // empty' "$f" 2>/dev/null)")"
                rm -f "$f" ;;
            429) return 0 ;;    # back off; try next cron
            401|400) rm -f "$f"
                     echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] queue-drain failed $HTTP_STATUS for $(basename "$f")" \
                         >> "$ERROR_LOG" 2>/dev/null || true
                     ;;
            *)   return 0 ;;    # keep + retry later
        esac
    done < <(find "$QUEUE_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
}

# ─── Drain-only mode ────────────────────────────────────────────────────────
if [[ "$DRAIN_ONLY" == true ]]; then
    drain_queue
    exit 0
fi

# ─── Dry-run: print yesterday's wrapped payload, no POST, no state change ────
# Price refresh in dry-run only when explicitly requested (tests/manual).
if [[ "$DRY_RUN" == true ]]; then
    [[ -n "${INTELLISENSE_HEARTBEAT_REFRESH_IN_DRYRUN:-}" ]] && hb_refresh_prices || true
    INNER_FILE="$(mktemp)"
    hb_build_payload "$INTELLISENSE_SETUP_PATH" "$PWD" > "$INNER_FILE"
    if [[ ! -s "$INNER_FILE" ]]; then
        echo "ERROR: payload assembly produced no output." >&2
        rm -f "$INNER_FILE"; exit 2
    fi
    PAYLOAD_FILE="$(mktemp)"
    hb_wrap_for_api "$(cat "$INNER_FILE")" > "$PAYLOAD_FILE"
    jq . "$PAYLOAD_FILE"
    rm -f "$PAYLOAD_FILE" "$INNER_FILE"
    exit 0
fi

# ─── Send one reported period; advances watermark only on 2xx ────────────────
# Returns 0 on delivery (2xx), 1 otherwise. On a non-2xx that isn't a transient
# rate-limit, the INNER is queued (deduped by period) for a later drain.
send_period() {
    local period="$1"
    local inner wrapped idem status
    inner="$(mktemp)"
    hb_build_payload "$INTELLISENSE_SETUP_PATH" "$PWD" "$period" > "$inner"
    if [[ ! -s "$inner" ]]; then
        echo "ERROR: payload assembly produced no output for $period." >&2
        rm -f "$inner"; return 1
    fi
    wrapped="$(mktemp)"
    hb_wrap_for_api "$(cat "$inner")" > "$wrapped"
    idem="$(jq -r '.idempotency_key // empty' "$inner")"
    post_payload "$wrapped"
    status="$HTTP_STATUS"
    case "$status" in
        2*) : ;;                          # delivered
        429) : ;;                         # transient — retry next run, do not queue
        401|400)
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] heartbeat POST failed http=$status curl_rc=$CURL_RC idem=$idem" \
                >> "$ERROR_LOG" 2>/dev/null || true
            ;;
        *)  enqueue "$inner" "$idem" ;;   # 5xx / network / no-token → queue INNER
    esac
    rm -f "$inner" "$wrapped"
    [[ "$status" == 2* ]]
}

# ─── Drain any pending queue entries first (oldest first) ──────────────────
drain_queue

# ─── App-level catch-up: send every missing period oldest→newest ────────────
END_PERIOD="$(_hb_yesterday)"
WATERMARK=""
[[ -f "$STATE_FILE" ]] && WATERMARK="$(head -1 "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')"

PERIODS=()
if [[ -z "$WATERMARK" ]]; then
    # First run (no watermark yet): send only yesterday and
    # establish the watermark. Avoids a POST-storm of empty days on new installs;
    # genuine multi-day recovery applies once a watermark exists.
    PERIODS=("$END_PERIOD")
else
    while IFS= read -r p; do
        [[ -n "$p" ]] && PERIODS+=("$p")
    done < <(hb_missing_periods "$WATERMARK" "$END_PERIOD")
fi

# Refresh the runtime price table ONLY when a period is actually due — this is
# what keeps an hourly cadence cheap: a current watermark means
# PERIODS is empty, so no `git fetch` and no POST happen. Queue draining above
# needs no prices (it re-wraps already-built INNERs). Fail-soft + bounded
# a model release / price change still reaches devs without a
# `git pull`, on the first hourly run after a new UTC day rolls over.
if (( ${#PERIODS[@]} > 0 )); then
    hb_refresh_prices || true
fi

# Nothing to do if already current (watermark >= yesterday).
for period in "${PERIODS[@]}"; do
    if send_period "$period"; then
        _hb_advance_watermark "$period"   # advance watermark on success
    else
        # Stop on first failure to keep the watermark contiguous; the queued/
        # retried day(s) resume on the next run.
        break
    fi
done

exit 0
