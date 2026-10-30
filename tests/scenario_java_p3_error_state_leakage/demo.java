// tests/scenario_java_p3_error_state_leakage/demo.java
//
// Demonstrates AI-regression pattern P3 (Error State Leakage) for
// Java + Spring Boot + Spring Data JPA / Hibernate.
//
// Why this scenario exists
// ------------------------
// A @Transactional service can mutate an entity in memory, throw, and trigger
// rollback. The DB row is restored, but Hibernate's first-level cache (the
// EntityManager's persistence context) still holds the mutated copy. A
// subsequent call in the same persistence context returns the stale in-memory
// state — and the API silently leaks it.
//
// The canonical defense: the *production* code path (e.g. the rollback handler
// or @RestControllerAdvice) calls em.clear() so the cache is purged when the
// exception flows out. The test does NOT call em.clear() — that's the bug
// production must handle. The test just re-reads via findFromDb and asserts
// the value matches the DB row, not the in-memory mutation.
//
// Run: java tests/scenario_java_p3_error_state_leakage/demo.java
// (Plain Java — no records, no JPA dependency; compatible with Java 11+.)
//
// Required output (greppable, in order):
//   MOCKED TEST: PASS (BUG NOT CAUGHT)
//   REAL-PATH TEST vs BUGGY: FAIL (BUG CAUGHT)
//   REAL-PATH TEST vs FIXED: PASS (FIX VERIFIED)

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.Map;

public class demo {

    // -----------------------------------------------------------------------
    // Domain object — plain class, no records (Java 11 safe).
    // -----------------------------------------------------------------------
    static final class Order {
        final String id;
        BigDecimal amount;
        Order(String id, BigDecimal amount) {
            this.id = id;
            this.amount = amount;
        }
    }

    // -----------------------------------------------------------------------
    // Simulated durable DB row — survives rollback. The single source of truth.
    // -----------------------------------------------------------------------
    static final Map<String, BigDecimal> DB = new HashMap<>();

    // -----------------------------------------------------------------------
    // Simulated Hibernate first-level cache (per-persistence-context).
    // findFromDb serves from cache when populated, matching real Hibernate.
    // -----------------------------------------------------------------------
    static final Map<String, Order> FIRST_LEVEL_CACHE = new HashMap<>();

    static Order findFromDb(String id) {
        Order cached = FIRST_LEVEL_CACHE.get(id);
        if (cached != null) return cached;
        Order fromDb = new Order(id, DB.get(id));
        FIRST_LEVEL_CACHE.put(id, fromDb);
        return fromDb;
    }

    static void resetState() {
        FIRST_LEVEL_CACHE.clear();
        DB.clear();
        DB.put("order-1", new BigDecimal("100"));
    }

    // -----------------------------------------------------------------------
    // BUGGY production: @Transactional method mutates the loaded entity,
    // throws. Rollback restores the DB row, but the @RestControllerAdvice
    // (or whatever catches the exception) does NOT clear the persistence
    // context. The cache still holds the mutated copy.
    // -----------------------------------------------------------------------
    static void buggyMutateAndThrow(String id) {
        Order o = findFromDb(id);
        o.amount = new BigDecimal("999");   // mutate in memory
        throw new RuntimeException("simulated business failure");
        // No em.clear() anywhere on the production code path.
    }

    // -----------------------------------------------------------------------
    // FIXED production: same mutation, but the production code path wraps
    // the mutation in try/catch and calls em.clear() on the rollback branch
    // BEFORE rethrowing. The cache is purged so subsequent reads hit the DB.
    // -----------------------------------------------------------------------
    static void fixedMutateAndThrow(String id) {
        try {
            Order o = findFromDb(id);
            o.amount = new BigDecimal("999");
            throw new RuntimeException("simulated business failure");
        } catch (RuntimeException e) {
            FIRST_LEVEL_CACHE.clear();   // <-- production-owned defense
            throw e;
        }
    }

    // -----------------------------------------------------------------------
    // BEFORE: test mocks the repository entirely. Cache pollution invisible.
    // -----------------------------------------------------------------------
    static boolean mockedTest() {
        Order mockOrder = new Order("order-1", new BigDecimal("100"));
        return mockOrder.amount.compareTo(new BigDecimal("100")) == 0;
    }

    // -----------------------------------------------------------------------
    // AFTER: real-path test runs against the production code path AS-IS.
    // The test does NOT call em.clear() — that's the production code's job.
    // After the throw is observed, the test re-reads via findFromDb and
    // asserts the value matches the DB row (100), not the in-memory
    // mutation (999). For BUGGY: cache pollutes the read → 999 → fails.
    // For FIXED: cache cleared by production → re-read from DB → 100 → passes.
    // -----------------------------------------------------------------------
    static boolean realPathAssertsCleanState(java.util.function.Consumer<String> productionMethod) {
        try {
            productionMethod.accept("order-1");
            return false;   // should have thrown
        } catch (RuntimeException expected) {
            // NO em.clear() here — the test does NOT defend production.
            Order reloaded = findFromDb("order-1");
            return reloaded.amount.compareTo(new BigDecimal("100")) == 0;
        }
    }

    public static void main(String[] args) {
        // 1. Mocked test — bug invisible.
        resetState();
        if (mockedTest()) {
            System.out.println("MOCKED TEST: PASS (BUG NOT CAUGHT)");
        } else {
            System.out.println("MOCKED TEST: FAIL (unexpected)");
            System.exit(1);
        }

        // 2. Real-path test against BUGGY production. Cache pollution
        // pollutes the re-read. Test SHOULD fail (catching the bug).
        resetState();
        if (!realPathAssertsCleanState(demo::buggyMutateAndThrow)) {
            System.out.println("REAL-PATH TEST vs BUGGY: FAIL (BUG CAUGHT)");
        } else {
            System.out.println("REAL-PATH TEST vs BUGGY: PASS (unexpected — bug not caught)");
            System.exit(1);
        }

        // 3. Real-path test against FIXED production. Cache cleared by
        // production code; re-read returns DB row. Test SHOULD pass.
        resetState();
        if (realPathAssertsCleanState(demo::fixedMutateAndThrow)) {
            System.out.println("REAL-PATH TEST vs FIXED: PASS (FIX VERIFIED)");
        } else {
            System.out.println("REAL-PATH TEST vs FIXED: FAIL (fix didn't take)");
            System.exit(1);
        }
    }
}
