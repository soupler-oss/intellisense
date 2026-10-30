#!/usr/bin/env bash
# validate-contract-schema.sh — Validate a Layer-1 intellisense contract artifact
#
# Inputs:
#   $1                                       Path to the contract: .intellisense/contracts/<branch>.md
#                                            (front matter = the fields), or a JSON file with the same fields
#   --changed-files=<csv>                    Optional comma-separated list of files in the push
#                                            (used for scope-drift / file-outside-scope checks)
#   --current-classification-id=<id>         Optional. When provided, contract.classification_id
#                                            must equal this value (Gate Rule R7, task-binding).
#                                            Used by the PreToolUse gate to detect when an edit
#                                            is being made under a different task than the one
#                                            the contract was approved for.
#   --context={edit|evidence}                Optional, default "edit". Splits Gate Rule R6
#                                            lifecycle semantics:
#                                              edit (PreToolUse): only approved|active unlock
#                                                edits; draft|presented|retroactive|evidence_only
#                                                are all rejected.
#                                              evidence (pre-push, audit replay): retroactive
#                                                and evidence_only are accepted as audit
#                                                artifacts; draft|presented|empty still rejected
#                                                because they signal an incomplete lifecycle.
#                                            R1, R2, R3, R4, R5, R7, scope-drift, and the schema
#                                            layer apply identically in both contexts.
#
# Exit codes (stable contract — pre-push depends on these):
#   0  valid (schema + policy)
#   1  schema invalid (missing field, wrong type, branch mismatch)
#   2  policy invalid (R1–R7 violation, file outside declared scope)
#   3  internal error (file missing, malformed JSON, jq missing)
#
# Layer 1 rule: this validator's success does NOT exempt a push from carrying
# visible Beads: / Change Contract: artifacts in the commit body or
# .intellisense/contracts/*.md. It supplements those checks; it never replaces them.

set -uo pipefail

CONTRACT_FILE=""
CHANGED_FILES_CSV=""
CURRENT_CLASSIFICATION_ID=""
VALIDATION_CONTEXT="edit"

for arg in "$@"; do
    case "$arg" in
        --changed-files=*) CHANGED_FILES_CSV="${arg#--changed-files=}" ;;
        --current-classification-id=*) CURRENT_CLASSIFICATION_ID="${arg#--current-classification-id=}" ;;
        --context=*) VALIDATION_CONTEXT="${arg#--context=}" ;;
        --*) echo "validate-contract-schema: unknown flag: $arg" >&2; exit 3 ;;
        *)
            if [ -z "$CONTRACT_FILE" ]; then CONTRACT_FILE="$arg"
            else echo "validate-contract-schema: unexpected positional arg: $arg" >&2; exit 3
            fi ;;
    esac
done

# Reject invalid --context= up-front so misuse is loud, not silent.
case "$VALIDATION_CONTEXT" in
    edit|evidence) ;;
    *) echo "validate-contract-schema: invalid --context=$VALIDATION_CONTEXT (allowed: edit, evidence)" >&2; exit 3 ;;
esac

if [ -z "$CONTRACT_FILE" ]; then
    echo "usage: validate-contract-schema.sh <contract.md|contract.json> [--changed-files=a,b,c] [--current-classification-id=<id>] [--context=edit|evidence]" >&2
    exit 3
fi

if [ ! -f "$CONTRACT_FILE" ]; then
    echo "validate-contract-schema: contract file not found: $CONTRACT_FILE" >&2
    exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "validate-contract-schema: jq not on PATH (required for JSON validation)" >&2
    exit 3
fi

