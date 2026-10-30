// tests/scenario_java_p2_select_omission/demo.java
//
// Demonstrates AI-regression pattern P2 (SELECT / Projection Omission)
// for Java + Spring Boot + Spring Data JPA.
//
// Why this scenario exists
// ------------------------
// In Spring Data JPA, a @Query projection or JPQL select clause can omit a
// column that the response shape now requires. Mock-based tests pass because
// the mock returns the field. Key-only assertions (e.g.
// assertThat(json).hasField("amount")) also pass — JSON serializers emit
// `"amount": null` for unselected columns. The real-path test must seed a
// fixture row, fetch via the real repository, and assert the VALUE of the
// new/changed field, not just key presence.
//
// Run: java tests/scenario_java_p2_select_omission/demo.java
// (Plain Java — no records, no JPA dependency; compatible with Java 11+
// single-file source-launching.)
//
// Required output (greppable, in order):
//   MOCKED TEST: PASS (BUG NOT CAUGHT)
//   KEY-ONLY ASSERTION: PASS (BUG NOT CAUGHT)
//   VALUE ASSERTION: FAIL (BUG CAUGHT)
//   VALUE ASSERTION: PASS (FIX VERIFIED)

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;

public class demo {

    // -----------------------------------------------------------------------
    // Domain object — plain class with all-args constructor + accessors
    // (Java 11 safe; no records).
    // -----------------------------------------------------------------------
    static final class Order {
        private final String id;
        private final BigDecimal amount;
        private final String currency;
        Order(String id, BigDecimal amount, String currency) {
            this.id = id;
            this.amount = amount;
            this.currency = currency;
        }
        String id() { return id; }
        BigDecimal amount() { return amount; }
        String currency() { return currency; }
    }

    // -----------------------------------------------------------------------
    // The seeded DB row (what's actually in the table).
    // -----------------------------------------------------------------------
    static final Order SEED = new Order("order-1", new BigDecimal("125.50"), "USD");

    // -----------------------------------------------------------------------
    // The mock that the unit test relies on — happens to return the full row.
    // -----------------------------------------------------------------------
    static Order mockRepositoryFind(String id) {
        return SEED;
    }

    // -----------------------------------------------------------------------
    // BUGGY: @Query("select new Order(o.id, o.currency) from Order o")
    // Forgets the amount field. Returns null for amount.
    // -----------------------------------------------------------------------
    static Order buggyRealRepositoryFind(String id) {
        return new Order(SEED.id(), null, SEED.currency());
    }

    // -----------------------------------------------------------------------
    // FIXED: projection includes all fields.
    // -----------------------------------------------------------------------
    static Order fixedRealRepositoryFind(String id) {
        return new Order(SEED.id(), SEED.amount(), SEED.currency());
    }

    // -----------------------------------------------------------------------
    // BEFORE-style test: against the mock. Bug invisible.
    // -----------------------------------------------------------------------
    static boolean mockedTest() {
        Order o = mockRepositoryFind("order-1");
        return o.amount().compareTo(new BigDecimal("125.50")) == 0;   // mock returned full row
    }

    // -----------------------------------------------------------------------
    // WEAK real-path test: only asserts key presence (the `hasField` style).
    // This still misses the bug because `null` is a valid value at the key.
    // -----------------------------------------------------------------------
    static boolean keyOnlyAssertion(java.util.function.Function<String, Order> impl) {
        Order o = impl.apply("order-1");
        // Simulates Jackson serialization to JSON: amount field IS present, even if null.
        Map<String, Object> asJson = new LinkedHashMap<>();
        asJson.put("id", o.id());
        asJson.put("amount", o.amount());   // null when projection omits column
        asJson.put("currency", o.currency());
        return asJson.containsKey("amount");   // PASS even when amount is null!
    }

    // -----------------------------------------------------------------------
    // STRONG real-path test: asserts the VALUE matches the seed fixture.
    // This is the canonical P2 defense.
    // -----------------------------------------------------------------------
    static boolean valueAssertion(java.util.function.Function<String, Order> impl) {
        Order o = impl.apply("order-1");
        return o.amount() != null
            && o.amount().compareTo(SEED.amount()) == 0;   // catches null from omitted SELECT
    }

    public static void main(String[] args) {
        // 1. Mocked test passes — bug NOT caught.
        if (mockedTest()) {
            System.out.println("MOCKED TEST: PASS (BUG NOT CAUGHT)");
        } else {
            System.out.println("MOCKED TEST: FAIL (unexpected)");
            System.exit(1);
        }

        // 2. Key-only assertion against the BUGGY real path — STILL passes.
        if (keyOnlyAssertion(demo::buggyRealRepositoryFind)) {
            System.out.println("KEY-ONLY ASSERTION: PASS (BUG NOT CAUGHT)");
        } else {
            System.out.println("KEY-ONLY ASSERTION: FAIL (unexpected)");
            System.exit(1);
        }

        // 3. Value assertion against the BUGGY real path — fails, bug caught.
        if (!valueAssertion(demo::buggyRealRepositoryFind)) {
            System.out.println("VALUE ASSERTION: FAIL (BUG CAUGHT)");
        } else {
            System.out.println("VALUE ASSERTION: PASS (unexpected — bug not caught)");
            System.exit(1);
        }

        // 4. Value assertion against the FIXED real path — passes, fix verified.
        if (valueAssertion(demo::fixedRealRepositoryFind)) {
            System.out.println("VALUE ASSERTION: PASS (FIX VERIFIED)");
        } else {
            System.out.println("VALUE ASSERTION: FAIL (fix didn't take)");
            System.exit(1);
        }
    }
}
