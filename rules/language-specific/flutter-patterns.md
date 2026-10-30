---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Flutter / Dart Development Rules

Covers Flutter mobile (iOS + Android, shared `lib/`), Flutter Web (same `lib/` + `web/` shell), and Dart 3+ with sound null-safety required. **Repo-convention-first:** match the repo's established state-management library (Riverpod, BLoC/flutter_bloc, Provider, GetX, Redux, or `setState`-only) — never force a migration. The patterns below apply across all of them.

---

## Naming Conventions

- **Files**: `lowercase_with_underscores.dart` — never camelCase/PascalCase.
- **Tests**: `*_test.dart`, colocated under `test/` mirroring `lib/`.
- **Generated**: `*.g.dart` (json_serializable/drift), `*.freezed.dart` (freezed) — never hand-edit.
- **Types / Widgets**: `PascalCase` (`OrderCard`, `OrderState`). **Functions / vars / params**: `camelCase`.
- **Constants**: `lowerCamelCase` top-level `const` (`defaultPageSize`, not `DEFAULT_PAGE_SIZE`).
- **Booleans**: `isLoading`, `hasError`, `shouldRefetch`. **Private**: underscore prefix (`_handleTap`).

---

## Project Layout

Match the repo's convention; mixing layouts within one repo is the anti-pattern.

| Feature-first (preferred for >5 features) | Layer-first (smaller apps) |
|---|---|
| `lib/features/<feature>/{data,domain,presentation}` | `lib/{widgets,services,models,screens}/` |
| `lib/shared/` cross-feature widgets + utils | `lib/shared/` cross-feature utils |
| `lib/main.dart` + `lib/app.dart` (root + MaterialApp) | Same |

---

## Widget Boundaries

- **Presentational** — props-only (`final` fields), no fetching, no global-state reads. Use `const` constructors when possible (enables widget-tree caching).
- **Container** — read providers/blocs, pass plain data down to presentational children.
- Prefer `StatelessWidget` + a state-mgmt lib over `StatefulWidget` for anything beyond purely-local UI state (animation/text controllers, focus nodes).

---

## Side Effects: `mounted`, `dispose`, async gaps

After every `await` in a `State`, check `mounted` before `setState`/`context` use — the widget may have unmounted while the future was pending (lint: `use_build_context_synchronously`). Always release subscriptions, controllers, and timers in `dispose`.

```dart
Future<void> _load() async {
  final data = await api.fetchOrders();
  if (!mounted) return;                 // critical after every await
  setState(() => _orders = data);
}

@override
void dispose() {
  _scrollController.dispose();
  _streamSub?.cancel();
  _debounceTimer?.cancel();
  super.dispose();
}
```

---

## Async State (loading / error / data)

Three explicit states; never represent loading via `data == null` ambiguity. Riverpod's `AsyncValue<T>` and BLoC sealed states do this already; for `setState`-only code, model it and render via a `switch` expression so the analyzer enforces exhaustive handling.

```dart
sealed class AsyncState<T> { const AsyncState(); }
class Idle<T>    extends AsyncState<T> { const Idle(); }
class Loading<T> extends AsyncState<T> { const Loading(); }
class Success<T> extends AsyncState<T> { const Success(this.data);  final T data; }
class Failure<T> extends AsyncState<T> { const Failure(this.error); final Object error; }
```

---

## PII in Logs / Telemetry

- Never send full user objects to Crashlytics / Firebase Analytics / Sentry breadcrumbs.
- Strip emails, phone numbers, tracking number numbers, and payment tokens from error reports.
- Mask `debugPrint` output in production — guard with `kReleaseMode` or a logger wrapper.
- `toString()` defaults to all fields; override it on any class holding PII.

---

## Isolated Real-Persistence Tests (P3 / P4)

Flutter routes to **P3** and **P4** (`@rules/operational/ai-regression-patterns.md`). P1 may apply if the app has mock/fixture-mode toggles; P2 is N/A (no client DB projection layer). Assert state *shape* after the failure transition. Use `flutter_test` + `mocktail`/`mockito`.

**P3 — Error State Leakage:** a fetch fails after a partial/loaded state existed; the error path doesn't reset it, so the widget shows an error banner *and* the stale list. The weak test asserts only the banner and misses the leak.

```dart
// after a refresh that throws post-load:
expect(find.byType(ErrorBanner), findsOneWidget);   // error visible
expect(find.byType(OrderRow), findsNothing);         // CRITICAL: stale list cleared
```

**P4 — Optimistic Update Without Rollback:** favorite/like/add-to-cart applies locally before the API confirms; on failure no compensating action restores prior state, so UI and server diverge silently.

```dart
// favorite() stubbed to throw:
await tester.tap(find.byIcon(Icons.favorite_border));
await tester.pump();                                          // mid-flight optimistic ON
expect(find.byIcon(Icons.favorite), findsOneWidget);
await tester.pumpAndSettle();                                 // failure resolves
expect(find.byIcon(Icons.favorite_border), findsOneWidget);   // CRITICAL: rolled back
```

Runnable, dependency-free demos: `tests/scenario_flutter_p3_error_leakage/demo.dart`, `tests/scenario_flutter_p4_rollback/demo.dart` — each shows the weak (happy-path) test passing while the real-path test catches the bug.

---

## Common Anti-Patterns

