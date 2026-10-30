#!/usr/bin/env python3
"""
Scenario A — mechanical demonstration of P2 (SELECT/projection omission).

Self-contained Python stdlib demo that proves the persistence-path +
value-assertion rule (rules/operational/testing.md §Persistence-Path Rule
for Shape/Query Changes) catches the bug class P2 from
rules/operational/ai-regression-patterns.md.

It uses only sqlite3 + json + sys (stdlib) — no Laravel, no external
service repo, no test framework. The demonstration is the same mechanism
that would fire in a Laravel RefreshDatabase feature test, a Go
httptest+sqlite handler test, or a Python pytest+SQLAlchemy test, but
stripped to the essential SQL-projection / value-assertion interaction.

Run:
    python3 tests/scenario_a_select_omission/demo.py

Expected:
    BEFORE (buggy projection): VALUE ASSERTION: FAIL
    AFTER  (fixed projection): VALUE ASSERTION: PASS
    exit code 0 (invariant: BEFORE fails AND AFTER passes)
"""
import json
import sqlite3
import sys


def setup_db() -> sqlite3.Connection:
    """In-memory SQLite, schema, and a fixture row with non-null notification_settings."""
    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE TABLE users ("
        "  id INTEGER PRIMARY KEY,"
        "  email TEXT NOT NULL,"
        "  notification_settings TEXT"
        ")"
    )
    conn.execute(
        "INSERT INTO users(id, email, notification_settings) VALUES (?, ?, ?)",
        (1, "u@x.com", json.dumps({"email": True, "sms": False})),
    )
    conn.commit()
    return conn


def buggy_get_profile(conn: sqlite3.Connection, user_id: int) -> dict:
    """BEFORE fix — projection omits notification_settings.

    The response shape claims to carry the field, but the SELECT clause
    never read it from the DB, so the rendered value is None. This is the
    P2 bug class verbatim: response shape change without corresponding
    query change.
    """
    cur = conn.execute("SELECT id, email FROM users WHERE id = ?", (user_id,))
    row = cur.fetchone()
    if row is None:
        return {"data": None}
    user_id_val, email = row
    return {
        "data": {
            "id": user_id_val,
            "email": email,
            "notification_settings": None,
        }
    }


def fixed_get_profile(conn: sqlite3.Connection, user_id: int) -> dict:
    """AFTER fix — projection includes notification_settings."""
    cur = conn.execute(
        "SELECT id, email, notification_settings FROM users WHERE id = ?",
        (user_id,),
    )
    row = cur.fetchone()
    if row is None:
        return {"data": None}
    user_id_val, email, ns_json = row
    return {
        "data": {
            "id": user_id_val,
            "email": email,
            "notification_settings": json.loads(ns_json) if ns_json else None,
        }
    }


def assert_value(response: dict) -> None:
    """Value-assertion mandated by testing.md §Persistence-Path Rule.

    Equivalent to:
      Laravel:  $response->assertJsonPath('data.notification_settings.email', true);
      Python:   assert body["data"]["notification_settings"]["email"] is True
      Go:       if got.NotificationSettings.Email != true { t.Errorf(...) }
    A key-only assertion (`'notification_settings' in body['data']`) would
    incorrectly pass against None and miss P2.
    """
    ns = response["data"]["notification_settings"]
    assert ns is not None, (
        "notification_settings is None — projection omitted the column. "
        "This is exactly the P2 bug class."
    )
    assert ns["email"] is True, f"expected email=True, got {ns!r}"


def run(label: str, response: dict) -> bool:
    print(f"\n=== {label} ===")
    print(f"response: {json.dumps(response, indent=2)}")
    try:
        assert_value(response)
        print("VALUE ASSERTION: PASS")
        return True
    except AssertionError as e:
        print(f"VALUE ASSERTION: FAIL — {e}")
        return False


def main() -> int:
    conn = setup_db()

    buggy_response = buggy_get_profile(conn, 1)
    buggy_passed = run("BEFORE (buggy projection — SELECT omits column)", buggy_response)

    fixed_response = fixed_get_profile(conn, 1)
    fixed_passed = run("AFTER (fixed projection — SELECT includes column)", fixed_response)

    print("\n=== Scenario A summary ===")
    print(f"  BEFORE assertion failed (bug exposed)? {'YES' if not buggy_passed else 'NO'}")
    print(f"  AFTER assertion passed (fix verified)? {'YES' if fixed_passed else 'NO'}")

    if (not buggy_passed) and fixed_passed:
        print("\nScenario A mechanically demonstrated. P2 caught by value-assertion.")
        return 0
    print("\nScenario A demo invariant violated — investigate.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
