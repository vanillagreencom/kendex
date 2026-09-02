#!/usr/bin/env bash
# Regression tests for ci-logs against a log past the pipe buffer (KEN-1143).
#
# Three sites in ci-logs.sh changed behaviour once the log outgrew a kernel
# bound, and `--lines` cannot hold a log under either: it caps lines, not bytes.
#
#   classify_error_type  `echo "$logs" | grep -qi PATTERN` — grep exits on its
#                        first match and SIGPIPEs the writer past the 64KB pipe
#                        buffer. In condition position errexit does not fire, so
#                        141 reads as a plain no-match and a log naming its own
#                        failure falls through to the job-name heuristics.
#   safe/json output     `jq -n --arg logs "$logs"` — a single argv string over
#                        MAX_ARG_STRLEN (128KB) is refused by the kernel, taking
#                        the whole result with it: nothing on stdout at all.
#   log_fetch_failed     `printf '%s' "$logs" | tr '\n' ' ' | head -c 300` —
#                        head closes after 300 bytes, and that assignment has no
#                        guard, so errexit kills the branch that exists to
#                        report the fetch failure: exit 141, no JSON, no message.
#
# One staged log clears both bounds, at the default `--lines`. Each site
# reverted to its old form reddens this suite.
#
# Run: bash skills/github/tests/ci-logs-large-log.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="$TEST_DIR/../scripts/commands/ci-logs.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

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

assert_ge() {
  local got="$1" bound="$2" name="$3"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -ge "$bound" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: >= %s\n        got:    %s\n' "$name" "$bound" "$got"
  fi
}

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

run_ci_logs() { (PATH="$TMP_ROOT/bin:$PATH" bash "$CMD" "$@"); }

# 100 lines of ~1.4KB, so the log clears both bounds this command has to
# survive: the 64KB pipe buffer, by more than a reader takes before closing, so
# the writer is still blocked when it does; and MAX_ARG_STRLEN, the kernel's
# 128KB cap on one argv string, which the log would cross if it were passed to
# jq as an argument. 100 lines is the DEFAULT `--lines` window, so nothing here
# depends on the caller asking for more: `--lines` caps lines and never bytes.
# The padding carries none of the classifier's other patterns, so only the
# `clippy` branch can match, and the marker sits on the first line — where the
# reader closes with the whole log still to write.
padding="$(printf 'x%.0s' {1..1400})"
{
  printf 'warning: clippy::needless_borrow on this line\n'
  for _i in $(seq 1 99); do
    printf '2026-09-02T10:00:00Z  compiling crate %s\n' "$padding"
  done
} > "$TMP_ROOT/big.log"
log_bytes=$(wc -c <"$TMP_ROOT/big.log")
assert_ge "$log_bytes" 131072 "staged log clears the pipe buffer and the single-argument cap"
assert_eq "$(wc -l <"$TMP_ROOT/big.log")" "100" "staged log fits the default --lines window whole"

# The job name matches none of the fallback heuristics, so the log is the only
# thing that can produce a classification other than "unknown".
gh_stub_answer pr-view '{"title":"a pr"}'
gh_stub_answer pr-checks '[{"name":"nightly guard","state":"FAILURE","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/123/job/456","workflow":"CI"}]'
gh_stub_answer run-view "$(cat "$TMP_ROOT/big.log")"

echo "=== a log past the pipe buffer is classified and returned whole (KEN-1143) ==="
# The exit status is captured rather than inherited: a log the kernel refuses to
# pass in argv takes the command down mid-run, and that has to report as a red
# assertion here, not as the suite aborting before it makes any.
set +e
out="$(run_ci_logs 42 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "0" "the command survives a log past both bounds"
assert_eq "$(jq -r '.error_type' <<<"$out")" "clippy" "large log classifies by its content, not the job name"
assert_eq "$(jq -r '.logs | length' <<<"$out")" "$((log_bytes - 1))" "the whole retained window reaches the JSON"
assert_eq "$(jq -r '.run_id' <<<"$out")" "123" "the failing run is the one reported"

echo "=== a large gh error is reported, not swallowed (KEN-1143) ==="
gh_stub_reset
gh_stub_answer pr-view '{"title":"a pr"}'
gh_stub_answer pr-checks '[{"name":"nightly guard","state":"FAILURE","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/123/job/456","workflow":"CI"}]'
gh_stub_fail run-view 1 "$(cat "$TMP_ROOT/big.log")"

set +e
out="$(run_ci_logs 42)"
rc=$?
set -e
assert_eq "$rc" "1" "a log-fetch failure exits 1"
assert_eq "$(jq -r '.error' <<<"$out")" "log_fetch_failed" "the failure is reported as log_fetch_failed"
assert_eq "$(jq -r '.details | length' <<<"$out")" "300" "the detail is clipped to 300 characters"
assert_eq "$(jq -r '.details | test("\n") | not' <<<"$out")" "true" "the detail is flattened to one line"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
