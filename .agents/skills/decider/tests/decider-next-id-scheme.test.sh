#!/usr/bin/env bash
# Scheme-aware decisions next-id rows.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"
# shellcheck source=lib/mutate-script.sh
source "$TEST_DIR/lib/mutate-script.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

make_index() {
  local repo="$1"
  mkdir -p "$repo/docs/decisions"
}

ADR_REPO="$TMP_ROOT/adr-repo"
make_index "$ADR_REPO"
cat >"$ADR_REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | ADR-0001 | PROJ-100 | First decision | Establishes the log | Never | Active | [Full](ADR-0001-first.md) |
| 2026-01-11 | ADR-0035 | PROJ-101 | Current scheme | Summary mentions **D1:** and D1/D3/D5 prose labels | Never | Active | [Full](ADR-0035-current.md) |
EOF

D_REPO="$TMP_ROOT/d-repo"
make_index "$D_REPO"
cat >"$D_REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | PROJ-100 | First decision | Mentions unrelated D999 prose token | Never | Active | [Full](D001-first.md) |
EOF

MIXED_REPO="$TMP_ROOT/mixed-repo"
make_index "$MIXED_REPO"
cat >"$MIXED_REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D008 | PROJ-100 | Legacy decision | Existing D-prefixed row | Never | Active | [Full](D008-legacy.md) |
| 2026-01-11 | ADR-0009 | PROJ-101 | Switched scheme | Existing ADR-prefixed row | Never | Active | [Full](ADR-0009-switch.md) |
| 2026-01-12 | ADR-0035 | PROJ-102 | Latest ADR decision | Current scheme | Never | Active | [Full](ADR-0035-latest.md) |
EOF

BAD_LAST_REPO="$TMP_ROOT/bad-last-repo"
make_index "$BAD_LAST_REPO"
cat >"$BAD_LAST_REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D008 | PROJ-100 | Legacy decision | Existing D-prefixed row | Never | Active | [Full](D008-legacy.md) |
| 2026-01-11 | ADR-0035 | PROJ-101 | Latest numeric decision | Existing ADR-prefixed row | Never | Active | [Full](ADR-0035-latest.md) |
| 2026-01-12 | ADR-current | PROJ-102 | Unparseable final ID | Current row has no numeric suffix | Never | Active | [Full](ADR-current.md) |
EOF

EMPTY_REPO="$TMP_ROOT/empty-repo"
make_index "$EMPTY_REPO"
cat >"$EMPTY_REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
EOF

run_next_id() {
  local script="$1" repo="$2" environment="$3"
  set +e
  case "$environment" in
    default)
      out=$( (cd "$repo" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH DECISIONS_DIR=docs/decisions "$script" next-id) 2>"$ERR_FILE")
      ;;
    d-prefix)
      out=$( (cd "$repo" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=D "$script" next-id) 2>"$ERR_FILE")
      ;;
    adr-prefix)
      out=$( (cd "$repo" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=ADR- "$script" next-id) 2>"$ERR_FILE")
      ;;
    adr-configured)
      out=$( (cd "$repo" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH DECISIONS_DIR=docs/decisions DECISION_ID_PREFIX=ADR- DECISION_ID_WIDTH=4 "$script" next-id) 2>"$ERR_FILE")
      ;;
    invalid-width)
      out=$( (cd "$repo" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH DECISIONS_DIR=docs/decisions DECISION_ID_WIDTH=zero "$script" next-id) 2>"$ERR_FILE")
      ;;
    *)
      set -e
      fail "unknown next-id environment: $environment"
      return
      ;;
  esac
  rc=$?
  set -e
  err="$(<"$ERR_FILE")"
}

record_row() {
  local mode="$1" name="$2" actual="$3" expected="$4"
  if [[ "$actual" == "$expected" ]]; then
    if [[ "$mode" == normal ]]; then
      pass "$name"
    fi
  else
    if [[ "$mode" == normal ]]; then
      fail "$name (expected: $expected; got: $actual)"
    else
      table_failures+="|$name|"
    fi
  fi
}

