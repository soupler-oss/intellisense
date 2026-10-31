# Quick start — your first change with intellisense

**Time:** 10 minutes · **Goal:** set up a repository, make one ordinary change and one risky change, and see what
intellisense does with each.

## 1. Install

```bash
brew install soupler-oss/tap/intellisense     # or: curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh | sh
intellisense version
```

> Windows: `scoop bucket add soupler https://github.com/soupler-oss/scoop-bucket && scoop install intellisense` (Core
> mode; Live mode needs WSL). With Go: `go install github.com/soupler-oss/intellisense/cmd/intellisense@latest`.

## 2. Set up a repository (Core mode)

```bash
cd your-repo
intellisense init           # asks: languages, AI assistants, ticket system, CI check
```

It writes `.intellisense.yml` (your rules), `.intellisense/rules/`, an instruction file for each assistant you chose,
a pre-push hook, and — if you said yes — `.github/workflows/intellisense.yml`. Commit it. Adding intellisense is itself
a high-risk change, so the commit already shows the format:

```bash
git add -A
git commit -m "chore: adopt intellisense" \
  -m "Refs: #1" \
  -m "Change Contract: scope=adopt intellisense, risk=low"
git push
```

## 3. An ordinary change: fix a typo in the docs

Edit `README.md`, then:

```console
$ intellisense classify
Tier 0 — routine (docs, tests, comments)
  Tier 0  README.md                                        safe      documentation
```

Commit with any message and push. Nothing extra is needed.

## 4. A standard change: add a feature

Ask your assistant to add CSV export to a report, in `reports/export.go`:

```console
$ intellisense classify
Tier 1 — standard
  Tier 1  reports/export.go                                default   no rule matched
requires: task + contract
```

Push without a ticket and the hook stops you, saying exactly what to add. Commit with the ticket and a one-line
change note instead:

```bash
git commit -m "feat(reports): add CSV export" \
  -m "Refs: #142" \
  -m "Change Contract: scope=CSV export for reports, risk=low"
git push                                       # PASSED
```

## 5. A high-risk change: touch payments

Any file under a `payments/`, `billing/`, `auth/`, `migrations/` or `secrets/` folder is Tier 2:

```console
$ intellisense classify payments/refund.go
Tier 2 — high risk
  Tier 2  payments/refund.go                               tier2     financial
requires: task + contract
```

Same evidence as before, and in the change note say honestly how risky it is (`risk=high`). On the pull request,
the **Intellisense Gate** check runs the same rules, so the reviewer sees the ticket, the scope and the stated risk.

## 6. Make your own rules

- Mark your own risky folders, add a stricter tier, require tests: [docs/customization.md](docs/customization.md).
- Write a rule every assistant follows: put it in `.intellisense/rules/organization/` and run `intellisense sync`.
- Connect GitHub Issues, Jira, Linear or Beads: [docs/integrations.md](docs/integrations.md).

---

## Using Claude Code? Add Live mode

```bash
intellisense live install          # once per computer; asks for a ticket system and code intelligence (both may be none)
intellisense live status
```

Then, in a repository set up as above, start Claude Code and try a first task with the slash commands:

```
/plan add CSV export to the monthly report     # files affected, tests, risks, success criteria
/contract                                      # records the change note the gate will ask for
/tdd                                           # red → green → improve
/verify                                        # build, tests, lint, security
/code-review                                   # issues by severity
```

While you work, Live mode sorts each request by risk, and stops Claude editing a standard or high-risk file until
the change note is approved — so missing evidence is caught before the code is written, not at push time.

The full path from requirement to pull request, including changes across several repositories, is in
[docs/WORKFLOW.md](docs/WORKFLOW.md). Everything Live mode installs is in [docs/live-mode.md](docs/live-mode.md).

## Contributing to intellisense itself

To run Live mode from a git checkout instead of the binary: `bash setup.sh` (it takes `--tracker` and
`--code-intel`, both defaulting to `none`). See [CONTRIBUTING.md](CONTRIBUTING.md).
