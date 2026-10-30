#!/usr/bin/env python3
# Heartbeat usage_summary builder. Reads ~/.claude/projects/**/*.jsonl,
# aggregates yesterday's token usage by event timestamp, applies a
# canonical+aliases price table, emits the usage_summary block.
#
# SECURITY BOUNDARY: this script handles raw transcript content
# (user prompts, model output). It MUST NOT leak any of that content
# into stdout, stderr, logs, or the heartbeat payload. parse_error_detail
# and warnings entries are constructed via build_parse_error_detail()
# from a curated allow-list of tokens only.

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Curated allow-list of stage tokens (Section 3.x)
ALLOWED_STAGES = {"discover", "open", "parse", "aggregate", "price"}
# Curated allow-list of error type tokens
ALLOWED_ERROR_TYPES = {
    "json_decode",
    "missing_field",
    "io_error",
    "schema_mismatch",
    "internal",
}

MAX_DETAIL_LEN = 120


def _safe_int(value):
    """Strict int coercion. None → 0. Numeric → int. Anything else raises
    TypeError so the caller can decide (partial parse vs propagate).
    """
    if value is None:
        return 0
    if isinstance(value, bool):
        # bool is a subclass of int in Python; reject explicitly
        raise TypeError("bool is not a valid token count")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        # Reject NaN / inf; otherwise truncate
        if value != value or value == float("inf") or value == float("-inf"):
            raise ValueError("non-finite token count")
        return int(value)
    raise TypeError(f"unsupported token count type: {type(value).__name__}")


def build_parse_error_detail(stage, error_type, line_no=None,
                              basename=None, sid_prefix=None):
    """Construct sanitized parse_error_detail from curated tokens ONLY.

    Inputs are pre-validated against ALLOWED_STAGES and ALLOWED_ERROR_TYPES.
    Numeric/basename/sid arguments are typed; no raw exception, stderr, or
    transcript content is accepted. Output is truncated to MAX_DETAIL_LEN.
    """
    if stage not in ALLOWED_STAGES:
        stage = "internal"
    if error_type not in ALLOWED_ERROR_TYPES:
        error_type = "internal"

    parts = [f"{stage}:{error_type}"]
    if isinstance(line_no, int) and line_no >= 0:
        parts.append(f"line={line_no}")
    if basename and "/" not in basename and "\\" not in basename:
        # Take only POSIX basename, no path separator can be present
        safe_basename = basename[:40]
        parts.append(f"file={safe_basename}")
    if sid_prefix:
        # First 8 chars, alphanumeric+dash only
        sid_clean = "".join(c for c in sid_prefix[:8] if c.isalnum() or c == "-")
        if sid_clean:
            parts.append(f"sid={sid_clean}")

    detail = " ".join(parts)
    if len(detail) > MAX_DETAIL_LEN:
        detail = detail[: MAX_DETAIL_LEN - 1] + "…"
    return detail


def empty_summary(period, status="complete", error=None,
                   parse_error_detail=None, warnings=None):
    """Build a zero-valued usage_summary block."""
    block = {
        "period": period,
        "sessions": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "total_tokens": 0,
        "total_cost": 0,
        "models_used": [],
        "model_breakdowns": [],
        "unknown_models": [],
        "cost_estimation_status": status,
        "warnings": warnings or [],
    }
    if error is not None:
        block["error"] = error
    if parse_error_detail is not None:
        block["parse_error_detail"] = parse_error_detail
    return block


