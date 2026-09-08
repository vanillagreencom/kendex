#!/usr/bin/env bash
# Missing, existing, and invalid decisions directory rows.
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

NO_DIR="$TMP_ROOT/no-dir-project"
mkdir -p "$NO_DIR"
printf '[env]\nDECISIONS_DIR = "docs/decisions"\n' >"$NO_DIR/kendex.settings.toml"

UNSET_DIR="$TMP_ROOT/unset-project"
mkdir -p "$UNSET_DIR"

HAS_DIR="$TMP_ROOT/has-dir-project"
mkdir -p "$HAS_DIR/docs/decisions"
cat >"$HAS_DIR/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | PROJ-100 | Use Redis for session caching | Fast and simple | If latency degrades | Active | [Full](D001-session-caching.md) |
EOF

NOT_A_DIR="$TMP_ROOT/not-a-dir"
touch "$NOT_A_DIR"

run_decisions() {
  local script="$1" state="$2"
  shift 2
  set +e
  case "$state" in
    configured-absent)
      out=$( (cd "$NO_DIR" && env -u DECISIONS_DIR "$script" "$@") 2>"$ERR_FILE")
      ;;
    undiscovered)
      out=$( (cd "$UNSET_DIR" && env -u DECISIONS_DIR "$script" "$@") 2>"$ERR_FILE")
      ;;
    existing)
      out=$( (cd "$HAS_DIR" && env -u DECISIONS_DIR DECISIONS_DIR=docs/decisions "$script" "$@") 2>"$ERR_FILE")
      ;;
    configured-file)
      out=$( (cd "$NO_DIR" && env -u DECISIONS_DIR DECISIONS_DIR="$NOT_A_DIR" "$script" "$@") 2>"$ERR_FILE")
      ;;
    *)
      set -e
      fail "unknown directory state: $state"
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

evaluate_directory_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name state action argument expected_status
  local stdout_rule expected_stdout stderr_rule needle_one needle_two actual_stdout actual_stderr
  local projected projection_rc actual expected guard
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name state action argument expected_status stdout_rule expected_stdout stderr_rule needle_one needle_two; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    case "$action" in
      issue) run_decisions "$script" "$state" search --issue "$argument" ;;
      keyword) run_decisions "$script" "$state" search "$argument" ;;
      list|next-id|help) run_decisions "$script" "$state" "$action" ;;
      get) run_decisions "$script" "$state" get "$argument" ;;
      *) fail "unknown directory-row action: $action"; continue ;;
    esac

    case "$stdout_rule" in
      exact)
        actual_stdout="$out"
        ;;
      contains)
        actual_stdout=0
        [[ "$out" == *"$expected_stdout"* ]] && actual_stdout=1
        expected_stdout=1
        ;;
      ids)
        set +e
        projected=$(jq -cer 'if type == "array" then [.[].id] else error("not an array") end' <<<"$out" 2>/dev/null)
        projection_rc=$?
        set -e
        actual_stdout="$projection_rc:$projected"
        expected_stdout="0:$expected_stdout"
        ;;
      ignore)
        actual_stdout=ignored
        expected_stdout=ignored
        ;;
      *) fail "unknown stdout rule: $stdout_rule"; continue ;;
    esac

    case "$stderr_rule" in
      contains)
        actual_stderr=0
        [[ "$err" == *"$needle_one"* ]] && actual_stderr=1
        expected=1
        ;;
      both)
        actual_stderr=0,0
        [[ "$err" == *"$needle_one"* ]] && actual_stderr=1,0
        [[ "$err" == *"$needle_one"* && "$err" == *"$needle_two"* ]] && actual_stderr=1,1
        expected=1,1
        ;;
      empty)
        actual_stderr="$err"
        expected=""
        ;;
      ignore)
        actual_stderr=ignored
        expected=ignored
        ;;
      *) fail "unknown stderr rule: $stderr_rule"; continue ;;
    esac

    actual="$rc~$actual_stdout~$actual_stderr"
    record_row "$mode" "$name" "$actual" "$expected_status~$expected_stdout~$expected"
  done <<'DIRECTORY_CASES'
