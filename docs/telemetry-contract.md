# intellisense Metrics — Telemetry Collector Contract

**Audience:** the team that owns your organization's intellisense telemetry collector
(the endpoint configured at `~/.intellisense/heartbeat-endpoint` — see `setup.sh`).
This is a reference contract: it describes the shape intellisense sends, not a
specific vendor or URL.

---

## TL;DR

intellisense produces analytics data through two channels:

1. **Commit trailers** — every intellisense-active commit carries a single `Intellisense-Metadata: <json>` trailer line. Read it via the existing GitHub commits API. **No changes required on the collector's side for this channel.**
2. **Heartbeat POST** — each developer's laptop POSTs one small JSON document up to 3 times per day per dev.

The two channels feed the same analytics database. Trailers carry per-commit / per-PR signals; heartbeats carry per-developer / per-day state. Both paths are designed to overlap deliberately on token/cost so you can cross-check.

---

## Part 1 — Commit trailers

### Where to read them

`GET /repos/{owner}/{repo}/pulls/{pr-number}/commits` returns the per-commit metadata. Parse the `message` field of each commit.

**Important:** read from the pre-merge PR commits API, NOT from default-branch `git log`. GitHub's "Squash and merge" drops per-commit trailers from the final default-branch commit. The `/pulls/{n}/commits` endpoint keeps them intact via the PR head refs.

### When trailers appear

Every commit made on an intellisense-onboarded repo by a developer with an active Claude Code session.

Commits with no active Claude Code session (no intellisense) emit no trailers — absence is the signal. Analytics classifies those as "developer-only" per metric #7.

### Format — single JSON trailer

Every intellisense-active commit carries exactly one `Intellisense-Metadata: <json>` line. The JSON's `v` field is the metadata-schema version (currently `1`). Tier 0 commits omit the skill/rule/agent chain; everything else is identical. Schema is additive under a dual-read policy — analytics MUST ignore unknown fields rather than reject them, so new fields (like `routing`) flow in without coordinated parser updates.

| Tier of the commit | JSON keys present |
|---|---|
| **Tier 0** (doc-only, dep bump, cosmetic) | `v`, `author_type`, `commit_kind`, `stamping_source`, `classification_state`, `tier`, `mode`, `session`, `version`, `tokens` |
| **Tier 1 / Tier 2** (feature, bug fix, security, financial) | the above + `skills`, `rules_expected`, `agents` |
| **Either tier, when routing escalations occurred** | the above + `routing` (see below) |
| **Stub commits** (no active session, merge, squash, jq missing, classification corrupt) | `v`, `author_type`, `commit_kind`, `stamping_source`, plus shape-specific fields (`tier`, `classification_state`, `tooling_state`, `session`) — see hooks/prepare-commit-msg for the canonical stub set |
| **Non-intellisense commit** | no `Intellisense-Metadata` trailer at all — absence is the signal |

`tokens` is always an object with five integer fields: `input`, `output`, `cache_creation`, `cache_read`, `total`. `total = input + output + cache_creation + cache_read`.

### Real example — Tier 1 commit with a routing escalation

```
fix(account): correct negative-balance handling

Change Contract: files_affected=2, estimated_lines=80, confidence=0.88, risk=medium

Intellisense-Metadata: {"v":1,"author_type":"claude_with_intellisense","commit_kind":"single","stamping_source":"local_hook","classification_state":"ok","tier":2,"mode":"full_feature","session":"00000000-0000-4000-8000-000000000001","version":"1.0.0","skills":["plan","tdd"],"rules_expected":["baseline/security","baseline/reasoning-integrity","operational/development-workflow","operational/testing","language-specific/go-patterns"],"agents":["Explore","Plan"],"tokens":{"input":8234,"output":1893,"cache_creation":1024,"cache_read":42000,"total":53151},"routing":{"model_per_phase":{},"promotions":["high_risk_file","tier_2"],"escalations":[{"from_tier":0,"to_tier":2,"trigger":"path_pattern","phase":"implement"}]}}
```

### Real example — Tier 0 commit

