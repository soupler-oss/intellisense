---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# C / C++ Development Rules

## Naming Conventions

Follow the repository's existing style guide (Google, LLVM or project-specific) and its `.clang-format`; do not mix styles in one file. Without one:
- **Types**: `UpperCamelCase`; **functions and variables**: `snake_case` (C) or `lowerCamelCase` (C++ if the codebase does)
- **Macros and compile-time constants**: `UPPER_SNAKE_CASE`
- One header per module; include guards or `#pragma once`.

## Build

- CMake (or the project's build system) is the source of truth; no hand-edited build artefacts in the repository.
- Builds are warning-clean with `-Wall -Wextra -Werror` (or the project's set); do not lower warnings to land a change.
- Run `clang-format` and `clang-tidy` on changed files before commit.

## Memory and Resource Safety

- C++: **RAII for every resource** — `std::unique_ptr` / `std::shared_ptr`, containers, lock guards. No naked `new`/`delete` in new code.
- C: every allocation has one obvious owner and one free path; check every `malloc` result.
- No raw buffer functions on untrusted input: never `strcpy`, `strcat`, `sprintf`, `gets`. Use bounded versions (`snprintf`, `strncpy` with explicit termination) or `std::string` / `std::span`.
- Bounds-check indexes from input. Prefer `.at()` or explicit checks over `operator[]` on untrusted data.
- Integer overflow on sizes is a security bug: check before multiplying lengths.
- Run tests under AddressSanitizer and UndefinedBehaviorSanitizer in CI.

## Concurrency

- Shared state is protected by a mutex (`std::scoped_lock`) or is `std::atomic`; document which.
- No data races: run ThreadSanitizer on concurrent code.

## Money and Data

- Amounts are integer minor units (`int64_t` cents) or a decimal library — **never `float`/`double`**.
- SQL through prepared statements with bound parameters only.

## Isolated Real-Persistence Tests

For code that reads or writes the database (P1 path divergence, P2 projection omission), test against a real
database instance (a container in CI), not a mocked storage interface:
- **P1:** run the production path; no test-only branch that fabricates the response.
- **P2:** insert a row with every column set to a non-default value and assert each value read back through the
  API — a column list that drops a field then fails.

## Testing

- GoogleTest / Catch2 / the project's framework; a bug fix starts with a failing test.
- Fuzz parsers and decoders (libFuzzer) when they read untrusted input.

## AI-Regression Watchlist

- A cast (`reinterpret_cast`, C-style cast) added to silence a type error.
- `// NOLINT` or a warning pragma added without a reason.
- A bounds or null check removed "because it is never null".
