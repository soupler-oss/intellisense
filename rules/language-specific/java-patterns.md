---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Java + Spring Boot Patterns

Entrypoint for Java/Spring Boot. Version-aware: every idiom tagged with its minimum stable Java version. Spring Boot 2.x + 3.x covered; Quarkus/Micronaut out of scope. Canonical entrypoint per Hybrid Entrypoint architecture (`ai-regression-patterns.md` §Architecture Rule) — heavy guidance lives in `java/*.md` subfiles.

## Framework Detection

Before applying Spring-specific rules, confirm the repo is Spring Boot:
- `pom.xml` contains `spring-boot-starter-parent` → Spring Boot
- `build.gradle{,.kts}` contains `org.springframework.boot` plugin or `spring-boot-starter` → Spring Boot
- Neither → use only version matrices + naming/layout rules; skip Spring-specific guidance

## Java Version Matrix (stable features only)

The "Min Java" column lists the version where each feature became **stable**. Preview features are forbidden in production code — they can change syntax/semantics between releases. To experiment, use a feature branch + `--enable-preview` + Beads issue.

| Feature | Min Java | Pre-version substitute |
|---|---|---|
| `java.time.*` (`Instant`, `LocalDateTime`, `Duration`) | 8 | — (never use `java.util.Date`/`SimpleDateFormat`) |
| Streams + lambdas + `Optional` | 8 | — |
| `List.of()` / `Map.of()` / `Set.of()` | 9 | `Collections.unmodifiableList(Arrays.asList(...))` |
| `var` (local-var type inference) | 10 | Full type declaration |
| `String.isBlank()` / `strip()` / `lines()` | 11 | `s == null \|\| s.trim().isEmpty()` |
| `Optional.isEmpty()` | 11 | `!opt.isPresent()` |
| `HttpClient` (`java.net.http`) | 11 | Apache HttpClient / OkHttp / `HttpURLConnection` |
| `Files.writeString` / `readString` | 11 | `Files.write(path, str.getBytes(UTF_8))` |
| Text blocks | 15 | Concat or `String.join("\n", ...)` |
| Records | 16 | Lombok `@Value` or hand-written immutable class |
| `Stream.toList()` short form | 16 | `.collect(Collectors.toList())` |
| Pattern matching for `instanceof` | 16 | `if (x instanceof Foo) { Foo f = (Foo) x; ... }` |
| Sealed classes | 17 | Abstract class with package-private constructor |
| Pattern matching for `switch` | 21 | Old switch statement |
| Virtual threads (`Thread.ofVirtual()`) | 21 | `Executors.newCachedThreadPool()` for I/O |

**Non-LTS rule:** Java 18/19/20/22/23 inherit from the nearest LTS below — e.g. Java 20 = Java 17 baseline + features added in 18/19/20.

## Java ↔ Spring Boot Compatibility

SB 3.x drops Java 8/11 entirely.

| Spring Boot | Java 8 | Java 11 | Java 17 | Java 21 | Namespace | Security DSL |
|---|---|---|---|---|---|---|
| 2.0 – 2.5 | yes | yes | no | no | `javax.*` | `WebSecurityConfigurerAdapter` |
| 2.6 – 2.7 | yes | yes | yes | no | `javax.*` | `WebSecurityConfigurerAdapter` (deprecated) |
| 3.0 – 3.1 | no | no | yes | no | `jakarta.*` | `SecurityFilterChain` bean |
| 3.2+ | no | no | yes | yes | `jakarta.*` | `SecurityFilterChain` bean |

A Java 8 repo MUST stay on Spring Boot 2.x; no SB3 path without upgrading Java to 17 first. SB 2.7 supports Java 17 but minimum is Java 8 — trapdoor only opens at SB 3.x. `javax.*` → `jakarta.*` is gated on the SB major-version upgrade. SB 2.7 reached OSS end-of-life Nov 2023.

## Naming Conventions