```
docs: fix typo in README

Intellisense-Metadata: {"v":1,"author_type":"claude_with_intellisense","commit_kind":"single","stamping_source":"local_hook","classification_state":"ok","tier":0,"mode":"refactor","session":"00000000-...","version":"1.0.0","tokens":{"input":120,"output":40,"cache_creation":0,"cache_read":1500,"total":1660}}
```

### Field semantics

| JSON field | Type | Meaning |
|---|---|---|
| `v` | integer | Metadata-schema version. Currently `1`. Bumped on shape change; additive fields don't bump. |
| `author_type` | enum | `claude_with_intellisense` \| `merge` \| `squash` \| `no_session_signal` — classifies who/what produced the commit. |
| `commit_kind` | enum | `single` \| `merge` \| `squash` — git-level commit shape. |
| `stamping_source` | string | Always `local_hook` for now (where the trailer was injected). Reserved for future CI-side stamping. |
| `classification_state` | enum | `ok` \| `missing` \| `corrupt` \| `unavailable` — degraded states still emit a trailer(universal coverage). |
| `tier` | `0` \| `1` \| `2` | Effective tier = max(prompt_tier, path_tier, policy_tier). May be higher than the classifier's prompt_tier; see `routing` below. |
| `mode` | string | `full_feature` \| `bug_fix` \| `refactor` \| `hotfix` \| `design_review_only` \| `pr_review` \| `qa` \| `fix_pr_comments` |
| `session` | UUID | Claude Code session uuid — joins to per-session token data |
| `version` | semver | intellisense platform version on the dev's machine |
| `skills` | array of strings | Skills invoked this session (e.g. `["plan","tdd","code-review"]`) — Tier 1/2 only |
| `rules_expected` | array of strings | Rule files the classifier expected to load. NOT proof they actually entered Claude's context window — naming reflects this honestly. Tier 1/2 only. |
| `agents` | array of strings | Subagents spawned (e.g. `["Explore","Plan"]`) — Tier 1/2 only |
| `tokens.input` | integer | New input tokens consumed in this commit's attribution window |
| `tokens.output` | integer | New output tokens consumed in this commit's attribution window |
| `tokens.cache_creation` | integer | Tokens consumed creating prompt-cache entries |
| `tokens.cache_read` | integer | Tokens served from prompt cache (cheaper than `input`; needed for accurate cost & cache-hit-rate) |
| `tokens.total` | integer | Sum of the four above; analytics MAY recompute and reject on mismatch |
| `routing.model_per_phase` | object | **Restricted access** — placeholder object today (`{}`). Reserved for `{plan, implement, review} → model-name` map once per-phase model selection is instrumented. Treat absence/empty as "not tracked yet", not "no model used". |
| `routing.promotions` | array of strings | **Restricted access** — deduped labels describing why this session's effective tier ended up where it did. Enum: `tier_2` (any escalation reached Tier 2), `high_risk_file` (a Tier 2 path pattern matched — auth, financial, migration, security, reasoning-integrity), `policy_floor` (`.intellisense/manifest.json:policy_minimum_tier` raised the tier). Empty array = no escalations this session. |
| `routing.escalations` | array of objects | **Restricted access** — session-cumulative escalation timeline. Each entry: `{event_id, ts, from_tier, to_tier, trigger, reason, phase}`. `trigger` enum: `path_pattern` \| `policy_floor`. `phase` enum: `implement` \| `commit` \| `unknown` (coarse, derived from the gated tool name; finer per-skill phase tracking is deferred). Capped at the last 20 entries to bound trailer size. **Dedup contract:** `event_id` is a stable per-session hash over `{from_tier, to_tier, trigger, reason}` — the same logical escalation produces the same `event_id` whether it surfaces via this trailer, via the per-session JSONL writer, or via the daily heartbeat. Analytics MUST dedup by `(session, event_id)` across all three channels before summing across commits; otherwise a session with N commits over-counts each escalation N×. The trailer is a cumulative view, so the same `event_id` will reappear in every later commit's trailer for that session — that is by design; dedup it on read. Routing counters elsewhere in this doc (heartbeat `escalations_today`, `promotions_count.*`) report **unique escalation events**, not gated-tool invocations. |

### Parsing the JSON

