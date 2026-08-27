#!/usr/bin/env bash
# Tests for the block-bare-cd hook.
#
# The hook refuses a top-level `cd` that would move the working directory for
# every later tool call, and passes anything that scopes the move — a
# subshell, an &&-chain doing the real work — or that only mentions cd. The
# argument is optional on both sides of the check: a bare `cd` goes to $HOME,
# which is the same permanent move as `cd /tmp`.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (the pre-fix hook, a no-op hook) run against these same assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-bare-cd.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1"; then pass "$3"; else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$1")"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
json_for() {
  local c
  c=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$c"
}

run_hook() { # command -> rc, stderr in ERR_FILE
  set +e
  json_for "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

echo "=== block-bare-cd: refused shapes ==="
run_hook 'cd';            assert_eq "$rc" 2 'a bare cd with no argument is refused'
run_hook 'cd ';           assert_eq "$rc" 2 'a bare cd with a trailing space is refused'
run_hook '   cd';         assert_eq "$rc" 2 'leading whitespace does not hide a bare cd'
run_hook 'cd /tmp';       assert_eq "$rc" 2 'cd with a path is refused'
run_hook 'cd ~/dev';      assert_eq "$rc" 2 'cd to a home-relative path is refused'
run_hook 'cd ..';         assert_eq "$rc" 2 'cd .. is refused'

echo "=== block-bare-cd: the refusal names the cause and the rewrite ==="
run_hook 'cd'
assert_contains "$ERR_FILE" 'across tool calls' 'the refusal names what it prevents'
assert_contains "$ERR_FILE" '(cd /path && command)' 'the refusal names the subshell rewrite'

echo "=== block-bare-cd: accepted shapes ==="
run_hook '(cd /tmp && ls)';   assert_eq "$rc" 0 'a subshell-scoped cd passes'
run_hook 'cd /tmp && ls';     assert_eq "$rc" 0 'a cd chained with the real work passes'
run_hook 'echo cd';           assert_eq "$rc" 0 'a command that only mentions cd passes'
run_hook 'cdr --version';     assert_eq "$rc" 0 'a command whose name merely starts with cd passes'
run_hook 'ls -la';            assert_eq "$rc" 0 'an unrelated command passes'
run_hook 'git checkout main'; assert_eq "$rc" 0 'a command with no cd at all passes'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
