#!/usr/bin/env bash
# Regression tests for scheme-aware decisions next-id (vstack#956).
#
# next-id must derive the next decision number from the INDEX.md ID column, not
# from DNNN-looking tokens in prose cells, and it must preserve repositories'
# existing ID schemes such as ADR-0001.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"

run_next_id() {
  local dir="$1"
  shift
  set +e
  out=$( (cd "$dir" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH "$@" "$DECISIONS" next-id) 2>"$ERR_FILE")
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

echo "=== decisions next-id scheme inference (vstack#956) ==="

ADR_REPO="$TMP_ROOT/adr-repo"
mkdir -p "$ADR_REPO/docs/decisions"
cat >"$ADR_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | ADR-0001 | PROJ-100 | First decision | Establishes the log | Never | Active | [Full](ADR-0001-first.md) |
| 2026-01-11 | ADR-0035 | PROJ-101 | Current scheme | Summary mentions **D1:** and D1/D3/D5 prose labels | Never | Active | [Full](ADR-0035-current.md) |
EOF

run_next_id "$ADR_REPO" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "ADR next-id exits 0"
assert_eq "$out" "ADR-0036" "ADR scheme and width are preserved"
assert_eq "$err" "" "ADR next-id emits no stderr"

D_REPO="$TMP_ROOT/d-repo"
mkdir -p "$D_REPO/docs/decisions"
cat >"$D_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | PROJ-100 | First decision | Mentions unrelated D999 prose token | Never | Active | [Full](D001-first.md) |
EOF

run_next_id "$D_REPO" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "D next-id exits 0"
assert_eq "$out" "D002" "prose DNNN token does not affect next-id"

MIXED_REPO="$TMP_ROOT/mixed-repo"
mkdir -p "$MIXED_REPO/docs/decisions"
cat >"$MIXED_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D008 | PROJ-100 | Legacy decision | Existing D-prefixed row | Never | Active | [Full](D008-legacy.md) |
| 2026-01-11 | ADR-0009 | PROJ-101 | Switched scheme | Existing ADR-prefixed row | Never | Active | [Full](ADR-0009-switch.md) |
| 2026-01-12 | ADR-0035 | PROJ-102 | Latest ADR decision | Current scheme | Never | Active | [Full](ADR-0035-latest.md) |
EOF

run_next_id "$MIXED_REPO" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "mixed next-id exits 0"
assert_eq "$out" "ADR-0036" "unconfigured next-id follows the last ID-column scheme"

run_next_id "$MIXED_REPO" DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=D
assert_eq "$rc" "0" "configured prefix next-id exits 0"
assert_eq "$out" "D009" "configured prefix scans only matching ID-column rows"

BAD_LAST_REPO="$TMP_ROOT/bad-last-repo"
mkdir -p "$BAD_LAST_REPO/docs/decisions"
cat >"$BAD_LAST_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D008 | PROJ-100 | Legacy decision | Existing D-prefixed row | Never | Active | [Full](D008-legacy.md) |
| 2026-01-11 | ADR-0035 | PROJ-101 | Latest numeric decision | Existing ADR-prefixed row | Never | Active | [Full](ADR-0035-latest.md) |
| 2026-01-12 | ADR-current | PROJ-102 | Unparseable final ID | Current row has no numeric suffix | Never | Active | [Full](ADR-current.md) |
EOF

run_next_id "$BAD_LAST_REPO" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "1" "unparseable final ID exits nonzero"
assert_eq "$out" "" "unparseable final ID emits no stdout"
assert_contains "$err" "ADR-current" "unparseable final ID names the bad ID"
assert_contains "$err" "DECISION_ID_PREFIX" "unparseable final ID points at explicit scheme configuration"

run_next_id "$BAD_LAST_REPO" DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=ADR-
assert_eq "$rc" "0" "configured prefix bypasses unparseable final-ID inference"
assert_eq "$out" "ADR-0036" "configured prefix still scans matching numeric rows"

EMPTY_REPO="$TMP_ROOT/empty-repo"
mkdir -p "$EMPTY_REPO/docs/decisions"
cat >"$EMPTY_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
EOF

run_next_id "$EMPTY_REPO" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "empty index next-id exits 0"
assert_eq "$out" "D001" "empty index keeps the default DXXX scheme"

run_next_id "$EMPTY_REPO" DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=ADR- DECISION_ID_WIDTH=4
assert_eq "$rc" "0" "configured empty index next-id exits 0"
assert_eq "$out" "ADR-0001" "configured empty index supports custom scheme"

run_next_id "$EMPTY_REPO" DECISIONS_DIR=docs/decisions DECISION_ID_WIDTH=zero
assert_eq "$rc" "1" "invalid width exits nonzero"
assert_contains "$err" "DECISION_ID_WIDTH" "invalid width names DECISION_ID_WIDTH"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
