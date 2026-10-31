# Language-Support Onboarding

> **Audience:** intellisense platform team. Not symlinked into developer machines — this file lives in `docs/` because it documents how the platform team adds new language/framework support to intellisense itself, which is not relevant to service-repo developers.

Reference document for adding (or auditing) a new language/framework stack in intellisense. Consult when the change set touches `setup-repos.sh` stack arms, `rules/language-specific/`, `templates/CLAUDE.md.*.template`, or `hook-packs/`.

The catalog architecture rule lives at `@rules/operational/ai-regression-patterns.md` (§Architecture Rule). This file extends that rule with the full file inventory, mechanical enforcement, and rollback semantics.

---

## Architecture Invariant — Shared-File Purity

The following files MUST stay stack-agnostic forever:

- `rules/operational/testing.md`
- `skills/tdd/SKILL.md`
- `skills/code-review/SKILL.md`

**Stack-specific routing and examples live ONLY in:**

- `rules/operational/ai-regression-patterns.md` (catalog — routes only)
- `rules/language-specific/<stack>-patterns.md` (examples and patterns)

Any reference to `<stack>-patterns.md` (any concrete stack name) inside a shared file is a violation, including code blocks, lists, and prose. Generic catalog references — pointing to `@rules/operational/ai-regression-patterns.md` and "the matching language-specific rule" — are required.

This invariant is enforced mechanically by `tests/test_stack_detection.sh` Check A. Violations block merge.

---

## File Inventory (every new stack add must address)

| Area | Required? | Notes |
|---|---|---|
| `rules/language-specific/<stack>-patterns.md` | REQUIRED | Must include a §"Isolated Real-Persistence Tests" section covering the applicable AI-regression patterns (P1–P4). |
| `rules/language-specific/<stack>/*.md` | OPTIONAL | Stack-owned subfiles for large stacks per the Hybrid Entrypoint architecture (codified in `ai-regression-patterns.md` §Architecture Rule). Entrypoint `<stack>-patterns.md` is still REQUIRED. Subfiles do not need their own catalog Routes — the entrypoint's Routes cover the whole stack. Trigger threshold: entrypoint >350 lines or a topic has a distinct load condition. |
| `rules/operational/ai-regression-patterns.md` Routes | REQUIRED | Append `, @rules/language-specific/<stack>-patterns.md §<section>` to the Routes list of each applicable P1–P4 entry. The catalog is the only enumerator. |
| `setup-repos.sh` — usage banner and validation arm (the `case "$STACK" in` block) | REQUIRED | Add the new stack identifier. |
| `setup-repos.sh` — `LANG_RULE=` switches (three separate switches) | REQUIRED | Map stack → `<stack>-patterns.md`. All three switches must agree. |
| `setup-repos.sh` — manifest-detection block | REQUIRED | Detect the stack from its manifest file (`go.mod`, `package.json`, `composer.json`, etc.) and emit a non-`[TODO]` `STACK_DETECTED` value. |
| `templates/CLAUDE.md.<stack>.template` | REQUIRED | Per-repo template copied by `setup-repos.sh`. |
| `templates/knowledge-base/` stubs | NOT APPLICABLE | Stack-agnostic. Reused for all stacks. |
| `hook-packs/<stack>/` | OPTIONAL | Add only when the stack has stack-specific pre-push checks. Skip when `hook-packs/basic/` covers the need. |
| `infrastructure/service-map.md` | REQUIRED IF REPOS EXIST | Add the new stack section and register actual service entries. |
| `infrastructure/knowledge-base.md` | REQUIRED IF REPOS EXIST | Term ownership for the new repos. |
| `tests/test_stack_detection.sh` | RE-RUN, NOT EDIT | Existing checks must continue to pass. |
| `tests/scenario_<stack>_<pattern>/` | REQUIRED IF AI-regression guidance is added | Proof artifact: `before` (weak/mocked test misses the bug) + `after` (real-path / value-asserting test catches it) + `run.sh`. Mirrors `tests/scenario_a_select_omission/`. |
| `scripts/validate-intellisense-content.sh` | OPTIONAL | Edit only if a new validation rule is needed. |
| `setup.sh` | REQUIRED | Layer-3 manual-fallback prompt (`case "$MANUAL_STACK" in`) and non-interactive error message must list the new stack. Skipped historically on the assumption that `setup.sh` is stack-agnostic; in fact the manual-fallback path is a second source of truth for the supported-stack list. Enforced by `tests/test_stack_detection.sh` Check H. |
| `CLAUDE.md` (this repo) | REQUIRED | Update the supported-stack count and any enumerations of language groups. |
| `docs/ARCHITECTURE.md` | OPTIONAL | Update only if it enumerates stacks. |
| Shared operational files (`/tdd`, `/code-review`, `testing.md`) | NEVER EDIT FOR STACK-SPECIFIC REASONS | Architecture invariant above. |

