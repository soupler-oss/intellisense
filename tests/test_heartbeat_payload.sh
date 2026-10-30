#!/usr/bin/env bash
# tests/test_heartbeat_payload.sh
#
# Tests for the heartbeat payload builder (scripts/lib/heartbeat-payload.sh).
# Pure-function unit tests — no network, no real config files.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/heartbeat-payload.sh"

# shellcheck source=../scripts/lib/heartbeat-payload.sh
source "$LIB"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: hb_intellisense_version reads VERSION file ==="
TMP=$(mktemp -d)
echo "9.9.9" > "$TMP/VERSION"
v="$(hb_intellisense_version "$TMP")"
[[ "$v" == "9.9.9" ]] && pass "VERSION read correctly" || fail "got '$v' expected '9.9.9'"
rm -rf "$TMP"

echo "=== Case 1b: hb_intellisense_version falls back to 'unknown' when no VERSION ==="
TMP=$(mktemp -d)
v="$(hb_intellisense_version "$TMP")"
[[ "$v" == "unknown" ]] && pass "missing VERSION → 'unknown'" || fail "got '$v'"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: hb_platform returns a lowercase string ==="
p="$(hb_platform)"
[[ "$p" =~ ^[a-z]+$ ]] && pass "platform='$p' is lowercase" || fail "platform='$p'"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: hb_gate_mode reads intellisense.gate_mode from settings.json ==="
TMP_SETTINGS=$(mktemp)
jq -n '{intellisense: {gate_mode: "enforced"}}' > "$TMP_SETTINGS"
gm="$(hb_gate_mode "$TMP_SETTINGS")"
[[ "$gm" == "enforced" ]] && pass "gate_mode='enforced' read correctly" || fail "got '$gm'"
rm -f "$TMP_SETTINGS"

echo "=== Case 3b: hb_gate_mode defaults to 'pilot' when key absent ==="
TMP_SETTINGS=$(mktemp)
echo '{}' > "$TMP_SETTINGS"
gm="$(hb_gate_mode "$TMP_SETTINGS")"
[[ "$gm" == "pilot" ]] && pass "missing intellisense.gate_mode → 'pilot'" || fail "got '$gm'"
rm -f "$TMP_SETTINGS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: hb_idempotency_key shape <login>_<date> ==="
k="$(hb_idempotency_key "alice" "2026-05-19")"
[[ "$k" == "alice_2026-05-19" ]] && pass "idempotency_key='$k'" || fail "got '$k'"

echo "=== Case 4b: hb_idempotency_key handles empty login → 'unknown_<date>' ==="
k="$(hb_idempotency_key "" "2026-05-19")"
[[ "$k" == "unknown_2026-05-19" ]] && pass "empty login → 'unknown'" || fail "got '$k'"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: hb_onboarded_repos returns [] when both sources missing ==="
r="$(hb_onboarded_repos /no/such/tsv /no/such/registry.json)"
[[ "$r" == "[]" ]] && pass "missing tsv + registry → []" || fail "got '$r'"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5b: hb_onboarded_repos reads from primary tsv source ==="
TMP_TSV="$(mktemp)"
TMP_REPO_WITH="$(mktemp -d)"
TMP_REPO_WITHOUT="$(mktemp -d)"
touch "$TMP_REPO_WITH/CLAUDE.md"  # one has CLAUDE.md, one doesn't
{
    printf '%s\tgo\n' "$TMP_REPO_WITH"
    printf '%s\tpython\n' "$TMP_REPO_WITHOUT"
} > "$TMP_TSV"

r="$(hb_onboarded_repos "$TMP_TSV" /no/such/registry.json)"
n=$(echo "$r" | jq 'length' 2>/dev/null)
[[ "$n" == "2" ]] && pass "Case 5b: tsv with 2 entries → 2 repos" || fail "got $n entries"

# F4 verification — real filesystem check, not jq predicate
with_claude_md=$(echo "$r" | jq -r --arg p "$TMP_REPO_WITH" '.[] | select(.path == $p) | .claude_md_present')
without_claude_md=$(echo "$r" | jq -r --arg p "$TMP_REPO_WITHOUT" '.[] | select(.path == $p) | .claude_md_present')
[[ "$with_claude_md" == "true" ]] && pass "F4: claude_md_present=true when CLAUDE.md exists" \
    || fail "F4: got '$with_claude_md', expected true"
[[ "$without_claude_md" == "false" ]] && pass "F4: claude_md_present=false when CLAUDE.md missing" \
    || fail "F4: got '$without_claude_md', expected false"

# stack from tsv
go_stack=$(echo "$r" | jq -r --arg p "$TMP_REPO_WITH" '.[] | select(.path == $p) | .stack')
[[ "$go_stack" == "go" ]] && pass "Case 5b: stack read from tsv" || fail "stack='$go_stack'"
rm -rf "$TMP_TSV" "$TMP_REPO_WITH" "$TMP_REPO_WITHOUT"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5c: hb_onboarded_repos dedups across primary + fallback ==="
TMP_TSV="$(mktemp)"
TMP_REG="$(mktemp)"
SHARED_PATH="$(mktemp -d)"
printf '%s\tgo\n' "$SHARED_PATH" > "$TMP_TSV"
jq -n --arg p "$SHARED_PATH" \
    '{projects: [{path: $p, stack: "python", repo: "should-not-win"}]}' > "$TMP_REG"

r="$(hb_onboarded_repos "$TMP_TSV" "$TMP_REG")"
n=$(echo "$r" | jq 'length')
[[ "$n" == "1" ]] && pass "Case 5c: dedup by path (1 entry not 2)" || fail "dedup failed, got $n"
won_stack=$(echo "$r" | jq -r '.[0].stack')
[[ "$won_stack" == "go" ]] && pass "Case 5c: primary tsv wins over fallback registry" \
    || fail "stack='$won_stack' (expected 'go' from tsv)"
rm -f "$TMP_TSV" "$TMP_REG"; rm -rf "$SHARED_PATH"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5d (F1): hb_github_login fallback chain ==="
# When gh is missing, the chain should fall through to env var, then git
# config email, then $USER. We test with a controlled environment.
login_via_env=$(
    PATH="/usr/bin:/bin" \
    INTELLISENSE_GH_LOGIN="env-override-user" \
    bash -c "source '$LIB' && hb_github_login"
)
[[ "$login_via_env" == "env-override-user" ]] \
    && pass "F1: INTELLISENSE_GH_LOGIN env override wins when gh missing" \
    || fail "F1: got '$login_via_env'"

