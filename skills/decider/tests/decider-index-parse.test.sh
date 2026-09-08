#!/usr/bin/env bash
# INDEX link parsing and document enrichment.
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

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/docs/decisions"
cat >"$REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-01 | D001 | PROJ-1 | Markdown link cell | Reason one | Never | Active | [Full](D001-md-link.md) |
| 2026-01-02 | D002 | PROJ-2 | Backticked cell | Reason two | Never | Active | Full -> `D002-backtick.md` |
| 2026-01-03 | D003 | PROJ-3 | Bare filename cell | Reason three | Never | Active | Full -> D003-bare.md |
| 2026-01-04 | D004 | PROJ-4 | No document yet | Reason four | Never | Active | pending |
EOF
printf '# D001\n\n**Date**: 2026-01-01\n\nGoverns tokenone handling.\n' >"$REPO/docs/decisions/D001-md-link.md"
printf '# D002\n\n**Date**: 2026-01-02\n\nGoverns tokentwo handling.\n' >"$REPO/docs/decisions/D002-backtick.md"
printf '# D003\n\n**Date**:2026-01-03\n\nGoverns tokenthree handling.\n' >"$REPO/docs/decisions/D003-bare.md"

BAD_REPO="$TMP_ROOT/bad-repo"
mkdir -p "$BAD_REPO/docs/decisions"
cat >"$BAD_REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-02-01 | D101 | PROJ-1 | Well-formed row | Reason one | Never | Active | [Full](D101.md) |
| 2026-02-02 | D102 | PROJ-2 | Truncated row | Active |
| 2026-02-03 | D103 | PROJ-3 | Second well-formed | Reason three | Never | Active | [Full](D103.md) |
EOF

run_decisions() {
  local script="$1" repo="$2" decisions_dir="$3"
  shift 3
  set +e
  out=$( (cd "$repo" && DECISIONS_DIR="$decisions_dir" "$script" "$@") 2>"$ERR_FILE")
  rc=$?
  set -e
  err="$(<"$ERR_FILE")"
}

project_json() {
  local expression="$1"
  set +e
  projected=$(jq -cer "$expression" <<<"$out" 2>/dev/null)
  projection_rc=$?
  set -e
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

evaluate_link_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name kind argument expected actual guard
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name kind argument expected; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    run_decisions "$script" "$REPO" "$REPO/docs/decisions" "${kind%%-*}" "$argument"
    case "$kind" in
      search-ids)
        project_json 'if type == "array" then [.[].id] | join(",") else error("not an array") end'
        ;;
      get-path)
        project_json 'if type == "object" and has("path") then .path else error("missing path") end'
        expected="$REPO/docs/decisions/$expected"
        ;;
      get-empty-path)
        project_json 'if type == "object" and has("path") then .path else error("missing path") end'
        ;;
      get-date)
        project_json 'if type == "object" and has("date") then .date else error("missing date") end'
        ;;
      *)
        fail "unknown link-row projection: $kind"
        continue
        ;;
    esac
    if [[ -z "$projected" ]]; then
      projected='<empty>'
    fi
    actual="$rc~$projection_rc~$projected"
    record_row "$mode" "$name" "$actual" "0~0~$expected"
  done <<'LINK_CASES'
md-link-body~search-ids~tokenone~D001
backtick-body~search-ids~tokentwo~D002
bare-body~search-ids~tokenthree~D003
md-link-path~get-path~D001~D001-md-link.md
backtick-path~get-path~D002~D002-backtick.md
date-enrichment~get-date~D001~2026-01-01
date-unspaced~get-date~D003~2026-01-03
empty-cell-path~get-empty-path~D004~<empty>
empty-cell-date~get-date~D004~unknown
LINK_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="link table executed no rows"
    [[ -n "$only_row" ]] && guard="link table selected no row: $only_row"
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

evaluate_diagnostic_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name fixture projection expected actual first second third guard first_line
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name fixture projection expected; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    if [[ "$fixture" == malformed ]]; then
      run_decisions "$script" "$BAD_REPO" "$BAD_REPO/docs/decisions" list
    else
      run_decisions "$script" "$REPO" "$REPO/docs/decisions" list
    fi
    case "$projection" in
      ids)
        project_json 'if type == "array" then [.[].id] | join(",") else error("not an array") end'
        actual="$rc~$projection_rc~$projected"
        expected="0~0~$expected"
        ;;
      malformed-warning)
        first_line="${err%%$'\n'*}"
        actual="$rc~$first_line"
        ;;
      empty-stderr)
        actual="$rc~${err:-<empty>}"
        ;;
      *)
        fail "unknown diagnostic-row projection: $projection"
        continue
        ;;
    esac
    expected="${expected//<bad-index>/$BAD_REPO\/docs\/decisions\/INDEX.md}"
    record_row "$mode" "$name" "$actual" "$expected"
  done <<'DIAGNOSTIC_CASES'