---

## Validation Checklist

Run on every stack-add PR. Checks 2–9 are merge-blocking; checks 1 and 11 are reviewer-discipline.

| # | Check | Command | Expected | Catches Python-class omission? | Merge gate |
|---|---|---|---|---|---|
| 1 | Stack-name discovery | `grep -rn '<stack>' . --include='*.md' --include='*.sh'` | Manual review against the inventory above | Advisory | Advisory |
| 2 | Shared-file purity | `bash tests/test_stack_detection.sh` (Check A) | Zero `<X>-patterns.md` references in the three shared files (catalog reference excluded) | YES — direct catch | BLOCKING |
| 3 | Forward consistency | `bash tests/test_stack_detection.sh` (Check B) | Every `rules/language-specific/<stack>-patterns.md` has at least one Route in the catalog | YES if the new patterns file is committed without catalog routing | BLOCKING |
| 4 | Reverse consistency | `bash tests/test_stack_detection.sh` (Check C) | Every `LANG_RULE=` reference in `setup-repos.sh` resolves to an existing patterns file | YES if a stack is declared in `setup-repos.sh` but the patterns file is missing | BLOCKING |
| 5 | Stack-onboarding completeness | `bash tests/test_stack_detection.sh` (Check D) | Every `<stack>-patterns.md` has a LANG_RULE arm in `setup-repos.sh` AND `templates/CLAUDE.md.<arm>.template` | YES if the patterns file is shipped without setup-repos.sh integration OR template | BLOCKING |
| 6 | Cross-switch LANG_RULE consistency | `bash tests/test_stack_detection.sh` (Check E) | All LANG_RULE switches agree per stack (no "one switch updated, another missed") | YES if a refactor disagreement is introduced | BLOCKING |
| 7 | Validation-arm ↔ LANG_RULE parity | `bash tests/test_stack_detection.sh` (Check F) | Validation arm and LANG_RULE switches reference the same set of stacks | YES if a stack is declared in only one of the two surfaces | BLOCKING |
| 8 | Enforcement-chain integrity | `bash tests/test_stack_detection.sh` (Check G) | This doc references `tests/test_stack_detection.sh` (so the test cannot be silently removed without orphaning the doc) | Catches doc-side test-reference deletion | BLOCKING |
| 9 | `setup.sh` ↔ `setup-repos.sh` parity | `bash tests/test_stack_detection.sh` (Check H) | Manual-fallback prompt in `setup.sh` lists the same stacks as `setup-repos.sh`'s validation arm, minus stacks classified `unsupported` | YES if a stack is added to `setup-repos.sh` but the `setup.sh` manual prompt is left stale | BLOCKING |
| 10 | Existing content validation | `bash scripts/validate-intellisense-content.sh` | PASS (frontmatter, references, token budgets) | NO — does not check stack purity | BLOCKING |
| 11 | AI-regression proof | `bash tests/scenario_<stack>_<pattern>/run.sh` (when applicable) | `before` test passes against the buggy code; `after` test fails | Phase-specific | BLOCKING when present |
| 12 | Touched-file scope | `git diff --name-only origin/develop..HEAD \| sort` | Only files in the inventory above | Reviewer comparison | Advisory |

---

## Rollback Semantics — Partial-Onboarding Failure Modes

