---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Spring Boot Patterns

Stack-owned subfile of `java-patterns.md` (entrypoint). Covers DI, validation, error handling, Actuator endpoint exposure, and concurrency. Read this when working in Spring Boot code paths.

## Constructor Injection (mandatory)

Never `@Autowired` on fields. Always constructor injection with `final` fields. The default constructor-only single-constructor case can omit `@Autowired` entirely (Spring auto-detects).

```java
@Service
public class OrderService {
    private final OrderRepository orderRepository;
    private final PaymentClient paymentClient;

    public OrderService(OrderRepository orderRepository, PaymentClient paymentClient) {
        this.orderRepository = orderRepository;
        this.paymentClient = paymentClient;
    }
}
```

Why: field injection hides dependencies from the constructor signature, breaks testability (need reflection or `@SpringBootTest` to wire mocks), and prevents `final` fields. Constructor injection makes dependencies explicit and the bean immutable after wiring.

**Lombok shortcut:** `@RequiredArgsConstructor` generates the constructor over all `final` fields. Same effect, less boilerplate. See [`java/lombok.md`](lombok.md).

## Bean Validation

`@Valid` on controller params + `@NotNull` / `@NotBlank` / `@Size` / `@Min` / `@Max` on DTOs. Validation groups for create-vs-update.

**Namespace gate (critical):**
- Spring Boot 2.x → `javax.validation.*` (e.g. `import javax.validation.Valid; import javax.validation.constraints.NotBlank;`)
- Spring Boot 3.x → `jakarta.validation.*` (e.g. `import jakarta.validation.Valid; import jakarta.validation.constraints.NotBlank;`)

```java
public class CreateOrderRequest {
    @NotBlank(message = "customerId required")
    private String customerId;

    @NotNull
    @Min(1)
    private Integer quantity;

    @NotNull
    private BigDecimal amount;   // see java/financial.md
}

@PostMapping("/orders")
public ResponseEntity<OrderDto> create(@Valid @RequestBody CreateOrderRequest req) { ... }
```

Validation groups for distinguishing create vs update (where some fields are immutable post-create):

```java
public interface OnCreate {}
public interface OnUpdate {}

public class OrderRequest {
    @Null(groups = OnCreate.class) @NotNull(groups = OnUpdate.class)
    private Long id;

    @NotBlank(groups = OnCreate.class)
    private String customerId;
}
```

## Error Handling

`@RestControllerAdvice` for global handlers. Never swallow exceptions — `catch (Exception e) { }` is forbidden. Never `e.printStackTrace()` in production code; use a logger. Prefer unchecked exceptions for business errors (checked exceptions force throws-list maintenance up the call chain without adding type-system value).

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(NotFoundException.class)
    public ResponseEntity<ProblemDetail> handleNotFound(NotFoundException ex) {
        log.info("not_found resource={} reason={}", ex.getResource(), ex.getMessage());
        ProblemDetail body = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage());
        body.setType(URI.create("https://api.example.com/errors/not-found"));
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(body);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ProblemDetail> handleValidation(MethodArgumentNotValidException ex) {
        // map BindingResult fieldErrors → ProblemDetail.properties["errors"]
        ...
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ProblemDetail> handleGeneric(Exception ex) {
        log.error("unhandled_exception", ex);   // structured, with stack trace
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
            .body(ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "internal error"));
    }
}
```

**Error-response shape policy:**
- **New endpoints in a service with no established convention:** RFC 7807 (`application/problem+json`) is **preferred**. Spring Boot 3.x has built-in support via `org.springframework.http.ProblemDetail`. On SB 2.x, use `org.zalando.problem` or hand-roll the structure.
- **Endpoints in a service with an existing error-shape convention:** match the existing shape. Do **not** introduce a second error-shape inside the same service — heterogeneity breaks client-side error parsers.
- Document the chosen convention in the per-repo CLAUDE.md so future Claude sessions hold the line.

Never expose stack traces or internal class names to clients. The handler returns the safe shape; logs get the diagnostic detail.

## Spring Boot Actuator — Endpoint Exposure (security-critical)

Spring Boot's defaults are not safe for internet-facing services. Three actuator endpoints leak secrets if exposed without auth:

- `/actuator/env` — full `Environment` dump. Spring redacts properties whose names match `password|secret|key|token`, but **custom-named properties (e.g. `app.jwt.signing-key`) are NOT redacted automatically**.
- `/actuator/configprops` — same data, structured differently. Same redaction caveat.
- `/actuator/heapdump` — full JVM heap snapshot. Contains in-memory secrets, JWTs, DB connections, user records. **No redaction at all.**

**Mandatory rules:**
- Only `/actuator/health` and `/actuator/info` may be exposed publicly without auth. Everything else MUST be on an internal-only port (`management.server.port: 9091`) bound to a private network, OR protected by Spring Security with a role check.
- Explicit allowlist via `management.endpoints.web.exposure.include` — **never** `*` in any committed profile.
- `management.endpoint.health.show-details: when_authorized` (or `never` for public-facing). Default `always` leaks DB-connection state, disk usage, downstream service URLs.
- `/actuator/shutdown` is disabled by default — never enable it in committed config.
- Custom `@ConfigurationProperties` carrying secrets MUST use names matching the redaction pattern (`*.secret`, `*.key`, `*.password`, `*.token`) — otherwise they show in plaintext via `/env`.

```yaml
management:
  server:
    port: 9091                          # separate port — bind to internal network only
    address: 127.0.0.1                  # or internal LAN IP; never 0.0.0.0 on management port
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus   # explicit allowlist
  endpoint:
    health:
      show-details: when_authorized
      probes:
        enabled: true                   # liveness + readiness for k8s
    shutdown:
      enabled: false                    # never true in committed config
