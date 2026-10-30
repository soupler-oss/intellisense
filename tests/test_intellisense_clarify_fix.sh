#!/usr/bin/env bash
# Regression tests for the "clarify-over-ceremony" fix .
#
# Covers:
#   1. Classifier corroboration — a bare Tier-1 keyword with explicit read-only
#      intent downgrades to Tier 0; a real edit verb stays Tier 1.
#   2. Contract-gate Exhibit-D carve-out — a Tier-2 *prompt* must not force a
#      contract on an unrelated docs edit, BUT the policy floor and path tier
#      must still be honored (a fail-open otherwise).
#
# Hermetic: uses INTELLISENSE_SETTINGS_FILE + temp CWDs; does not touch ~/.claude.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export INTELLISENSE_SETUP_PATH="$REPO_ROOT"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"
GATE="$REPO_ROOT/scripts/preToolUse-contract-gate.sh"

# Hermetic settings: audit-chain enforced (so Tier 1+ without a contract blocks),
# gate enforced. Isolated from the developer's real ~/.claude/settings.json.
SETTINGS="$(mktemp)"
printf '%s' '{"intellisense":{"gate_mode":"enforced","audit_chain_enforcement":"enforced","sync_enforcement":"warn"}}' > "$SETTINGS"
export INTELLISENSE_SETTINGS_FILE="$SETTINGS"

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1 (got: $2, want: $3)"; FAIL=$((FAIL+1)); }

# classify_tier <prompt> -> echoes effective tier
classify_tier(){
    local p="$1" t; t="$(mktemp -d)"
    printf '%s' "$(jq -nc --arg p "$p" --arg c "$t" '{prompt:$p,session_id:"s",cwd:$c}')" \
        | bash "$CLASSIFIER" >/dev/null 2>&1
    jq -r '.tier' "$t/.intellisense/session/s.classification.json" 2>/dev/null
    rm -rf "$t"
}

INTELLISENSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# gate_exit <relpath> <prompt_tier> [policy_minimum_tier] -> echoes exit code
gate_exit(){
    local rel="$1" tier="$2" policy="${3:-}" t; t="$(mktemp -d)"
    mkdir -p "$t/.intellisense/session" "$(dirname "$t/$rel")"
    # The paths below are this repository's (rules/baseline/security.md): judge them by its own policy.
    cp "$INTELLISENSE_ROOT/.intellisense.yml" "$t/.intellisense.yml"
    jq -nc --arg tier "$tier" '{tier:$tier,mode:"full_feature",classification_id:"cls_t"}' \
        > "$t/.intellisense/session/s.classification.json"
    [ -n "$policy" ] && jq -nc --argjson p "$policy" '{policy_minimum_tier:$p}' > "$t/.intellisense/manifest.json"
    printf '%s' "$(jq -nc --arg f "$t/$rel" --arg c "$t" '{tool_name:"Edit",tool_input:{file_path:$f},session_id:"s",cwd:$c}')" \
        | bash "$GATE" >/dev/null 2>&1
    local rc=$?
    rm -rf "$t"
    echo "$rc"
}

echo "── Classifier corroboration ──────────────────────────────────────────"
t=$(classify_tier "what does setup do?");          [ "$t" = "0" ] && ok "read-only 'what does setup do?' -> Tier 0" || no "read-only 'what does setup do?'" "$t" "0"
t=$(classify_tier "explain the hook");             [ "$t" = "0" ] && ok "read-only 'explain the hook' -> Tier 0" || no "read-only 'explain the hook'" "$t" "0"
t=$(classify_tier "change the config in the hook");[ "$t" = "1" ] && ok "edit 'change the config' -> Tier 1 (no fail-open)" || no "edit 'change the config'" "$t" "1"
t=$(classify_tier "fix the broken setup script");  [ "$t" = "1" ] && ok "edit 'fix the setup script' -> Tier 1" || no "edit 'fix the setup script'" "$t" "1"

echo "── Contract-gate Exhibit-D carve-out (+ policy floor) ────────────────"
e=$(gate_exit "docs/notes/foo.md" "2");      [ "$e" = "0" ] && ok "Tier-2 prompt + docs + no policy -> ALLOW (exit 0)" || no "Tier-2 + docs + no policy" "$e" "0"
e=$(gate_exit "docs/notes/foo.md" "2" "1");  [ "$e" = "2" ] && ok "Tier-2 prompt + docs + policy_minimum_tier=1 -> BLOCK (exit 2)" || no "Tier-2 + docs + policy=1 (a fail-open otherwise)" "$e" "2"
e=$(gate_exit "rules/baseline/security.md" "2"); [ "$e" = "2" ] && ok "Tier-2 prompt + security.md -> BLOCK (exit 2)" || no "Tier-2 + security.md" "$e" "2"
e=$(gate_exit "app/handler.go" "2");        [ "$e" = "2" ] && ok "Tier-2 prompt + code -> BLOCK (exit 2)" || no "Tier-2 + code" "$e" "2"
e=$(gate_exit "docs/notes/foo.md" "0");      [ "$e" = "0" ] && ok "Tier-0 prompt + docs -> ALLOW (exit 0)" || no "Tier-0 + docs" "$e" "0"

rm -f "$SETTINGS"
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
