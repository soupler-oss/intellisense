---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Ruby / Rails Development Rules

## Naming Conventions

- **Classes and modules**: `CamelCase` — `LedgerEntry`, `Payments::Refund`
- **Methods and variables**: `snake_case` — `post_entry`, `retry_count`
- **Constants**: `SCREAMING_SNAKE_CASE`
- **Predicates** end in `?` (`settled?`); **dangerous / mutating** variants end in `!` (`save!`)
- File names match the constant they define (`app/services/payments/refund.rb` → `Payments::Refund`), so Zeitwerk can load them.

## Project Setup

- `Gemfile.lock` is committed. Verify a worktree with `bundle install && bundle exec rspec` (or `bin/rails test`).
- `bundle exec rubocop` passes before commit; do not add a `rubocop:disable` without a reason comment.

## Errors

- Rescue specific errors; **never `rescue Exception`** (it catches `SignalException` and `NoMemoryError`). A bare `rescue => e` must re-raise or report.
- Use bang methods (`save!`, `update!`, `create!`) inside transactions so a failure rolls back instead of returning `false` unnoticed.

## Rails

- Business logic lives in models or service objects, not controllers or views.
- Strong parameters for every mass assignment; never `permit!`.
- Avoid N+1: `includes`/`preload` for associations used in a loop (check with `bullet` in development).
- Callbacks (`after_save` …) only for persistence concerns; side effects (emails, payments, HTTP) go in jobs or services.

## Money and Data

- Amounts are integer cents (`money-rails` / `Money` objects) or `BigDecimal` — **never `Float`**.
- A read-then-update of a balance runs in `transaction` with `lock!` / `with_lock` (`SELECT … FOR UPDATE`).
- Idempotency for anything that charges or pays out: a unique key enforced by a database index, not just a Ruby check.
- Never interpolate input into SQL: `where("x = ?", v)` or hash conditions, never `where("x = #{v}")`.
- Migrations are reversible (`change` or `up`/`down`); large-table changes use `algorithm: :concurrently` and are split from code deploys.

## Isolated Real-Persistence Tests

Request specs that hit the real database (P1 path divergence, P2 projection omission), not stubbed models:
- **P1:** exercise the production branch; no `Rails.env.test?` shortcuts that build responses by hand.
- **P2:** create a record with every attribute set (factory with explicit values), request the endpoint, and assert
  each value — a `select(...)` that omits a column then fails instead of returning `nil`.

## Testing

- RSpec or Minitest; factories (`factory_bot`) over fixtures for new code.
- Request specs for endpoints; a bug fix starts with a failing spec.
- Do not stub the object under test.

## AI-Regression Watchlist

- `rescue nil` or `rescue => e; nil` hiding an error.
- `skip_before_action :authenticate_user!` or `protect_from_forgery except:` added without review.
- `update_column` / `update_all` used to bypass validations.
