---
applies_to: [all]
phase: [0, 1]
priority: HIGH
enforcement: advisory
load_when: planning
---

# Graph-Supported Stacks

Applies only when the team chose `code-review-graph` as its code intelligence (`--code-intel code-review-graph`). The integration enforces graph-native workflows only on stacks an organization has explicitly opted into — see "No default mandatory stacks" below. This rule defines the classification.

**Classification matters because:**

- **mandatory-supported:** opt-in only (`INTELLISENSE_GRAPH_MANDATORY_STACKS`, see below) — `setup-repos.sh` builds the graph and enforces readiness criteria. `/code-review` §Impact Analysis treats graph results as primary.
- **candidate-supported:** `setup-repos.sh` builds the graph but does NOT enforce readiness. Output is treated as if from a weak stack until the stack is validated on a real production repo (§Candidate → Mandatory Promotion).
- **weak:** `setup-repos.sh` builds best-effort. Readiness is advisory. All graph-derived skill output is automatically prefixed with the `[INTELLISENSE-WEAK-STACK]` advisory marker.
- **unsupported:** `setup-repos.sh` declines without an explicit `--graph-exception unsupported-stack` opt-out.
- **case-by-case:** intellisense Platform Owner decides per repo.

## No default mandatory stacks

No stack ships mandatory-supported. `code-review-graph` is a single-maintainer
third-party tool (see `@docs/CODE-REVIEW-GRAPH-INTEGRATION.md` § Third-party
dependency) — this framework does not hard-depend any organization on it by
default. Go and Python default to candidate-supported (built, advisory,
never blocking) like every other stack below.

An organization that has evaluated the tool and wants hard enforcement for
specific stacks opts in explicitly:

```bash
INTELLISENSE_GRAPH_MANDATORY_STACKS="go python" bash setup-repos.sh --repo /path/to/repo --stack go
```

Comma- or space-separated, case-insensitive. Record a standing choice in
`rules/organization/` rather than passing the env var by hand every run.
Clear the validation bar in "Candidate → Mandatory Promotion" below first.

## Stack Classification

| Stack | Status | Behavior |
|---|---|---|
| **Go** | candidate-supported (opt into mandatory via `INTELLISENSE_GRAPH_MANDATORY_STACKS`) | Graph built; readiness advisory unless opted in |
| **Python** | candidate-supported (opt into mandatory via `INTELLISENSE_GRAPH_MANDATORY_STACKS`) | Graph built; readiness advisory unless opted in |
| **TypeScript / JavaScript / Node / NestJS / React** | candidate-supported | Graph built; readiness advisory; treated as weak until validated |
| **Java / C# / Kotlin / Rust** | candidate-supported | Same |
| **Laravel / PHP** | weak | Best-effort build; readiness advisory; output marked `[INTELLISENSE-WEAK-STACK]` |
| **Angular** | weak | Best-effort build; readiness advisory; output marked `[INTELLISENSE-WEAK-STACK]` |
| **Flutter / Dart** | weak | Best-effort build; readiness advisory; output marked `[INTELLISENSE-WEAK-STACK]`. Promotion to candidate-supported requires the standard validation bar (per §Candidate → Mandatory Promotion). |
| **Vue 2/3** | unsupported | `setup-repos.sh` declines without `--graph-exception unsupported-stack` |
| **Other (Solidity, GDScript, etc.)** | case-by-case | Decided per repo by intellisense Platform Owner |

## Minimum Node Thresholds

`setup-repos.sh` readiness requires `nodes >= minimum_threshold`. Stacks lacking this many nodes after a build typically indicate a parser failure or misconfigured repo, not a legitimately small codebase.

| Stack | Default minimum nodes |
|---|---|
| Go | 50 |
| Python | 50 |
| TypeScript / JavaScript / Node / NestJS / React (when promoted) | 50 |
| Java / C# / Kotlin / Rust (when promoted) | 50 |
| Laravel / Angular / Flutter (weak) | not enforced — readiness is advisory |

**Per-repo override:** `setup-repos.sh --min-nodes <N>` lowers the threshold for legitimately small repos. The override is recorded in `.intellisense/graph-status.json` (`min_nodes_override`) and triggers the universal `[INTELLISENSE-WEAK-STACK: empty-graph]` advisory marker on every subsequent skill invocation when below the stack default.

## Candidate → Mandatory Promotion

A candidate-supported stack moves to mandatory-supported only after intellisense validates a real production repo of that stack:

1. Build the graph on a representative production repo and run `verify-setup.sh --repo` against it.
2. Verify build success rate ≥ 95% over 30 days.
3. Verify `/code-review` §Impact Analysis returns useful output (qualitative grader on N=10 PRs).
4. The platform owner records the validation in this file (a PR, reviewed).
5. Stack moves from candidate-supported to mandatory-supported.

## Version Floor

The integration pins `code-review-graph==2.3.2`. Floor bumps require:

1. Run `verify-setup.sh` against the new version on at least one repo per supported stack.
2. Update the pin in `setup.sh` and `rules/operational/intelligence-sources.md`.
3. intellisense Platform Owner approves via PR review.

The pin is intentional. Future bumps are intentional too.

## Cross-references

- `@rules/operational/intelligence-sources.md` — engineering-question → upstream tool mapping
- `@rules/operational/graph-policy.md` — when graph is required (full policy; pointer summary in `@rules/operational/development-workflow.md §Codebase Exploration`)
- `@docs/CODE-REVIEW-GRAPH-INTEGRATION.md` — install, opting in, third-party dependency

## Validation record

- **Flutter/Dart** is weak (not case-by-case) after a real production repo built clean: 830 files parsed, 3,795 Dart
  nodes, `readiness=ready` in 4.9s. One-repo signal — promotion to candidate-supported still requires the full bar.
