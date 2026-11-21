#!/usr/bin/env bash
# json_or_default (scripts/lib/github-api.sh): the answer is the command's
# stdout alone, judged against the expected JSON type; stderr reaches the
# caller only when the command fails or its answer is not that type. Every
# caller that reads gh JSON through it (pr-merge's review read, pr-list-ready,
# ci-logs, pr-cross-check) reads this way.
#
# A row is `label^status^stderr^stdout^type^rc^out^err`, fields separated by `^`:
#   status  the exit status the staged `gh pr view` returns
#   stderr  what it writes to stderr, `-` for nothing
#   stdout  what it writes to stdout, `-` for nothing
#   type    the JSON type the call expects
#   rc      json_or_default's exit status
#   out     its stdout, exactly
#   err     `none` for an empty stderr, `stderr` for one that carries the
#           command's stderr, `both` for one that carries its stdout too
set -euo pipefail

# The lib derives PROJECT_ROOT through git at source time.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "json-or-default: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "json-or-default: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "json-or-default: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"
PATH="$TMP_ROOT/bin:$PATH"

# gh 2.105.0's `gh pr view` opens this block on stderr on a successful read.
HINT='hint: if you need to wait for this pull request to be reviewed, merged, or closed'
REVIEW='{"reviewDecision":"APPROVED","latestReviews":[]}'
CHECKS='[{"name":"Lint","state":"SUCCESS"}]'

ROWS="\
an object on stdout beside a success hint is the answer^0^$HINT^$REVIEW^object^0^$REVIEW^none
an array on stdout beside a success hint is the answer^0^$HINT^$CHECKS^array^0^$CHECKS^none
a failed command answers the fallback and passes its stderr on^1^HTTP 502^-^object^1^{}^stderr
a failed command's stdout is passed on beside its stderr^1^HTTP 502^partial^object^1^{}^both
a non-JSON answer answers the fallback and passes both streams on^0^$HINT^not json^object^2^{}^both
an answer of the wrong type answers the fallback^0^$HINT^$CHECKS^object^2^{}^both
an empty answer answers the fallback^0^$HINT^-^object^2^{}^stderr
"

while IFS='^' read -r label status stderr stdout type want_rc want_out want_err; do
  [[ -n "$label" ]] || continue
  gh_stub_reset
  # An empty stream is staged as a bare newline, which reads back empty.
  stage_err="$stderr" stage_out="$stdout"
  [[ "$stage_err" != - ]] || stage_err=""
  [[ "$stage_out" != - ]] || stage_out=""
  gh_stub_fail pr-view "$status" "$stage_err" "$stage_out"
  rc=0
  (
    cd "$TMP_ROOT/repo"
    # shellcheck source=../scripts/lib/github-api.sh
    . "$REPO_ROOT/skills/github/scripts/lib/github-api.sh"
    fallback='[]'
    [[ "$type" == array ]] || fallback='{}'
    json_or_default "$fallback" "$type" gh pr view 1 --json reviewDecision,latestReviews
  ) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  out="$(cat "$TMP_ROOT/out")"
  err="$(cat "$TMP_ROOT/err")"
  got_err=none
  if [[ -n "$err" ]]; then
    got_err=other
    if [[ "$stderr" != - && "$err" == *"$stderr"* ]]; then
      got_err=stderr
      [[ "$stdout" == - || "$err" != *"$stdout"* ]] || got_err=both
    fi
  fi
  assert_eq "rc=$rc out=$out err=$got_err" "rc=$want_rc out=$want_out err=$want_err" "$label"
done <<<"$ROWS"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