# No gh, no env-var, but USER set → use $USER
login_via_user=$(
    PATH="/usr/bin:/bin" \
    USER="some-real-user" \
    HOME="$(mktemp -d)" \
    bash -c "unset INTELLISENSE_GH_LOGIN; source '$LIB' && hb_github_login"
)
[[ "$login_via_user" == "some-real-user" ]] \
    && pass "F1: \$USER fallback when no gh, no env" \
    || fail "F1: got '$login_via_user'"

# No gh, no env-var, no USER, no git config → empty (caller substitutes 'unknown')
# Override HOME so 'git config --global' reads from an empty config file.
TMP_HOME_EMPTY=$(mktemp -d)
login_empty=$(
    PATH="/usr/bin:/bin" \
    HOME="$TMP_HOME_EMPTY" \
    bash -c "unset INTELLISENSE_GH_LOGIN USER; source '$LIB' && hb_github_login"
)
[[ -z "$login_empty" ]] \
    && pass "F1: empty when nothing resolves (caller maps to 'unknown')" \
    || fail "F1: got '$login_empty' (expected empty)"
rm -rf "$TMP_HOME_EMPTY"

# ─────────────────────────────────────────────────────────────────────────────
# Case 5e: env wins over wrong git email.
# setup.sh resolves the GitHub username and bakes it into the launchd plist's
# EnvironmentVariables. When the cron fires under launchd (no gh keychain),
# INTELLISENSE_GH_LOGIN must beat the email local-part, or baking the env var
# has no effect.
echo "=== Case 5e: INTELLISENSE_GH_LOGIN env beats wrong git email ==="
TMP_HOME_5e=$(mktemp -d)
git config --file "$TMP_HOME_5e/.gitconfig" user.email "test.user@example.com"
login_5e=$(
    PATH="/usr/bin:/bin" \
    INTELLISENSE_GH_LOGIN="test-github-login" \
    HOME="$TMP_HOME_5e" \
    bash -c "source '$LIB' && hb_github_login"
)
[[ "$login_5e" == "test-github-login" ]] \
    && pass "5e: env 'test-github-login' wins over email local-part 'test.user'" \
    || fail "5e: got '$login_5e' (expected 'test-github-login') — env override broken"
rm -rf "$TMP_HOME_5e"

# Case 5g: INTELLISENSE_GH_LOGIN must beat gh CLI when gh is present and
# authenticated. gh may be authenticated against a GitHub Enterprise account
# (e.g. "firstname.lastname"); the env-var override baked into the launchd
# plist / crontab by setup.sh must still win.
echo "=== Case 5g: INTELLISENSE_GH_LOGIN beats gh CLI when gh is present ==="
TMP_GH_DIR_5g=$(mktemp -d)
cat > "$TMP_GH_DIR_5g/gh" <<'GHSHIM'
#!/bin/bash
# Mimics `gh api user --jq .login` returning a GitHub Enterprise login that
# differs from the developer's github.com handle.
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo "first.last"
    exit 0
fi
exit 1
GHSHIM
chmod +x "$TMP_GH_DIR_5g/gh"
login_5g=$(
    PATH="$TMP_GH_DIR_5g:/usr/bin:/bin" \
    INTELLISENSE_GH_LOGIN="gh-handle" \
    bash -c "source '$LIB' && hb_github_login"
)
[[ "$login_5g" == "gh-handle" ]] \
    && pass "5g: env 'gh-handle' wins over gh CLI 'first.last' (override semantics intact)" \
    || fail "5g: got '$login_5g' (expected 'gh-handle') — gh-first ordering would have produced 'first.last'"
rm -rf "$TMP_GH_DIR_5g"

# Case 5f: email local-part fallback is the documented safety net.
# Product decision (recorded in change contract): wrong identity > no identity
# for internal telemetry. When setup.sh failed to populate INTELLISENSE_GH_LOGIN
# (e.g., dev installed before this fix, or non-interactive without the env
# pre-set), step 3 must still emit *something* so the heartbeat carries a
# stable-ish identifier rather than degrading to 'unknown'. This test exists
# specifically so that future cleanup PRs don't silently delete the email
# fallback and reintroduce the empty-identity regression that the 2026-05-19
# fix already addressed.
echo "=== Case 5f: email local-part safety net preserved when env unset ==="
TMP_HOME_5f=$(mktemp -d)
HOME="$TMP_HOME_5f" git config --global user.email "test.user@example.com"
login_5f=$(
    PATH="/usr/bin:/bin" \
    USER="" \
    HOME="$TMP_HOME_5f" \
    bash -c "unset INTELLISENSE_GH_LOGIN; source '$LIB' && hb_github_login"
)
[[ "$login_5f" == "test.user" ]] \
    && pass "5f: email fallback still emits local-part when env unset (safety net intact)" \
    || fail "5f: got '$login_5f' — safety net broken; devs would degrade to 'unknown'"
rm -rf "$TMP_HOME_5f"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6: hb_build_payload contains all required top-level keys ==="
# Isolate HOME so the build_payload picks up our test tsv, not the real one
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
echo "1.2.3" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session" "$TMP_HOME/.intellisense"
printf '%s\tunknown\n' "$TMP_WS" > "$TMP_HOME/.intellisense/onboarded-repos.tsv"

YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)
jq -n --arg ts "${YESTERDAY}T10:00:00Z" \
    '{tier:"1", mode:"bug_fix", session_id:"x", classification_id:"y", prompt_hash:"z", timestamp:$ts}' \
    > "$TMP_WS/.intellisense/session/x.classification.json"

PAYLOAD=$(HOME="$TMP_HOME" hb_build_payload "$TMP_SETUP" "$TMP_WS")
echo "$PAYLOAD" | jq . >/dev/null 2>&1 && pass "payload is valid JSON" || fail "payload not valid JSON: $PAYLOAD"

for key in event_type schema timestamp github_login intellisense_version platform gate_mode onboarded_repos behavior_stats idempotency_key; do
    echo "$PAYLOAD" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1 \
        && pass "payload has '$key'" || fail "payload missing '$key'"
done

for f in period classifier_overrides_today local_trailer_drift_count audit_chain_warnings_today mode_mix top_skills_used plan_to_commit_ratio; do
    echo "$PAYLOAD" | jq -e --arg f "$f" '.behavior_stats | has($f)' >/dev/null 2>&1 \
        && pass "behavior_stats.$f present" || fail "behavior_stats.$f missing"
done

echo "$PAYLOAD" | jq -e '.event_type == "developer_heartbeat"' >/dev/null 2>&1 \
    && pass "event_type = developer_heartbeat" || fail "event_type wrong"
echo "$PAYLOAD" | jq -e '.schema == 1' >/dev/null 2>&1 \
    && pass "schema = 2" || fail "schema wrong"
echo "$PAYLOAD" | jq -e '.intellisense_version == "1.2.3"' >/dev/null 2>&1 \
    && pass "intellisense_version read from custom path" || fail "intellisense_version wrong"