| Failure Mode | What's there | What's missing | Caught by | Merge-blocking? |
|---|---|---|---|---|
| Orphaned patterns file | `<stack>-patterns.md` created | Catalog Routes not added | Check B (forward) | YES |
| Orphaned LANG_RULE | `setup-repos.sh` LANG_RULE references a file | Patterns file not created | Check C (reverse) | YES |
| Patterns file shipped, no `setup-repos.sh` integration | `<stack>-patterns.md` + Catalog Route | LANG_RULE arm not added | Check D | YES |
| Missing template | Stack arm + patterns file present | `templates/CLAUDE.md.<arm>.template` missing | Check D (caught at PR time, not deferred to first runtime use) | YES |
| Cross-switch LANG_RULE disagreement | Two of three LANG_RULE switches updated | Third switch left stale (e.g., refactor partial) | Check E | YES |
| Validation-arm ↔ LANG_RULE mismatch | Stack added to validation arm but not LANG_RULE (or reverse) | The other surface | Check F | YES |
| Doc-side test-reference removed | This doc edited to remove `tests/test_stack_detection.sh` | Reference link to the enforcing test | Check G | YES |
| `setup.sh` manual prompt stale | Stack added to `setup-repos.sh` validation arm + LANG_RULE switches | `setup.sh` `case "$MANUAL_STACK" in` arm and non-interactive error message not updated | Check H | YES |
| Re-introduced enumeration in shared file | Someone re-adds `<X>-patterns.md` to `/tdd`, `/code-review`, or `testing.md` | n/a | Check A | YES |
| Orphaned stack arm | `case "$STACK" in` arm added | LANG_RULE switches not updated | `setup-repos.sh` runtime: empty `LANG_RULE` produces missing `@rules/language-specific/` reference. Reviewer-visible. Plus Check F. | Runtime YES + Check F |
| Orphaned detection block | Manifest detection added | Stack arm not declared | `setup-repos.sh` rejects unknown `--stack` at the validation arm. Plus Check C once the patterns file is added. | YES |
| Missing manifest detection | Stack arm + LANG_RULE + patterns file + template all present | Manifest-detection block at `setup-repos.sh` lines 1027-1107 not extended | None — runtime emits `STACK_DETECTED=[TODO]`, degraded but not breakage | **Known limit** — see "Known limits" below |
| Catalog Route added but no examples | Route line exists in catalog | Section missing in `<stack>-patterns.md` (e.g., Route says `§Foo` but file has `§Bar`) | Reviewer follows the `§<section>` link and finds nothing | **Known limit** — see "Known limits" below |
| Test deleted along with all doc references in the same PR | Both `tests/test_stack_detection.sh` and the doc references in the same commit | n/a (Check G can't run if the test itself is deleted) | None statically; CI integration would catch | **Known limit** — see "Known limits" below |

### Known limits (intentionally not enforced statically)

Three failure modes are documented but not caught by `tests/test_stack_detection.sh` in Phase 1. Reviewers must catch them by eye, or CI integration must close the gap.

- **Manifest-detection block presence (G3).** `setup-repos.sh` lines 1027-1107 detect each stack from its manifest file. A new stack must extend this block. If skipped, runtime produces `STACK_DETECTED=[TODO]` — degraded scan output, not a hard failure. Statically detecting block presence requires bash-block parsing or a runtime fixture; deferred until the failure mode is observed in practice.
- **Stale `§section` references in catalog Routes (G4).** Routes reference specific sections in `<stack>-patterns.md`. If the section name doesn't match, the Route link 404s for the next reader. Statically checking this requires parsing Route lines and verifying `## <section>` headers in the target file; deferred — reviewer eye + the `## ` headings on PR diff are the catch.
- **Simultaneous deletion of test + doc references.** Check G fires when this doc loses its reference to the test. But if a single PR deletes BOTH `tests/test_stack_detection.sh` AND the doc's references to it, the test is no longer running and Check G no longer guards. Mitigation: when CI is wired up, the missing test path itself will fail the pipeline (out of Phase 1 scope). Until then, this is the residual gap.

### Rollback procedure

1. **Detect.** `bash tests/test_stack_detection.sh` exits non-zero.
2. **Identify.** The failing check names the offending stack and file.
3. **Block.** CI fails on the PR. No manual override.
4. **Fix forward or revert.** The maintainer either completes the missing file in the same PR or reverts the partial commit. Partial state in `main` is not allowed.

"Merge half and finish later" is not a supported workflow.

---

## Future-Stack Scaling

### Why shared files stop growing
After Phase 1, `/tdd`, `/code-review`, and `testing.md` contain zero stack enumeration. Adding the 5th, 6th, … 10th stack changes nothing in these files. Their token cost is constant.

### Why catalog growth stays bounded
Each new stack adds at most 4 Route entries (one per applicable P1–P4 pattern), each ~15 tokens, ≈60 tokens per stack.

| Stack count | Catalog overhead from Routes | Total catalog (today: ≈950 tokens) |
|---|---|---|
| 4 (today) | ~240 tokens | ~950 tokens |
| 6 (after Phase 2) | ~360 tokens | ~1070 tokens |
| 10 | ~600 tokens | ~1310 tokens |
| 12 | ~720 tokens | ~1430 tokens (≈95% of cap) |

### Compression triggers

1. **Hard cap.** `ai-regression-patterns.md` is hard-capped at 1500 tokens (existing rule, line 75 of that file). A stack add that would breach the cap is **blocked** until compression is performed.
2. **Soft trigger at 1300 tokens (≈87% of cap).** The next stack add must be paired with a compression pass.

### Compression strategies (when triggered)

- Group Routes by type (Evidence / Persistence-rule / Test-pattern subheadings) and list patterns under each, dropping inline-per-stack repetition.
- Factor common subsection names: declare the convention in the catalog header and drop `§<section>` suffixes from individual Route lines.
- Split into per-tier catalogs (`ai-regression-patterns-backend.md`, `ai-regression-patterns-frontend.md`) — last resort, only at >12 stacks.

### Why new stacks become mostly isolated work

A new stack adds: 1 patterns file, 1 template, optionally 1 hook-pack, ~5 line additions in `setup-repos.sh`, ~3 line additions in `setup.sh` (manual-fallback prompt + non-interactive error), and ~4 catalog Route lines. Zero edits to shared files. Zero edits to skills. That is the scaling property.

---

## Pattern Applicability Matrix (which P1–P4 apply to my stack)

Use this matrix before step 2 to decide which AI-regression patterns the new stack must cover. Definitions live in `@rules/operational/ai-regression-patterns.md`.

| Stack characteristic | Applies | Why |
|---|---|---|
| Backend with DB / persistence layer | **P1**, **P2** | Path divergence (sandbox vs prod) and SELECT/projection drift are the dominant same-model blind spots |
| Sandbox/mock vs production code paths | **P1** | Hardcoded mock branch diverges from the live branch |
| Response-shape changes via ORM/SQL | **P2** | Field added/renamed without matching SELECT |
| Frontend with persistent state (Redux/NgRx/Pinia) | **P3** | Error path doesn't clear prior success state |
| Optimistic UI updates / cache mutations | **P4** | UI mutates before API confirmation; no rollback on failure |
| Pure library / utility code (no I/O, no UI) | none | None of P1–P4 apply; document why in the patterns file header |

Examples: backend (Go, NestJS, Laravel, Django, Rust+Diesel) → P1+P2. Frontend (React, Angular, Vue) → P3+P4 (P1 if mock/fixture toggles exist). Mobile (Swift, Kotlin, Flutter) → P3+P4.

If unsure, list candidate patterns in the tracking issue and flag for review.

---

## Process — Adding a New Stack (ordered)

1. **Plan.** Open an issue describing the stack and the affected services. Use the Pattern Applicability Matrix above to identify which P1–P4 apply.
2. **Patterns file.** Create `rules/language-specific/<stack>-patterns.md` with the §"Isolated Real-Persistence Tests" section covering the applicable P1–P4 patterns.
3. **Catalog routes.** Append Route entries to each applicable P1–P4 in `ai-regression-patterns.md`.
4. **Template.** Create `templates/CLAUDE.md.<stack>.template` from the closest existing template.
5. **Setup integration.** Add the stack to `setup-repos.sh` at all required sites (validation arm, LANG_RULE switches, manifest-detection block) AND to `setup.sh`'s Layer-3 manual-fallback prompt + non-interactive error message (`case "$MANUAL_STACK" in` arm + the `Add one of:` listing). Check H asserts parity between the two surfaces.
6. **Hook-pack.** Add `hook-packs/<stack>/` only if stack-specific pre-push checks are needed.
7. **Service registry.** Update `infrastructure/service-map.md` and `infrastructure/knowledge-base.md` for actual repos.
8. **Proof artifact.** Add `tests/scenario_<stack>_<pattern>/` if the stack contributes AI-regression guidance.
9. **Validate.** Run the validation checklist above.
10. **Touch nothing else.** Especially: do NOT edit `/tdd`, `/code-review`, or `testing.md` for stack-specific reasons.