# A contract is a Markdown file (.intellisense/contracts/<branch>.md) whose front matter holds the fields. Read
# it as JSON through the engine; the shared names fill the Live ones (scope → requirement, risk → risk_level).
# This script may be copied into a repository on its own, so the engine lookup is inline.
CONTRACT_SOURCE="$CONTRACT_FILE"
case "$CONTRACT_FILE" in
    *.md)
        _engine=""
        for _c in "${INTELLISENSE_BIN:-}" "${INTELLISENSE_HOME:-$HOME/.intellisense}/bin/intellisense" "$(command -v intellisense 2>/dev/null)"; do
            if [ -n "$_c" ] && [ -x "$_c" ]; then _engine="$_c"; break; fi
        done
        if [ -z "$_engine" ]; then
            echo "validate-contract-schema: the intellisense engine is needed to read $CONTRACT_FILE (install: intellisense live install)" >&2
            exit 3
        fi
        _contract_json="$(mktemp)"
        trap 'rm -f "$_contract_json"' EXIT
        if ! "$_engine" contract show "$CONTRACT_FILE" 2>/dev/null \
            | jq '(if has("requirement") then . else (if has("scope") then .requirement = .scope else . end) end)
                  | (if has("risk_level") then . else (if has("risk") then .risk_level = .risk else . end) end)' \
            >"$_contract_json" 2>/dev/null || [ ! -s "$_contract_json" ]; then
            echo "validate-contract-schema: malformed front matter in $CONTRACT_FILE" >&2
            exit 3
        fi
        CONTRACT_FILE="$_contract_json"
        ;;
esac

# Confirm valid JSON before any field access — malformed → internal error
if ! jq -e . "$CONTRACT_FILE" >/dev/null 2>&1; then
    echo "validate-contract-schema: malformed JSON in $CONTRACT_FILE" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Schema checks (exit 1 on failure)
# ---------------------------------------------------------------------------

