---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Configuration & Security (`application.yml` + PII)

Stack-owned subfile of `java-patterns.md` (entrypoint). Covers `application.yml` / `application.properties` discipline, the Spring placeholder syntax trap, and PII rules for logging.

The Spring Boot Actuator endpoint-exposure rules live in [`spring-boot.md`](spring-boot.md) §"Spring Boot Actuator — Endpoint Exposure" — they're part of the framework-detection-gated content for Spring services.

## Format

**YAML preferred for nested config; properties OK for flat config. Don't mix within one repo.** The repo's Stack Details block (per-repo CLAUDE.md) should declare the format; new config goes in that format.

## Secrets policy

Mirrors [`security.md`](../../baseline/security.md) baseline — never restated, only enforced here. Three rules:

1. **Never commit secrets** (DB passwords, API keys, JWT signing keys, OAuth client secrets) to any `application*.yml` in the repo.
2. **Use `${ENV_VAR}` placeholders only.**
3. **Fail fast at startup** if a required env var is unset — see "Spring placeholder syntax trap" below.

## Spring placeholder syntax trap

**`${VAR:?message}` is Bash syntax, NOT Spring.** This is a real security risk — using Bash syntax in Spring silently boots with a known-bad value.

Spring's documented placeholder grammar:
- `${name}` — required; throws `PlaceholderResolutionException` at startup if unset and no other config source provides it
- `${name:default}` — optional, uses `default` if unset

Spring parses `${DB_PASSWORD:?DB_PASSWORD env var required}` as "property name = `DB_PASSWORD`, default value = `?DB_PASSWORD env var required`". When the env var is unset, Spring uses that literal string as the password and boots successfully. The service runs with a known-broken value. **This is a fail-open security hole.**

### Correct fail-fast patterns

**Option A — explicit startup validator (preferred for production secrets):**

```java
@Component
class RequiredEnvValidator {
    @Value("${DB_PASSWORD:}") private String dbPassword;   // empty default — placeholder always resolves
    @Value("${JWT_SIGNING_KEY:}") private String jwtSigningKey;

    @PostConstruct
    void validate() {
        Map<String, String> required = Map.of(
            "DB_PASSWORD", dbPassword,
            "JWT_SIGNING_KEY", jwtSigningKey
        );
        List<String> missing = required.entrySet().stream()
            .filter(e -> e.getValue() == null || e.getValue().isEmpty())
            .map(Map.Entry::getKey)
            .toList();
        if (!missing.isEmpty()) {
            throw new IllegalStateException("required env vars unset: " + missing);
        }
    }
}
```

Explicit, testable, gives a clear error message at startup. The trade-off: it's per-property boilerplate. Worth it for the handful of irreplaceable secrets.

**Option B — no default in placeholder (simplest):**

```yaml
spring:
  datasource:
    password: ${DB_PASSWORD}   # no `:default` — Spring throws PlaceholderResolutionException at startup if unset
```

Spring fails to boot with `PlaceholderResolutionException` if `DB_PASSWORD` is missing AND no other config source provides it. The "no other source" caveat matters: if a fallback `application-prod.yml` defines the property (even with an empty string), the env-var-unset condition doesn't fire.

Use Option B for the simple case, Option A when you need a specific error message or want to validate beyond presence (e.g. format-check that the key is base64).

### Anti-pattern (must reject in review)

```yaml
# WRONG — Bash syntax, not Spring
spring.datasource.password: ${DB_PASSWORD:?DB_PASSWORD env var required}

# WRONG — empty default with no validator
spring.datasource.password: ${DB_PASSWORD:}
```

Reviewers must flag and reject both. The first silently boots with `?DB_PASSWORD env var required` as the password. The second silently boots with an empty string. Both are fail-open.

## Profile activation

- **Tests:** use `@ActiveProfiles("test")` on the test class. Never rely on env-var-set profile in CI — it makes tests order-dependent.
- **Production:** set `SPRING_PROFILES_ACTIVE=prod` via the deployment manifest. Don't set `spring.profiles.active` inside committed `application.yml` — that creates implicit profile chains that surprise readers.
- **`spring.profiles.include` is forbidden in committed files** — same reason. Compose profiles via the active-set in the runtime environment, not via include directives.

