## Task Tracking with Beads (when the team chose `tracker: beads`)

The requirement is tracker-neutral: *every Tier 1+ commit traces to a tracked issue, referenced in a commit trailer*
whose key is one of `evidence.task_trailers` in `.intellisense.yml`. GitHub Issues, Jira and Linear work the same way
(`Refs: #123`, `Task: PROJ-12`). This file applies only when the team picked Beads (`intellisense live install
--tracker beads`, or `integrations.tracker: beads`); then the trailer is `Beads: <id>`, and with
`evidence.verify_tasks: true` the gate checks each ID with `bd show`.

### When to open an issue first

Before writing code for any Tier 1+ change, and in particular for:

1. **Cross-repo changes** — rule, skill, agent or template updates that reach several onboarded repos.
2. **Financial and security work** — migrations, payment patterns, PII handling, secret management.
3. **Multi-step dependencies** — one PR must land before another, or work is blocked on another service.

Check for existing work before creating an issue:
```bash
bd ready                          # available work
bd list --status=open             # related open work
bd search "<keywords>"            # similar scope
```
If one exists, claim it (`bd update <id> --claim`) instead of creating a duplicate.

### Tier 0 minimal path

A change is Tier 0 when it is doc-only, test-only, or comment-only (the policy's path rules decide; `intellisense
classify` shows it). Tier 0 needs no issue and skips the deeper review disciplines (predict-before-inspect, risk-pattern
detection, risk-tied evidence, independent review, `[NEEDS-VERIFICATION]`). Standard `/verify` and `/code-review`
still apply.

**Escalation:** if the change touches API response, DB query, auth, financial, sandbox/prod path, migration, or
cross-service contract — STOP and reclassify Tier 1+. **If uncertain, it isn't Tier 0.**

### Issue template

```
Title: Concise summary (what is this change)

## Why
Motivation and context (what problem does this solve, why now)

## Scope
- Affected files: [list with language/service if cross-repo]
- Services/repos impacted: [e.g., "all Go services", "orders-service + billing"]

## Validation
- [ ] All affected services identified (cross-repo only)
- [ ] Compliance/financial impact assessed
- [ ] Backward compatibility checked (breaking changes documented)
- [ ] Rollout plan (cross-repo: validation gates before merge)

## Cross-Repo Impact (multi-service only)
- Services that must validate, rollout order, rollback steps
- Risk level: low|medium|high [justified]
```

### Lifecycle

```bash
bd create --title="..." --description="..." --type=task|feature|bug --priority=2
bd update <id> --claim                                   # when you start
bd update <id> --notes="Planning done, implementing"     # meaningful milestones only
bd close <id>                                            # when complete
```

Each Tier 1+ commit carries `Beads: <id>`; put the same line in the PR description for traceability.

### What enforces it

- **`intellisense gate`** (pre-push hook and CI) blocks a Tier 1+ commit without a task trailer. It does not require
  Beads: any key in `evidence.task_trailers` counts.
- **`verify-setup.sh`** checks for `bd` and `.beads/` only when the tracker is `beads`.
- **`setup.sh` / `setup-repos.sh`** install and initialise Beads only when it was chosen.
