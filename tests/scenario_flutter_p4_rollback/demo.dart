#!/usr/bin/env dart
// tests/scenario_flutter_p4_rollback/demo.dart
//
// Demonstrates AI-regression pattern P4 (Optimistic Update Without Rollback)
// for Flutter.
//
// Why this scenario exists
// ------------------------
// Flutter UIs commonly apply an optimistic update — flip a "favorite" toggle,
// change a status, start a cooldown timer — in local BLoC/Cubit state before
// the API confirms. The success path is fully visible; the failure path is
// implicit ("the API will succeed"). When the API fails, the failure branch
// surfaces an error but never restores the pre-optimistic value, so UI and
// server state diverge silently.
//
// Same-model review misses it because the failure path is invisible in the
// diff, and bloc_test suites rarely simulate an API failure *after* the
// optimistic mutation has been applied.
//
// Runs three checks in plain Dart: `dart run demo.dart` — no Flutter, no
// pub get, no test runner. State is modeled as plain classes.
//
// Required output (in order, line-by-line, greppable):
//   OPTIMISTIC UI: PASS (BUG NOT CAUGHT)
//   ROLLBACK TEST: FAIL (BUG CAUGHT)
//   ROLLBACK TEST: PASS (FIX VERIFIED)

import 'dart:io';

// ---------------------------------------------------------------------------
// Domain — a generic immutable copyWith state (the common Flutter pattern)
// ---------------------------------------------------------------------------
class FavoriteState {
  const FavoriteState({
    this.isFavorited = false,
    this.isSaving = false,
    this.errorMessage,
  });

  final bool isFavorited;
  final bool isSaving;
  final String? errorMessage;

  FavoriteState copyWith({bool? isFavorited, bool? isSaving, String? errorMessage}) {
    return FavoriteState(
      isFavorited: isFavorited ?? this.isFavorited,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

typedef FavoriteApi = Future<void> Function();

Future<void> succeedingApi() async {}
Future<void> failingApi() async => throw Exception('network');

// ---------------------------------------------------------------------------
// Buggy controller — optimistically flips the toggle; never rolls back on failure
// ---------------------------------------------------------------------------
class BuggyFavoriteController {
  FavoriteState state = const FavoriteState();

  Future<void> toggleFavorite(FavoriteApi api) async {
    // optimistic: flip the toggle before the server confirms
    state = state.copyWith(isFavorited: !state.isFavorited, isSaving: true);
    try {
      await api();
      state = state.copyWith(isSaving: false);
    } catch (e) {
      // BUG: error surfaced, but `isFavorited` is left flipped — no compensating action.
      state = state.copyWith(isSaving: false, errorMessage: e.toString());
    }
  }
}

// ---------------------------------------------------------------------------
// Fixed controller — the failure path rolls the optimistic flip back
// ---------------------------------------------------------------------------
class FixedFavoriteController {
  FavoriteState state = const FavoriteState();

  Future<void> toggleFavorite(FavoriteApi api) async {
    final previous = state.isFavorited;
    state = state.copyWith(isFavorited: !state.isFavorited, isSaving: true);
    try {
      await api();
      state = state.copyWith(isSaving: false);
    } catch (e) {
      // FIX: compensating action — restore the pre-optimistic value.
      state = state.copyWith(
        isFavorited: previous,
        isSaving: false,
        errorMessage: e.toString(),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 1 — optimistic-UI test (the test suites usually do write)
// API succeeds; assert the toggle flipped. Passes. Bug not caught.
// ---------------------------------------------------------------------------
Future<void> scenarioOptimistic() async {
  final c = BuggyFavoriteController();
  await c.toggleFavorite(succeedingApi);
  if (c.state.isFavorited && c.state.errorMessage == null) {
    print('OPTIMISTIC UI: PASS (BUG NOT CAUGHT)');
  } else {
    print('OPTIMISTIC UI: FAIL — isFavorited=${c.state.isFavorited}');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 2 — real-path test vs buggy (the failure-path suites usually skip)
// API fails after the optimistic flip. Assert the toggle rolled back to false.
// Buggy controller leaves it true. Test fails. Bug caught.
// ---------------------------------------------------------------------------
Future<void> scenarioRealPathBuggy() async {
  final c = BuggyFavoriteController();
  await c.toggleFavorite(failingApi);
  // Expectation: isFavorited rolled back to false. Buggy code leaves it true.
  if (c.state.isFavorited && c.state.errorMessage != null) {
    print('ROLLBACK TEST: FAIL (BUG CAUGHT)');
  } else {
    print('ROLLBACK TEST: PASS — bug NOT caught (this means the demo is broken)');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 3 — real-path test vs fixed
// API still fails. Fixed controller rolls back. Test passes. Fix verified.
// ---------------------------------------------------------------------------
Future<void> scenarioRealPathFixed() async {
  final c = FixedFavoriteController();
  await c.toggleFavorite(failingApi);
  if (!c.state.isFavorited && c.state.errorMessage != null) {
    print('ROLLBACK TEST: PASS (FIX VERIFIED)');
  } else {
    print('ROLLBACK TEST: FAIL after fix — isFavorited=${c.state.isFavorited}');
    exitCode = 1;
  }
}

Future<void> main() async {
  await scenarioOptimistic();
  await scenarioRealPathBuggy();
  await scenarioRealPathFixed();
}
