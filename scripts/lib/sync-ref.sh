#!/usr/bin/env bash
# sync-ref.sh — Shared integration-ref resolver/parser for the intellisense branch
# freshness sync gate (plan v7).
#
# Single source of truth for BOTH freshness gates, so they can never drift:
#   - scripts/preToolUse-contract-gate.sh  (pre-edit check; structured edits only)
#   - hooks/pre-push                        (mandatory, fail-open pre-push backstop)
# Mirrors the shared-lib pattern of scripts/lib/effective-tier.sh.
#
# This file MUST NOT have `set -e` / `set -u` at top level — it is sourced by
# callers with their own shell options and must not perturb them. Functions
# manage their own locals and NEVER exit the parent shell.
#
# ── Output contract (resolver/parser) ─────────────────────────────────────────
# sync_parse_integration_ref / sync_resolve_integration_ref echo ONE
# TAB-separated record:
#     <status>\t<confidence>\t<remote>\t<branch>
#   status:     ok | config_error | infra | none
#   confidence: explicit | inferred | guessed | "" (empty for non-ok)
#   remote/branch: decomposed target. For status=ok these are the fetch target.
#                  For config_error/infra they may carry the offending value so
#                  callers can build a precise message; never trust them as a
#                  real target unless status=ok.
#
# ── I7 (config-error ≠ infra-failure) ─────────────────────────────────────────
#   config_error = a DETERMINISTIC, purely-LOCAL syntax failure of an EXPLICIT
#                  manifest ref (empty / whitespace / control char / leading '-'
#                  / no remote segment / fails `git check-ref-format`). Callers
#                  BLOCK this in `enforced` mode, WARN otherwise.
#   infra        = anything touching the network or remote state (remote not
#                  configured, fetch failure/timeout/offline, ref absent after a
#                  successful fetch, git/jq missing). Callers ALWAYS warn+allow,
#                  never block.
# An ABSENT integration_ref is neither — resolution falls through to
# inferred/guessed and is governed by the normal enforce-on-inferred policy.

# ─── Field accessors (records are TAB-separated) ──────────────────────────────
sync_rec_status()     { printf '%s' "$1" | cut -f1; }
sync_rec_confidence() { printf '%s' "$1" | cut -f2; }
sync_rec_remote()     { printf '%s' "$1" | cut -f3; }
sync_rec_branch()     { printf '%s' "$1" | cut -f4; }

_sync_emit() {
    # _sync_emit <status> <confidence> <remote> <branch>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

# ─── Portable bounded execution (plan the heartbeat/F4) ──────────────────────────────────
# sync_bounded <seconds> <cmd...>  — runs cmd with a hard timeout. No unbounded
# git/gh calls anywhere in the freshness path. Returns cmd's exit code, or a
# non-zero (124-ish) on timeout via the kill path.
sync_bounded() {
    local secs="$1"; shift
    if   command -v timeout  >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else
        "$@" &
        local p=$!
        ( sleep "$secs"; kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null ) &
        local w=$!
        wait "$p" 2>/dev/null; local rc=$?
        kill "$w" 2>/dev/null
        return $rc
    fi
}

# ─── Strict explicit-ref parser (plan D11 / H5 / I3 / I7) ─────────────────────
# sync_parse_integration_ref <repo_root> <ref_string>
sync_parse_integration_ref() {
    local repo="$1" ref="$2"

    # (1) Reject empty / leading-dash / whitespace / control chars → CONFIG ERROR.
    #     These are deterministic, local, and never network-dependent.
    if [ -z "$ref" ]; then _sync_emit config_error explicit "" ""; return 0; fi
    case "$ref" in
        -*) _sync_emit config_error explicit "$ref" ""; return 0 ;;
    esac
    if printf '%s' "$ref" | LC_ALL=C grep -q '[[:space:][:cntrl:]]' 2>/dev/null; then
        _sync_emit config_error explicit "$ref" ""; return 0
    fi

    # (2) Remote = LONGEST prefix matching an actual configured remote name.
    #     Iterate `git remote` (do NOT split on first '/') so branch names with
    #     slashes (release/2.4) are supported.
    local remotes found="" r
    remotes=$(git -C "$repo" remote 2>/dev/null)
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        case "$ref" in
            "$r"/*) [ "${#r}" -gt "${#found}" ] && found="$r" ;;
        esac
    done <<EOF
$remotes
EOF

    if [ -z "$found" ]; then
        # No configured remote is a prefix. Two distinct cases:
        #   - ref has a '/' → it names a remote that doesn't exist → INFRA
        #     (missing remote; per I7 the user bucketed this as warn+allow).
        #   - ref has no '/' at all → structurally malformed → CONFIG ERROR.
        case "$ref" in
            */*) _sync_emit infra explicit "$ref" "" ;;
            *)   _sync_emit config_error explicit "$ref" "" ;;
        esac
        return 0
    fi
    local remote="$found" branch="${ref#$found/}"

    # (3) Confirm the remote really exists (URL resolvable). Missing → INFRA.
    if ! git -C "$repo" remote get-url "$remote" >/dev/null 2>&1; then
        _sync_emit infra explicit "$remote" "$branch"; return 0
    fi

    # (4) Validate the branch with canonical `git check-ref-format` → CONFIG
    #     ERROR on failure. Also reject a leading-dash branch component up front
    #     (arg-injection defense; check-ref-format alone may accept it).
    case "$branch" in
        ""|-*) _sync_emit config_error explicit "$remote" "$branch"; return 0 ;;
    esac
    if ! git check-ref-format "refs/heads/$branch" >/dev/null 2>&1; then
        _sync_emit config_error explicit "$remote" "$branch"; return 0
    fi

    _sync_emit ok explicit "$remote" "$branch"
    return 0
}

