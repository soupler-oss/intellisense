#!/usr/bin/env bash
# test_gate_friction_regression.sh — regression tests
#
# Two contract-gate friction false-positives found in session fb02f996:
#   Bug 1 (classifier): is_approval_prompt failed on harness-wrapped prompts.
#       A bare "proceed" arrived as a 210-char prompt because the harness
#       prepended <ide_opened_file>…</ide_opened_file>; the exact-match + 40-char
#       cap rejected it, so the approval was misread as a new task (broke R7).
#   Bug 2 (gate): the Bash path-extractor quote-strip was line-based, so a
#       multi-line quoted region (e.g. bd create --description="…\n…path.json…")
#       was never stripped and leaked a filename in prose as a bogus
#       out-of-scope write target.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"
RULES_FILE="$REPO_ROOT/scripts/classifier-rules.json"
export RULES_FILE

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ── Bug 1: source the REAL functions from the classifier and exercise them ────
# Extract just the two function definitions (each closes with a col-0 brace) so
# we test the shipped code without running the hook's main flow.
FN=$(mktemp)
sed -n '/^_strip_injected_context()/,/^}/p; /^is_approval_prompt()/,/^}/p' "$CLASSIFIER" > "$FN"
# shellcheck disable=SC1090
source "$FN"
rm -f "$FN"

echo "Bug 1 — approval detection survives harness-injected wrappers"

ide_wrapped='<ide_opened_file>The user opened the file /x/y.md in the IDE. This may or may not be related to the current task.</ide_opened_file>proceed'
if is_approval_prompt "$(_strip_injected_context "$ide_wrapped")"; then
    ok "ide_opened_file-wrapped 'proceed' detected as approval"
else
    no "ide_opened_file-wrapped 'proceed' NOT detected (bug 1 regressed)"
fi

sysrem_wrapped='<system-reminder>some injected note spanning
multiple lines</system-reminder>
ok'
if is_approval_prompt "$(_strip_injected_context "$sysrem_wrapped")"; then
    ok "system-reminder-wrapped 'ok' detected as approval"
else
    no "system-reminder-wrapped 'ok' NOT detected (bug 1 regressed)"
fi

# The conservative matcher must NOT be weakened: a scope-carrying prompt that
# merely contains an approval word is still NOT an approval.
if is_approval_prompt "$(_strip_injected_context '<ide_selection>x</ide_selection>proceed to delete the account table')"; then
    no "scope-carrying 'proceed to delete…' wrongly treated as approval (matcher weakened)"
else
    ok "scope-carrying prompt still rejected (conservative match intact)"
fi

# Bare approval still works (no regression from the stripping).
if is_approval_prompt "$(_strip_injected_context 'proceed')"; then
    ok "bare 'proceed' still detected"
else
    no "bare 'proceed' broke"
fi

# ── Bug 3: greedy .* deletes a real word between two same-name tags ────────────
# <ide_selection>a</ide_selection>proceed<ide_selection>b</ide_selection> must
# strip ONLY the two wrappers, leaving 'proceed'. A greedy regex matches from the
# first <ide_selection> to the LAST </ide_selection> and eats 'proceed' too.
echo "Bug 3 — non-greedy strip preserves a word bracketed by same-name tags"
greedy_case='<ide_selection>a</ide_selection>proceed<ide_selection>b</ide_selection>'
if is_approval_prompt "$(_strip_injected_context "$greedy_case")"; then
    ok "repeated same-name tags around 'proceed' strip to 'proceed'"
else
    no "greedy .* ate 'proceed' between two <ide_selection> tags (bug 3): got '$(_strip_injected_context "$greedy_case")'"
fi

# ── Bug 4: real harness command-* / local-command-* wrappers must be stripped ──
# These wrappers are emitted around slash-command invocations and their output.
# If they survive, they push a bare 'proceed' past the 40-char approval cap.
echo "Bug 4 — command-* / local-command-* wrappers are stripped"
for tag in command-name command-message command-args local-command-stdout local-command-stderr; do
    wrapped="<${tag}>some injected content for ${tag}</${tag}>proceed"
    if is_approval_prompt "$(_strip_injected_context "$wrapped")"; then
        ok "<${tag}> wrapper around 'proceed' stripped"
    else
        no "<${tag}> wrapper survived, 'proceed' not detected (bug 4): got '$(_strip_injected_context "$wrapped")'"
    fi
done

# ── Bug 2: multi-line quote strip (mirrors gate's tr + sed pipeline) ──────────
echo "Bug 2 — multi-line quoted region is stripped before path extraction"
# Same transformation as scripts/preToolUse-contract-gate.sh (collapse newlines,
# then sentinel-replace quoted regions).
strip(){ printf '%s' "$1" | tr '\n\r' '  ' | sed -E "s/\"[^\"]*\"/__INTELLISENSE_QUOTED__/g; s/'[^']*'/__INTELLISENSE_QUOTED__/g"; }

multiline='bd create --description="## Why
this mentions secret/config.json in prose
end" --type=bug'
out=$(strip "$multiline")
if [[ "$out" != *"config.json"* ]]; then
    ok "filename inside multi-line quoted prose is stripped"
else
    no "filename leaked from multi-line quoted prose (bug 2 regressed): $out"
fi

# A real redirect target OUTSIDE quotes must survive (no over-stripping).
redirect='echo "note: edit config/app.json later" > /tmp/realtarget.txt'
out=$(strip "$redirect")
if [[ "$out" == *"/tmp/realtarget.txt"* && "$out" != *"app.json"* ]]; then
    ok "real redirect target preserved; quoted filename stripped"
else
    no "redirect/quoted handling wrong: $out"
fi

echo
echo "Bug-friction regression: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