echo "$PAYLOAD" | jq -e '.behavior_stats.mode_mix.bug_fix == 1' >/dev/null 2>&1 \
    && pass "behavior_stats counted yesterday's classification" \
    || fail "behavior_stats didn't aggregate the test fixture: $(echo "$PAYLOAD" | jq -c '.behavior_stats')"

# F1 verification: github_login must NEVER be empty (caller substitutes 'unknown')
login_in_payload=$(echo "$PAYLOAD" | jq -r '.github_login')
[[ -n "$login_in_payload" ]] && pass "F1: github_login is non-empty in payload" \
    || fail "F1: github_login empty in payload"

rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6b (F2): launchd-equivalent — PWD=\$HOME, behavior_stats still populated ==="
# Daily cron runs from $HOME (no .intellisense/session/ there),
# previous code returned empty mode_mix. New code reads from the onboarded-
# repos.tsv and aggregates across listed repo paths even when PWD has nothing.
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session" "$TMP_HOME/.intellisense"
printf '%s\tgo\n' "$TMP_WS" > "$TMP_HOME/.intellisense/onboarded-repos.tsv"
jq -n --arg ts "${YESTERDAY}T10:00:00Z" \
    '{mode:"bug_fix", session_id:"sid1", timestamp:$ts}' \
    > "$TMP_WS/.intellisense/session/sid1.classification.json"
jq -n --arg ts "${YESTERDAY}T11:00:00Z" \
    '{mode:"full_feature", session_id:"sid2", timestamp:$ts}' \
    > "$TMP_WS/.intellisense/session/sid2.classification.json"

# Run from TMP_HOME — mimics launchd which has no idea about repo paths
PAYLOAD=$(cd "$TMP_HOME" && HOME="$TMP_HOME" hb_build_payload "$TMP_SETUP" "$TMP_HOME")
mm=$(echo "$PAYLOAD" | jq -c '.behavior_stats.mode_mix')
bug_count=$(echo "$PAYLOAD" | jq -r '.behavior_stats.mode_mix.bug_fix // 0')
feat_count=$(echo "$PAYLOAD" | jq -r '.behavior_stats.mode_mix.full_feature // 0')
[[ "$bug_count" == "1" && "$feat_count" == "1" ]] \
    && pass "F2: mode_mix aggregated across registry repos (cron-equivalent path)" \
    || fail "F2: mode_mix=$mm — daily cron would have produced this; expected bug_fix=1, full_feature=1"

# Should NOT have used PWD as the source (TMP_HOME has no .intellisense/session)
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6c (F2): multi-repo aggregation across two onboarded paths ==="
TMP_HOME=$(mktemp -d)
TMP_WS_A=$(mktemp -d)
TMP_WS_B=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS_A/.intellisense/session" "$TMP_WS_B/.intellisense/session" "$TMP_HOME/.intellisense"
printf '%s\tgo\n%s\tphp\n' "$TMP_WS_A" "$TMP_WS_B" > "$TMP_HOME/.intellisense/onboarded-repos.tsv"

# Repo A: 2 bug_fix sessions yesterday with /plan skill
jq -n --arg ts "${YESTERDAY}T09:00:00Z" \
    '{mode:"bug_fix", session_id:"a1", timestamp:$ts}' \
    > "$TMP_WS_A/.intellisense/session/a1.classification.json"
jq -n --arg ts "${YESTERDAY}T09:30:00Z" \
    '{mode:"bug_fix", session_id:"a2", timestamp:$ts}' \
    > "$TMP_WS_A/.intellisense/session/a2.classification.json"
jq -n --arg ts "${YESTERDAY}T09:00:00Z" \
    '{session_id:"a1", skills_used:["plan","tdd"], agents_spawned:[], first_prompt_ts:$ts}' \
    > "$TMP_WS_A/.intellisense/session/a1.usage.json"

# Repo B: 1 refactor session yesterday with /plan skill
jq -n --arg ts "${YESTERDAY}T14:00:00Z" \
    '{mode:"refactor", session_id:"b1", timestamp:$ts}' \
    > "$TMP_WS_B/.intellisense/session/b1.classification.json"
jq -n --arg ts "${YESTERDAY}T14:00:00Z" \
    '{session_id:"b1", skills_used:["plan","code-review"], agents_spawned:[], first_prompt_ts:$ts}' \
    > "$TMP_WS_B/.intellisense/session/b1.usage.json"

PAYLOAD=$(HOME="$TMP_HOME" hb_build_payload "$TMP_SETUP" "$TMP_HOME")
mm=$(echo "$PAYLOAD" | jq -c '.behavior_stats.mode_mix')
echo "$PAYLOAD" | jq -e '.behavior_stats.mode_mix.bug_fix == 2' >/dev/null 2>&1 \
    && pass "F2: bug_fix=2 aggregated from repo A" \
    || fail "F2: bug_fix wrong in mode_mix=$mm"
echo "$PAYLOAD" | jq -e '.behavior_stats.mode_mix.refactor == 1' >/dev/null 2>&1 \
    && pass "F2: refactor=1 aggregated from repo B" \
    || fail "F2: refactor missing in mode_mix=$mm"

# top_skills_used should include plan twice (once per repo) + tdd + code-review
plan_count=$(echo "$PAYLOAD" | jq -r '.behavior_stats.top_skills_used[] | select(.skill == "plan") | .count')
[[ "$plan_count" == "2" ]] && pass "F2: top_skills.plan=2 (cross-repo union)" \
    || fail "F2: plan count=$plan_count (expected 2)"
rm -rf "$TMP_HOME" "$TMP_WS_A" "$TMP_WS_B" "$TMP_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7: behavior_stats.period is yesterday's date (UTC) ==="
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session"
EXPECTED_PERIOD=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)
PAYLOAD=$(HOME="$TMP_HOME" hb_build_payload "$TMP_SETUP" "$TMP_WS")
got=$(echo "$PAYLOAD" | jq -r '.behavior_stats.period')
[[ "$got" == "$EXPECTED_PERIOD" ]] && pass "period=$EXPECTED_PERIOD (yesterday UTC)" \
    || fail "period=$got expected=$EXPECTED_PERIOD"
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
# usage_summary is ALWAYS present; one of states A/B/C/D.
echo "=== Case 8: usage_summary always present, State B for empty transcripts ==="
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
TMP_TRANSCRIPTS=$(mktemp -d)   # empty dir → State B
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session"
# Use scheduled-equivalent PATH so jq/python3 resolve
SCHED_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PAYLOAD=$( PATH="$SCHED_PATH" HOME="$TMP_HOME" \
    HB_CLAUDE_PROJECTS_DIR="$TMP_TRANSCRIPTS" INTELLISENSE_PRICES_MAX_AGE_DAYS=100000 \
    bash -c "source '$LIB' && hb_build_payload '$TMP_SETUP' '$TMP_WS'" 2>/dev/null )
