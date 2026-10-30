// tests/scenario_java_p1_path_divergence/demo.java
//
// Demonstrates AI-regression pattern P1 (Sandbox / Production Path Divergence)
// for Java + Spring Boot.
//
// Why this scenario exists
// ------------------------
// In Spring Boot, services often branch on a profile (e.g. @Profile("sandbox")
// vs @Profile("production")) or on a feature flag. When a developer updates
// the response shape in one branch, same-model review tends to inherit the
// writer's mental model ("the change is in the controller") and never
// re-examines the other branch. Mock-based tests only exercise one path.
// The real-path test must exercise BOTH and assert identical shape.
//
// Run: java tests/scenario_java_p1_path_divergence/demo.java
// (Plain Java — no records, no Spring; compatible with Java 11+
// single-file source-launching.)
//
// Required output (greppable, in order):
//   MOCKED TEST: PASS (BUG NOT CAUGHT)
//   REAL-PATH TEST: FAIL (BUG CAUGHT)
//   REAL-PATH TEST: PASS (FIX VERIFIED)

import java.math.BigDecimal;
import java.util.Objects;

public class demo {

    // -----------------------------------------------------------------------
    // Domain object — plain class with all-args constructor + accessors
    // (Java 11 safe; no records).
    // -----------------------------------------------------------------------
    static final class OrderDto {
        private final String id;
        private final BigDecimal amount;
        private final String currency;
        OrderDto(String id, BigDecimal amount, String currency) {
            this.id = id;
            this.amount = amount;
            this.currency = currency;
        }
        String id() { return id; }
        BigDecimal amount() { return amount; }
        String currency() { return currency; }
    }

    // -----------------------------------------------------------------------
    // Production path: returns the full DTO from a real persistence layer.
    // -----------------------------------------------------------------------
    static OrderDto productionFetch(String id) {
        return new OrderDto(id, new BigDecimal("125.50"), "USD");
    }

    // -----------------------------------------------------------------------
    // Buggy sandbox path: was updated to return a hardcoded mock, but the
    // developer forgot the currency field. Mock-based tests passed because
    // the test author also forgot to assert on currency.
    // -----------------------------------------------------------------------
    static OrderDto buggySandboxFetch(String id) {
        return new OrderDto(id, new BigDecimal("125.50"), null);   // currency lost!
    }

    // -----------------------------------------------------------------------
    // Fixed sandbox path: parity with production shape; all fields present.
    // -----------------------------------------------------------------------
    static OrderDto fixedSandboxFetch(String id) {
        return new OrderDto(id, new BigDecimal("125.50"), "USD");
    }

    // -----------------------------------------------------------------------
    // BEFORE: mocked test only checks the prod path. Sandbox bug invisible.
    // -----------------------------------------------------------------------
    static boolean mockedTestProdOnly() {
        OrderDto result = productionFetch("order-1");
        return result.id().equals("order-1")
            && result.amount().compareTo(new BigDecimal("125.50")) == 0
            && "USD".equals(result.currency());
    }

    // -----------------------------------------------------------------------
    // AFTER: real-path test exercises BOTH profiles, asserts identical shape.
    // -----------------------------------------------------------------------
    static boolean realPathTest(java.util.function.Function<String, OrderDto> sandboxImpl) {
        OrderDto prod = productionFetch("order-1");
        OrderDto sandbox = sandboxImpl.apply("order-1");
        return Objects.equals(prod.id(), sandbox.id())
            && prod.amount().compareTo(sandbox.amount()) == 0
            && Objects.equals(prod.currency(), sandbox.currency());   // catches the bug
    }

    public static void main(String[] args) {
        // 1. Mocked test against prod path only — bug is NOT caught.
        if (mockedTestProdOnly()) {
            System.out.println("MOCKED TEST: PASS (BUG NOT CAUGHT)");
        } else {
            System.out.println("MOCKED TEST: FAIL (unexpected)");
            System.exit(1);
        }

        // 2. Real-path test against the BUGGY sandbox impl — bug IS caught.
        if (!realPathTest(demo::buggySandboxFetch)) {
            System.out.println("REAL-PATH TEST: FAIL (BUG CAUGHT)");
        } else {
            System.out.println("REAL-PATH TEST: PASS (unexpected — bug not caught)");
            System.exit(1);
        }

        // 3. Real-path test against the FIXED sandbox impl — verifies fix.
        if (realPathTest(demo::fixedSandboxFetch)) {
            System.out.println("REAL-PATH TEST: PASS (FIX VERIFIED)");
        } else {
            System.out.println("REAL-PATH TEST: FAIL (fix didn't take)");
            System.exit(1);
        }
    }
}
