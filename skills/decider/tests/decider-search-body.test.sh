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
  local projected projection_rc actual
  table_failures=""
  while IFS='~' read -r name query projection expected setup; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
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
  done <<'CASES'
body-hermetic~hermetic~ids~["D027"]~none
body-clippy~clippy~ids~["D046"]~none
summary-body-score~forgery~ids-scores~D047:4.5,D027:0.5~none
body-score~hermetic~ids-scores~D027:0.5~none
and-across-fields~performance hermetic~ids~["D027"]~none
and-across-decisions-miss~hermetic gating~ids~[]~none
regex-bodies~hermetic|clippy~sorted-ids~["D027","D046"]~none
keyword-miss~zzz-absent-token~ids~[]~none
unindexed-file~hermetic~ids~["D027"]~stray
CASES
  if [[ "$mode" == control ]]; then
    printf '%s' "$table_failures"
  fi
}

echo "=== decisions body-search rows ==="
evaluate_search_rows "$DECISIONS" normal

echo "=== must-fail control ==="
ordering_mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/no-score-sort/decisions" '] | sort_by(-.score) | .[:$limit]' '] | .[:$limit]' 1)"
failures="$(evaluate_search_rows "$ordering_mutant" control summary-body-score)"
if [[ "$failures" == *'|summary-body-score|'* ]]; then
  pass "missing score sort fails the ranking row"
else
  fail "missing score sort did not fail the ranking row"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
