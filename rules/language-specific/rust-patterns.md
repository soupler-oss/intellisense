---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Rust Development Rules

## Naming Conventions

- **Types, traits, enum variants**: `UpperCamelCase` — `LedgerEntry`, `PaymentState::Settled`
- **Functions, methods, variables, modules**: `snake_case` — `post_entry`, `retry_count`
- **Constants and statics**: `SCREAMING_SNAKE_CASE` — `MAX_RETRIES`
- **Lifetimes**: short, lowercase — `'a`, `'conn`
- **Conversions**: `as_` (cheap borrow), `to_` (expensive clone), `into_` (consumes self)

## Project Setup

- `Cargo.lock` is committed for binaries and services; libraries follow the workspace policy.
- Verify a worktree with `cargo build --locked && cargo test --locked`. `--locked` fails instead of silently updating dependencies.
- `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` must pass before commit.

## Errors

- Libraries return typed errors (`thiserror`); binaries may use `anyhow` at the edge. Never return `Box<dyn Error>` from a public library API.
- **No `unwrap()` / `expect()` on input, I/O, parsing or network results** in non-test code. `expect("invariant: …")` is allowed only for a true invariant, with the invariant stated.
- Propagate with `?` and add context (`.with_context(|| format!("loading {path}"))`); do not log and re-return the same error.
- `panic!` is for bugs, not for bad input.

## Ownership and Safety

- Prefer borrowing (`&str`, `&[T]`) in parameters; clone only where the reason is obvious.
- **`unsafe` needs a `// SAFETY:` comment** naming the invariant that makes it sound, and a test that exercises it. New `unsafe` in a change is a review flag.
- Async: never hold a `std::sync::Mutex` guard across `.await`; use `tokio::sync::Mutex` or restructure. Never block (`std::thread::sleep`, sync I/O) inside an async task.

## Money and Data

- Amounts are integers in the smallest currency unit (`i64` cents) or a decimal type (`rust_decimal`) — **never `f32`/`f64`**.
- Check arithmetic on money: `checked_add` / `checked_sub` and handle `None`; release builds wrap silently on overflow.
- Database writes that read-then-update a balance run in one transaction with a row lock (`SELECT … FOR UPDATE` via `sqlx`/`diesel`).
- Use the query builder's bind parameters; never `format!` user input into SQL.

## Isolated Real-Persistence Tests

For handlers that read or write the database (P1 path divergence, P2 projection omission), test against a real
database (a container via `testcontainers`, or a per-test schema), not a mocked repository:
- **P1:** call the production code path, not a `cfg(test)` or feature-flag branch that builds the response by hand.
- **P2:** insert a row with every field set to a non-default value, call the endpoint, and assert each value — a
  query that forgets a column then fails instead of returning `None`/default.

## Testing

- Unit tests in a `#[cfg(test)] mod tests` beside the code; integration tests in `tests/`.
- A bug fix starts with a failing test that reproduces it.
- Property tests (`proptest`) for parsers, encoders and arithmetic on money.

## AI-Regression Watchlist

- `.unwrap()` added to make a compile error go away.
- `.clone()` sprinkled to satisfy the borrow checker instead of fixing the ownership.
- `#[allow(...)]` added to silence a clippy lint without a reason comment.