echo "$PAYLOAD" | jq -e 'has("usage_summary")' >/dev/null && \
    pass "Case 8: usage_summary present" || \
    fail "Case 8: usage_summary missing — $(echo "$PAYLOAD" | jq -c .)"
echo "$PAYLOAD" | jq -e '.usage_summary.cost_estimation_status == "complete"' >/dev/null && \
    pass "Case 8: empty transcripts → State B (status=complete)" || \
    fail "Case 8: empty transcripts wrong state"
echo "$PAYLOAD" | jq -e '.usage_summary.sessions == 0' >/dev/null && \
    pass "Case 8: idle sessions=0" || \
    fail "Case 8: idle sessions not 0"
echo "$PAYLOAD" | jq -e '.usage_summary.warnings == []' >/dev/null && \
    pass "Case 8: idle warnings=[]" || \
    fail "Case 8: idle warnings not empty"
echo "$PAYLOAD" | jq -e '.usage_summary | has("error") | not' >/dev/null && \
    pass "Case 8: idle has no error key" || \
    fail "Case 8: idle has error key"
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP" "$TMP_TRANSCRIPTS"

# ─────────────────────────────────────────────────────────────────────────────
# Collector API contract: POST body is a wrapper {org_id, heartbeats:[<inner>]};
# usage_summary carries total_cost, total_tokens and model_breakdowns.

echo "=== Case 9: usage_summary uses total_cost ==="
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
TMP_TRANSCRIPTS=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session"
SCHED_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PAYLOAD=$( PATH="$SCHED_PATH" HOME="$TMP_HOME" \
    HB_CLAUDE_PROJECTS_DIR="$TMP_TRANSCRIPTS" INTELLISENSE_PRICES_MAX_AGE_DAYS=100000 \
    bash -c "source '$LIB' && hb_build_payload '$TMP_SETUP' '$TMP_WS'" 2>/dev/null )
echo "$PAYLOAD" | jq -e '.usage_summary | has("total_cost")' >/dev/null && \
    pass "Case 9: usage_summary.total_cost present" || \
    fail "Case 9: usage_summary.total_cost missing — $(echo "$PAYLOAD" | jq -c '.usage_summary')"
echo "$PAYLOAD" | jq -e '.usage_summary | has("total_cost_usd") | not' >/dev/null && \
    pass "Case 9: usage_summary has no total_cost_usd field" || \
    fail "Case 9: unexpected total_cost_usd field"
echo "$PAYLOAD" | jq -e '.usage_summary | has("total_tokens")' >/dev/null && \
    pass "Case 9: usage_summary.total_tokens present" || \
    fail "Case 9: usage_summary.total_tokens missing"
echo "$PAYLOAD" | jq -e '.usage_summary | has("model_breakdowns")' >/dev/null && \
    pass "Case 9: usage_summary.model_breakdowns present (array, possibly empty)" || \
    fail "Case 9: usage_summary.model_breakdowns missing"
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP" "$TMP_TRANSCRIPTS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 10 (v3 contract): hb_wrap_for_api wraps payload in {org_id, heartbeats:[...]} ==="
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
mkdir -p "$TMP_WS/.intellisense/session"
INNER=$(HOME="$TMP_HOME" hb_build_payload "$TMP_SETUP" "$TMP_WS")
WRAPPED=$(INTELLISENSE_HEARTBEAT_ORG_ID="test-org-uuid-12345" \
    bash -c "source '$LIB' && hb_wrap_for_api '$(printf '%s' "$INNER" | sed "s/'/'\\\\''/g")'" 2>/dev/null)
echo "$WRAPPED" | jq -e '.org_id == "test-org-uuid-12345"' >/dev/null && \
    pass "Case 9: wrapper.org_id from env var" || \
    fail "Case 9: wrapper.org_id wrong/missing — $(echo "$WRAPPED" | jq -c '.org_id // "ABSENT"')"
echo "$WRAPPED" | jq -e '.heartbeats | type == "array" and length == 1' >/dev/null && \
    pass "Case 9: wrapper.heartbeats is single-element array" || \
    fail "Case 9: wrapper.heartbeats not a 1-element array"
echo "$WRAPPED" | jq -e '.heartbeats[0].event_type == "developer_heartbeat"' >/dev/null && \
    pass "Case 9: wrapper.heartbeats[0] preserves inner payload" || \
    fail "Case 9: inner payload lost in wrap"
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
# hb_onboarded_repos must skip tsv entries whose paths no longer
# exist on disk. setup-repos.sh appends to the tsv on every onboarding run,
# including throwaway /tmp/ test dirs. Without this filter, production
# payload reports ghost repos to the analytics dashboard.
echo "=== Case 11: hb_onboarded_repos skips paths that no longer exist ==="
TMP_HOME=$(mktemp -d)
ALIVE_PATH=$(mktemp -d)   # exists
DEAD_PATH="$TMP_HOME/this-was-deleted-yesterday"   # does NOT exist
mkdir -p "$TMP_HOME/.intellisense"
printf '%s\tgo\n%s\tpython\n' "$ALIVE_PATH" "$DEAD_PATH" \
    > "$TMP_HOME/.intellisense/onboarded-repos.tsv"

REPOS=$(HOME="$TMP_HOME" hb_onboarded_repos)
count=$(echo "$REPOS" | jq 'length')
[[ "$count" == "1" ]] && pass "tk0: stale path filtered (count=$count)" \
    || fail "tk0: expected 1 alive entry, got $count — full: $(echo "$REPOS" | jq -c .)"
alive_emitted=$(echo "$REPOS" | jq -r '.[0].path // ""')
[[ "$alive_emitted" == "$ALIVE_PATH" ]] && pass "tk0: only the alive path emitted" \
    || fail "tk0: alive path missing — got '$alive_emitted'"
echo "$REPOS" | jq -e --arg dead "$DEAD_PATH" '[.[] | select(.path == $dead)] | length == 0' >/dev/null \
    && pass "tk0: dead path absent from payload" \
    || fail "tk0: dead path leaked into payload"
rm -rf "$TMP_HOME" "$ALIVE_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# routing aggregation must dedup before counting.
# Summing every JSONL line would count a session that recorded the same
# escalation 3× (one per gated edit) as 3 escalations / 3 tier_2 promotions.
# hb_behavior_stats dedupes by event_id, with fallback
# {session_file, from_tier, to_tier, trigger, reason} when event_id is empty.

