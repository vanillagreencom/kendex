#!/usr/bin/env bash
# Regression tests for decisions missing-directory handling (vstack#561).
#
# In a repository with no decisions directory, read-only lookups (search,
# list) previously exited 1 with "DECISIONS_DIR '...' does not exist", turning
# an inapplicable lookup into a workflow failure. They now emit an empty JSON
# array with a stderr note and exit 0. These tests assert that soft path for
# both the configured-but-absent and unset-undiscovered cases, and that real
# errors are preserved: zero-match searches in an existing directory are
# unchanged, a configured path that exists but is a file stays a hard error,
# and creation-workflow commands (next-id, get) still require the directory.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"

# Run the decisions script from a given directory with DECISIONS_DIR removed
# from the parent environment (pass VAR=value args to set it explicitly).
# Captures stdout in $out, stderr in $err, exit code in $rc.
run_decisions() {
  local dir="$1"
  shift
  set +e
  out=$( (cd "$dir" && env -u DECISIONS_DIR "$@" "$DECISIONS" "${ARGS[@]}") 2>"$ERR_FILE")
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "=== decisions missing decisions dir (vstack#561) ==="

# --- Project with a configured DECISIONS_DIR that does not exist -------------
# Mirrors the reported failure: vstack.settings.toml sets DECISIONS_DIR but
# the repository has no decisions directory.
NO_DIR="$TMP_ROOT/no-dir-project"
mkdir -p "$NO_DIR"
printf '[env]\nDECISIONS_DIR = "docs/decisions"\n' >"$NO_DIR/vstack.settings.toml"

ARGS=(search --issue PROJ-557)
run_decisions "$NO_DIR"
assert_eq "$rc" "0" "issue search with absent dir exits 0"
assert_eq "$out" "[]" "issue search with absent dir emits empty array"
assert_contains "$err" "docs/decisions" "issue search note names the missing dir"
assert_contains "$err" "not present" "issue search notes dir not present on stderr"

ARGS=(search "ffi error handling")
run_decisions "$NO_DIR"
assert_eq "$rc" "0" "keyword search with absent dir exits 0"
assert_eq "$out" "[]" "keyword search with absent dir emits empty array"
assert_contains "$err" "not present" "keyword search notes dir not present on stderr"

ARGS=(list)
run_decisions "$NO_DIR"
assert_eq "$rc" "0" "list with absent dir exits 0"
assert_eq "$out" "[]" "list with absent dir emits empty array"
assert_contains "$err" "not present" "list notes dir not present on stderr"

# Creation-workflow commands still require the directory.
ARGS=(next-id)
run_decisions "$NO_DIR"
assert_eq "$rc" "1" "next-id with absent dir still errors"
assert_contains "$err" "does not exist" "next-id reports missing DECISIONS_DIR"

ARGS=(get D001)
run_decisions "$NO_DIR"
assert_eq "$rc" "1" "get with absent dir still errors"
assert_contains "$err" "does not exist" "get reports missing DECISIONS_DIR"

# --- DECISIONS_DIR unset and auto-discovery finds nothing --------------------
UNSET_DIR="$TMP_ROOT/unset-project"
mkdir -p "$UNSET_DIR"

ARGS=(search --issue PROJ-557)
run_decisions "$UNSET_DIR"
assert_eq "$rc" "0" "issue search with undiscovered dir exits 0"
assert_eq "$out" "[]" "issue search with undiscovered dir emits empty array"
assert_contains "$err" "no decisions directory found" "undiscovered dir noted on stderr"

ARGS=(help)
run_decisions "$UNSET_DIR"
assert_eq "$rc" "0" "help works without a decisions dir"
assert_contains "$out" "Decision Lookup Tool" "help prints usage without a decisions dir"

# --- Existing directory: zero-match and match behavior unchanged -------------
HAS_DIR="$TMP_ROOT/has-dir-project"
mkdir -p "$HAS_DIR/docs/decisions"
cat >"$HAS_DIR/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | PROJ-100 | Use Redis for session caching | Fast and simple | If latency degrades | Active | [Full](D001-session-caching.md) |
EOF

ARGS=(search "zzz nonexistent term")
run_decisions "$HAS_DIR" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "zero-match keyword search in existing dir exits 0"
assert_eq "$out" "[]" "zero-match keyword search emits empty array"
assert_eq "$err" "" "zero-match keyword search emits no stderr note"

ARGS=(search --issue PROJ-999)
run_decisions "$HAS_DIR" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "zero-match issue search in existing dir exits 0"
assert_eq "$out" "[]" "zero-match issue search emits empty array"
assert_eq "$err" "" "zero-match issue search emits no stderr note"

ARGS=(search "redis")
run_decisions "$HAS_DIR" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "matching keyword search in existing dir exits 0"
assert_contains "$out" '"D001"' "matching keyword search returns D001"

ARGS=(next-id)
run_decisions "$HAS_DIR" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "next-id in existing dir exits 0"
assert_eq "$out" "D002" "next-id in existing dir returns D002"

# --- Configured path exists but is a file: hard error for every command ------
touch "$TMP_ROOT/not-a-dir"

ARGS=(search --issue PROJ-557)
run_decisions "$NO_DIR" DECISIONS_DIR="$TMP_ROOT/not-a-dir"
assert_eq "$rc" "1" "search with file at DECISIONS_DIR exits nonzero"
assert_eq "$out" "" "search with file at DECISIONS_DIR emits no result"
assert_contains "$err" "is not a directory" "search with file at DECISIONS_DIR reports hard error"

ARGS=(next-id)
run_decisions "$NO_DIR" DECISIONS_DIR="$TMP_ROOT/not-a-dir"
assert_eq "$rc" "1" "next-id with file at DECISIONS_DIR exits nonzero"
assert_contains "$err" "is not a directory" "next-id with file at DECISIONS_DIR reports hard error"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