def load_price_table(path):
    """Load the price table.

    Returns (alias_map, zero_cost, last_verified):
      - alias_map     : raw_model_alias -> (canonical, record)
      - zero_cost     : set of model aliases that are KNOWN and intentionally
                        priced at zero (e.g. "<synthetic>", Claude Code's
                        placeholder id for compaction/system events). These are
                        real token-consuming events with no billable model, so
                        they count toward token totals but contribute 0 cost and
                        must NOT pollute unknown_models (which would flip
                        cost_estimation_status to "partial").
      - last_verified : the table's _last_verified date string, or None.
    """
    with open(path, "r") as f:
        data = json.load(f)
    alias_map = {}
    for record in data.get("models", []):
        canonical = record["canonical"]
        for alias in record.get("aliases", []):
            alias_map[alias] = (canonical, record)
    zero_cost = set(data.get("known_zero_cost", []))
    last_verified = data.get("_last_verified")
    return alias_map, zero_cost, last_verified


def parse_iso_date(ts):
    """Extract YYYY-MM-DD UTC from an ISO timestamp, or None on failure."""
    if not ts or not isinstance(ts, str):
        return None
    try:
        # Handle both 'Z' and explicit offsets
        ts_clean = ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts_clean)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt.strftime("%Y-%m-%d")
    except (ValueError, TypeError):
        return None


def discover_files(transcripts_dir):
    """List JSONL files under the transcripts dir.

    Correctness boundary is the per-event `timestamp` inside each JSONL line
    (checked in process_file). mtime is NOT used as a filter — copied,
    restored, or synced transcript files can carry yesterday's events with
    an old mtime, so mtime is never a correctness filter. If perf becomes a
    real issue at scale, use an index rather than a date filter that can drop
    valid events.

    Glob is recursive (**/*.jsonl): besides <project>/<session>.jsonl,
    Claude Code writes subagent transcripts at
    <project>/<session>/subagents/agent-*.jsonl (Agent/Task/Workflow
    subagents). A one-level glob (*/*.jsonl) would miss those files and
    under-report usage (~25% vs ccusage).
    """
    root = Path(transcripts_dir)
    if not root.exists():
        return []
    try:
        return list(root.glob("**/*.jsonl"))
    except OSError:
        return []


def process_file(path, period, alias_map):
    """Yield (session_id, usage_dict, canonical_or_None, raw_model, dedup_key)
    tuples for lines in `path` whose timestamp falls in `period`.

    `dedup_key` is `(sessionId, requestId)` when available, else
    `(sessionId, message.id)`, else `None`. Caller is responsible for
    skipping duplicates — Claude Code transcripts can replay the same
    assistant turn multiple times (session resume, sidechain branches,
    compact-context summarization), so summing all events double-counts
    cost. Dedup lives in aggregate() because the same `(session, request)`
    pair can appear across multiple JSONL files.

    On per-line errors, yields ("__parse_error__", line_no) — caller
    counts these in warnings without exposing line content.
    """
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        yield ("__io_error__", 0)
        return

    line_no = 0
    with fh:
        for line in fh:
            line_no += 1
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                yield ("__parse_error__", line_no)
                continue

            event_date = parse_iso_date(event.get("timestamp"))
            if event_date != period:
                continue

            message = event.get("message") or {}
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue

            session_id = event.get("sessionId") or event.get("session_id")
            raw_model = message.get("model")
            canonical = None
            if raw_model and raw_model in alias_map:
                canonical, _record = alias_map[raw_model]

            request_id = event.get("requestId")
            message_id = message.get("id") if isinstance(message, dict) else None
            if request_id:
                dedup_key = ("req", session_id, request_id)
            elif message_id:
                dedup_key = ("msg", session_id, message_id)
            else:
                dedup_key = None

            # Per-line field validation — a single bad token field must NOT
            # zero the day. If any int() conversion
            # raises, count the line as parse_partial and continue with the
            # next line. Aggregation of good lines is unaffected.
            try:
                normalized_usage = {
                    "input_tokens": _safe_int(usage.get("input_tokens")),
                    "output_tokens": _safe_int(usage.get("output_tokens")),
                    "cache_creation_tokens": _safe_int(
                        usage.get("cache_creation_input_tokens")
                    ),
                    "cache_read_tokens": _safe_int(
                        usage.get("cache_read_input_tokens")
                    ),
                }
            except (TypeError, ValueError):
                yield ("__parse_error__", line_no)
                continue
            yield (session_id, normalized_usage, canonical, raw_model, dedup_key)