# Required-field list. Source of truth: skills/contract/schema.json `required[]`.
# The list below is a fallback for when schema.json is unreachable (jq missing).
# It MUST match schema.json.
_SCHEMA_FILE_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/contract/schema.json"
_SCHEMA_FILE="${INTELLISENSE_CONTRACT_SCHEMA:-$_SCHEMA_FILE_DEFAULT}"
REQUIRED_FIELDS=()
if [ -f "$_SCHEMA_FILE" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r f; do
        REQUIRED_FIELDS+=("$f")
    done < <(jq -r '.required[]' "$_SCHEMA_FILE" 2>/dev/null)
fi
if [ "${#REQUIRED_FIELDS[@]}" -eq 0 ]; then
    REQUIRED_FIELDS=(
        "branch"
        "mode"
        "requirement"
        "files_affected"
        "estimated_lines"
        "confidence_score"
        "risk_level"
        "financial_impact"
        "high_risk_files_touched"
        "protected_files_touched"
        "rollback_strategy"
        "test_strategy"
        "session_id"
        "prompt_hash"
        "classification_id"
        "state"
    )
fi

SCHEMA_ERRORS=()

for field in "${REQUIRED_FIELDS[@]}"; do
    if ! jq -e "has(\"$field\")" "$CONTRACT_FILE" >/dev/null 2>&1; then
        SCHEMA_ERRORS+=("missing required field: $field")
    fi
done

VALID_MODES='full_feature bug_fix refactor hotfix pr_review qa design_review_only fix_pr_comments'
VALID_RISK='low medium high'
VALID_STATE='draft presented approved active retroactive evidence_only'

if [ ${#SCHEMA_ERRORS[@]} -eq 0 ]; then
    MODE=$(jq -r '.mode' "$CONTRACT_FILE")
    RISK=$(jq -r '.risk_level' "$CONTRACT_FILE")
    grep -qw "$MODE" <<<"$VALID_MODES" || SCHEMA_ERRORS+=("invalid mode: $MODE")
    grep -qw "$RISK" <<<"$VALID_RISK" || SCHEMA_ERRORS+=("invalid risk_level: $RISK")

    STATE=$(jq -r '.state // empty' "$CONTRACT_FILE")
    if [ -n "$STATE" ]; then
        grep -qw "$STATE" <<<"$VALID_STATE" || SCHEMA_ERRORS+=("invalid state: $STATE (allowed: $VALID_STATE)")
    fi

    # Enforce JSON Schema property types, not only required-field presence:
    # every required field is type-checked. Catches errors like
    # `requirement: null`, `estimated_lines: "x"`, `test_strategy: 123`.

    # String fields (required to be non-null strings).
    for sf in branch mode requirement rollback_strategy test_strategy session_id prompt_hash classification_id state; do
        actual_type=$(jq -r ".$sf | type" "$CONTRACT_FILE" 2>/dev/null)
        # A field the schema does not require is only type-checked when present.
        if ! printf '%s\n' "${REQUIRED_FIELDS[@]}" | grep -qFx "$sf" 2>/dev/null; then
            if jq -e "has(\"$sf\")" "$CONTRACT_FILE" >/dev/null 2>&1 && [ "$actual_type" != "string" ]; then
                SCHEMA_ERRORS+=("$sf must be a string when present (got: $actual_type)")
            fi
            continue
        fi
        if [ "$actual_type" != "string" ]; then
            SCHEMA_ERRORS+=("$sf must be a string (got: $actual_type)")
        elif [ -z "$(jq -r ".$sf" "$CONTRACT_FILE" 2>/dev/null)" ] || [ "$(jq -r ".$sf" "$CONTRACT_FILE")" = "null" ]; then
            SCHEMA_ERRORS+=("$sf must be non-empty (got: empty/null)")
        fi
    done

    # Numeric fields
    if [ "$(jq -r '.estimated_lines | type' "$CONTRACT_FILE")" != "number" ]; then
        SCHEMA_ERRORS+=("estimated_lines must be a number (got: $(jq -r '.estimated_lines | type' "$CONTRACT_FILE"))")
    elif jq -e '.estimated_lines < 0' "$CONTRACT_FILE" >/dev/null 2>&1; then
        SCHEMA_ERRORS+=("estimated_lines must be >= 0")
    fi
    if [ "$(jq -r '.confidence_score | type' "$CONTRACT_FILE")" != "number" ]; then
        SCHEMA_ERRORS+=("confidence_score must be a number (got: $(jq -r '.confidence_score | type' "$CONTRACT_FILE"))")
    elif jq -e '.confidence_score < 0 or .confidence_score > 1' "$CONTRACT_FILE" >/dev/null 2>&1; then
        SCHEMA_ERRORS+=("confidence_score must be between 0.0 and 1.0")
    fi

    # Boolean field
    if [ "$(jq -r '.financial_impact | type' "$CONTRACT_FILE")" != "boolean" ]; then
        SCHEMA_ERRORS+=("financial_impact must be a boolean (got: $(jq -r '.financial_impact | type' "$CONTRACT_FILE"))")
    fi

    # Array fields (and item types)
    for af in files_affected high_risk_files_touched protected_files_touched; do
        if [ "$(jq -r ".$af | type" "$CONTRACT_FILE")" != "array" ]; then
            SCHEMA_ERRORS+=("$af must be an array (got: $(jq -r ".$af | type" "$CONTRACT_FILE"))")
        elif jq -e ".$af | map(type) | unique | length > 1 or (.[0] != \"string\" and length > 0)" "$CONTRACT_FILE" >/dev/null 2>&1; then
            SCHEMA_ERRORS+=("$af items must all be strings")
        fi
    done
fi

# Branch staleness — JSON branch field must equal current git branch.
# Skipped when not run inside a git work tree (e.g., synthetic fixture tests).
if [ ${#SCHEMA_ERRORS[@]} -eq 0 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DECLARED_BRANCH=$(jq -r '.branch' "$CONTRACT_FILE")
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [ -n "$CURRENT_BRANCH" ] && [ "$DECLARED_BRANCH" != "$CURRENT_BRANCH" ]; then
        SCHEMA_ERRORS+=("stale contract: declared branch '$DECLARED_BRANCH' != current branch '$CURRENT_BRANCH'")
    fi
fi

if [ ${#SCHEMA_ERRORS[@]} -gt 0 ]; then
    echo "❌ contract schema invalid:" >&2
    for err in "${SCHEMA_ERRORS[@]}"; do echo "  - $err" >&2; done
    exit 1
fi

# ---------------------------------------------------------------------------
# Policy checks — Gate Rules R1–R5 (exit 2 on failure)
# Reference: rules/operational/development-workflow.md §"Change Contract Gate Rules"
# ---------------------------------------------------------------------------

POLICY_ERRORS=()

HIGH_RISK_COUNT=$(jq '.high_risk_files_touched | length' "$CONTRACT_FILE")
PROTECTED_COUNT=$(jq '.protected_files_touched | length' "$CONTRACT_FILE")
APPROVAL=$(jq -r '.approval_received_at // ""' "$CONTRACT_FILE")
CONFIDENCE=$(jq '.confidence_score' "$CONTRACT_FILE")
FILES_COUNT=$(jq '.files_affected | length' "$CONTRACT_FILE")
FINANCIAL=$(jq '.financial_impact' "$CONTRACT_FILE")
MODE=$(jq -r '.mode' "$CONTRACT_FILE")
RISK=$(jq -r '.risk_level' "$CONTRACT_FILE")

# R1: high_risk_files_touched non-empty → risk_level ∈ {medium, high}
if [ "$HIGH_RISK_COUNT" -gt 0 ] && [ "$RISK" = "low" ]; then
    POLICY_ERRORS+=("R1: high_risk_files_touched is non-empty ($HIGH_RISK_COUNT) but risk_level=low — must be medium or high")
fi

# R2: protected_files_touched non-empty → approval_received_at non-empty
if [ "$PROTECTED_COUNT" -gt 0 ] && [ -z "$APPROVAL" ]; then
    POLICY_ERRORS+=("R2: protected_files_touched is non-empty ($PROTECTED_COUNT) but approval_received_at is missing/empty")
fi

# R3: confidence_score ≥ 0.75
if awk "BEGIN { exit !($CONFIDENCE < 0.75) }"; then
    POLICY_ERRORS+=("R3: confidence_score=$CONFIDENCE is below 0.75 — clarify or replan")
fi

# R4: mode == bug_fix → len(files_affected) ≤ 3
if [ "$MODE" = "bug_fix" ] && [ "$FILES_COUNT" -gt 3 ]; then
    POLICY_ERRORS+=("R4: mode=bug_fix declares $FILES_COUNT files — exceeds 3-file limit, escalate to full_feature or split")
fi

# R5: financial_impact == true → mode must be full_feature
if [ "$FINANCIAL" = "true" ] && [ "$MODE" != "full_feature" ]; then
    POLICY_ERRORS+=("R5: financial_impact=true but mode=$MODE — must be full_feature")
fi

# R6: contract lifecycle (audit-chain hardening 2026-05-20).
# Context-aware lifecycle gating:
#   edit (PreToolUse default): only approved|active unlock edits; all other
#     states (draft, presented, retroactive, evidence_only, empty) are rejected.
#   evidence (pre-push, audit replay): retroactive and evidence_only are
#     legitimate audit artifacts and pass; draft|presented|empty are still
#     rejected because they signal an incomplete lifecycle, not evidence.
STATE_FOR_R6=$(jq -r '.state // ""' "$CONTRACT_FILE")
_r6_reject() { POLICY_ERRORS+=("R6 ($VALIDATION_CONTEXT): contract state=${1:-<empty>} — $2"); }
case "$VALIDATION_CONTEXT" in
    edit)
        case "$STATE_FOR_R6" in
            approved|active) ;;
            draft|presented)
                _r6_reject "$STATE_FOR_R6" "edits require state in {approved, active}. Confirm with the user, then update the contract state."
                ;;
            retroactive|evidence_only)
                _r6_reject "$STATE_FOR_R6" "this is a reviewer-evidence state; it cannot unlock edits. Run /contract to produce a fresh approved contract bound to the current task."
                ;;
            "")
                _r6_reject "" "set state to draft|presented|approved|active|retroactive|evidence_only and re-run /contract approval flow."
                ;;
            *) ;;   # invalid enum value was caught at schema layer
        esac
        ;;
    evidence)
        case "$STATE_FOR_R6" in
            approved|active|retroactive|evidence_only) ;;
            draft|presented)
                _r6_reject "$STATE_FOR_R6" "evidence-context validator expected approved|active|retroactive|evidence_only; draft/presented indicate incomplete approval and cannot stand as evidence."
                ;;
            "")
                _r6_reject "" "evidence-context validator requires a non-empty state."
                ;;
            *) ;;
        esac
        ;;
