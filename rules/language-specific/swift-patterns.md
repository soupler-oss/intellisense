---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Swift / iOS Development Rules

## Naming Conventions

- **Types and protocols**: `UpperCamelCase` — `LedgerEntry`, `PaymentProviding`
- **Functions, properties, variables, enum cases**: `lowerCamelCase` — `postEntry()`, `.settled`
- Follow the Swift API Design Guidelines: name for clarity at the call site (`move(from:to:)`), Boolean properties read as assertions (`isEmpty`).

## Project Setup

- Swift Package Manager: `Package.resolved` is committed. Verify a worktree with `swift build && swift test` (or `xcodebuild test -scheme …`).
- SwiftLint / SwiftFormat run in CI; do not add `// swiftlint:disable` without a reason.

## Errors and Optionals

- **No force unwrap (`!`) or `try!`** on input, network or decoding results. Use `guard let` / `if let` / `??` and handle the failure.
- Throw typed errors (`enum … : Error`); do not use optionals to hide why something failed.
- `fatalError` only for programmer errors that can never happen at runtime.

## Concurrency

- Prefer Swift concurrency (`async`/`await`, actors) for new code; UI updates on `@MainActor`.
- Mark shared mutable state as an `actor` or protect it; enable strict concurrency checking and fix `Sendable` warnings instead of suppressing them.
- No blocking work on the main thread.

## Money and Data

- Amounts are `Decimal` or integer minor units (`Int64` cents) — **never `Double`/`Float`**. Format with `NumberFormatter` / `.currency` using the right locale.
- Secrets and tokens go in the Keychain, never in `UserDefaults`, plist files or source.
- Validate server data: decode with `Codable` into strict types and treat decoding failures as errors.
- App Transport Security stays on; no `NSAllowsArbitraryLoads`.

## Isolated Real-Persistence Tests

For view models and stores that mutate state around a request (P3 error-state leakage, P4 optimistic update):
- **P3:** load success data, then make the next request fail; assert the error state is shown **and** the stale
  success data is cleared.
- **P4:** apply an optimistic change, make the request fail, and assert the state is rolled back exactly.
Use an injected fake client for the failure, but the real view model and persistence layer.

## Testing

- XCTest / Swift Testing; one behaviour per test. A bug fix starts with a failing test.
- Inject dependencies (protocols) so network and storage can be faked; do not hit the network in unit tests.
- UI tests for critical flows (sign-in, payment) only; keep them few and stable.

## AI-Regression Watchlist

- `!` or `try!` added to make the compiler stop complaining.
- `@unchecked Sendable` or `nonisolated(unsafe)` added to silence concurrency warnings.
- Logging of tokens, personal data or full request bodies.
