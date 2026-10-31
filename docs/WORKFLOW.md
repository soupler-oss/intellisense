# Development Workflow (10 Steps)

The default path from a requirement to a merged pull request, using intellisense's Claude Code slash commands. All of
them come with [Live mode](live-mode.md); `/plan`, `/tdd`, `/verify`, `/diagnose` and `/incident` are also available
in Core mode (`skills:` in `.intellisense.yml`).

The example throughout: *"add CSV export to the monthly report"*.

---

## Step 1 — Intake (always first)

**Where:** any directory · **Time:** 2–3 minutes · **Command:** `/where-to-start`

```
/where-to-start add CSV export to the monthly report
```

Ranks the repositories that most likely own the change, with reasons, from your organization's service map
(`infrastructure/service-map.md`). If you guessed the wrong repository, this corrects it.

---

## Step 2 — Discovery (if several repositories are involved)

**Where:** any directory · **Time:** 2–3 minutes · **Command:** `/multi-service-plan`

```
/multi-service-plan add CSV export to the monthly report
```

Lists what changes in each repository, the order to deploy them in, and where they connect. Confirm the scope before
planning.

---

## Step 3 — Planning

**Where:** the repository from Step 1 · **Time:** 5–10 minutes · **Command:** `/plan` (one repository) or
`/multi-service-plan` (several)

```
/plan add CSV export to the monthly report
```

Lists the files affected, the test strategy, the risks and the success criteria. If the change is Tier 1 or 2,
`/contract` records the change contract the push gate will ask for.

---

## Step 4 — Checks before changing shared things (only when they apply)

**Time:** 5–10 minutes

| You are changing | Check by hand first |
|---|---|
| An API other services call | The consumers listed in each repository's `CLAUDE.md` API contracts section: will they still work? |
| A database table other services read | The consumers in `infrastructure/service-map.md`: does the change break their queries? |
| A shared library or component | Build each consumer listed in the service map against the change. |

Fix or escalate any incompatibility before implementing.

---

## Step 5 — Implementation (test first)

**Where:** the repository · **Time:** 20–40 minutes · **Command:** `/tdd`

1. **Red:** write a failing test for the new behaviour.
2. **Green:** write the least code that passes it.
3. **Improve:** refactor while the tests stay green.

---

## Step 6 — Other repositories (if several are involved)

Repeat Step 5 in each repository from the plan, keeping the contracts between them compatible.

---

## Step 7 — Verification

**Time:** 5–10 minutes · **Commands:** `/verify`, then `/code-review`

`/verify` runs build → tests → lint → security → coverage. Fix failures and run it again.

`/code-review` reports issues as CRITICAL, HIGH, MEDIUM or LOW. Fix every CRITICAL one; fix HIGH ones before the pull
request.

---

## Step 8 — Cross-repository check (several repositories only)

Run Step 7 in every affected repository, and confirm the deployment order from Step 2 still holds.

---

## Step 9 — Knowledge capture

**Time:** 3–5 minutes · **Command:** `/learn`

Extracts patterns and decisions from the session and suggests where to keep each one: a rule (the repository's
`CLAUDE.md` or `.intellisense/rules/organization/`), or `bd remember` when the team uses Beads.

---

## Step 10 — Commit and pull request

```bash
git switch -c feat/csv-export
git add -A
git commit -m "feat(reports): add CSV export to the monthly report" \
  -m "Refs: #142" \
  -m "Change Contract: scope=monthly report CSV export, risk=low"
git push -u origin feat/csv-export
```

The task reference (`Refs: #142`) and the change contract are what the push gate checks for a Tier 1 or 2 change; use
your tracker's trailer (`Jira: PROJ-142`, `Linear: ENG-142`, `Beads: bd-142`).

A good pull request description says **what** changed, **why**, **how it was tested**, the **impact on other
repositories**, the **deployment order** and the **rollback plan**.

---

## Production incident

Use `/incident` instead of steps 1–10. It runs a shortened path — diagnose, a minimal fix with a rollback plan,
expedited review — and ends with a follow-up ticket to complete the skipped steps within 48 hours.

---

## When stuck

| Problem | Command |
|---|---|
| A test fails and you don't know why | `/diagnose` |
| Not sure which other services a change affects | `/multi-service-plan` (its first step reads the service map) |
| Not sure which repository owns something | `/where-to-start` |

---

## Checklist

- [ ] 1 `/where-to-start` — the right repository
- [ ] 2 `/multi-service-plan` — if several repositories
- [ ] 3 `/plan` — the requirement understood; `/contract` if Tier 1+
- [ ] 4 Shared API, table or library checked — if any
- [ ] 5 `/tdd` — red, green, improve
- [ ] 6 Repeated per repository — if several
- [ ] 7 `/verify` and `/code-review` pass
- [ ] 8 Every affected repository verified — if several
- [ ] 9 `/learn`
- [ ] 10 Commit with a task reference and contract; complete pull request description