```python
# Python (analytics pipeline)
import json, re
TRAILER = re.compile(r'^Intellisense-Metadata: (\{.*\})$', re.M)
match = TRAILER.search(commit_message)
if match:
    meta = json.loads(match.group(1))
    # Current schema version is v=1. Per the dual-read policy, additive
    # fields don't bump the version — readers MUST ignore unknown fields
    # rather than reject them. A higher `v` only appears with a shape change
    # (rename, removal), coordinated separately.
    if meta.get("v") != 1:
        # unknown shape — log and continue with best-effort parse.
        pass
    tier   = meta["tier"]
    tokens = meta["tokens"]   # always present, all 5 sub-fields
    skills = meta.get("skills", [])   # Tier 0 commits omit
    # routing.escalations[] (Tier 1/2 commits) — dedup by (session, event_id)
    # across this trailer, the per-session JSONL, and the heartbeat. Rows with
    # an empty event_id use the fallback key.
    routing = meta.get("routing", {})
    for esc in routing.get("escalations", []):
        key = (
            meta["session"],
            esc.get("event_id") or
            (esc["from_tier"], esc["to_tier"], esc["trigger"], esc.get("reason", "")),
        )
        # … aggregate by key …
```

```bash
# bash / CI scripts
git log -1 --format=%B HEAD | grep '^Intellisense-Metadata:' | sed 's/^Intellisense-Metadata: //' | jq .
```

### Token attribution — no double-counting

`tokens` uses a per-session cursor. Each transcript message is counted in exactly one commit's trailer. If a PR has 5 commits using ~10k tokens each, summing the 5 trailers gives ~50k — the real total.

`cache_read` and `cache_creation` are included because cached prompt data is real spend (cache reads are billed at a discount, cache creation at a premium) and because cache hit rate is itself a useful metric.

**The math:**
- First commit on a session: cursor starts empty, tally tokens from session start
- Each subsequent commit: tally tokens since the previous commit's cursor position
- Two-phase commit logic: cursor only advances after the commit actually lands (Phase 2 `post-commit` hook). Aborted commits do not advance the cursor.

Branch reuse, squash, force-push do not double-count when the analytics team follows the integrity rules below.

### Routing data — cross-channel rule (read this first)

The same routing escalation event appears in **both** the per-commit trailer (`Intellisense-Metadata.routing.escalations[]`) and the daily heartbeat (`behavior_stats.routing_stats.escalations_today`). They are NOT additive — they are the same event, surfaced through two different ingestion paths for two different use cases.

**Authoritative source by metric:**

| Question the dashboard answers | Source channel | Why |
|---|---|---|
| "How many escalations today / this week / this month?" | **Heartbeat** | One row per dev per day, server-deduplicated by `idempotency_key`. Summing across days gives correct totals without further dedup. |
| "How many escalations in this PR?" | **Trailer** (with within-session dedup) | Heartbeat has no PR granularity. Read each PR commit's `routing.escalations[]`, dedup by `(session, event_id)` — array position is NOT a stable identity because the trailer caps at the last 20 events and the same `event_id` reappears in later commits of the same session. For rows with an empty `event_id` (the writer had no hash tool), fall back to `(session, from_tier, to_tier, trigger, reason)`. Count once per unique key. |
| "Which classifier mode produces the most escalations?" | **Heartbeat** (`mode_mix` join) + **Trailer** (per-PR `mode` field as cross-check) | Heartbeat aggregates per dev per day; trailer carries the per-commit mode for drill-down. |
| "Per-developer rate over time" | **Heartbeat** only | Access-restricted per governance section — see RBAC note below. |

**Do NOT sum trailer counts and heartbeat counts.** If a developer had 1 real escalation in a 5-commit session, the trailer channel will surface it 5 times (session-cumulative) and the heartbeat will surface it 1 time. Naive sum = 6; truth = 1.

### Integrity checks the analytics team should run on ingest

