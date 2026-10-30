---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Testing Patterns (JUnit 5 + Mockito + slices)

Stack-owned subfile of `java-patterns.md` (entrypoint). Covers JUnit 5 conventions, Spring slice tests, and the `@MockBean` → `@MockitoBean` migration in SB 3.4+.

The full-DB real-persistence pattern (P1/P2/P3 catalog-routed section) stays in the entrypoint at `java-patterns.md` §"Isolated Real-Persistence Tests" — this file covers everything else.

## JUnit 5 (Jupiter) is the default

JUnit 4 is allowed only in legacy modules where a JUnit 5 migration is already in flight. New code uses JUnit 5.

**Imports (note `org.junit.jupiter.api`, NOT `org.junit`):**
```java
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.extension.ExtendWith;
import static org.assertj.core.api.Assertions.assertThat;
```

**AssertJ** for assertions (`assertThat(x).isEqualTo(y).hasFieldOrPropertyWithValue(...)`) — fluent, chainable, better error messages than JUnit's `assertEquals`. Hamcrest is allowed but AssertJ is the preferred default.

**Test class names:** `XxxTest` for unit / slice tests; `XxxIT` for integration tests with Testcontainers or the full Spring context. The `IT` suffix lets the build's `failsafe` plugin (Maven) or test-type split (Gradle) run integration tests in a different phase.

**Test method names:** `should_do_x_when_y` or `do_x_when_y` — readable as English. Avoid `testFoo()` — the `test` prefix is redundant in JUnit 5.

## Mockito basics (no Spring context)

For testing a service in isolation without Spring:

```java
@ExtendWith(MockitoExtension.class)
class OrderServiceTest {
    @Mock OrderRepository orderRepository;
    @Mock PaymentClient paymentClient;
    @InjectMocks OrderService orderService;

    @Test
    void should_throw_NotFound_when_order_missing() {
        when(orderRepository.findById(42L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> orderService.findOrder(42L))
            .isInstanceOf(NotFoundException.class)
            .hasMessageContaining("Order 42");
    }
}
```

`@InjectMocks` constructs the service and wires the `@Mock` fields in via constructor injection (because the service uses constructor injection — see [`spring-boot.md`](spring-boot.md) §"Constructor Injection").

**Don't `@Spy` unless you have a real need** — partial mocks blur the boundary between code-under-test and test-doubles. The usual smell is that the service should be split.

## Spring slice tests

`@SpringBootTest` boots the full application context and is slow — last resort. Spring has narrower test "slices" that load only the beans relevant to the layer being tested.

### `@WebMvcTest` — controller slice

```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {
    @Autowired MockMvc mockMvc;
    @MockBean OrderService orderService;        // SB 2.x / 3.0–3.3
    // @MockitoBean OrderService orderService;  // SB 3.4+ — see "Mock-in-context" below

    @Test
    void GET_returns_404_when_service_throws_NotFound() throws Exception {
        when(orderService.findOrder(42L)).thenThrow(new NotFoundException("Order 42"));

        mockMvc.perform(get("/orders/42"))
            .andExpect(status().isNotFound())
            .andExpect(jsonPath("$.detail").value("Order 42"));
    }
}
```

Loads only the controller + `@RestControllerAdvice` + Spring MVC infrastructure. Repository / service beans are absent — replace them with `@MockBean` (or `@MockitoBean` on SB 3.4+).

### `@DataJpaTest` — repository slice

```java
@DataJpaTest
class OrderRepositoryTest {
    @Autowired OrderRepository orderRepository;
    @Autowired TestEntityManager em;

    @Test
    void findByStatus_returns_matching_orders() {
        em.persistAndFlush(new Order("ORD-1", OrderStatus.PAID));
        em.persistAndFlush(new Order("ORD-2", OrderStatus.PENDING));

        List<Order> paid = orderRepository.findByStatus(OrderStatus.PAID);

        assertThat(paid).hasSize(1).extracting(Order::getNumber).containsExactly("ORD-1");
    }
}
```

