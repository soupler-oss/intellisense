---
name: verify
description: Use after implementation and before opening a pull request, to run build, tests, lint, security and safety checks and report real output.
---

# /verify — Full Verification Suite

## Purpose
Run comprehensive checks before PR: build → test → lint → security → safety.

## When to Use
- After implementation complete
- Before creating PR (must pass all checks)
- For every commit to feature branch

## Checks (All Must Pass)

### 1. Build Verification
- Go: `go build ./...`
- PHP: `composer install --no-dev --optimize-autoloader` (production); `composer install` (dev)
- Angular: `ng build`

### 2. Test Execution
- Go: `go test ./...`
- PHP: `php artisan test`
- Angular: `ng test`

### 3. Static Analysis
- Go: `go vet ./...`, `golangci-lint`
- PHP: `php -l`, `psalm`, `phpstan`
- Angular: `ng lint`

### 4. Coverage Check
- Default: 80%+ new code coverage
- Financial paths: 95%+ (non-negotiable)
- Reports: coverage per file, per function

### 5. Security Scan
- Secret scanning (no API keys, tokens, passwords)
- Injection vulnerability detection (SQL, XSS)
- Dependency vulnerability check

### 6. Financial Safety (if applicable)
- Transaction idempotency checks
- Balance verification tests
- Concurrent request tests for account operations

### 7. Completeness Check (for "fix / remove / rename / change ALL X" tasks)
**Skip for bounded single-target changes** (one function, one file, clear AC —
there the acceptance criteria ARE the check). Apply when the task is a class:
"fix all", "remove every use of", "rename across the repo", "change this
symbol everywhere it's used".

**Pick the tool by what kind of "all" it is** — only the last row costs agent
tokens; the first two are cheap/free:

| Kind of completeness | Example | Tool |
|---|---|---|
| Text / string / doc | "remove every `OLD_FLAG`", "rename a label" | `grep -rn <pattern>` (free) |
| Code symbol / API / caller | "changed this function/type/contract — who breaks?" | **code-review-graph** who-calls / change-spread (cheap; Go/Python; needs graph built — see `/code-review` §0.5) |
| Behavioral / edge-case | "handle every error path / enum value" | fresh agent review (expensive — gate per the trigger rules) |

Grep finds *text*; it will **miss** a caller that uses a changed symbol via an
interface/wrapper or without the literal name nearby — that's a structural
question, so use the graph there, not grep.

Then, whichever tool:
1. **Build the work-list BEFORE fixing** — run the search/query first; its
   output IS the list (not memory, not a finder-agent's sample).
2. **Re-check AFTER** — re-run; assert **zero** remaining outside an explicit,
   named allowlist (archived docs, intentional examples).
3. **State the boundary** — what was checked, and what was NOT (paths / file
   types / classes / stacks not covered).

> A green build/test/lint does **not** imply completeness — those verify what is
> *present*, not whether instances *outside the diff* were missed. When the
> graph is unavailable (weak stack / not built), fall back to grep + agent.
> "Done" on a class change = the re-check returns zero, not "I fixed the ones I
> noticed."

## Output
```
✅ Build: SUCCESS
✅ Tests: 245 passed, 0 failed
✅ Coverage: 96% (financial paths)
✅ Lint: 0 warnings
✅ Security: No vulnerabilities found
✅ Financial: Idempotency + concurrency tests pass

All checks passed. Ready for PR.
```

## Failure Handling
If any check fails, fix before proceeding to PR. Do NOT force merge.

## Next Step
Run `/code-review` and fix CRITICAL/HIGH issues before PR creation.
