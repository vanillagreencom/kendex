#!/usr/bin/env bash
# Regression tests for queue-wait's argument validation and -h/--help
# (kendex#972, kendex#981, KEN-556), split from queue_wait.sh at this seam
# (the poll/verdict suites and their fixture stubs live there). Every case
# terminates in the arg parser, before auth or any gh call; the recording
# gh stub makes any gh invocation visible.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/argbin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
cat > "$TMP_ROOT/argbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/argval-gh.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/argbin/gh"

run_qw() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/argbin:$PATH" \
       .agents/skills/orch/scripts/queue-wait "$@")
}

echo "=== queue-wait argument validation ==="

# --- 15. argument validation: poll_interval > max_wait (kendex#972) ---------
# The reported invocation shape: `queue-wait 481 1800` reads as poll=1800,
# max=600 and can only ever poll once while overshooting the budget.
err="$TMP_ROOT/e15"
run_qw 1 1800 600 --json --no-check-probe >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "poll_interval > max_wait exits 2" "$err"
assert_contains "$(cat "$err")" "exceeds max_wait" "swapped-arg error names the cause" "$err"

# --- 16. argument validation: non-numeric interval --------------------------
err="$TMP_ROOT/e16"
run_qw 1 abc 600 --json --no-check-probe >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "non-numeric poll_interval exits 2" "$err"
assert_contains "$(cat "$err")" "positive integer" "non-numeric error is explicit" "$err"

# --- 17. --help prints usage and exits 0 ------------------------------------
err="$TMP_ROOT/e17"
out="$(run_qw --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"
assert_contains "$out" "Usage: queue-wait" "--help prints usage" "$err"
# The heredoc is the contract's sole home (KEN-556): pin tokens whose
# semantics live nowhere else (KEN-555: tokens, never sentences).
assert_contains "$out" "Exit codes:" "--help carries the exit-code table" "$err"
assert_contains "$out" "not_queued" "--help carries the verdict vocabulary" "$err"
assert_contains "$out" "QUEUE_WAIT_ARM_GRACE" "--help carries the environment knobs" "$err"

# --- 17b. an unknown flag is rejected in the parser, never absorbed ---------
# Without the -*) branch, --bogus-flag lands in a positional slot and dies
# later blaming poll_interval (kendex#981, same shape as ci-wait).
err="$TMP_ROOT/e17b"
run_qw 1 30 600 --bogus-flag >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "unknown flag exits 2" "$err"
assert_contains "$(cat "$err")" "unknown option" "unknown-flag error names the flag, not a positional" "$err"


# Missing PR# is the usage-error class (exit 2), never exit 1.
err="$TMP_ROOT/e-missing"
run_qw >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "missing PR# exits 2" "$err"
assert_contains "$(cat "$err")" "missing required <PR#>" "missing PR# names the argument" "$err"

if [[ -e "$TMP_ROOT/argval-gh.calls" ]]; then
  assert_eq "$(cat "$TMP_ROOT/argval-gh.calls")" "" "no case above ever invoked gh"
else
  assert_eq "no-calls" "no-calls" "no case above ever invoked gh"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