# ─── Tiered resolver (plan the metadata check / H2 / I4 / I5) ─────────────────────────────────
# sync_resolve_integration_ref <repo_root> <allow_gh>
#   allow_gh: "1" to permit a bounded `gh pr view` lookup (pre-edit always sets
#   1; pre-push sets it only when intellisense.sync_pr_lookup_in_prepush=true, I5).
sync_resolve_integration_ref() {
    local repo="$1" allow_gh="${2:-0}"
    local manifest="$repo/.intellisense/manifest.json"

    # explicit: manifest integration_ref (validated, may yield config_error/infra)
    if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
        local ref
        ref=$(jq -r '.integration_ref // empty' "$manifest" 2>/dev/null)
        if [ -n "$ref" ]; then
            sync_parse_integration_ref "$repo" "$ref"
            return 0
        fi
    fi

    # explicit: PR base via bounded `gh pr view` (opt-in; OFF in pre-push by
    # default per I5). gh failure is NOT a config error — fall through.
    if [ "$allow_gh" = "1" ] && command -v gh >/dev/null 2>&1; then
        local base rem=""
        base=$(sync_bounded 8 gh pr view --json baseRefName -q .baseRefName 2>/dev/null)
        if [ -n "$base" ]; then
            if   git -C "$repo" remote get-url upstream >/dev/null 2>&1; then rem=upstream
            elif git -C "$repo" remote get-url origin   >/dev/null 2>&1; then rem=origin; fi
            case "$base" in -*) base="" ;; esac
            if [ -n "$rem" ] && [ -n "$base" ] && git check-ref-format "refs/heads/$base" >/dev/null 2>&1; then
                _sync_emit ok explicit "$rem" "$base"; return 0
            fi
        fi
    fi

    # inferred: prefer the UPSTREAM default branch.
    #
    # CRITICAL (fork-workflow correctness): when an `upstream` remote exists we
    # must NEVER fall back to origin/<default> — in a fork workflow the fork's
    # OWN master IS the stale base, so comparing HEAD against it reports "fresh"
    # while you are actually behind upstream (the false-negative in Case 1 of the
    # 3-case fork review). Resolve upstream's default instead; if we cannot, FAIL
    # OPEN (infra) rather than measure against the fork.
    local sref def
    if git -C "$repo" remote get-url upstream >/dev/null 2>&1; then
        # (a) local upstream/HEAD, when set.
        sref=$(git -C "$repo" symbolic-ref "refs/remotes/upstream/HEAD" 2>/dev/null)
        def="${sref#refs/remotes/upstream/}"
        if [ -z "$sref" ] || [ "$def" = "$sref" ] || [ -z "$def" ]; then
            # (b) upstream/HEAD not set locally — the common fork case, since
            #     `git remote add upstream && git fetch` does NOT create it. Ask
            #     the remote for its real default (bounded; one round-trip,
            #     once/session via the caller's TTL marker).
            def=$(GIT_TERMINAL_PROMPT=0 sync_bounded 8 git -C "$repo" ls-remote --symref upstream HEAD 2>/dev/null \
                  | awk '/^ref:/{print $2; exit}')
            def="${def#refs/heads/}"
        fi
        if [ -n "$def" ]; then
            _sync_emit ok inferred "upstream" "$def"; return 0
        fi
        # upstream exists but its default is unresolvable (offline / odd remote):
        # fail open — never compare against the fork's master.
        _sync_emit infra inferred "upstream" ""; return 0
    fi

    # No `upstream` remote: legitimate single-remote / non-fork repo — infer the
    # integration branch from origin's HEAD.
    sref=$(git -C "$repo" symbolic-ref "refs/remotes/origin/HEAD" 2>/dev/null)
    def="${sref#refs/remotes/origin/}"
    if [ -n "$sref" ] && [ "$def" != "$sref" ] && [ -n "$def" ]; then
        _sync_emit ok inferred "origin" "$def"; return 0
    fi

    # guessed: heuristic main → master → develop against origin (no upstream here)
    local b
    if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
        for b in main master develop; do
            if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then
                _sync_emit ok guessed "origin" "$b"; return 0
            fi
        done
    fi

    _sync_emit none "" "" ""
    return 0
}