- **`setState` inside `build`** — infinite rebuild loop; mutate in handlers or `initState`.
- **Missing `dispose`** — `TextEditingController` / `AnimationController` / `ScrollController` / `StreamSubscription` leak.
- **`BuildContext` across async gaps** — use a `mounted` check.
- **Blocking I/O on the main isolate** — parsing >16ms causes jank; use `compute()` or an isolate.
- **Non-`const` constructors where possible** — defeats widget caching; run `flutter analyze --fatal-infos` for `prefer_const_constructors`.
- **Swallowing caught `Exception`** — surface via a Failure state; log with stack trace.
- **`Provider.of<T>(listen:true)` in `build` for read-only** — use `context.read<T>()` vs `context.watch<T>()` deliberately.
- **Generated-file edits** — re-run `dart run build_runner build --delete-conflicting-outputs`, never hand-edit.
- **Missing `Key` on reorderable/insertable list items** — Flutter rebuilds wrong elements and loses state.
- **`print()` in committed code** — use `debugPrint` / `dart:developer log` / repo logger (`avoid_print`).
- **Stale `TODO`/`FIXME` without a ticket** — require `// TODO(JIRA-123):` so it's traceable.

---

## Resolving Analyzer Errors

Fix `dart/flutter analyze` errors **one at a time**, smallest surgery first; re-run after each to confirm the count dropped with no new error.

- **Never suppress without justification.** `// ignore:` / `// ignore_for_file:` are last resorts and must state *why* on the same line (e.g. `// ignore: invalid_use_of_protected_member — SDK gap, dart-lang/sdk#NNNNN`).
- **Generated-code errors → regenerate**, don't patch — they mean the source annotation changed.
- **`--fatal-infos` in CI, advisory locally.** Treat infos/warnings as real; don't let them mask the next error.

---

## Test Strategy

- **Coverage priority:** domain (use-cases, pure logic) → presentation (BLoC/Notifier transitions) → data (repos, mappers). Domain is cheapest and catches the most logic bugs.
- **Tooling:** `flutter_test` (widget), `bloc_test` (state sequences), `mocktail`/`mockito` (stubs), `integration_test/` (cross-stack platform-channel round-trips).
- **Assert values, not just keys/widgets.** `expect(state.total, 4200)` beats `expect(state, isA<Loaded>())`.
- **One behavior per test.** Name for the outcome (`reverts favorite when API fails`), not the method.

---

## Native Platform Folders (`ios/`, `android/`)

**Risk-escalation areas:** `flutter test` can't exercise them, CI for *both* platforms must pass, signing/provisioning/store-listing live here, and diffs are reviewed by people who may not know Swift/Kotlin. Only `flutter build` + device validation catches errors.

| File | Edited when | What to verify |
|---|---|---|
| `ios/Runner/Info.plist` | New capability, URL scheme, permission | `NS*UsageDescription` keys match runtime calls + App Store metadata |
| `ios/Runner/AppDelegate.swift` | Plugin reg, deep-link, lifecycle | `super` chain preserved; `GeneratedPluginRegistrant.register` once; callbacks on main thread |
| `ios/Runner.entitlements` | Push, app groups, associated domains | Entries match Apple Developer-portal capability state |
| `ios/Podfile` | New native dependency | `platform :ios, 'X.Y'` matches Xcode target; `pod install --repo-update`; commit `Podfile.lock` |
| `android/.../AndroidManifest.xml` | New permission, intent filter, deep link | `<uses-permission>` matches runtime; `android:exported` explicit (API 31+) |
| `android/app/build.gradle` | minSdk/targetSdk, signing, ProGuard | `minSdkVersion >= 21`; signing via env/gitignored `key.properties`, never committed secrets |
| `android/.../MainActivity.kt` | Custom `MethodChannel`, lifecycle | Channel name matches Dart **exactly**; results on `Handler(Looper.getMainLooper())` |
| `android/build.gradle` | AGP / Kotlin / Gradle bumps | All three move together; CI JDK matches; `org.gradle.jvmargs` ≥ `-Xmx2048m` |

### Native anti-patterns

- Permission used at runtime without `<uses-permission>` — silently denied.
- iOS capability without matching `.entitlements` + Developer-portal enable — App Store rejection.
- `MethodChannel` name mismatch (Dart vs Swift/Kotlin) — "works" but never delivers; no compile-time check.
- Returning from a `MethodChannel` handler off the main thread — UI updates race/crash.
- Hand-editing `Podfile.lock` / `gradle.lockfile` / `project.pbxproj` — let the tool regenerate; use Xcode UI for the project file.
- Committing `GoogleService-Info.plist` / `google-services.json` with production keys to a shared repo — secret leak.
- Bumping AGP without Kotlin / Gradle wrapper — the most common "works on my machine" CI failure.

### Testing native code

- Swift unit tests → `ios/RunnerTests/` (XCTest, via Xcode or `xcodebuild test`). Kotlin → `android/app/src/test/` (JUnit, `./gradlew test`).
- Platform-channel round-trip → `integration_test/` (Dart, on device/emulator) — the cross-stack contract.
- **CI matrix** must include `flutter build apk --release` and `flutter build ios --release --no-codesign` to catch native config drift.
- Optional pre-commit: `hook-packs/flutter/flutter-native-format.sh` lints staged Swift/Kotlin when `swiftformat`/`swift-format`/`ktlint` are on PATH, else skips silently.

---

## Cross-references

- AI-regression pattern routing: `@rules/operational/ai-regression-patterns.md`
- Generic testing rules: `@rules/operational/testing.md`
- Onboarding workflow: `docs/language-support-onboarding.md`