| Check | Action |
|---|---|
| `Intellisense-Metadata` trailer missing on a Tier 1+ commit, OR JSON parse fails, OR required fields absent | tag PR row with `trailer_integrity: missing`, `contract_status: warning` |
| `tier` declared but file paths in the diff imply a higher tier | tag with `trailer_integrity: inconsistent`, `contract_status: warning` |
| `tokens.total != tokens.input + tokens.output + tokens.cache_creation + tokens.cache_read` | tag with `trailer_integrity: inconsistent`, `contract_status: warning` |
| Squash-merge | always read from `GET /pulls/{n}/commits` (pre-merge), NOT default-branch `git log` |
| Force-push | replace the PR's stored commit set on each `synchronize` / `closed` webhook (don't sum old + new SHAs) |
| Cherry-pick (commit appears in 2 PRs) | dedup key is `(repo, commit_sha)` — count once per PR it appears in |

Tier re-derivation logic for the integrity check is shared via `scripts/lib/effective-tier.sh` in the intellisense repo — port to your pipeline's language.

---

## Part 2 — Heartbeat POST

### Endpoint

```bash
curl -X POST "$INTELLISENSE_HEARTBEAT_URL" \
  -H "Authorization: Bearer <INTELLISENSE_HEARTBEAT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '<payload below>'
```

- **URL**: whatever your organization configured via `INTELLISENSE_HEARTBEAT_ENDPOINT` at setup time (stored at `~/.intellisense/heartbeat-endpoint`) — intellisense ships no default and never assumes a specific vendor or domain. HTTPS required in production (`--allow-http` is for local collector testing only).
- **Auth**: one shared bearer token, distributed by your organization's intellisense platform admin. Dev sets `INTELLISENSE_HEARTBEAT_TOKEN` env var (or pastes interactively) before running `bash setup.sh`.
- **Method**: POST
- **Content-Type**: application/json

### When the POST fires

Three triggers per developer:

| Trigger | When | Notes |
|---|---|---|
| `setup.sh` install | One-time, when a dev installs/refreshes intellisense | Catches every newly-onboarded dev immediately |
| `setup-repos.sh` install | Each time a dev onboards a new repo | Updates `onboarded_repos[]` |
| Daily cron at 09:00 local | Every day | Uses launchd (Mac) / anacron (Linux) so missed schedules fire on next wake. Laptop closed at 9 AM → fires at 9:47 when reopened. |

If the API is unreachable, the heartbeat script writes the payload to `~/.claude-intellisense/heartbeat-queue/<timestamp>.json` and retries on next fire. Queue is bounded at 30 entries (≈1 month).

### Full payload schema

```json
{
  "event_type": "developer_heartbeat",
  "schema": 1,
  "timestamp": "2026-05-19T09:00:14Z",
  "github_login": "example-dev",
  "intellisense_version": "1.0.0",
  "platform": "darwin",
  "gate_mode": "pilot",

  "onboarded_repos": [
    { "repo": "your-org/orders-service", "stack": "go",  "claude_md_present": true },
    { "repo": "your-org/reporting-service",   "stack": "go",  "claude_md_present": true },
    { "repo": "your-org/invoicing-service",  "stack": "php", "claude_md_present": true }
  ],

  "usage_summary": {
    "period": "2026-05-18",
    "sessions": 12,
    "input_tokens": 1234567,
    "output_tokens": 234567,
    "cache_creation_tokens": 100000,
    "cache_read_tokens": 5000000,
    "total_cost_usd": 12.45,
    "models_used": ["opus-4-7", "sonnet-4-6"]
  },

  "behavior_stats": {
    "period": "2026-05-18",
    "classifier_overrides_today": 2,
    "local_trailer_drift_count": 0,
    "audit_chain_warnings_today": 0,
    "mode_mix": { "full_feature": 3, "bug_fix": 7, "refactor": 1, "design_review_only": 4 },
    "top_skills_used": [
      { "skill": "plan",        "count": 8 },
      { "skill": "tdd",         "count": 5 },
      { "skill": "code-review", "count": 4 }
    ],
    "plan_to_commit_ratio": 0.75,
    "routing_stats": {
      "promotions_count": { "tier_2": 1, "high_risk_file": 1, "low_confidence": 0 },
      "demotions_count":  { "tier_0_mechanical": 0 },
      "escalations_today": 3,
      "escalation_to_replan_ratio": 0,
      "degraded_sessions": 2,
      "model_pinning_overrides": 0
    }
  },

  "tool_decision_counts": {
    "period": "2026-05-18",
    "accepted": 213,
    "rejected_by_user": 4,
    "tool_errors": 1
  },

  "prices_last_synced_at": "2026-06-04T03:30:11Z",

  "idempotency_key": "example-dev_2026-05-19"
}
```

