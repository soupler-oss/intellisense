#!/usr/bin/env bash
# tests/test_stack_java.sh — end-to-end behavior smoke for --stack java.
#
# Distinct from test_stack_detection.sh (which validates the catalog
# architecture across all stacks). This test exercises the real
# --stack java flow against a minimal pom.xml fixture and asserts:
# (1) setup-repos.sh accepts --stack java end-to-end,
# (2) CLAUDE.md is generated and references java-patterns.md,
# (3) re-running is idempotent (no duplicate intellisense:BEGIN markers),
# (4) no unresolved {{...}} placeholders leak into committed output,
# (5) run_stack_scans wired the Java arm correctly (structural map populated),
# (6) the degraded "[TODO] List key directories" placeholder is absent.
#
# Fresh-env safe: no `git commit`, no `git config` — only `git init`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP="$(mktemp -d -t intellisense-java-smoke-XXXXXX)"
trap "rm -rf '$TMP'" EXIT

# Build a minimal but realistic Spring Boot 3.2.4 / Java 17 fixture.
mkdir -p "$TMP/src/main/java/com/example" \
         "$TMP/src/main/resources" \
         "$TMP/src/test/java"
cat > "$TMP/pom.xml" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>smoke</artifactId>
  <version>0.0.1-SNAPSHOT</version>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.2.4</version>
  </parent>
  <properties>
    <java.version>17</java.version>
  </properties>
</project>
POM
# Give run_stack_scans a real file to count.
touch "$TMP/src/main/java/com/example/Application.java"

# git init only — NO git commit and NO git config (fresh CI envs without
# user.name/email would fail on commit).
(cd "$TMP" && git init -q)

LOG="$(mktemp)"
if ! bash "$INTELLISENSE_ROOT/setup-repos.sh" --repo "$TMP" --stack java --skip-ci > "$LOG" 2>&1; then
  echo "FAIL: setup-repos.sh exited non-zero for --stack java"
  cat "$LOG"
  exit 1
fi

# Test 1: CLAUDE.md created
if [ ! -f "$TMP/CLAUDE.md" ]; then
  echo "FAIL: CLAUDE.md not created"
  exit 1
fi

# Test 2: CLAUDE.md references java-patterns.md
if ! grep -q "java-patterns.md" "$TMP/CLAUDE.md"; then
  echo "FAIL: java-patterns.md not referenced in CLAUDE.md"
  exit 1
fi

# Test 3: Idempotency — second run preserves the INTELLISENSE-MANAGED marker and
# the java-patterns.md reference; file does not grow unboundedly.
# (setup-repos.sh writes <!-- INTELLISENSE-MANAGED --> on fresh creation. The
# intellisense:BEGIN/END markers are reserved for the inject path against a
# pre-existing CLAUDE.md, which is not the flow this smoke exercises.)
lines_before=$(wc -l < "$TMP/CLAUDE.md")
bash "$INTELLISENSE_ROOT/setup-repos.sh" --repo "$TMP" --stack java --skip-ci > /dev/null 2>&1
lines_after=$(wc -l < "$TMP/CLAUDE.md")
managed_count=$(grep -c '<!-- INTELLISENSE-MANAGED -->' "$TMP/CLAUDE.md" || echo 0)
if [ "$managed_count" != "1" ]; then
  echo "FAIL: idempotency — expected 1 <!-- INTELLISENSE-MANAGED --> marker, got $managed_count"
  exit 1
fi
if ! grep -q "java-patterns.md" "$TMP/CLAUDE.md"; then
  echo "FAIL: idempotency — java-patterns.md reference lost after second run"
  exit 1
fi
# Allow modest growth (e.g. updated stack-details lines) but flag a doubling
# or unbounded growth as a real idempotency bug.
if [ "$lines_after" -gt $((lines_before * 2)) ]; then
  echo "FAIL: idempotency — file grew from $lines_before to $lines_after lines (>2x); likely duplicated content"
  exit 1
fi

# Test 4: No unresolved {{...}} placeholders leak into committed output
if grep -E '\{\{[A-Z_]+\}\}' "$TMP/CLAUDE.md" > /dev/null; then
  echo "FAIL: unresolved {{...}} placeholder in CLAUDE.md"
  grep -E '\{\{[A-Z_]+\}\}' "$TMP/CLAUDE.md"
  exit 1
fi

# Test 5: Structural scan populated in the bootstrap file (proves run_stack_scans
# wired into the Java manifest-detection arm). setup-repos.sh writes scan output
# to .intellisense-bootstrap.md (NOT CLAUDE.md) — that's the file we check.
BOOTSTRAP="$TMP/.intellisense-bootstrap.md"
if [ ! -f "$BOOTSTRAP" ]; then
  echo "FAIL: .intellisense-bootstrap.md not created — setup-repos.sh did not generate scan output"
  exit 1
fi
if ! grep -qE '\[SCANNED 95%\].*src/main/java' "$BOOTSTRAP"; then
  echo "FAIL: expected [SCANNED 95%] ... src/main/java in .intellisense-bootstrap.md — run_stack_scans not wired in Java arm"
  echo "--- .intellisense-bootstrap.md head ---"
  head -30 "$BOOTSTRAP"
  exit 1
fi

# Test 6: Degraded placeholder absent (proves the manifest-detection arm fired,
# not a fallback). Check the bootstrap file, where structural map output lives.
if grep -q '\[TODO\] List key directories' "$BOOTSTRAP"; then
  echo "FAIL: '[TODO] List key directories' present in .intellisense-bootstrap.md — structural map not populated"
  exit 1
fi

# Test 7 (advisory, non-fatal): Spring Boot version surfaced in detection output
if ! grep -qE "Spring Boot 3\.2\.4|SB.*3\.2\.4" "$LOG"; then
  echo "WARN: Spring Boot 3.2.4 not surfaced in detection log (best-effort extraction)"
fi

echo "PASS: tests/test_stack_java.sh"
