#!/usr/bin/env node
/**
 * tests/scenario_react_p4_rollback/demo.js
 *
 * Demonstrates AI-regression pattern P4 (Optimistic Update Without Rollback) for React.
 *
 * Why this scenario exists
 * ------------------------
 * In React UIs, "like" / "favorite" / "add-to-cart" actions optimistically
 * mutate local state before the API confirms. The mocked test asserts that
 * the UI updated post-click and stops — the failure path is implicit
 * ("API will succeed"). When the API fails in production, no rollback fires;
 * UI state and server state diverge silently. Same-model review misses this
 * because the success path is fully visible in the diff and the failure path
 * is invisible.
 *
 * This file runs three end-to-end checks in plain Node — no npm install,
 * no React, no test runner. The optimistic-store and component behavior are
 * simulated as plain functions. TypeScript concepts appear as JSDoc.
 *
 * Required output (in order, line-by-line, greppable):
 *   OPTIMISTIC UI: PASS (BUG NOT CAUGHT)
 *   ROLLBACK TEST: FAIL (BUG CAUGHT)
 *   ROLLBACK TEST: PASS (FIX VERIFIED)
 */

'use strict';

// ---------------------------------------------------------------------------
// Domain types (TS-ish, expressed as JSDoc for plain-JS runnability)
// ---------------------------------------------------------------------------
/**
 * @typedef {Object} OrderState
 * @property {string} id
 * @property {number} likes
 */

// ---------------------------------------------------------------------------
// Buggy optimistic-like handler — mutates local state, never rolls back on failure
// ---------------------------------------------------------------------------
function makeBuggyLikeHandler(initial) {
  /** @type {OrderState} */
  const state = { ...initial };
  return {
    getState: () => ({ ...state }),
    /** @param {() => Promise<void>} apiCall */
    async like(apiCall) {
      state.likes += 1; // optimistic
      try {
        await apiCall();
      } catch (_err) {
        // BUG: caught but no rollback
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Fixed handler — rolls back optimistic mutation on API failure
// ---------------------------------------------------------------------------
function makeFixedLikeHandler(initial) {
  /** @type {OrderState} */
  const state = { ...initial };
  return {
    getState: () => ({ ...state }),
    /** @param {() => Promise<void>} apiCall */
    async like(apiCall) {
      state.likes += 1; // optimistic
      try {
        await apiCall();
      } catch (_err) {
        state.likes -= 1; // rollback (compensating action)
      }
    },
  };
}

// ---------------------------------------------------------------------------
// API stubs
// ---------------------------------------------------------------------------
const succeedingApi = () => Promise.resolve();
const failingApi = () => Promise.reject(new Error('network'));

// ---------------------------------------------------------------------------
// SCENARIO 1 — Mocked optimistic-UI test
// The test only checks the post-click optimistic state, ignoring failure path.
// Test passes. Bug not caught.
// ---------------------------------------------------------------------------
async function scenarioMocked() {
  const handler = makeBuggyLikeHandler({ id: 'order-1', likes: 0 });
  await handler.like(succeedingApi); // mocked: API succeeds
  const after = handler.getState();
  if (after.likes === 1) {
    console.log('OPTIMISTIC UI: PASS (BUG NOT CAUGHT)');
  } else {
    console.log(`OPTIMISTIC UI: FAIL — likes=${after.likes}`);
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 2 — Real-path test against buggy handler
// API fails post-mutation. Test asserts rollback. Buggy handler never rolls back.
// Test fails. Bug caught.
// ---------------------------------------------------------------------------
async function scenarioRealPathBuggy() {
  const handler = makeBuggyLikeHandler({ id: 'order-1', likes: 0 });
  await handler.like(failingApi); // API rejects
  const after = handler.getState();
  // Expectation: likes rolled back to 0. Buggy code leaves it at 1.
  if (after.likes !== 0) {
    console.log('ROLLBACK TEST: FAIL (BUG CAUGHT)');
  } else {
    console.log('ROLLBACK TEST: PASS — bug NOT caught (this would mean the demo is broken)');
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 3 — Real-path test against FIXED handler
// API still fails. Fixed handler rolls back. Test passes. Fix verified.
// ---------------------------------------------------------------------------
async function scenarioRealPathFixed() {
  const handler = makeFixedLikeHandler({ id: 'order-1', likes: 0 });
  await handler.like(failingApi); // API rejects
  const after = handler.getState();
  if (after.likes === 0) {
    console.log('ROLLBACK TEST: PASS (FIX VERIFIED)');
  } else {
    console.log(`ROLLBACK TEST: FAIL after fix — likes=${after.likes}`);
    process.exitCode = 1;
  }
}

(async () => {
  await scenarioMocked();
  await scenarioRealPathBuggy();
  await scenarioRealPathFixed();
})();