### Field semantics

| Field | Meaning | Sensitivity |
|---|---|---|
| `event_type` | Always `"developer_heartbeat"` | — |
| `schema` | Payload version; bump on additive change | — |
| `timestamp` | ISO 8601 UTC when the heartbeat fired | — |
| `github_login` | From `gh api user --jq .login` — already public on every commit and PR | Public |
| `intellisense_version` | Helps detect version drift across the fleet | — |
| `platform` | `darwin` / `linux` / `windows` from `uname -s` | — |
| `gate_mode` | `"pilot"` (default) or `"enforced"` — for the rollout-progress widget | — |
| `onboarded_repos[]` | Powers metrics #1 (repos on intellisense) and #5 (per-dev repo + stack mix) | Repo names only |
| `usage_summary` | Daily ccusage aggregate; powers metrics #3 (per-PR tokens cross-check), #4 (CC usage details) | Aggregate counts |
| `behavior_stats` | **Restricted access** — see governance section below | Aggregate counts |
| `tool_decision_counts` | Powers metric #8 (acceptance rate). Parsed from `tool_result.is_error + content prefix "The user doesn't want to proceed"` markers in Claude Code transcripts. | Aggregate counts |
| `prices_last_synced_at` | ISO 8601 UTC of this dev's last successful price-table sync from the repo, or `null` if never synced (maintainer running in-repo, or a dev whose fetch has never succeeded). Treat null as "unknown / never synced". Powers a price-table freshness widget: dashboards can flag devs whose `prices_last_synced_at` is stale (e.g. > 7 days) and whose cost numbers may lag a model release. Pairs with `usage_summary.warnings[].type == "prices_stale"`. | — |
| `idempotency_key` | `<github_login>_<YYYY-MM-DD>` — server-side dedup on same-day re-runs | — |

### Server-side behavior the collector's owners needs to implement

| Responsibility | What it does |
|---|---|
| Token validation | Constant-time equality check against the known shared token. Reject with `401 {"error":"invalid_token"}` if wrong. |
| Idempotency | Re-receiving the same `idempotency_key` on the same day → return `200`, do NOT write a duplicate event. |
| Schema validation | Reject implausible values (`plan_to_commit_ratio > 1`, negative tokens, etc.) with `400 {"error":"invalid_payload"}`. |
| Rate limit | Max ~10 events/dev/day. Reject excess with `429 {"error":"rate_limit"}`. |
| Audit log | Every POST recorded with `(github_login, timestamp, source_ip, validation_outcome)`. |
| Token rotation playbook | Annually OR on suspected leak. Generate new token → update server config → announce → devs re-run `setup.sh` with new env var. 7-day grace window where both tokens are accepted. |