**Important constraint:** `@DataJpaTest` uses an embedded DB by default (H2). This is fine for **mapping / query-syntax tests** (does the JPQL parse, does the projection deserialize correctly), but NOT for **behavior tests** (does this query under concurrent load behave like prod). Behavior tests use Testcontainers + the real prod DB engine — see [`../java-patterns.md`](../java-patterns.md) §"Isolated Real-Persistence Tests".

`@DataJpaTest` rolls back at the end of each test by default — fixtures don't pollute other tests.

### `@SpringBootTest` — full context (last resort)

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class OrderEndToEndIT {
    @LocalServerPort int port;
    @Autowired TestRestTemplate client;

    @Test
    void POST_order_persists_and_returns_201() { ... }
}
```

Reserve for end-to-end smoke that genuinely needs the full wiring (security filters, real serializer, real Jackson config). Avoid using it when a slice test would suffice — every `@SpringBootTest` adds seconds to the test suite.

## Mock-in-Spring-context — version-aware (`@MockBean` → `@MockitoBean`)

Spring Boot 3.4+ deprecates `@MockBean` (from `org.springframework.boot.test.mock.mockito`) in favor of `@MockitoBean` (from `org.springframework.test.context.bean.override.mockito`). Same intent (replace a Spring-managed bean with a Mockito mock in the test context), new package path.

| Spring Boot | Annotation | Package |
|---|---|---|
| 2.x | `@MockBean` | `org.springframework.boot.test.mock.mockito` |
| 3.0 – 3.3 | `@MockBean` | `org.springframework.boot.test.mock.mockito` |
| 3.4+ | **`@MockitoBean`** | `org.springframework.test.context.bean.override.mockito` |

```java
// Spring Boot 3.4+
@WebMvcTest(OrderController.class)
class OrderControllerTest {
    @MockitoBean OrderService orderService;   // <-- new package
    ...
}
```

When upgrading a repo to SB 3.4+, run a project-wide replace: `@MockBean` → `@MockitoBean` and the import. Document the chosen annotation in the per-repo CLAUDE.md so mixed usage doesn't sneak in.

**Plain Mockito (no Spring context) is unchanged across SB versions** — `@Mock` + `@InjectMocks` + `@ExtendWith(MockitoExtension.class)` works identically.

## Parameterized tests

For testing the same logic across multiple input combinations, prefer `@ParameterizedTest` over loops:

```java
@ParameterizedTest
@CsvSource({
    "100.00, USD, 100.00",
    "100.50, USD, 100.50",
    "100.555, USD, 100.56"
})
void rounds_to_two_decimals_HALF_UP(BigDecimal in, String currency, BigDecimal expected) {
    Money result = Money.of(in, currency).roundedToCents();
    assertThat(result.amount()).isEqualByComparingTo(expected);
}
```

Better diagnostic output than a single `@Test` looping over the cases — JUnit reports each parameter combination as a separate test.

## What not to do

- `@SpringBootTest` for every test — slow suite kills feedback loop
- `Thread.sleep(...)` in tests — flaky on slow CI; use Awaitility for timing-sensitive assertions
- `@Disabled` without a TODO + tracked issue — silent test rot
- Mocking the SUT (the class under test) — usually means the class should be split
- Tests that pass against a buggy SELECT projection because they only assert HTTP 200 — see [`../java-patterns.md`](../java-patterns.md) §"P2 — SELECT / Projection Omission" for the canonical example

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint, including the catalog-routed §"Isolated Real-Persistence Tests" P1/P2/P3 patterns
- [`spring-boot.md`](spring-boot.md) — Constructor injection (testability foundation), `@RestControllerAdvice` (covered by `@WebMvcTest`)
- [`persistence-jpa.md`](persistence-jpa.md) — `@Transactional` boundaries that test rollback semantics depend on
