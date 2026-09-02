#!/usr/bin/env bash
# Regression tests for ci-wait's argument validation (kendex#981), split
# from ci_wait.sh at this seam (the poll/verdict suites live there). Usage
# errors must terminate in the arg parser, before auth or any gh call: an
# unknown flag used to fall through into a positional slot and die under
# `set -u`, and --help was taken as the PR number and crashed in jq. The
# recording gh stub proves gh was never reached.
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

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Call-recording gh stub: every case here terminates in the parser or the
# config resolver, so ANY gh invocation is a failure the log makes visible.
mkdir -p "$TMP_ROOT/argbin"
cat > "$TMP_ROOT/argbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/argval-gh.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/argbin/gh"

echo "=== ci-wait argument validation (kendex#981) ==="

# Usage errors must terminate in the arg parser, before auth or any gh call:
# an unknown flag used to fall through into a positional slot and die under
# `set -u` as "timeout: unbound variable", and `--help` was taken as the PR
# number and crashed in jq. This gh stub records every invocation so a clean
# pass proves gh was never reached.
run_wait_args() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/argbin:$PATH" \
       .agents/skills/orch/scripts/ci-wait "$@")
}

assert_no_gh_calls() {
  local name="$1"
  if [[ -e "$TMP_ROOT/argval-gh.calls" ]]; then
    assert_eq "$(cat "$TMP_ROOT/argval-gh.calls")" "" "$name"
  else
    assert_eq "no-calls" "no-calls" "$name"
  fi
  rm -f "$TMP_ROOT/argval-gh.calls"
}

# Case 32: --help answers with usage and exit 0 instead of being consumed as
# the PR number.
stderr="$TMP_ROOT/case32.err"
set +e
output=$(run_wait_args --help 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case32: --help exits 0" "$stderr"
assert_contains "$output" "Usage: ci-wait" "case32: --help prints usage"
# The heredoc is the contract's sole home (KEN-556): pin tokens whose
# semantics live nowhere else (KEN-555: tokens, never sentences).
assert_contains "$output" "Exit codes:" "case32: --help carries the exit-code table"
assert_contains "$output" "no-CI route" "case32: --help carries the verdict=none contract"
assert_contains "$output" "CI_WAIT_NO_CHECKS_GRACE" "case32: --help carries the grace knob"
assert_no_gh_calls "case32: --help never invokes gh"

# Case 32b: -h behaves like --help.
stderr="$TMP_ROOT/case32b.err"
set +e
output=$(run_wait_args -h 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case32b: -h exits 0" "$stderr"
assert_contains "$output" "Usage: ci-wait" "case32b: -h prints usage"
assert_no_gh_calls "case32b: -h never invokes gh"

# Case 33: an unknown flag is rejected with usage on stderr, never absorbed
# into a positional slot (the "timeout: unbound variable" abort).
stderr="$TMP_ROOT/case33.err"
set +e
output=$(run_wait_args 492 --timeout 2400 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "case33: unknown flag exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "unknown option '--timeout'" "case33: unknown flag named on stderr"
assert_contains "$(cat "$stderr")" "Usage: ci-wait" "case33: unknown flag prints usage on stderr"
assert_not_contains "$(cat "$stderr")" "unbound variable" "case33: no set -u abort"
assert_no_gh_calls "case33: unknown flag never invokes gh"

# Case 34: a non-integer PR number is rejected before any gh call instead of
# crashing later in jq.
stderr="$TMP_ROOT/case34.err"
set +e
output=$(run_wait_args abc 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "case34: non-integer PR exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "positive integer" "case34: non-integer PR error is explicit"
assert_no_gh_calls "case34: non-integer PR never invokes gh"

# Case 34b: non-integer poll_interval / max_wait are rejected the same way.
stderr="$TMP_ROOT/case34b.err"
set +e
output=$(run_wait_args 1 abc 30 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "case34b: non-integer poll_interval exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "positive integer" "case34b: non-integer poll_interval error is explicit"

stderr="$TMP_ROOT/case34c.err"
set +e
output=$(run_wait_args 1 15 abc 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "case34c: non-integer max_wait exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "positive integer" "case34c: non-integer max_wait error is explicit"

# Case 35: no arguments at all gets usage, not an unbound-variable abort.
stderr="$TMP_ROOT/case35.err"
set +e
output=$(run_wait_args 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "case35: missing PR argument exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "Usage: ci-wait" "case35: missing PR argument prints usage on stderr"
assert_no_gh_calls "case35: missing PR argument never invokes gh"

# `--json` remaining accepted with valid positionals is covered by the output
# contract above (cases 10-14 run `ci-wait 1 1 30 --json` end to end).


echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