The collector's owners does **not** need to build any of the following (intellisense handles all of it on the dev side):
- Token issuance / minting
- Per-dev token storage (we use one shared token, intentionally — see future hardening below)
- Heartbeat scheduling (devs' laptops handle the cron)
- Payload generation (the dev-side script builds the JSON)

### Governance — restricted fields

All fields under `behavior_stats` are **restricted to intellisense-core engineering team + explicitly approved analytics maintainers**. The list:

- `classifier_overrides_today`
- `local_trailer_drift_count`
- `audit_chain_warnings_today`
- `plan_to_commit_ratio`
- `top_skills_used`
- `mode_mix`
- `routing_stats.*` (all sub-fields — promotions_count, demotions_count, escalations_today, escalation_to_replan_ratio, degraded_sessions, model_pinning_overrides)

Note: `routing.*` fields inside per-commit `Intellisense-Metadata` trailers carry the same restricted-access expectation. They are stored in commit messages (which are visible to anyone with repo read access), so the governance is honor-system at the storage layer; dashboards and analytics views that surface routing data must apply the same RBAC rules as behavior_stats.

**Why restricted:** these fields exist to improve the intellisense platform (classifier quality, hook reliability, skill adoption) — NOT to rank developers. Misusing them as performance signals would create the wrong incentives.

**Access rules:**
- Per-developer views of these fields require an `intellisense-core` role
- Default dashboards show team/repo aggregates only (5+ devs minimum to prevent re-identification)
- Anti-patterns to reject in code review:
  - ❌ "Top 10 developers by skill usage" → re-purposes the data for ranking
  - ❌ "Engineer X bypassed hooks 12 times this week" → uses friction signal as performance evidence
  - ✅ "`/plan` has a 30% commit-conversion rate across the org → redesign or retire" → platform decision

**Pilot mode (current):** governance is honor-system today; we document the rules. The dashboard layer should implement RBAC checks when it's built so this becomes enforced.

### Error contract (dev-side script behavior on each API response)

| API response | Heartbeat script behavior |
|---|---|
| `200 OK` | Mark queue entry as delivered, evict from queue |
| `401 {"error":"invalid_token"}` | Log to `~/.claude-intellisense/heartbeat-errors.log`; surface via `bd doctor`; prompt dev to re-run `setup.sh` |
| `400 {"error":"invalid_payload"}` | Log + alert admin (script bug); do not retry |
| `429 {"error":"rate_limit"}` | Drop event silently; next day's cron will send fresh |
| `200` with duplicate `idempotency_key` | Treat as success, evict from queue |
| `503` / unreachable | Keep payload in local queue, retry on next fire |

### Future hardening (deferred)

The current auth model is **one shared bearer token for all 300+ developers**. Known trade-offs accepted for shipping speed:
- A dev who extracts the token can spoof any `github_login` in payload
- One leak affects everyone until rotation
- No per-dev revocation on offboarding

If any of these become real problems (token leak, spoofed events spotted in audit log, compliance pushback), the upgrade path is:
1. **Pre-minted Ed25519 JWTs keyed on corporate email** — admin script syncs from corporate directory and pre-mints per-dev JWTs; setup.sh fetches by email; API validates with public key. Strong identity, no API call at setup time.
2. **Per-dev tokens via SSO browser enrollment** — setup.sh opens browser, dev does corporate SSO login once, captures token via localhost callback.

Either upgrade is additive — the heartbeat payload schema doesn't change, only the `Authorization` header validation does.

---

## What intellisense sends

**Commit trailers:**
- Commit trailer format — single `Intellisense-Metadata: <json>` line, schema **`v=1`** (additive-only under the dual-read policy)
- Tier 0 vs Tier 1/2 JSON field difference (Tier 0 omits skills/rules_expected/agents)
- Token-attribution math (per-session cursor, two-phase commit, 4 token components + total)
- Routing extension — `Intellisense-Metadata.routing` and `behavior_stats.routing_stats`; data sourced from `.intellisense/session/<sid>.routing.jsonl` written by the PreToolUse audit-chain gate on every path/policy tier escalation
- Integrity checks the analytics team should run

**Heartbeat:**
- `scripts/intellisense-heartbeat.sh` — payload builder + POST + local queue + idempotency
- Token install UX in `setup.sh`: `INTELLISENSE_HEARTBEAT_TOKEN` env var OR interactive paste (hidden); `--rotate-token`, `--no-heartbeat`, `--allow-http`, `--print-token-instructions` flags
- Token storage at `~/.intellisense/heartbeat-token` (mode 0600)
- Daily cron: launchd on macOS (`StartCalendarInterval` 09:00 local), anacron / `crontab @daily` on Linux. Idempotent across re-runs.
- `tool_decision_counts` parser (from transcripts)
- `behavior_stats` aggregator (5 governed fields)
- ccusage integration for `usage_summary` (omitted cleanly when ccusage not installed)
- Heartbeat fires once during `setup.sh` to land the dev on the dashboard immediately


---

## Suggested dashboard widgets (routing-aware, starting menu)

These are the highest-impact views derivable from the new fields. They are starting points — once the data is flowing, the analytics team owns dashboard composition. Every widget below names its source channel and the dedup/denominator rules so the numbers come out right on day one.

| # | Widget | Source | Formula / aggregation | Dedup / denominator notes |
|---|---|---|---|---|
| 1 | **Daily escalations trend** (line chart) | Heartbeat | `SUM(routing_stats.escalations_today)` grouped by day | Already deduped server-side via `idempotency_key`. Do NOT add trailer counts. |
| 2 | **Tier-2 incidents per week** (single big number) | Heartbeat | `SUM(routing_stats.promotions_count.tier_2)` over last 7 days | Headline metric: "how often is genuinely-severe risk sneaking under low-tier prompts". Watch this. |
| 3 | **Classifier-miss rate** (line chart, lower = better) | Heartbeat | `SUM(routing_stats.degraded_sessions) / SUM(usage_summary.sessions)` per day | Denominator from existing `usage_summary.sessions`. Sessions with any escalation count once regardless of how many escalations that session had. |
| 4 | **Escalation triggers breakdown** (stacked bar or pie) | Heartbeat | Stack `promotions_count.high_risk_file` vs `promotions_count.tier_2` vs `promotions_count.low_confidence` per day | Tells the platform team which classifier weakness is dominant — vocabulary gap (`high_risk_file`), severity-detection gap (`tier_2`), or uncertainty (`low_confidence`). |
| 5 | **Per-PR routing drill-down** (PR detail page) | Trailer | For the selected PR, parse each commit's `routing.escalations[]`, dedup by `(session, event_id)` (or the fallback key when `event_id` is empty), render as a timeline | This is the "why was this PR risky?" view. Trailer is the right source because it's per-commit; heartbeat has no PR granularity. Each unique `event_id` is one escalation, not one tool invocation — the writer dedupes within-session so 3 edits to the same Tier 2 file count as one event. |
| 6 | **Tier-2 path-pattern hot list** (table) | Trailer (Tier 1/2 commits only) | Count occurrences of each Tier 2 reason (`auth/identity`, `financial`, `database migration`, `security rule`, `reasoning-integrity rule`) across all PRs in the period. Dedup by session before counting. | Surfaces which path-pattern family fires most — direct input to classifier vocabulary improvements. |
| 7 | **Repo / team rollup** (table, 5+ devs minimum) | Heartbeat aggregated by team / repo via `onboarded_repos[]` join | Rows: team or repo. Columns: `escalations_today` (mean), `tier_2` count, `degraded_sessions` rate | **Governance:** Per-developer breakdown of these fields is restricted to a governance role. Default views aggregate to 5+ devs to prevent re-identification. |

### Widgets to **add later** (placeholder fields ship at 0 today)

| Widget | Lights up when | Why it's worth waiting for |
|---|---|---|
| Cost-by-phase | `routing.model_per_phase` writer lands | Tells you whether Opus is overused on review (cost) or Haiku is underused on planning (quality). |
| Replan compliance | `routing_stats.escalation_to_replan_ratio` source lands | Detects developers who power through mid-task escalations without re-invoking `/plan` — exact failure mode that breaks Tier 2 governance. |
| Over-classification rate | `routing_stats.demotions_count.tier_0_mechanical` writer lands | Inverse signal to escalation rate: are we forcing contracts on genuinely trivial work? |
| Router trust score | `routing_stats.model_pinning_overrides` writer lands | "Do developers actually trust the model router?" If override rate is high, retire or rebuild it. |

The four widgets above will populate automatically once their underlying writers ship — no schema change required.

---

## Collector requirements

A collector that receives intellisense heartbeats must:

1. **Accept the schema in this document.** Fields are additive under the dual-read policy; unknown fields must be ignored, not rejected.
2. **Authenticate with a bearer token.** Developers install it with `setup.sh`; when you rotate it, they run `bash setup.sh --rotate-token`.
3. **Treat `idempotency_key` as idempotent.** A same-day duplicate returns `200 OK` with no side effect (no duplicate event).
4. **Allow about 10 events per developer per day.** The heartbeat fires at most hourly and batches catch-up days.

---

Contact: your organization's intellisense platform admin for any clarification.