malformed-row-results~malformed~ids~D101,D103
malformed-row-diagnostic~malformed~malformed-warning~0~notice=index-row-invalid path=<bad-index> line=6 cells=5
healthy-index-diagnostic~healthy~empty-stderr~0~<empty>
DIAGNOSTIC_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="diagnostic table executed no rows"
    [[ -n "$only_row" ]] && guard="diagnostic table selected no row: $only_row"
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

expect_control_failure() {
  local failures="$1" row="$2" description="$3"
  if [[ "$failures" == *"|$row|"* ]]; then
    pass "$description"
  else
    fail "$description (failed rows: $failures)"
  fi
}

echo "=== decisions INDEX link and get rows ==="
evaluate_link_rows "$DECISIONS" normal

echo "=== decisions malformed and healthy INDEX rows ==="
evaluate_diagnostic_rows "$DECISIONS" normal

if [[ -z "${DECIDER_TABLE_CONTROL_RUN:-}" ]]; then
  echo "=== must-fail controls ==="
  fallback_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/no-fallback/decisions" '+ [ $cell | scan' '+ [ empty | scan' 2)"
  failures="$(evaluate_link_rows "$fallback_mutant" control)"
  expect_control_failure "$failures" backtick-body "backtick fallback loss fails its row"
  expect_control_failure "$failures" bare-body "bare fallback loss fails its row"

  date_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/no-date/decisions" '      date="$parsed"' '      date="mutated"' 1)"
  failures="$(evaluate_link_rows "$date_mutant" control)"
  expect_control_failure "$failures" date-enrichment "date mutation fails the enrichment row"

  warning_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/no-warning/decisions" '| select((.value | cells | length) < 8)' '| select(false)' 1)"
  failures="$(evaluate_diagnostic_rows "$warning_mutant" control)"
  expect_control_failure "$failures" malformed-row-diagnostic "warning suppression fails the diagnostic row"

  link_table_mutant="$(decider_empty_test_table "${BASH_SOURCE[0]}" "$TMP_ROOT/empty-link-table/decider/tests/decider-index-parse.test.sh" LINK_CASES)"
  if decider_test_fails_with "$link_table_mutant" "link table executed no rows"; then
    pass "an empty link table fails its row-count guard"
  else
    fail "an empty link table missed its row-count guard ($DECIDER_CONTROL_DETAIL)"
  fi
  if decider_diagnostic_only_table_control "$link_table_mutant" "$TMP_ROOT/empty-link-table/decider/tests/diagnostic-only.test.sh" "link table executed no rows" 2; then
    pass "a link-table diagnostic without a failure is rejected"
  else
    fail "a link-table diagnostic without a failure satisfied the control ($DECIDER_CONTROL_DETAIL)"
  fi
  set +e
  selection_output="$(evaluate_link_rows "$fallback_mutant" control unknown-link-row 2>&1)"
  selection_rc=$?
  set -e
  if [[ "$selection_rc" -ne 0 && "$selection_output" == *"TABLE_GUARD:link table selected no row: unknown-link-row"* ]]; then
    pass "an unknown link row fails its selection guard"
  else
    fail "an unknown link row missed its selection guard"
  fi

  diagnostic_table_mutant="$(decider_empty_test_table "${BASH_SOURCE[0]}" "$TMP_ROOT/empty-diagnostic-table/decider/tests/decider-index-parse.test.sh" DIAGNOSTIC_CASES)"
  if decider_test_fails_with "$diagnostic_table_mutant" "diagnostic table executed no rows"; then
    pass "an empty diagnostic table fails its row-count guard"
  else
    fail "an empty diagnostic table missed its row-count guard ($DECIDER_CONTROL_DETAIL)"
  fi
  if decider_diagnostic_only_table_control "$diagnostic_table_mutant" "$TMP_ROOT/empty-diagnostic-table/decider/tests/diagnostic-only.test.sh" "diagnostic table executed no rows" 2; then
    pass "a diagnostic-table diagnostic without a failure is rejected"
  else
    fail "a diagnostic-table diagnostic without a failure satisfied the control ($DECIDER_CONTROL_DETAIL)"
  fi
  set +e
  selection_output="$(evaluate_diagnostic_rows "$warning_mutant" control unknown-diagnostic-row 2>&1)"
  selection_rc=$?
  set -e
  if [[ "$selection_rc" -ne 0 && "$selection_output" == *"TABLE_GUARD:diagnostic table selected no row: unknown-diagnostic-row"* ]]; then
    pass "an unknown diagnostic row fails its selection guard"
  else
    fail "an unknown diagnostic row missed its selection guard"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
