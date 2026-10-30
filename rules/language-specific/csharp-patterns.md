---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# C# / .NET Development Rules

## Naming Conventions

- **Types, methods, properties, public fields, constants**: `PascalCase` — `LedgerService`, `PostEntryAsync`, `MaxRetries`
- **Parameters and locals**: `camelCase` — `accountId`
- **Private fields**: `_camelCase` — `_repository`
- **Interfaces**: `I` prefix — `IPaymentGateway`
- **Async methods**: `Async` suffix — `GetBalanceAsync`

## Project Setup

- Nullable reference types are on (`<Nullable>enable</Nullable>`); warnings are errors in CI (`<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`).
- Restore with lock files (`<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>`, `dotnet restore --locked-mode`).
- Verify a worktree with `dotnet build --no-restore && dotnet test --no-build`.

## Errors

- Throw specific exceptions; never `catch (Exception)` and swallow it. Catch at the boundary (controller, message handler) and map to a response.
- Do not use exceptions for expected outcomes (not found, validation); return a result type or `null` with nullable annotations.
- Preserve the stack: `throw;`, never `throw ex;`.

## Async

- Async all the way: **never `.Result`, `.Wait()` or `GetAwaiter().GetResult()`** on a task in request code (deadlocks and thread-pool starvation).
- Pass `CancellationToken` through every async call that accepts one.
- No `async void` except event handlers.

## Money and Data

- Amounts are `decimal` or integer minor units (`long` cents) — **never `double`/`float`**.
- Entity Framework: a read-then-update of a balance runs in one transaction with a lock (`FromSqlInterpolated("SELECT … FOR UPDATE")` or a concurrency token / `rowversion`) — not two separate `SaveChanges` calls.
- Use parameters (`FromSqlInterpolated`, Dapper parameters); never concatenate input into SQL.
- Migrations are reviewed SQL: check the generated script (`dotnet ef migrations script`) before merge.

## Dependency Injection

- Constructor injection; no service locator (`IServiceProvider.GetService` in business code).
- Do not inject a scoped service (e.g. `DbContext`) into a singleton.

## Isolated Real-Persistence Tests

For endpoints that read or write the database (P1 path divergence, P2 projection omission), test against a real
database (Testcontainers), not the EF in-memory provider:
- **P1:** exercise the production path; do not let an environment check return a hand-built response in tests.
- **P2:** seed an entity with non-default values for every field, call the endpoint, and assert each value — a
  `Select` projection that drops a property then fails instead of serialising a default.

## Testing

- xUnit/NUnit; one behaviour per test; name tests `Method_State_ExpectedResult`.
- Integration tests against a real database container (Testcontainers), not the EF in-memory provider, for anything with transactions or locks.

## AI-Regression Watchlist

- `!` (null-forgiving operator) added to silence a nullable warning.
- `#pragma warning disable` without a reason.
- `.Result` introduced to call async code from sync code.
