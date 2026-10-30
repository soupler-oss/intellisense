#!/usr/bin/env dart
// tests/scenario_flutter_p3_error_leakage/demo.dart
//
// Demonstrates AI-regression pattern P3 (Error State Leakage) for Flutter.
//
// Why this scenario exists
// ------------------------
// Flutter BLoC/Cubit code commonly models state as an immutable class with a
// copyWith method and nullable data fields. The standard transitions are:
//   load success -> emit(state.copyWith(isLoading: false, items: data))
//   load failure -> emit(state.copyWith(isLoading: false, errorMessage: e))
// On the failure path the previously-loaded `items` list is not passed, so
// copyWith's retain-by-default keeps it. The UI then renders an error banner
// AND the stale list at the same time.
//
// Same-model review misses it: the happy path and the single-error path both
// look correct in the diff; nobody asks "what success state is still set
// after the error fires?" Typical bloc_test suites cover load-success and
// load-failure but not the load-success -> refresh-fail transition where the
// leak appears.
//
// Runs three checks in plain Dart: `dart run demo.dart` — no Flutter, no
// pub get, no test runner. State is modeled as plain classes.
//
// Required output (in order, line-by-line, greppable):
//   HAPPY-PATH TEST: PASS (BUG NOT CAUGHT)
//   ERROR-CLEAR TEST: FAIL (BUG CAUGHT)
//   ERROR-CLEAR TEST: PASS (FIX VERIFIED)

import 'dart:io';

// ---------------------------------------------------------------------------
// Domain — a generic immutable copyWith state (the common Flutter pattern)
// ---------------------------------------------------------------------------
class Item {
  const Item(this.id);
  final String id;
}

class ListState {
  const ListState({
    this.isLoading = false,
    this.items = const <Item>[],
    this.errorMessage,
  });

  final bool isLoading;
  final List<Item> items;
  final String? errorMessage;

  // Retain-by-default copyWith: a field not passed keeps its prior value.
  // That convenience is exactly what lets a stale list survive an error.
  ListState copyWith({bool? isLoading, List<Item>? items, String? errorMessage}) {
    return ListState(
      isLoading: isLoading ?? this.isLoading,
      items: items ?? this.items,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

typedef ListApi = Future<List<Item>> Function();

Future<List<Item>> succeedingApi() async => const [Item('item-1'), Item('item-2')];
Future<List<Item>> failingApi() async => throw Exception('network');

// ---------------------------------------------------------------------------
// Buggy controller — the error path never clears `items`
// ---------------------------------------------------------------------------
class BuggyListController {
  ListState state = const ListState();

  Future<void> load(ListApi api) async {
    state = state.copyWith(isLoading: true);
    try {
      final items = await api();
      state = state.copyWith(isLoading: false, items: items);
    } catch (e) {
      // BUG: `items` not passed -> copyWith retains the previously loaded list.
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }
}

// ---------------------------------------------------------------------------
// Fixed controller — the error path explicitly clears `items`
// ---------------------------------------------------------------------------
class FixedListController {
  ListState state = const ListState();

  Future<void> load(ListApi api) async {
    state = state.copyWith(isLoading: true);
    try {
      final items = await api();
      state = state.copyWith(isLoading: false, items: items);
    } catch (e) {
      // FIX: clear the stale list when entering the error state.
      state = state.copyWith(
        isLoading: false,
        items: const <Item>[],
        errorMessage: e.toString(),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 1 — happy-path test (the test suites usually do write)
// Load succeeds; assert the list is populated. Passes. Bug not caught.
// ---------------------------------------------------------------------------
Future<void> scenarioHappyPath() async {
  final c = BuggyListController();
  await c.load(succeedingApi);
  if (c.state.items.length == 2 && c.state.errorMessage == null) {
    print('HAPPY-PATH TEST: PASS (BUG NOT CAUGHT)');
  } else {
    print('HAPPY-PATH TEST: FAIL — items=${c.state.items.length}');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 2 — real-path test vs buggy (the transition suites usually skip)
// Load 2 items, then a refresh fails. Assert the stale list was cleared.
// Buggy controller leaves it at 2. Test fails. Bug caught.
// ---------------------------------------------------------------------------
Future<void> scenarioRealPathBuggy() async {
  final c = BuggyListController();
  await c.load(succeedingApi); // 2 items loaded
  await c.load(failingApi);    // refresh fails
  // Expectation: on error the list is cleared. Buggy code leaves 2 items + an error.
  if (c.state.items.isNotEmpty && c.state.errorMessage != null) {
    print('ERROR-CLEAR TEST: FAIL (BUG CAUGHT)');
  } else {
    print('ERROR-CLEAR TEST: PASS — bug NOT caught (this means the demo is broken)');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 3 — real-path test vs fixed
// Same transition. Fixed controller clears the list. Test passes. Fix verified.
// ---------------------------------------------------------------------------
Future<void> scenarioRealPathFixed() async {
  final c = FixedListController();
  await c.load(succeedingApi);
  await c.load(failingApi);
  if (c.state.items.isEmpty && c.state.errorMessage != null) {
    print('ERROR-CLEAR TEST: PASS (FIX VERIFIED)');
  } else {
    print('ERROR-CLEAR TEST: FAIL after fix — items=${c.state.items.length}');
    exitCode = 1;
  }
}

Future<void> main() async {
  await scenarioHappyPath();
  await scenarioRealPathBuggy();
  await scenarioRealPathFixed();
}
