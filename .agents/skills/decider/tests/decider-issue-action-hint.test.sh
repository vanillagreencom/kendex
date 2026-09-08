#!/usr/bin/env bash
# Unsupported issue actions and the supported issue lookup.
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

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/docs/decisions"
cat >"$PROJECT/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | CC-125 | Use Redis for session caching | Fast and simple | If latency degrades | Active | [Full](D001-session-caching.md) |
EOF

run_decisions() {
  local script="$1"
  shift
  set +e
  out=$( (cd "$PROJECT" && env -u DECISIONS_DIR DECISIONS_DIR=docs/decisions "$script" "$@") 2>"$ERR_FILE")
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

evaluate_action_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name kind argument expected actual guard
  local first second projected projection_rc
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name kind argument expected; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    case "$kind" in
      issue)
        run_decisions "$script" issue "$argument"
        first=0
        second=0
        [[ "$err" == *"Unknown action 'issue'"* ]] && first=1
        [[ "$err" == *"search --issue"* ]] && second=1
        actual="$rc~$out~$first~$second"
        ;;
      issues)
        run_decisions "$script" issues "$argument"
        first=0
        [[ "$err" == *"search --issue"* ]] && first=1
        actual="$rc~$first"
        ;;
      unknown)
        run_decisions "$script" "$argument" CC-125
        first=0
        second=0
        [[ "$err" == *"Unknown action '$argument'"* ]] && first=1
        [[ "$out" == *"Usage: decisions"* ]] && second=1
        actual="$rc~$first~$second"
        ;;
      lookup)
        run_decisions "$script" search --issue "$argument"
        set +e
        projected=$(jq -cer 'if type == "array" then [.[].id] | join(",") else error("not an array") end' <<<"$out" 2>/dev/null)
        projection_rc=$?
        set -e
        actual="$rc~$projection_rc~$projected"
        ;;
      *)
        fail "unknown action-row kind: $kind"
        continue
        ;;
    esac
    record_row "$mode" "$name" "$actual" "$expected"
  done <<'ACTION_CASES'
issue-action~issue~CC-125~1~~1~1
issues-action~issues~CC-125~1~1
generic-unknown-action~unknown~bogus~1~1~1
supported-issue-lookup~lookup~CC-125~0~0~D001
ACTION_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="action table executed no rows"
    [[ -n "$only_row" ]] && guard="action table selected no row: $only_row"
    if [[ "$mode" == normal ]]; then
      fail "$guard"
    else
      printf 'TABLE_GUARD:%s' "$guard"
      return 1
    fi
  fi
  if [[ "$mode" == control ]]; then
    printf '%s' "$table_failures"
  fi
}

echo "=== decisions issue action rows ==="
evaluate_action_rows "$DECISIONS" normal

echo "=== must-fail control ==="
lookup_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/no-issue-match/decisions" '      .[] | select(.research | test($issue + "(?![0-9])"; "i")) |' '      .[] | select(false) |' 1)"
failures="$(evaluate_action_rows "$lookup_mutant" control supported-issue-lookup)"
if [[ "$failures" == *'|supported-issue-lookup|'* ]]; then
  pass "wrong lookup result fails the supported lookup row"
else
  fail "wrong lookup result did not fail the supported lookup row"
fi

if [[ -z "${DECIDER_TABLE_CONTROL_RUN:-}" ]]; then
  action_table_mutant="$(decider_empty_test_table "${BASH_SOURCE[0]}" "$TMP_ROOT/empty-action-table/decider/tests/decider-issue-action-hint.test.sh" ACTION_CASES)"
  if decider_test_fails_with "$action_table_mutant" "action table executed no rows"; then
    pass "an empty action table fails its row-count guard"
  else
    fail "an empty action table missed its row-count guard ($DECIDER_CONTROL_DETAIL)"
  fi
  set +e
  selection_output="$(evaluate_action_rows "$lookup_mutant" control unknown-action-row 2>&1)"
  selection_rc=$?
  set -e
  if [[ "$selection_rc" -ne 0 && "$selection_output" == *"TABLE_GUARD:action table selected no row: unknown-action-row"* ]]; then
    pass "an unknown action row fails its selection guard"
  else
    fail "an unknown action row missed its selection guard"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
