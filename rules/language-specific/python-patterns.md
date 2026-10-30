---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Python Development Rules

## Naming Conventions

**Public-vs-private rule (CRITICAL — defines module API):**
- **Public** (exported): no leading underscore — `UserBalance`, `read_file()`, `class User`
- **Private** (module-internal): single leading underscore — `_user_balance`, `_read_file()`
- **Name-mangled** (class-internal only): double leading underscore — rare

**Specific Rules:**
- **Classes**: `PascalCase` — `UserBalance`, `OrderProcessor`
- **Functions / methods**: `snake_case` — `calculate_fee`, `process_order`
- **Variables**: `snake_case` — `user_balance`, `retry_count`
- **Constants**: `UPPER_SNAKE_CASE` — `MAX_RETRIES`, `DEFAULT_TIMEOUT`
- **Modules / packages**: lowercase — `billing`, `http_client` (underscore only when needed)
- **Type variables**: `PascalCase` — `T`, `KeyT`
- **Dunder names**: reserved for Python protocol — never invent `__custom__`

**Boolean naming**:
```python
is_active = True
has_permission = False
should_retry = True
```

---

## Worktree Setup

Dependencies live in `pyproject.toml` + `poetry.lock` (both committed).

**Setup (required):**
```bash
cd /path/to/worktree && poetry install --no-interaction --no-root
```

**Verification:** `poetry run python --version`. If `poetry.lock` is out of sync, run `poetry lock --no-update` and commit before proceeding.

---

## Framework-Specific Notes

- DO NOT mix web frameworks within the same repo (FastAPI / Flask / Django pick one).
- Shared library packages: NEVER add business logic. Changes affect ALL downstream consumers.
- **FastAPI**: Pydantic models for request/response; `Depends()` for DI; `async def` handlers for I/O.
- **Django**: ORM models + migrations as code; `transaction.atomic()` + `select_for_update()` for financial mutations; signals discouraged for new code.
- **Flask**: Blueprints + application factory (`create_app()`); validate request bodies via Pydantic or marshmallow.

---

## Type Hints

- PEP 604 unions for new code: `int | None` (NOT `Optional[int]`).
- `from __future__ import annotations` at the top of every module.
- Public APIs MUST have complete annotations; internal helpers MAY skip when types are obvious.
- Financial code: `mypy --strict` clean is a build-break gate.

## Error Handling Patterns

```python
class AccountError(Exception): ...
class InsufficientFundsError(AccountError): ...

try:
    debit(account, amount)
except InsufficientFundsError as err:
    raise PaymentRejectedError("balance check failed") from err
```

- Use `raise … from err` to preserve the cause chain.
- Use `with` blocks for any resource needing cleanup (DB sessions, locks, files).
- Bare `except:` and `except Exception:` are advisory-blocked unless re-raised.

## Concurrency

- `async`/`await` for I/O-bound; never call blocking I/O from `async def` — use `asyncio.to_thread()`.
- Prefer `asyncio.TaskGroup` (3.11+) over manual `asyncio.gather()` + bare `create_task()`.
- Always pass an explicit timeout to network/DB awaits.

## Parametrized Tests (Canonical pytest Style)

```python
import pytest
from decimal import Decimal

@pytest.mark.parametrize(
    "name, amount, want, want_err",
    [
        ("basic case",     Decimal("100"),  Decimal("2"), False),
        ("zero input",     Decimal("0"),    Decimal("0"), False),
        ("negative input", Decimal("-100"), Decimal("0"), True),
    ],
)
def test_calculate_fee(name, amount, want, want_err):
    if want_err:
        with pytest.raises(ValueError):
            calculate_fee(amount)
        return
    assert calculate_fee(amount) == want, name
```

- One test file per source module: `src/foo/bar.py` → `tests/foo/test_bar.py`.
- Fixtures via `conftest.py` at the lowest scope that covers consumers.
- Coverage via `pytest-cov`; financial modules require ≥90% line coverage.

## Code Patterns

