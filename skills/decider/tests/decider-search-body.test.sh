#!/usr/bin/env bash
# Body search, scoring, and result ordering.
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

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/docs/decisions"
cat >"$REPO/docs/decisions/INDEX.md" <<'EOF'
| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-01 | D027 | CC-1 | Performance measurement stack | Needs stable baselines | Never | Active | [D027](D027-perf.md) |
| 2026-01-02 | D046 | CC-2 | Dev surface feature gating | Keeps prod lean | Never | Active | [D046](D046-gating.md) |
| 2026-01-03 | D047 | CC-3 | Signature forgery guard | Prevents forgery | Never | Active | [D047](D047-forgery.md) |
| 2026-01-04 | D048 | KEN-9001 | Retired runner layout | Lives in dormant tools-runner code | Never | Removed | `D048-runner.md` |
EOF
printf '# D027\n\nBenchmarks run in a hermetic sandbox against forgery and host drift.\n' >"$REPO/docs/decisions/D027-perf.md"
printf '# D046\n\nClippy lints are enforced on the dev surface.\n' >"$REPO/docs/decisions/D046-gating.md"
printf '# D047\n\nGuards against forgery of signatures.\n' >"$REPO/docs/decisions/D047-forgery.md"

run_search() {
  local script="$1" query="$2"
  set +e
  out=$( (cd "$REPO" && DECISIONS_DIR="$REPO/docs/decisions" "$script" search "$query") 2>/dev/null)
  rc=$?
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

evaluate_search_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name query projection expected setup
  local projected projection_rc actual guard
  local executed_rows=0
  table_failures=""
  while IFS='~' read -r name query projection expected setup; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    if [[ "$setup" == stray ]]; then
      printf 'hermetic stray note not linked from INDEX\n' >"$REPO/docs/decisions/STRAY.md"
    fi
    run_search "$script" "$query"
    set +e
    case "$projection" in
      ids)
        projected=$(jq -cer 'if type == "array" then [.[].id] else error("not an array") end' <<<"$out" 2>/dev/null)
        ;;
      sorted-ids)
        projected=$(jq -cer 'if type == "array" then [.[].id] | sort else error("not an array") end' <<<"$out" 2>/dev/null)
        ;;
      status-rationale)
        projected=$(jq -cer 'if type == "array" then [.[] | "\(.id)|\(.status)|\(.rationale)"] | join(";") else error("not an array") end' <<<"$out" 2>/dev/null)
        ;;
      status-path)
        projected=$(jq -cer 'if type == "array" then [.[] | "\(.id)|\(.status)|\(.path | sub(".*/"; ""))"] | join(";") else error("not an array") end' <<<"$out" 2>/dev/null)
        ;;
      ids-scores)
        projected=$(jq -cer 'if type == "array" then [.[] | "\(.id):\(.score)"] | join(",") else error("not an array") end' <<<"$out" 2>/dev/null)
        ;;
      *)
        set -e
        fail "unknown search-row projection: $projection"
        continue
        ;;
    esac
    projection_rc=$?
    set -e
    actual="$rc~$projection_rc~$projected"
    record_row "$mode" "$name" "$actual" "0~0~$expected"
  done <<'SEARCH_CASES'
body-hermetic~hermetic~ids~["D027"]~none
body-clippy~clippy~ids~["D046"]~none
summary-body-score~forgery~ids-scores~D047:4.5,D027:0.5~none
body-score~hermetic~ids-scores~D027:0.5~none
and-across-fields~performance hermetic~ids~["D027"]~none
and-across-decisions-miss~hermetic gating~ids~[]~none
regex-bodies~hermetic|clippy~sorted-ids~["D027","D046"]~none
keyword-miss~zzz-absent-token~ids~[]~none
unindexed-file~hermetic~ids~["D027"]~stray
status-keyword~dormant~status-rationale~D048|Removed|Lives in dormant tools-runner code~none
status-active-keyword~hermetic~status-rationale~D027|Active|Needs stable baselines~none
status-regex~dormant|zzz-absent-token~status-rationale~D048|Removed|Lives in dormant tools-runner code~none
status-issue~--issue=KEN-9001~status-rationale~D048|Removed|Lives in dormant tools-runner code~none
removed-path-keyword~dormant~status-path~D048|Removed|~none
removed-path-regex~dormant|zzz-absent-token~status-path~D048|Removed|~none
removed-path-issue~--issue=KEN-9001~status-path~D048|Removed|~none
active-path-keyword~hermetic~status-path~D027|Active|D027-perf.md~none
SEARCH_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="body-search table executed no rows"
    [[ -n "$only_row" ]] && guard="body-search table selected no row: $only_row"
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

echo "=== decisions body-search rows ==="
evaluate_search_rows "$DECISIONS" normal

echo "=== must-fail control ==="
ordering_mutant="$(decider_mutate_script "$TMP_ROOT/no-score-sort/decisions" '] | sort_by(-.score) | .[:$limit]' '] | .[:$limit]' 1)"
failures="$(evaluate_search_rows "$ordering_mutant" control summary-body-score)"
if [[ "$failures" == *'|summary-body-score|'* ]]; then
  pass "missing score sort fails the ranking row"
else
  fail "missing score sort did not fail the ranking row"
fi

fields_mutant="$(decider_mutate_script "$TMP_ROOT/no-status-rationale/decisions" '      {id, decision, status, rationale, path}' '      {id, decision, path}' 1)"
failures="$(evaluate_search_rows "$fields_mutant" control status-issue)"
if [[ "$failures" == *'|status-issue|'* ]]; then
  pass "rows without status and rationale fail the issue row"
else
  fail "rows without status and rationale did not fail the issue row"
fi

removed_mutant="$(decider_mutate_script "$TMP_ROOT/removed-path/decisions" 'then .path = "" else' 'then . else' 1)"
failures="$(evaluate_search_rows "$removed_mutant" control removed-path-keyword)"
if [[ "$failures" == *'|removed-path-keyword|'* ]]; then
  pass "a Removed row's deleted path fails the Removed path row"
else
  fail "a Removed row's deleted path did not fail the Removed path row"
fi

echo "=== get on a Removed row ==="
get_removed() { # SCRIPT — prints path|rationale for D048
  (cd "$REPO" && DECISIONS_DIR="$REPO/docs/decisions" "$1" get D048) 2>/dev/null | jq -r '"\(.path)|\(.rationale)"'
}
if [[ "$(get_removed "$DECISIONS")" == "|Lives in dormant tools-runner code" ]]; then
  pass "get gives a Removed row no path and its rationale"
else
  fail "get on a Removed row (got: $(get_removed "$DECISIONS"))"
fi
if [[ "$(get_removed "$removed_mutant")" != "|Lives in dormant tools-runner code" ]]; then
  pass "a Removed row's deleted path fails the get row"
else
  fail "a Removed row's deleted path did not fail the get row"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