def compute_cost(canonical, record, usage):
    """Cost in USD for a single event's usage against a canonical record."""
    if record is None:
        return 0.0
    return (
        usage["input_tokens"] * record["input_per_mtok"] / 1_000_000.0
        + usage["output_tokens"] * record["output_per_mtok"] / 1_000_000.0
        + usage["cache_creation_tokens"]
        * record["cache_creation_per_mtok"]
        / 1_000_000.0
        + usage["cache_read_tokens"]
        * record["cache_read_per_mtok"]
        / 1_000_000.0
    )


def aggregate(transcripts_dir, period, alias_map, zero_cost=None):
    """Aggregate transcripts for the period into the usage_summary."""
    zero_cost = zero_cost or set()
    files = discover_files(transcripts_dir)
    if not files:
        return empty_summary(period, status="complete")

    totals = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
    }
    sessions = set()
    files_with_events = set()
    models_used = set()
    unknown_models = set()
    total_cost = 0.0
    bad_lines = 0
    unreadable_files = 0
    missing_usage = 0
    duplicate_events = 0
    seen_dedup_keys = set()
    per_model = {}  # canonical_name -> {inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost}

    for fpath in files:
        any_event_from_file = False
        for tup in process_file(fpath, period, alias_map):
            if tup[0] == "__parse_error__":
                bad_lines += 1
                continue
            if tup[0] == "__io_error__":
                unreadable_files += 1
                continue
            session_id, usage, canonical, raw_model, dedup_key = tup
            # Skip replayed assistant turns (same sessionId+requestId
            # appearing more than once across the transcript set). Events
            # without any usable dedup key are kept — better to risk a
            # small over-count than silently drop legitimate usage.
            if dedup_key is not None:
                if dedup_key in seen_dedup_keys:
                    duplicate_events += 1
                    continue
                seen_dedup_keys.add(dedup_key)
            any_event_from_file = True
            for k in totals:
                totals[k] += usage[k]
            if session_id:
                sessions.add(session_id)
            else:
                files_with_events.add(str(fpath))

            if canonical:
                models_used.add(canonical)
                _, record = alias_map.get(raw_model, (None, None))
                event_cost = compute_cost(canonical, record, usage)
                total_cost += event_cost
                bucket = per_model.setdefault(canonical, {
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.0,
                })
                bucket["inputTokens"] += usage["input_tokens"]
                bucket["outputTokens"] += usage["output_tokens"]
                bucket["cacheCreationTokens"] += usage["cache_creation_tokens"]
                bucket["cacheReadTokens"] += usage["cache_read_tokens"]
                bucket["cost"] += event_cost
            elif raw_model and raw_model in zero_cost:
                # Known placeholder model (e.g. "<synthetic>"): real tokens,
                # zero billable cost. Count it as a known model so it does NOT
                # land in unknown_models / flip cost_estimation_status.
                models_used.add(raw_model)
                bucket = per_model.setdefault(raw_model, {
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.0,
                })
                bucket["inputTokens"] += usage["input_tokens"]
                bucket["outputTokens"] += usage["output_tokens"]
                bucket["cacheCreationTokens"] += usage["cache_creation_tokens"]
                bucket["cacheReadTokens"] += usage["cache_read_tokens"]
            elif raw_model:
                unknown_models.add(raw_model)
            else:
                missing_usage += 1

        if not any_event_from_file:
            pass

    session_count = len(sessions) + len(files_with_events)

    warnings = []
    if bad_lines:
        warnings.append({"type": "parse_partial", "bad_lines": bad_lines})
    if unknown_models:
        warnings.append(
            {"type": "unknown_model", "model_alias_count": len(unknown_models)}
        )
    if unreadable_files:
        warnings.append(
            {"type": "file_unreadable", "file_count": unreadable_files}
        )
    if duplicate_events:
        warnings.append(
            {"type": "duplicate_events", "event_count": duplicate_events}
        )

    cost_status = "partial" if unknown_models else "complete"

    total_tokens = (
        totals["input_tokens"]
        + totals["output_tokens"]
        + totals["cache_creation_tokens"]
        + totals["cache_read_tokens"]
    )
    model_breakdowns = [
        {
            "modelName": name,
            "inputTokens": v["inputTokens"],
            "outputTokens": v["outputTokens"],
            "cacheCreationTokens": v["cacheCreationTokens"],
            "cacheReadTokens": v["cacheReadTokens"],
            "cost": round(v["cost"], 6),
        }
        for name, v in sorted(per_model.items())
    ]
    return {
        "period": period,
        "sessions": session_count,
        "input_tokens": totals["input_tokens"],
        "output_tokens": totals["output_tokens"],
        "cache_creation_tokens": totals["cache_creation_tokens"],
        "cache_read_tokens": totals["cache_read_tokens"],
        "total_tokens": total_tokens,
        "total_cost": round(total_cost, 6),
        "models_used": sorted(models_used),
        "model_breakdowns": model_breakdowns,
        "unknown_models": sorted(unknown_models),
        "cost_estimation_status": cost_status,
        "warnings": warnings,
    }