Packages lowercase reverse-domain (`com.example.<service>.<layer>`). Classes/records PascalCase. Methods/fields camelCase. Constants UPPER_SNAKE_CASE. Test classes `XxxTest` (unit) or `XxxIT` (integration with Testcontainers). REST controllers `XxxController` (never `XxxResource` — that's JAX-RS).

## Project Layout

```
src/main/java/com/example/<service>/
├── controller/ service/ repository/ domain/ config/ exception/
src/main/resources/
├── application{,-dev,-prod}.yml   # no secrets committed
├── db/migration/                  # Flyway: V<ts>__<desc>.sql
└── db/changelog/                  # Liquibase
src/test/java/                     # mirrors main; resources/application-test.yml
```

`application-local.yml` is `.gitignore`d (developer overrides only).

## Build Tool Parity

| Task | Maven | Gradle |
|---|---|---|
| Run tests | `mvn test` | `./gradlew test` |
| Single test | `mvn -Dtest=ClassName#method test` | `./gradlew test --tests ClassName.method` |
| Build jar | `mvn package` | `./gradlew bootJar` |
| Dependency tree | `mvn dependency:tree` | `./gradlew dependencies` |
| Skip tests | `mvn package -DskipTests` | `./gradlew bootJar -x test` |

## Isolated Real-Persistence Tests (P1 / P2 / P3)

Catalog-routed section. Each pattern has a proof artifact under `tests/scenario_java_*/`.

**Universal rules:**
- Testcontainers with the prod DB engine + version; wire JDBC URL via `@DynamicPropertySource`. **Never H2 for behavior tests** (diverges on case sensitivity, JSON, FK cascade, isolation).
- Assert on **values**, never "no exception thrown" — a HTTP-200 check passes against a SELECT clause returning `null` for the changed field.

### P1 — Sandbox / Production Path Divergence

`@Profile`/feature-flag branches construct different response shapes. Same-model review misses the branch the writer didn't touch.

Rule: exercise BOTH profiles against the same input; assert identical response shape (full DTO equality, not key presence). See `tests/scenario_java_p1_path_divergence/demo.java`.

### P2 — SELECT / Projection Omission

JPQL `select` or `@Query` projection forgets a column the response now requires. Mocks return the field; key-only assertions pass against `null`.

Rule: seed a fixture row, fetch via the real repository, assert the field has its **fixture value** (not just key presence, not just non-null). See `tests/scenario_java_p2_select_omission/demo.java`.

### P3 — Error State Leakage

`@Transactional` mutates in memory, throws, rollback fires. DB row restored, but Hibernate's first-level cache holds the mutated copy and serves it to subsequent calls.

Rule: the **production code path** must clear the persistence context on rollback (e.g. `@RestControllerAdvice` calls `em.clear()`), NOT the test. Test asserts a fresh `findById` returns the pre-call DB state. See `tests/scenario_java_p3_error_state_leakage/demo.java`.

## Operational Subfiles

Heavy framework-specific guidance lives in stack-owned subfiles:

- [java/spring-boot.md](java/spring-boot.md) — DI, validation, errors, Actuator, concurrency
- [java/persistence-jpa.md](java/persistence-jpa.md) — `@Transactional`, N+1, repositories, Optional
- [java/db-migrations.md](java/db-migrations.md) — Flyway, Liquibase, shadow-mode column drop, MySQL `ALGORITHM=INPLACE`
- [java/testing.md](java/testing.md) — JUnit 5, slices, `@MockitoBean` (SB 3.4+)
- [java/security-config.md](java/security-config.md) — `application.yml` secrets, Spring placeholder syntax, PII in logs
- [java/financial.md](java/financial.md) — `BigDecimal`, `RoundingMode`, `SELECT FOR UPDATE`, idempotency keys
- [java/lombok.md](java/lombok.md) — version-aware Lombok stance

## Common Anti-Patterns

**Absolutes — no legacy carveout:**
- `double` / `float` for money — use `BigDecimal` (financial safety)
- Logging full user/order objects, tokens, PAN, OTP, card numbers (PII/security baseline)
- SQL injection via string concat — use `setParameter()` always
- **`${VAR:?message}` Spring placeholder** — Bash syntax; Spring parses as `default="?message"` and silently boots with `?message` as the value. Full guidance in [java/security-config.md](java/security-config.md) §"Spring placeholder syntax trap".
- Editing a merged Flyway V-file — breaks `flyway_schema_history` checksum; immutability is non-negotiable

**DEFAULT / LEGACY carveouts (new code uses DEFAULT; existing code may stay until refactor):**
- `java.util.Date` / `SimpleDateFormat` — DEFAULT `java.time.*`; LEGACY existing util.Date in non-financial paths may stay
- H2 for tests — DEFAULT Testcontainers; LEGACY H2 schema-shape tests may stay (not behavior tests)
- Field injection (`@Autowired` on field) — DEFAULT constructor injection; LEGACY existing field-injection isn't required to be refactored opportunistically

**Other anti-patterns:**
- Swallowed exceptions; `e.printStackTrace()`; `Optional.get()` without check (use `orElseThrow(...)`)
- Static `SimpleDateFormat` (not thread-safe — use `DateTimeFormatter`)
- `new Random()` for security tokens — use `SecureRandom`
- `Thread.sleep()` in production code; long param lists (>4–5 → use DTO or `@Builder`)

## Cross-References

- `@~/.intellisense/rules/baseline/security.md` — Security checks, PII rules, migration policy
- `@~/.intellisense/rules/operational/testing.md` — Real-persistence test convention across stacks
- `@~/.intellisense/rules/operational/graph-policy.md` — Java is `candidate-supported`
- `@~/.intellisense/rules/operational/ai-regression-patterns.md` — Catalog routes P1/P2/P3 to §"Isolated Real-Persistence Tests" above