echo "=== Case 12: heartbeat dedupes duplicate routing rows by event_id ==="
TMP_WS=$(mktemp -d)
SID="sid-routing-dup"
mkdir -p "$TMP_WS/.intellisense/session"
ROUTING="$TMP_WS/.intellisense/session/${SID}.routing.jsonl"
PERIOD=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d)
cat > "$ROUTING" <<EOF
{"event_id":"dup1abc000000001","ts":"${PERIOD}T10:00:00Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
{"event_id":"dup1abc000000001","ts":"${PERIOD}T10:00:05Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
{"event_id":"dup1abc000000001","ts":"${PERIOD}T10:00:10Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
EOF

STATS=$(hb_behavior_stats "[\"$TMP_WS\"]" "$PERIOD")
echo "$STATS" | jq -e '.routing_stats.escalations_today == 1' >/dev/null 2>&1 \
    && pass "Case 12: 3 duplicate rows → escalations_today=1" \
    || fail "Case 12: escalations_today=$(echo "$STATS" | jq -r '.routing_stats.escalations_today')"
echo "$STATS" | jq -e '.routing_stats.promotions_count.tier_2 == 1' >/dev/null 2>&1 \
    && pass "Case 12: promotions_count.tier_2=1 (unique events)" \
    || fail "Case 12: promotions_count.tier_2=$(echo "$STATS" | jq -r '.routing_stats.promotions_count.tier_2')"
echo "$STATS" | jq -e '.routing_stats.promotions_count.high_risk_file == 1' >/dev/null 2>&1 \
    && pass "Case 12: promotions_count.high_risk_file=1 (unique events)" \
    || fail "Case 12: promotions_count.high_risk_file=$(echo "$STATS" | jq -r '.routing_stats.promotions_count.high_risk_file')"
rm -rf "$TMP_WS"

echo "=== Case 13: rows with empty event_id dedup by fallback key ==="
TMP_WS=$(mktemp -d)
SID="sid-routing-noeid"
mkdir -p "$TMP_WS/.intellisense/session"
ROUTING="$TMP_WS/.intellisense/session/${SID}.routing.jsonl"
# Two duplicate rows (same {from,to,trigger,reason}, no event_id) AND
# one distinct row (different trigger/reason) — fallback dedup must
# collapse the first two into one, keep the third as a separate event.
cat > "$ROUTING" <<EOF
{"ts":"${PERIOD}T11:00:00Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
{"ts":"${PERIOD}T11:01:00Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
{"ts":"${PERIOD}T11:02:00Z","kind":"escalation","from_tier":0,"to_tier":1,"trigger":"policy_floor","reason":"policy_minimum_tier","phase":"implement"}
EOF

STATS=$(hb_behavior_stats "[\"$TMP_WS\"]" "$PERIOD")
echo "$STATS" | jq -e '.routing_stats.escalations_today == 2' >/dev/null 2>&1 \
    && pass "Case 13: fallback dedup → escalations_today=2 (1 dup, 1 distinct)" \
    || fail "Case 13: escalations_today=$(echo "$STATS" | jq -r '.routing_stats.escalations_today')"
echo "$STATS" | jq -e '.routing_stats.promotions_count.tier_2 == 1' >/dev/null 2>&1 \
    && pass "Case 13: tier_2=1 (collapsed duplicates)" \
    || fail "Case 13: tier_2=$(echo "$STATS" | jq -r '.routing_stats.promotions_count.tier_2')"
echo "$STATS" | jq -e '.routing_stats.promotions_count.high_risk_file == 1' >/dev/null 2>&1 \
    && pass "Case 13: high_risk_file=1 (only the financial event)" \
    || fail "Case 13: high_risk_file=$(echo "$STATS" | jq -r '.routing_stats.promotions_count.high_risk_file')"
rm -rf "$TMP_WS"

# ─────────────────────────────────────────────────────────────────────────────
# Cases 14–21: price-table refresh + synthetic zero-cost + prices_stale
# All hermetic — no network (hb_refresh_prices network path is exercised only
# via in_repo_skip + fail-soft branches here; a live fetch is opt-in below).
PARSER="$REPO_ROOT/scripts/lib/heartbeat_usage_parser.py"
PRICES="$REPO_ROOT/scripts/lib/heartbeat-prices.json"
HBPERIOD="2026-06-03"

_mk_transcripts() {  # $1=dir, $2=model, $3=in, $4=out  -> writes one event
    mkdir -p "$1/proj"
    printf '{"timestamp":"%sT10:00:00Z","sessionId":"s","requestId":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
        "$HBPERIOD" "$RANDOM" "$2" "$3" "$4" >> "$1/proj/s.jsonl"
}

echo "=== Case 14: opus-4-8 is priced (not unknown) ==="
TMP=$(mktemp -d); _mk_transcripts "$TMP" "claude-opus-4-8" 1000000 1000000
OUT=$(python3 "$PARSER" --period "$HBPERIOD" --prices "$PRICES" --transcripts-dir "$TMP" 2>/dev/null)
echo "$OUT" | jq -e '(.unknown_models|length==0) and (.total_cost==30.0)' >/dev/null 2>&1 \
    && pass "Case 14: opus-4-8 priced, cost=30.0 (1M*5 + 1M*25)" \
    || fail "Case 14: cost=$(echo "$OUT"|jq -r .total_cost) unknown=$(echo "$OUT"|jq -c .unknown_models)"
rm -rf "$TMP"

echo "=== Case 15: opus-4.5+ at 5/25, opus-4-1 at 15/75 (3x correction) ==="
jq -e '.models[] | select(.canonical=="claude-opus-4-6") | .input_per_mtok==5 and .output_per_mtok==25' "$PRICES" >/dev/null 2>&1 \
    && pass "Case 15: opus-4-6 = 5/25" || fail "Case 15: opus-4-6 = $(jq -r '.models[]|select(.canonical=="claude-opus-4-6")|"\(.input_per_mtok)/\(.output_per_mtok)"' "$PRICES")"
jq -e '.models[] | select(.canonical=="claude-opus-4-1") | .input_per_mtok==15 and .output_per_mtok==75' "$PRICES" >/dev/null 2>&1 \
    && pass "Case 15: opus-4-1 stays 15/75" || fail "Case 15: opus-4-1 mispriced"

echo "=== Case 16: <synthetic> = zero-cost known, status complete (screenshot bug) ==="
TMP=$(mktemp -d); _mk_transcripts "$TMP" "claude-opus-4-8" 1000 1000; _mk_transcripts "$TMP" "<synthetic>" 500 0
OUT=$(python3 "$PARSER" --period "$HBPERIOD" --prices "$PRICES" --transcripts-dir "$TMP" 2>/dev/null)
echo "$OUT" | jq -e '(.cost_estimation_status=="complete") and (.unknown_models|length==0) and (any(.model_breakdowns[]; .modelName=="<synthetic>" and .cost==0))' >/dev/null 2>&1 \
    && pass "Case 16: <synthetic> 0-cost, not unknown, status=complete" \
    || fail "Case 16: status=$(echo "$OUT"|jq -r .cost_estimation_status) unknown=$(echo "$OUT"|jq -c .unknown_models)"
rm -rf "$TMP"

echo "=== Case 17: a genuinely unknown model still flags partial ==="
TMP=$(mktemp -d); _mk_transcripts "$TMP" "claude-made-up-9" 10 10
OUT=$(python3 "$PARSER" --period "$HBPERIOD" --prices "$PRICES" --transcripts-dir "$TMP" 2>/dev/null)
echo "$OUT" | jq -e '(.cost_estimation_status=="partial") and (.unknown_models|index("claude-made-up-9"))' >/dev/null 2>&1 \
    && pass "Case 17: real unknown still flagged partial" \
    || fail "Case 17: status=$(echo "$OUT"|jq -r .cost_estimation_status)"
rm -rf "$TMP"

echo "=== Case 18: hb_validate_prices accepts good, rejects garbage ==="
hb_validate_prices "$PRICES" && pass "Case 18a: good table accepted" || fail "Case 18a: good table rejected"
TMP=$(mktemp); echo '{"models":[]}' > "$TMP"
hb_validate_prices "$TMP" && fail "Case 18b: empty models accepted (wrong)" || pass "Case 18b: empty models rejected"
echo 'not json' > "$TMP"
hb_validate_prices "$TMP" && fail "Case 18c: non-json accepted (wrong)" || pass "Case 18c: non-json rejected"
rm -f "$TMP"

echo "=== Case 19: hb_prices_stale_reason — env reason + age check ==="
( export HB_PRICES_STALE_REASON="fetch_failed"
  [[ "$(hb_prices_stale_reason "$PRICES")" == "fetch_failed" ]] ) \
    && pass "Case 19a: refresh-failure reason surfaces" || fail "Case 19a"
TMP=$(mktemp); jq '._last_verified="2000-01-01"' "$PRICES" > "$TMP"
( unset HB_PRICES_STALE_REASON; r="$(hb_prices_stale_reason "$TMP")"; [[ "$r" == cache_age_* ]] ) \
    && pass "Case 19b: over-age cache → cache_age_* reason" || fail "Case 19b: got '$(unset HB_PRICES_STALE_REASON; hb_prices_stale_reason "$TMP")'"
TMP=$(mktemp); jq --arg d "$(date -u +%Y-%m-%d)" '._last_verified=$d' "$PRICES" > "$TMP"
( unset HB_PRICES_STALE_REASON; [[ -z "$(hb_prices_stale_reason "$TMP")" ]] ) \
    && pass "Case 19c: fresh table → no stale reason" || fail "Case 19c: fresh table flagged stale"
rm -f "$TMP"

echo "=== Case 20: hb_refresh_prices NEVER mutates an in-repo working tree ==="
BEFORE=$(jq -S . "$PRICES" | shasum -a 256 | cut -d' ' -f1)
( INTELLISENSE_SETUP_PATH="$REPO_ROOT" hb_refresh_prices; [[ "${HB_PRICES_STALE_REASON}" == "in_repo_skip" ]] ) \
    && pass "Case 20a: in-repo run → in_repo_skip" || fail "Case 20a: reason='${HB_PRICES_STALE_REASON:-}'"
AFTER=$(jq -S . "$PRICES" | shasum -a 256 | cut -d' ' -f1)
[[ "$BEFORE" == "$AFTER" ]] && pass "Case 20b: repo prices.json unchanged by refresh" || fail "Case 20b: refresh mutated the repo file"

echo "=== Case 21: prices_stale warning reaches the payload warnings[] ==="
TMP=$(mktemp -d); _mk_transcripts "$TMP" "claude-opus-4-8" 10 10
OUT=$(python3 "$PARSER" --period "$HBPERIOD" --prices "$PRICES" --transcripts-dir "$TMP" --prices-stale-reason "fetch_failed" 2>/dev/null)
echo "$OUT" | jq -e 'any(.warnings[]; .type=="prices_stale" and .reason=="fetch_failed")' >/dev/null 2>&1 \
    && pass "Case 21: prices_stale warning present with reason" \
    || fail "Case 21: warnings=$(echo "$OUT"|jq -c .warnings)"
rm -rf "$TMP"

echo "=== Case 22: LIVE fetch+validate+swap to an out-of-repo runtime (opt-in) ==="
# Hits the network — skipped unless INTELLISENSE_HB_LIVE_FETCH=1 so CI stays hermetic.
if [[ "${INTELLISENSE_HB_LIVE_FETCH:-}" == "1" ]]; then
    BIN=$(mktemp -d)/bin; mkdir -p "$BIN/lib"
    cp "$REPO_ROOT/scripts/lib/heartbeat-payload.sh" "$BIN/lib/"
    echo '{"_last_verified":"2000-01-01","models":[{"canonical":"old","aliases":["old"],"input_per_mtok":1,"output_per_mtok":1,"cache_creation_per_mtok":1,"cache_read_per_mtok":1}]}' > "$BIN/lib/heartbeat-prices.json"
    REPO_SHA_BEFORE=$(jq -S . "$REPO_ROOT/scripts/lib/heartbeat-prices.json" | shasum -a 256 | cut -d' ' -f1)
    (
      source "$BIN/lib/heartbeat-payload.sh"
      INTELLISENSE_SETUP_PATH="$REPO_ROOT" hb_refresh_prices
      echo "${HB_PRICES_STALE_REASON:-}" > "$BIN/.reason"
    )
    REASON=$(cat "$BIN/.reason")
    if [[ -z "$REASON" ]]; then pass "Case 22a: live refresh succeeded (no stale reason)"; else fail "Case 22a: reason='$REASON' (network/auth?)"; fi
    hb_validate_prices "$BIN/lib/heartbeat-prices.json" && pass "Case 22b: fetched table is schema-valid" || fail "Case 22b: fetched table invalid"
    [[ "$(jq -r '._last_verified' "$BIN/lib/heartbeat-prices.json")" != "2000-01-01" ]] && pass "Case 22c: runtime copy was replaced by remote content" || fail "Case 22c: stale copy not replaced"
    [[ -f "$BIN/lib/.prices-last-synced" ]] && pass "Case 22d: .prices-last-synced stamped on success" || fail "Case 22d: no sync timestamp written"
    REPO_SHA_AFTER=$(jq -S . "$REPO_ROOT/scripts/lib/heartbeat-prices.json" | shasum -a 256 | cut -d' ' -f1)
    [[ "$REPO_SHA_BEFORE" == "$REPO_SHA_AFTER" ]] && pass "Case 22e: repo working tree NOT mutated by live fetch" || fail "Case 22e: live fetch mutated the repo file"
    rm -rf "$(dirname "$BIN")"
else
    echo "  (skipped — set INTELLISENSE_HB_LIVE_FETCH=1 to run the real network fetch)"
fi

echo "=== Case 23: hb_prices_last_synced_at reads the stamp ==="
BIN=$(mktemp -d)/bin; mkdir -p "$BIN/lib"
cp "$REPO_ROOT/scripts/lib/heartbeat-payload.sh" "$BIN/lib/"
( source "$BIN/lib/heartbeat-payload.sh"; [[ -z "$(hb_prices_last_synced_at)" ]] ) \
    && pass "Case 23a: no stamp → empty (never synced)" || fail "Case 23a: expected empty"
printf '2026-06-04T03:30:11Z\n' > "$BIN/lib/.prices-last-synced"
( source "$BIN/lib/heartbeat-payload.sh"; [[ "$(hb_prices_last_synced_at)" == "2026-06-04T03:30:11Z" ]] ) \
    && pass "Case 23b: stamp read back correctly" || fail "Case 23b: stamp not read"
rm -rf "$(dirname "$BIN")"

echo "=== Case 24: integrity manifest excludes runtime-mutable prices.json ==="
# Regression guard for the tamper-detector gap: a refreshed prices.json must NOT
# make verify-setup Check 19c/19d read as "runtime tampered".
BIN=$(mktemp -d)/bin; mkdir -p "$BIN"
INTELLISENSE_HEARTBEAT_BIN_DIR="$BIN" bash "$REPO_ROOT/scripts/refresh-heartbeat-runtime.sh" >/dev/null 2>&1
if [[ -f "$BIN/MANIFEST.sha256" ]]; then
    grep -q "heartbeat-prices.json" "$BIN/MANIFEST.sha256" \
        && fail "Case 24a: prices.json still in manifest (would false-fail tamper check)" \
        || pass "Case 24a: prices.json excluded from integrity manifest"
    # Simulate hb_refresh_prices swapping the table, then re-check the manifest.
    echo '{"_last_verified":"2099-01-01","models":[]}' > "$BIN/lib/heartbeat-prices.json"
    source "$BIN/lib/hash.sh" 2>/dev/null
    DIV=false
    while read -r h f; do
        [[ -z "$h" ]] && continue
        cur=$(hb_sha256 "$BIN/$f" 2>/dev/null); [[ "$cur" == "$h" ]] || DIV=true
    done < "$BIN/MANIFEST.sha256"
    $DIV && fail "Case 24b: manifest diverged after prices swap (false tamper)" \
          || pass "Case 24b: manifest stable after prices swap — no false tamper"
else
    fail "Case 24: refresh-heartbeat-runtime.sh produced no manifest"
fi
rm -rf "$(dirname "$BIN")"

echo "=== Case 25: payload carries the CORRECT prices_last_synced_at value (non-null + null) ==="
# Closes the gap: prove the assembled payload emits the actual stamp, not just
# that the stamp file exists. Out-of-repo runtime, isolated HOME, no network.
BIN=$(mktemp -d)/bin; mkdir -p "$BIN/lib"
cp "$REPO_ROOT/scripts/lib/heartbeat-payload.sh"      "$BIN/lib/"
cp "$REPO_ROOT/scripts/lib/heartbeat_usage_parser.py" "$BIN/lib/"
cp "$REPO_ROOT/scripts/lib/heartbeat-prices.json"     "$BIN/lib/"
EMPTY=$(mktemp -d); FAKE_HOME=$(mktemp -d)
STAMP="2026-06-04T05:00:00Z"
printf '%s\n' "$STAMP" > "$BIN/lib/.prices-last-synced"
PAY=$( source "$BIN/lib/heartbeat-payload.sh"
       HOME="$FAKE_HOME" HB_CLAUDE_PROJECTS_DIR="$EMPTY" hb_build_payload "$REPO_ROOT" "$EMPTY" 2>/dev/null )
GOT=$(echo "$PAY" | jq -r '.prices_last_synced_at' 2>/dev/null)
[[ "$GOT" == "$STAMP" ]] && pass "Case 25a: payload value == stamp ($GOT)" || fail "Case 25a: got '$GOT' expected '$STAMP'"
rm -f "$BIN/lib/.prices-last-synced"
PAY2=$( source "$BIN/lib/heartbeat-payload.sh"
        HOME="$FAKE_HOME" HB_CLAUDE_PROJECTS_DIR="$EMPTY" hb_build_payload "$REPO_ROOT" "$EMPTY" 2>/dev/null )
GOT2=$(echo "$PAY2" | jq -r '.prices_last_synced_at' 2>/dev/null)
[[ "$GOT2" == "null" ]] && pass "Case 25b: no stamp → payload field is JSON null" || fail "Case 25b: got '$GOT2'"
rm -rf "$(dirname "$BIN")" "$EMPTY" "$FAKE_HOME"

echo "=== Case 26: hb_pick_prices_remote — canonical-by-URL across fork/non-fork ==="
GR=$(mktemp -d); git -C "$GR" init -q
git -C "$GR" remote add origin "git@github.com:soupler-oss/intellisense.git"
[[ "$(hb_pick_prices_remote "$GR")" == "origin" ]] \
    && pass "Case 26a: non-fork (origin=example-org) → origin" || fail "Case 26a: got $(hb_pick_prices_remote "$GR")"
git -C "$GR" remote set-url origin "git@github.com:somefork/intellisense.git"
git -C "$GR" remote add upstream "git@github.com:soupler-oss/intellisense.git"
[[ "$(hb_pick_prices_remote "$GR")" == "upstream" ]] \
    && pass "Case 26b: fork (upstream=example-org) → upstream" || fail "Case 26b: got $(hb_pick_prices_remote "$GR")"
git -C "$GR" remote remove upstream
git -C "$GR" remote add canonical "https://github.com/soupler-oss/intellisense.git"
[[ "$(hb_pick_prices_remote "$GR")" == "canonical" ]] \
    && pass "Case 26c: URL match beats name (misnamed canonical=example-org) → canonical" || fail "Case 26c: got $(hb_pick_prices_remote "$GR")"
[[ "$(INTELLISENSE_PRICES_REMOTE=myremote hb_pick_prices_remote "$GR")" == "myremote" ]] \
    && pass "Case 26d: INTELLISENSE_PRICES_REMOTE override wins" || fail "Case 26d"
git -C "$GR" remote remove canonical
[[ "$(hb_pick_prices_remote "$GR")" == "origin" ]] \
    && pass "Case 26e: no example-org remote → origin fallback" || fail "Case 26e: got $(hb_pick_prices_remote "$GR")"
rm -rf "$GR"

echo "=== Case 27: all manifest writers + verifier agree on the same set ==="
# Predicate-diff: setup.sh and refresh-heartbeat-runtime.sh WRITE the manifest;
# verify-setup.sh RECOMPUTES it. If any one lists a different file set, fresh
# installs false-fail the tamper check. prices.json must be in NONE of them.
_mset() { awk "/$2/{f=1} f{print} f&&/$3/{exit}" "$1" \
            | grep -oE 'intellisense-heartbeat\.sh|lib/heartbeat-payload\.sh|lib/heartbeat_usage_parser\.py|lib/heartbeat-prices\.json' \
            | sort -u | tr '\n' ','; }
SET_SETUP=$(_mset "$REPO_ROOT/setup.sh" '_hb_write_manifest\(\)' '^}')
SET_REFRESH=$(_mset "$REPO_ROOT/scripts/refresh-heartbeat-runtime.sh" 'for f in intellisense-heartbeat' 'done')
SET_VERIFY=$(_mset "$REPO_ROOT/verify-setup.sh" 'for f in intellisense-heartbeat' 'done')
[[ "$SET_SETUP" == "$SET_REFRESH" && "$SET_REFRESH" == "$SET_VERIFY" ]] \
    && pass "Case 27a: setup == refresh == verify manifest sets ($SET_SETUP)" \
    || fail "Case 27a: sets differ — setup=[$SET_SETUP] refresh=[$SET_REFRESH] verify=[$SET_VERIFY]"
[[ "$SET_SETUP" != *"heartbeat-prices.json"* ]] \
    && pass "Case 27b: prices.json excluded from all manifest sets" \
    || fail "Case 27b: prices.json present in a manifest set"
grep -A7 "for pair in" "$REPO_ROOT/verify-setup.sh" | grep -q "heartbeat-prices.json" \
    && fail "Case 27c: verify-setup 19d (repo compare) still includes prices.json" \
    || pass "Case 27c: verify-setup 19d excludes prices.json"

echo "=== Case 28: subagent transcripts (nested subagents/) are counted ==="
# discover_files() must glob **/*.jsonl recursively, so
# <project>/<session>/subagents/agent-*.jsonl (Agent/Task/Workflow subagents)
# is counted, as ccusage does.
TMP=$(mktemp -d)
_mk_transcripts "$TMP" "claude-opus-4-8" 1000 2000   # depth-1 main session
mkdir -p "$TMP/proj/sess-1/subagents"
printf '{"timestamp":"%sT11:00:00Z","sessionId":"agent-s1","requestId":"r-sub-1","message":{"model":"claude-opus-4-8","usage":{"input_tokens":300,"output_tokens":700,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
    "$HBPERIOD" > "$TMP/proj/sess-1/subagents/agent-abc.jsonl"
OUT=$(python3 "$PARSER" --period "$HBPERIOD" --prices "$PRICES" --transcripts-dir "$TMP" 2>/dev/null)
echo "$OUT" | jq -e '.input_tokens==1300 and .output_tokens==2700 and .sessions==2' >/dev/null 2>&1 \
    && pass "Case 28: nested subagents/ transcript counted (in=1300 out=2700 sessions=2)" \
    || fail "Case 28: in=$(echo "$OUT"|jq -r .input_tokens) out=$(echo "$OUT"|jq -r .output_tokens) sessions=$(echo "$OUT"|jq -r .sessions)"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 28: hb_build_payload honors an EXPLICIT period ==="
# Catch-up backfill passes the reported period so idempotency_key and
# usage_summary.period reflect the DAY BEING REPORTED, not the send date.
TMP_HOME=$(mktemp -d)
TMP_WS=$(mktemp -d)
TMP_SETUP=$(mktemp -d)
TMP_PROJ=$(mktemp -d)
echo "1.0.0" > "$TMP_SETUP/VERSION"
EXPLICIT_PERIOD="2026-06-01"
# Seed tool_result transcripts for BOTH the reported day and yesterday, under
# HB_CLAUDE_PROJECTS_DIR (NOT $HOME). hb_tool_decision_counts must honor the
# override and scope to the explicit period — a backfill that
# leaked yesterday's decisions would show period=yesterday and/or accepted=2.
TD_YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d 2>/dev/null)
mkdir -p "$TMP_PROJ/p"
{
  printf '{"timestamp":"%sT10:00:00Z","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}\n' "$EXPLICIT_PERIOD"
  printf '{"timestamp":"%sT10:00:00Z","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}\n' "$TD_YESTERDAY"
} > "$TMP_PROJ/p/s.jsonl"
PAYLOAD=$(HOME="$TMP_HOME" HB_CLAUDE_PROJECTS_DIR="$TMP_PROJ" INTELLISENSE_GH_LOGIN="EXPLICITUSER" \
    hb_build_payload "$TMP_SETUP" "$TMP_WS" "$EXPLICIT_PERIOD" 2>/dev/null)
idem=$(echo "$PAYLOAD" | jq -r '.idempotency_key')
usage_period=$(echo "$PAYLOAD" | jq -r '.usage_summary.period')
behavior_period=$(echo "$PAYLOAD" | jq -r '.behavior_stats.period')
decisions_period=$(echo "$PAYLOAD" | jq -r '.tool_decision_counts.period')
decisions_accepted=$(echo "$PAYLOAD" | jq -r '.tool_decision_counts.accepted')
[[ "$idem" == *"_$EXPLICIT_PERIOD" ]] \
    && pass "idempotency_key carries explicit period ($idem)" \
    || fail "idempotency_key=$idem expected suffix _$EXPLICIT_PERIOD"
[[ "$usage_period" == "$EXPLICIT_PERIOD" ]] \
    && pass "usage_summary.period == explicit period" \
    || fail "usage_summary.period=$usage_period expected=$EXPLICIT_PERIOD"
[[ "$behavior_period" == "$EXPLICIT_PERIOD" ]] \
    && pass "behavior_stats.period == explicit period" \
    || fail "behavior_stats.period=$behavior_period expected=$EXPLICIT_PERIOD"
[[ "$decisions_period" == "$EXPLICIT_PERIOD" ]] \
    && pass "tool_decision_counts.period == explicit period" \
    || fail "tool_decision_counts.period=$decisions_period expected=$EXPLICIT_PERIOD"
[[ "$decisions_accepted" == "1" ]] \
    && pass "tool_decision_counts scoped to reported day only (accepted=1)" \
    || fail "tool_decision_counts.accepted=$decisions_accepted expected=1 (yesterday's event leaked?)"
rm -rf "$TMP_HOME" "$TMP_WS" "$TMP_SETUP" "$TMP_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