def main():
    parser = argparse.ArgumentParser(description="Heartbeat usage parser")
    parser.add_argument("--period", required=True, help="YYYY-MM-DD UTC")
    parser.add_argument("--prices", required=True, help="Path to prices.json")
    parser.add_argument(
        "--transcripts-dir",
        default=os.environ.get(
            "HB_CLAUDE_PROJECTS_DIR",
            os.path.expanduser("~/.claude/projects"),
        ),
    )
    parser.add_argument(
        "--prices-stale-reason",
        default="",
        help="Non-empty when the runtime refresh failed or the cached table "
             "is over-age; surfaced as a prices_stale warning so the stale "
             "tail is visible on the dashboard rather than silent.",
    )
    args = parser.parse_args()

    last_verified = None

    def _emit(summary):
        """Attach the prices_stale warning (if any) and print. The warning is
        data-only — reason is a short enum-like token, never a path or raw git
        error, per security baseline."""
        if args.prices_stale_reason:
            w = {"type": "prices_stale", "reason": args.prices_stale_reason}
            if last_verified:
                w["last_verified"] = last_verified
            summary.setdefault("warnings", []).append(w)
        print(json.dumps(summary))
        return 0

    # Fatal failure handler — emit State D, exit 0, never raise outward
    try:
        try:
            alias_map, zero_cost, last_verified = load_price_table(args.prices)
        except (OSError, json.JSONDecodeError, KeyError, ValueError):
            detail = build_parse_error_detail("price", "io_error")
            return _emit(empty_summary(
                args.period,
                status="unavailable",
                error="parse_failed",
                parse_error_detail=detail,
                warnings=[{"type": "fatal_parse_failure"}],
            ))

        if not os.path.isdir(args.transcripts_dir):
            # No transcripts dir = State B (idle), not fatal.
            return _emit(empty_summary(args.period, status="complete"))

        summary = aggregate(args.transcripts_dir, args.period, alias_map,
                            zero_cost)
        return _emit(summary)
    except Exception:
        # Any unhandled exception = fatal. NEVER pass the exception
        # text through — sanitize via the curated builder.
        detail = build_parse_error_detail("internal", "internal")
        print(json.dumps(empty_summary(
            args.period,
            status="unavailable",
            error="parse_failed",
            parse_error_detail=detail,
            warnings=[{"type": "fatal_parse_failure"}],
        )))
        return 0


if __name__ == "__main__":
    sys.exit(main())