```

**Anti-patterns:**
- `management.endpoints.web.exposure.include: '*'` in any committed profile
- Actuator endpoints on the application port (same port as user traffic) — exposes them to the internet by default
- `management.endpoint.health.show-details: always` on public-facing services
- Enabling `/actuator/shutdown`
- Custom secret property named without the redaction-pattern suffix (`app.jwt.signingKey` → leaks; `app.jwt.signing-secret` → redacted)

## Concurrency

`CompletableFuture` over raw `Thread`. `@Async` requires `@EnableAsync` + a configured `Executor` bean — the default executor is unbounded, which is a production hazard under load.

```java
@Configuration
@EnableAsync
public class AsyncConfig {
    @Bean(name = "taskExecutor")
    public Executor taskExecutor() {
        ThreadPoolTaskExecutor exec = new ThreadPoolTaskExecutor();
        exec.setCorePoolSize(8);
        exec.setMaxPoolSize(32);
        exec.setQueueCapacity(100);     // bounded queue — rejects on saturation
        exec.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        exec.setThreadNamePrefix("async-");
        exec.initialize();
        return exec;
    }
}

@Service
public class NotificationService {
    @Async("taskExecutor")
    public CompletableFuture<Void> sendEmailAsync(EmailRequest req) { ... }
}
```

**`Future.get()` discipline:** always pass a timeout — never `.get()` with no argument. An unbounded wait blocks the calling thread indefinitely if the producer never completes.

```java
// PASS
String result = future.get(5, TimeUnit.SECONDS);

// FAIL
String result = future.get();   // can block forever
```

**Virtual threads (Java 21+):** `Executors.newVirtualThreadPerTaskExecutor()` for I/O-bound work — file/network/DB. NOT for CPU-bound work (no benefit) and NOT for code holding `synchronized` blocks or native monitors (virtual threads pin to their carrier thread, defeating the point).

```java
// Java 21+: I/O-bound parallel calls
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    var f1 = executor.submit(() -> client.fetchOrder(orderId));
    var f2 = executor.submit(() -> client.fetchCustomer(customerId));
    var order = f1.get(5, TimeUnit.SECONDS);
    var customer = f2.get(5, TimeUnit.SECONDS);
}
```

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint with version matrices, anti-patterns summary, framework detection
- [`persistence-jpa.md`](persistence-jpa.md) — `@Transactional`, N+1, repository patterns
- [`security-config.md`](security-config.md) — `application.yml` secrets policy, PII in logs
- [`testing.md`](testing.md) — JUnit 5, slice tests, `@MockitoBean` migration
