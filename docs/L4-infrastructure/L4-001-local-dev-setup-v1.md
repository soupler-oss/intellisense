# L4-001 · Local Development Setup & Smoke Runbook

---
| Field | Value |
|---|---|
| Document ID | L4-001-local-dev-setup-v1 |
| Layer | L4 — Infrastructure & Deployment |
| Status | Final |
| Version | v1 |
| Created | 2026-10-30 |
| Last Updated | 2026-10-30 |
| Owner | Soupler |
| Reviewers | Soupler |
| Copyright | © 2026 Soupler. All rights reserved. |
| License | Apache-2.0 |
---

## Purpose

How to build and test intellisense locally and prove it works. Update whenever prerequisites, bootstrap, smoke
commands or troubleshooting change (L0-006 §3.4).

## 1 · Prerequisites
- Go (current stable; `go.mod` sets the minimum, 1.22), git, bash, jq, python3
- `shellcheck` and `gitleaks` (`brew install shellcheck gitleaks`)
- Optional, for the tests that need them: `bd` (Beads) and `code-review-graph` — `bash scripts/ci/install-test-deps.sh`

## 2 · Bootstrap
```bash
bash bin/install-hooks.sh          # commit-msg, pre-commit (gitleaks) and pre-push (this repo's own gate)
go build ./cmd/intellisense
```

## 3 · Smoke
```bash
bash scripts/ci/lint.sh            # gofmt, go vet, bash -n, JSON, shellcheck
bash scripts/ci/test.sh            # Go and Bash suites, as CI runs them (about 3 minutes)
bash bin/statutory-integrity.sh    # the docs gate
go run ./cmd/intellisense classify # the tier of your change
```

## 4 · Known local limitations
- Tests that need `bd` or `code-review-graph` skip locally unless installed; CI installs both and
  sets `INTELLISENSE_REQUIRE_OPTIONAL_TOOLS=1` so they cannot skip there.
- Machine-level tests (they change `~/.claude`) run only with `--all`, on a disposable machine.
- Windows is verified only in CI (`Go (windows-latest)`).
- Run the suite with stdin closed (`</dev/null`) when scripting it: some stubs read stdin when it is not a terminal.

## Version history

| Version | Date | Author | Summary of changes |
|---|---|---|---|
| v1 | 2026-10-30 | Soupler | Local setup and smoke for the Go CLI and Live mode |
