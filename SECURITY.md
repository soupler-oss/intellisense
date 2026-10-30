# Security Policy

## Supported versions

Only the latest release on `main` is supported.

## Reporting a vulnerability

**Do not open a public issue.** Report privately through GitHub:
<https://github.com/soupler-oss/intellisense/security/advisories/new>

Include what is affected, how to reproduce it, and the impact. You will get an acknowledgement, and a fix or an explanation, as soon as the maintainer can; please allow reasonable time before public disclosure.

## What counts

intellisense is a governance gate: it decides whether a push or pull request carries the evidence its risk tier needs, it writes agent instructions and git hooks into repositories, and in Live mode it edits `~/.claude/settings.json` and runs hooks inside every coding session. The interesting classes are:

- **Gate bypass** — any change that should classify as Tier 1 or Tier 2 but passes as Tier 0, or a Tier 1/2 change that passes without its evidence (path tricks, renames, comment-only disguises, policy-file edits that are not themselves gated).
- **Writing outside the target** — path traversal, or overwriting files outside the repository or outside the managed blocks `intellisense sync` owns.
- **Command injection** through policy values, branch names, file names or commit messages.
- **Telemetry leaks** — prompt text, file contents or local paths reaching heartbeat or commit metadata (the heartbeat contract allows counts only; see [docs/telemetry-contract.md](docs/telemetry-contract.md)).
- **CI exposure** — the GitHub Action leaking secrets or running untrusted pull request code with a write token.