evaluate_next_id_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name repo_name environment expected_status
  local stdout_rule expected_stdout stderr_rule repo actual_stdout actual_stderr actual expected guard
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name repo_name environment expected_status stdout_rule expected_stdout stderr_rule; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    repo="$TMP_ROOT/$repo_name"
    run_next_id "$script" "$repo" "$environment"
    case "$stdout_rule" in
      exact) actual_stdout="$out" ;;
      ignore) actual_stdout=ignored; expected_stdout=ignored ;;
      *) fail "unknown stdout rule: $stdout_rule"; continue ;;
    esac
    case "$stderr_rule" in
      empty)
        actual_stderr="$err"
        expected=""
        ;;
      ignore)
        actual_stderr=ignored
        expected=ignored
        ;;
      bad-id-prefix)
        actual_stderr=0,0
        [[ "$err" == *ADR-current* ]] && actual_stderr=1,0
        [[ "$err" == *ADR-current* && "$err" == *DECISION_ID_PREFIX* ]] && actual_stderr=1,1
        expected=1,1
        ;;
      width)
        actual_stderr=0
        [[ "$err" == *DECISION_ID_WIDTH* ]] && actual_stderr=1
        expected=1
        ;;
      *) fail "unknown stderr rule: $stderr_rule"; continue ;;
    esac
    actual="$rc~$actual_stdout~$actual_stderr"
    record_row "$mode" "$name" "$actual" "$expected_status~$expected_stdout~$expected"
  done <<'NEXT_ID_CASES'
inferred-adr~adr-repo~default~0~exact~ADR-0036~empty
ignore-prose-id~d-repo~default~0~exact~D002~ignore
latest-scheme~mixed-repo~default~0~exact~ADR-0036~ignore
configured-prefix~mixed-repo~d-prefix~0~exact~D009~ignore
unparseable-last-id~bad-last-repo~default~1~exact~~bad-id-prefix
configured-prefix-after-bad-id~bad-last-repo~adr-prefix~0~exact~ADR-0036~ignore
empty-default~empty-repo~default~0~exact~D001~ignore
empty-configured~empty-repo~adr-configured~0~exact~ADR-0001~ignore
invalid-width~empty-repo~invalid-width~1~ignore~~width
NEXT_ID_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="next-ID table executed no rows"
    [[ -n "$only_row" ]] && guard="next-ID table selected no row: $only_row"
    if [[ "$mode" == normal ]]; then
      fail "$guard"
      return 1
    else
      printf 'TABLE_GUARD:%s' "$guard"
      return 1
    fi
  fi
  if [[ "$mode" == control ]]; then
    printf '%s' "$table_failures"
  fi
}

echo "=== decisions next-id scheme rows ==="
evaluate_next_id_rows "$DECISIONS" normal

if [[ -z "${DECIDER_TABLE_CONTROL_RUN:-}" ]]; then
  echo "=== must-fail controls ==="
  arithmetic_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/wrong-next-id/decisions" '$((max_num + 1))' '$((max_num + 2))' 1)"
  failures="$(evaluate_next_id_rows "$arithmetic_mutant" control inferred-adr)"
  if [[ "$failures" == *'|inferred-adr|'* ]]; then
    pass "wrong next ID fails the inferred scheme row"
  else
    fail "wrong next ID did not fail the inferred scheme row"
  fi

  next_id_table_mutant="$(decider_empty_test_table "${BASH_SOURCE[0]}" "$TMP_ROOT/empty-next-id-table/decider/tests/decider-next-id-scheme.test.sh" NEXT_ID_CASES)"
  if decider_test_fails_with "$next_id_table_mutant" "next-ID table executed no rows"; then
    pass "an empty next-ID table fails its row-count guard"
  else
    fail "an empty next-ID table missed its row-count guard ($DECIDER_CONTROL_DETAIL)"
  fi
  if decider_diagnostic_only_table_control "$next_id_table_mutant" "$TMP_ROOT/empty-next-id-table/decider/tests/diagnostic-only.test.sh" "next-ID table executed no rows" 1; then
    pass "a next-ID-table diagnostic without a failure is rejected"
  else
    fail "a next-ID-table diagnostic without a failure satisfied the control ($DECIDER_CONTROL_DETAIL)"
  fi
  set +e
  selection_output="$(evaluate_next_id_rows "$arithmetic_mutant" control unknown-next-id-row 2>&1)"
  selection_rc=$?
  set -e
  if [[ "$selection_rc" -ne 0 && "$selection_output" == *"TABLE_GUARD:next-ID table selected no row: unknown-next-id-row"* ]]; then
    pass "an unknown next-ID row fails its selection guard"
  else
    fail "an unknown next-ID row missed its selection guard"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