# ─── Fetch + behind-count (plan post-commit / F1 / I8) ─────────────────────────────────
# sync_fetch_and_behind <repo> <remote> <branch> [secs]
#   ALWAYS performs a bounded fetch against fresh remote state (never reuses a
#   stale tracking ref — that is the I8 guarantee for the cached-ref path), then
#   computes behind via --left-right. Echoes an integer >=0 on success, or the
#   literal "infra" on ANY infra failure (fetch fail/timeout, ref unresolvable,
#   malformed count) so callers fail-open.
sync_fetch_and_behind() {
    local repo="$1" remote="$2" branch="$3" secs="${4:-8}"
    # GIT_TERMINAL_PROMPT=0 — never block on a credential prompt; a fetch that
    # would prompt fails fast and we fail-open. The sync_bounded watchdog is the
    # hard cap for SSH/network stalls. This is correct production hardening: a
    # hook must never hang waiting for interactive input.
    if ! GIT_TERMINAL_PROMPT=0 sync_bounded "$secs" git -C "$repo" fetch --quiet "$remote" "$branch" >/dev/null 2>&1; then
        printf 'infra\n'; return 0
    fi
    local target="$remote/$branch"
    if ! git -C "$repo" rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        if git -C "$repo" rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1; then
            target="FETCH_HEAD"
        else
            printf 'infra\n'; return 0
        fi
    fi
    local lr behind
    lr=$(git -C "$repo" rev-list --left-right --count "HEAD...$target" 2>/dev/null)
    behind=$(printf '%s' "$lr" | awk '{print $2}')
    case "$behind" in
        ''|*[!0-9]*) printf 'infra\n'; return 0 ;;
    esac
    printf '%s\n' "$behind"
    return 0
}

# ─── Settings readers (plan D9) — mirror audit_chain_mode() ───────────────────
sync_enforcement_mode() {
    # <settings_file> → off|warn|enforced (default warn)
    local f="$1" m="warn" v
    if [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.intellisense.sync_enforcement // empty' "$f" 2>/dev/null)
        case "$v" in off|warn|enforced) m="$v" ;; esac
    fi
    printf '%s' "$m"
}