## Developer-machine overrides

Keep `application-local.yml` in `.gitignore`. Spring Boot auto-loads it when present. Document the convention in the repo's onboarding so developers know where to put their local-only config (their own DB credentials, their MailHog SMTP port, etc.).

## Secret-file loading (SB 3.x)

For loading external secret files separate from `application*.yml`, Spring Boot 3.x supports `spring.config.import`:

```yaml
spring:
  config:
    import: optional:file:./secrets.yml
```

The `optional:` prefix allows the file to be missing in dev (developer-fills-via-env-var instead). **Drop the `optional:` prefix in production** — the file is the source of truth; missing-file should fail-fast.

## Example `application.yml`

```yaml
spring:
  datasource:
    # No ':default' — Spring throws PlaceholderResolutionException if env var unset.
    # Pair with @PostConstruct validator (Option A above) for explicit error messages.
    url: ${DB_URL}
    username: ${DB_USER}
    password: ${DB_PASSWORD}
    hikari:
      maximum-pool-size: ${DB_POOL_SIZE:10}
      leak-detection-threshold: 60000   # 60s — surfaces unclosed connections
  jpa:
    open-in-view: false                 # MANDATORY — prevents lazy load in controllers (N+1 trap)
    hibernate:
      ddl-auto: validate                # NEVER 'update' or 'create' in any committed profile
    properties:
      hibernate.jdbc.time_zone: UTC     # avoids tz drift on persisted timestamps
  flyway:
    enabled: true
    locations: classpath:db/migration
    baseline-on-migrate: false          # forces explicit baseline; never silent
    out-of-order: false                 # forces strict ordering — required for audit
logging:
  level:
    root: INFO
    com.example: DEBUG
    org.hibernate.SQL: ${SQL_LOG_LEVEL:WARN}   # never DEBUG in committed prod profile (PII leak — see "PII in Logs" below)
```

## Anti-patterns in `application.yml`

- `spring.jpa.hibernate.ddl-auto: update` (or `create`) in any committed profile — Flyway/Liquibase owns schema, not Hibernate
- `spring.jpa.open-in-view: true` (Spring Boot's default) — causes session-per-request, lazy-load in controllers, N+1 traps
- Plaintext passwords in committed `application*.yml`
- `application-prod.yml` containing real production creds (committed)
- `org.hibernate.SQL: DEBUG` in committed prod profile — logs every query with bound parameters, leaking PII into log aggregator

## PII in Logs

PII includes (mirrors [`security.md`](../../baseline/security.md) baseline): name, email, phone, address, date of birth, government IDs, device fingerprints, IP addresses.

**Rules:**
1. SLF4J parameterized logging only — `log.info("user {} placed order {}", userId, orderId)`. Never string concat (`log.info("user " + userId + ...)`).
2. **Never log full user/order objects** — `log.info("user: {}", user)` invokes `User.toString()` and dumps everything, including email/phone/address. Log the ID only.
3. **Never log tokens, card numbers, PAN, OTP, passwords** — even on error. Mask if you must reference them: `cardNumber.substring(0, 4) + "****"`.
4. **MDC for trace correlation:** `MDC.put("traceId", id)` at the request boundary + `%X{traceId}` in the logback pattern. Lets you grep by trace ID without putting it in every log statement.
5. **Structured logging naming:** prefer `log.info("fetch_market slug={}", slug)` over English-prose log lines. `<verb>_<noun>` event-name + `key=value` params parses cleanly in Kibana/Datadog.

```java
// PASS
log.info("create_order user_id={} total_cents={}", userId, totalCents);
log.error("order_create_failed user_id={} reason={}", userId, ex.getMessage(), ex);

// FAIL
log.info("Creating order for " + user + " with total " + total);   // string concat + full user dump
log.info("Card: " + cardNumber);                                    // PAN in logs
log.info("User: {}", user);                                         // full object via toString()
```

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint, including the `${VAR:?}` anti-pattern callout in §"Common Anti-Patterns"
- [`spring-boot.md`](spring-boot.md) — Spring Boot Actuator endpoint exposure (also security-critical config)
- [`../../baseline/security.md`](../../baseline/security.md) — PII baseline rules, secret management, fork workflow