configured-absent-issue~configured-absent~issue~PROJ-557~0~exact~[]~both~docs/decisions~not present
configured-absent-keyword~configured-absent~keyword~ffi error handling~0~exact~[]~contains~not present~
configured-absent-list~configured-absent~list~~0~exact~[]~contains~not present~
configured-absent-next-id~configured-absent~next-id~~1~ignore~~contains~does not exist~
configured-absent-get~configured-absent~get~D001~1~ignore~~contains~does not exist~
undiscovered-issue~undiscovered~issue~PROJ-557~0~exact~[]~contains~no decisions directory found~
help-without-directory~undiscovered~help~~0~contains~Decision Lookup Tool~ignore~~
existing-keyword-miss~existing~keyword~zzz nonexistent term~0~exact~[]~empty~~
existing-issue-miss~existing~issue~PROJ-999~0~exact~[]~empty~~
existing-keyword-hit~existing~keyword~redis~0~ids~["D001"]~ignore~~
existing-next-id~existing~next-id~~0~exact~D002~ignore~~
configured-file-search~configured-file~issue~PROJ-557~1~exact~~contains~is not a directory~
configured-file-next-id~configured-file~next-id~~1~ignore~~contains~is not a directory~
DIRECTORY_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="directory table executed no rows"
    [[ -n "$only_row" ]] && guard="directory table selected no row: $only_row"
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

echo "=== decisions directory-state rows ==="
evaluate_directory_rows "$DECISIONS" normal

if [[ -z "${DECIDER_TABLE_CONTROL_RUN:-}" ]]; then
  echo "=== must-fail controls ==="
  old_branch='  if [[ "$DECISIONS_DIR_ABSENT" -eq 1 ]]; then'
  old_branch+=$'\n    note_missing_decisions_dir\n'
  old_branch+="    echo '[]'"
  old_branch+=$'\n    return 0\n  fi\n\n  local all'
  new_branch='  if [[ "$DECISIONS_DIR_ABSENT" -eq 1 ]]; then'
  new_branch+=$'\n    note_missing_decisions_dir\n'
  new_branch+="    echo '[]'"
  new_branch+=$'\n    return 1\n  fi\n\n  local all'
  status_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/absent-search-fails/decisions" "$old_branch" "$new_branch" 1)"
  failures="$(evaluate_directory_rows "$status_mutant" control configured-absent-issue)"
  if [[ "$failures" == *'|configured-absent-issue|'* ]]; then
    pass "absent issue-search failure fails its row"
  else
    fail "absent issue-search failure did not fail its row"
  fi
  failures="$(evaluate_directory_rows "$status_mutant" control configured-absent-keyword)"
  if [[ "$failures" == *'|configured-absent-keyword|'* ]]; then
    pass "absent keyword-search failure fails its row"
  else
    fail "absent keyword-search failure did not fail its row"
  fi

  directory_table_mutant="$(decider_empty_test_table "${BASH_SOURCE[0]}" "$TMP_ROOT/empty-directory-table/decider/tests/decider-search-missing-dir.test.sh" DIRECTORY_CASES)"
  if decider_test_fails_with "$directory_table_mutant" "directory table executed no rows"; then
    pass "an empty directory table fails its row-count guard"
  else
    fail "an empty directory table missed its row-count guard ($DECIDER_CONTROL_DETAIL)"
  fi
  if decider_diagnostic_only_table_control "$directory_table_mutant" "$TMP_ROOT/empty-directory-table/decider/tests/diagnostic-only.test.sh" "directory table executed no rows" 1; then
    pass "a directory-table diagnostic without a failure is rejected"
  else
    fail "a directory-table diagnostic without a failure satisfied the control ($DECIDER_CONTROL_DETAIL)"
  fi
  set +e
  selection_output="$(evaluate_directory_rows "$status_mutant" control unknown-directory-row 2>&1)"
  selection_rc=$?
  set -e
  if [[ "$selection_rc" -ne 0 && "$selection_output" == *"TABLE_GUARD:directory table selected no row: unknown-directory-row"* ]]; then
    pass "an unknown directory row fails its selection guard"
  else
    fail "an unknown directory row missed its selection guard"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