sync_enforce_on_inferred() {
    # <settings_file> → true|false (default false)
    local f="$1" v
    if [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.intellisense.sync_enforce_on_inferred // empty' "$f" 2>/dev/null)
        [ "$v" = "true" ] && { printf 'true'; return 0; }
    fi
    printf 'false'
}

sync_pr_lookup_in_prepush() {
    # <settings_file> → true|false (default false, I5)
    local f="$1" v
    if [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.intellisense.sync_pr_lookup_in_prepush // empty' "$f" 2>/dev/null)
        [ "$v" = "true" ] && { printf 'true'; return 0; }
    fi
    printf 'false'
}

sync_ttl_minutes() {
    # <settings_file> <status> → minutes. Per-status defaults: fresh/declined 240,
    # warned_behind 60, fail_open 20.
    # NB: local var is 'st' not 'status' — 'status' is a read-only special
    # variable in zsh and `local status` aborts the function if anyone sources
    # this lib from a zsh context.
    local f="$1" st="$2" def v
    case "$st" in
        fresh|declined) def=240 ;;
        warned_behind)  def=60 ;;
        fail_open)      def=20 ;;
        *)              def=60 ;;
    esac
    if [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r --arg s "$st" '.intellisense.sync_recheck_ttl_minutes[$s] // empty' "$f" 2>/dev/null)
        case "$v" in ''|*[!0-9]*) ;; *) def="$v" ;; esac
    fi
    printf '%s' "$def"
}

# ─── Enforcement decision (plan H2) ───────────────────────────────────────────
# sync_should_block <mode> <confidence> <enforce_on_inferred>
#   → "block" | "warn". guessed NEVER blocks; inferred blocks only on opt-in;
#   explicit blocks when mode=enforced.
sync_should_block() {
    local mode="$1" conf="$2" eoi="$3"
    [ "$mode" = "enforced" ] || { printf 'warn'; return 0; }
    case "$conf" in
        explicit) printf 'block' ;;
        inferred) [ "$eoi" = "true" ] && printf 'block' || printf 'warn' ;;
        *)        printf 'warn' ;;
    esac
}

# ─── Cached-ref reader for pre-push (plan I5 / I8 / OQ7) ───────────────────────
# sync_read_cached_ref <repo_root> <settings_file>
#   Reads .intellisense/session/current-session-id → that session's freshness marker,
#   and if the marker is within its per-status TTL AND carries a still-valid
#   target, echoes "<confidence>\t<remote>\t<branch>". Else echoes nothing.
#   This is a TARGET-DISCOVERY cache only (I8): callers MUST still fetch+verify
#   against fresh remote state before computing behind.
sync_read_cached_ref() {
    local repo="$1" settings="$2"
    command -v jq >/dev/null 2>&1 || return 0
    local sid_file="$repo/.intellisense/session/current-session-id"
    [ -f "$sid_file" ] || return 0
    local sid; sid=$(tr -d '[:space:]' < "$sid_file" 2>/dev/null)
    [ -n "$sid" ] || return 0
    local marker="$repo/.intellisense/session/${sid}.sync-freshness-checked"
    [ -f "$marker" ] || return 0
    # 'st' not 'status' — zsh read-only special variable (see sync_ttl_minutes).
    local st ts target conf
    st=$(jq -r '.status // empty' "$marker" 2>/dev/null)
    ts=$(jq -r '.ts // empty' "$marker" 2>/dev/null)
    target=$(jq -r '.target // empty' "$marker" 2>/dev/null)
    conf=$(jq -r '.confidence // empty' "$marker" 2>/dev/null)
    [ -n "$target" ] && [ -n "$conf" ] || return 0
    case "$ts" in ''|*[!0-9]*) return 0 ;; esac
    local now ttl_min age_min
    now=$(date +%s 2>/dev/null); case "$now" in ''|*[!0-9]*) return 0 ;; esac
    ttl_min=$(sync_ttl_minutes "$settings" "$st")
    age_min=$(( (now - ts) / 60 ))
    [ "$age_min" -gt "$ttl_min" ] && return 0
    # Re-decompose + re-validate the cached target (remote may have changed).
    local parsed pst prem pbr
    parsed=$(sync_parse_integration_ref "$repo" "$target")
    pst=$(sync_rec_status "$parsed")
    prem=$(sync_rec_remote "$parsed")
    pbr=$(sync_rec_branch "$parsed")
    [ "$pst" = "ok" ] || return 0
    printf '%s\t%s\t%s\n' "$conf" "$prem" "$pbr"
}