esac
unset -f _r6_reject 2>/dev/null

# R7: task-aware contract binding. When the caller passes
# --current-classification-id=<id>, the contract.classification_id MUST match.
# Mismatch means the contract was approved for a DIFFERENT task and reusing it
# here would be a branch-wide permission, not a task-scoped one.
if [ -n "$CURRENT_CLASSIFICATION_ID" ]; then
    CONTRACT_CID=$(jq -r '.classification_id // ""' "$CONTRACT_FILE")
    if [ "$CONTRACT_CID" != "$CURRENT_CLASSIFICATION_ID" ]; then
        POLICY_ERRORS+=("R7: contract.classification_id ($CONTRACT_CID) does not match the current task's classification_id ($CURRENT_CLASSIFICATION_ID). Re-run /contract to bind a fresh contract to the current task, or confirm you are still on the same task before continuing.")
    fi
fi

# Scope drift: every changed file must be in files_affected[]
if [ -n "$CHANGED_FILES_CSV" ]; then
    DECLARED_FILES_TMP=$(mktemp)
    jq -r '.files_affected[]' "$CONTRACT_FILE" > "$DECLARED_FILES_TMP"
    OUT_OF_SCOPE=()
    IFS=',' read -ra CHANGED_ARR <<<"$CHANGED_FILES_CSV"
    for cf in "${CHANGED_ARR[@]}"; do
        # Trim LEADING/TRAILING whitespace only. The old
        # "${cf// /}" deleted INTERIOR spaces too, so a declared
        # "docs/foo bar.md" was compared as "docs/foobar.md" → false drift.
        cf_trim="${cf#"${cf%%[![:space:]]*}"}"
        cf_trim="${cf_trim%"${cf_trim##*[![:space:]]}"}"
        [ -z "$cf_trim" ] && continue
        if ! grep -Fxq "$cf_trim" "$DECLARED_FILES_TMP"; then
            OUT_OF_SCOPE+=("$cf_trim")
        fi
    done
    rm -f "$DECLARED_FILES_TMP"
    if [ ${#OUT_OF_SCOPE[@]} -gt 0 ]; then
        msg="scope drift: changed files not in files_affected[]:"
        for p in "${OUT_OF_SCOPE[@]}"; do msg+=" $p"; done
        POLICY_ERRORS+=("$msg")
    fi
fi

# Impact Discovery: present-when-type checks for the
# documentation fields. Schema declares both as strings; wrong types are
# warn-only (these are doc-only fields, never enforced).
for _piloted_field in impact_analysis impact_analysis_dismissed_suggestions; do
    if jq -e "has(\"$_piloted_field\")" "$CONTRACT_FILE" >/dev/null 2>&1; then
        _ft=$(jq -r ".$_piloted_field | type" "$CONTRACT_FILE" 2>/dev/null)
        if [ "$_ft" != "string" ] && [ "$_ft" != "null" ]; then
            echo "[impact-discovery] $_piloted_field present but type=$_ft (expected string per schema). (warn-only; never blocks)" >&2
        fi
    fi
done
unset _piloted_field _ft

# Warn-only emptiness check for impact_analysis on modes that ship code.
# Only a non-empty STRING value counts as populated — wrong
# types (e.g. impact_analysis: []) get the warning so they can't silently
# bypass the evidence requirement. design_review_only, pr_review, qa skip
# this warning entirely — they don't ship code. Clear the warning by
# populating impact_analysis with graph/rg evidence or the literal string
# 'n/a — <reason>' (e.g. 'n/a — graph unavailable', 'n/a — weak stack').
case "$MODE" in
    full_feature|bug_fix|refactor|hotfix|fix_pr_comments)
        IMPACT_TYPE=$(jq -r '.impact_analysis | type' "$CONTRACT_FILE" 2>/dev/null)
        if [ "$IMPACT_TYPE" = "string" ]; then
            IMPACT_RAW=$(jq -r '.impact_analysis' "$CONTRACT_FILE")
            IMPACT_TRIM="${IMPACT_RAW//[[:space:]]/}"
        else
            IMPACT_TRIM=""
        fi
        if [ -z "$IMPACT_TRIM" ]; then
            echo "[impact-discovery] impact_analysis is empty for mode=$MODE — populate via /plan Impact Discovery, or set 'n/a — <reason>'. (warn-only; never blocks)" >&2
        fi
        ;;
esac

if [ ${#POLICY_ERRORS[@]} -gt 0 ]; then
    echo "❌ contract policy invalid:" >&2
    for err in "${POLICY_ERRORS[@]}"; do echo "  - $err" >&2; done
    exit 2
fi

echo "✓ contract valid: mode=$MODE files=$FILES_COUNT confidence=$CONFIDENCE risk=$RISK"
exit 0
