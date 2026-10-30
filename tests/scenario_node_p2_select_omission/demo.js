#!/usr/bin/env node
/**
 * tests/scenario_node_p2_select_omission/demo.js
 *
 * Demonstrates AI-regression pattern P2 (SELECT / Projection Omission) for Node.
 *
 * Why this scenario exists
 * ------------------------
 * In Node backends using TypeORM, Prisma, or hand-written SQL, the response
 * shape can gain a field while the underlying SELECT projection forgets to
 * include the column. The mocked test happens to return the field (because
 * the mock writer remembered it). The real-path test returns `null` for
 * unselected columns. Same-model review misses this because the diff is in
 * the controller, not the query.
 *
 * This file runs three end-to-end checks in plain Node — no npm install,
 * no tsc, no ts-node. TypeScript concepts appear as JSDoc-style comments.
 *
 * Required output (in order, line-by-line, greppable):
 *   MOCKED TEST: PASS (BUG NOT CAUGHT)
 *   REAL-PATH TEST: FAIL (BUG CAUGHT)
 *   REAL-PATH TEST: PASS (FIX VERIFIED)
 */

'use strict';

// ---------------------------------------------------------------------------
// Domain types (TS-ish, expressed as JSDoc for plain-JS runnability)
// ---------------------------------------------------------------------------
/**
 * @typedef {Object} Order
 * @property {string} id
 * @property {number} totalCents
 * @property {{email:string}} notificationSettings
 */

// ---------------------------------------------------------------------------
// "Production" data (single source of truth — the row that actually exists)
// ---------------------------------------------------------------------------
const ROW = {
  id: 'order-1',
  totalCents: 12500,
  notificationSettings: { email: 'recipient@example.com' },
};

// ---------------------------------------------------------------------------
// 1. The buggy query — SELECT projection omits notificationSettings
// ---------------------------------------------------------------------------
function buggyOrderQuery(id) {
  // Simulates: SELECT id, total_cents FROM orders WHERE id = ?
  // notificationSettings column intentionally NOT selected.
  if (id !== ROW.id) return null;
  return { id: ROW.id, totalCents: ROW.totalCents }; // notificationSettings missing!
}

// 2. The fixed query — projection includes notificationSettings
function fixedOrderQuery(id) {
  if (id !== ROW.id) return null;
  return { ...ROW }; // full projection
}

// ---------------------------------------------------------------------------
// Mocked test runner — the writer hand-built the mock with the expected shape
// ---------------------------------------------------------------------------
function mockedQuery(id) {
  // This is what same-model review hand-wrote, mirroring the API response shape.
  // It does NOT reflect the actual SELECT in the production code.
  return { id, totalCents: 12500, notificationSettings: { email: 'recipient@example.com' } };
}

// ---------------------------------------------------------------------------
// Assertion helpers — value-asserting (catches null) and key-only (misses null)
// ---------------------------------------------------------------------------
function assertHasEmail(order, label) {
  // Value-asserting: requires a real string at notificationSettings.email
  if (
    !order ||
    !order.notificationSettings ||
    typeof order.notificationSettings.email !== 'string' ||
    order.notificationSettings.email.length === 0
  ) {
    return { ok: false, label, reason: 'notificationSettings.email is missing or empty' };
  }
  return { ok: true, label, value: order.notificationSettings.email };
}

// ---------------------------------------------------------------------------
// SCENARIO 1 — Mocked test against buggy query
// The mock returns the field; the buggy query never executes inside the test.
// Test passes. Bug not caught.
// ---------------------------------------------------------------------------
{
  const result = mockedQuery('order-1'); // mock — not the real production code
  const check = assertHasEmail(result, 'mocked');
  if (check.ok) {
    console.log('MOCKED TEST: PASS (BUG NOT CAUGHT)');
  } else {
    // Should not happen in this scenario — included for symmetry
    console.log(`MOCKED TEST: FAIL — ${check.reason}`);
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 2 — Real-path test against buggy query
// The buggy query runs; notificationSettings is undefined. Value assertion fails.
// Bug caught.
// ---------------------------------------------------------------------------
{
  const result = buggyOrderQuery('order-1'); // production code path
  const check = assertHasEmail(result, 'real-path');
  if (!check.ok) {
    console.log('REAL-PATH TEST: FAIL (BUG CAUGHT)');
  } else {
    console.log('REAL-PATH TEST: PASS — bug NOT caught (this would mean the demo is broken)');
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// SCENARIO 3 — Real-path test against FIXED query
// SELECT projection now includes the column. Value assertion passes.
// Fix verified.
// ---------------------------------------------------------------------------
{
  const result = fixedOrderQuery('order-1'); // fixed production code path
  const check = assertHasEmail(result, 'real-path-fixed');
  if (check.ok) {
    console.log('REAL-PATH TEST: PASS (FIX VERIFIED)');
  } else {
    console.log(`REAL-PATH TEST: FAIL after fix — ${check.reason}`);
    process.exitCode = 1;
  }
}