- `decimal.Decimal` for money — `float` is forbidden in financial paths.
- Timezone-aware datetimes only: `zoneinfo.ZoneInfo("UTC")` (never `pytz`).
- `select_for_update()` (Django) / `with_for_update()` (SQLAlchemy) on every balance mutation.
- `src/<package>/` layout; tests parallel under `tests/`. No top-level `__init__.py` outside packages.
- Avoid circular imports — route shared types through a small `models/` or `types.py` module.

## Isolated Real-Persistence Tests for HTTP/DB Code

For changes matching `@rules/operational/ai-regression-patterns.md §P1` (sandbox/prod divergence), `§P2` (SELECT/projection omission), or `§P3` (error state leakage): exercise the real handler + real query path. Per `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`, do NOT mock the ORM session or repository for response-shape tests — that hides projection bugs. **Note:** P4 (optimistic update + rollback) is a frontend-shaped pattern; not directly applicable to Python backend services.

### P2 — SELECT omission with SQLAlchemy + in-memory SQLite

```python
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.main import app, get_db
from app.models import Base, User

@pytest.fixture
def db_session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine, future=True)
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()

@pytest.fixture
def client(db_session):
    app.dependency_overrides[get_db] = lambda: db_session
    yield TestClient(app)
    app.dependency_overrides.clear()

def test_profile_returns_notification_settings_value_from_db(db_session, client):
    # Arrange — fixture row with a non-null value for the new field
    user = User(
        id=1,
        email="u@x.com",
        notification_settings={"email": True, "sms": False},
    )
    db_session.add(user)
    db_session.commit()

    # Act — real route, real ORM
    resp = client.get("/api/users/1/profile")

    # Assert — VALUE, not just key. If the route's query uses
    #   .options(load_only(User.id, User.email))  # forgets notification_settings
    # the response carries None and this assertion fails — exposing P2.
    assert resp.status_code == 200
    body = resp.json()
    assert body["data"]["notification_settings"]["email"] is True
    assert body["data"]["notification_settings"]["sms"] is False
```

For Django, use `pytest-django` with `--reuse-db` and `factory_boy`; the principle is identical: real ORM, real query, value assertion. For Postgres-specific behavior (JSONB operators, `SELECT FOR UPDATE`), use `testcontainers-python` instead of in-memory SQLite.

### P3 — Error state leakage (FastAPI / Flask)

When an error path is added, assert that prior request-scoped or session-scoped state does not leak into the error response.

```python
def test_failed_lookup_does_not_leak_partial_user(client, db_session):
    # Arrange — partial user (email set, profile missing)
    user = User(id=2, email="partial@x.com", notification_settings=None)
    db_session.add(user)
    db_session.commit()

    # Act — endpoint hits an error path
    resp = client.get("/api/users/2/full-profile")

    # Assert — error response must NOT carry the partial email field.
    assert resp.status_code == 404
    body = resp.json()
    assert "email" not in body  # P3: stale success state must be cleared
    assert body == {"error": "profile_not_found"}
```

### P1 — Sandbox/prod divergence (services with `SANDBOX_MODE`)

Parametrize the same assertion across both branches of the sandbox flag:

```python
@pytest.mark.parametrize("sandbox_mode", [True, False])
def test_profile_shape_parity_across_sandbox_and_prod(monkeypatch, client, sandbox_mode):
    monkeypatch.setenv("SANDBOX_MODE", "1" if sandbox_mode else "0")
    resp = client.get("/api/users/1/profile")
    assert resp.status_code == 200
    body = resp.json()
    # Both branches must carry the same field — divergence = P1 bug.
    assert "notification_settings" in body["data"]
    assert isinstance(body["data"]["notification_settings"], dict)
```

**Anti-patterns (do NOT use for risk-pattern changes):**
- `monkeypatch.setattr(app, "get_user", lambda _: User(...))` — bypasses the ORM; hides P2.
- `unittest.mock.patch("app.db.session")` returning a `MagicMock` whose `query().filter().one()` returns a hand-built object — same blind spot as the writer.
- Asserting only `resp.status_code == 200` and `"notification_settings" in body` — passes against `{"notification_settings": null}`.

**Rule of thumb:** if the test could pass when the field's value is `None` / zero-value, the test does not catch P2. Always assert a non-`None` value derived from a fixture row.
