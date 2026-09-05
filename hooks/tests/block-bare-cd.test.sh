#!/usr/bin/env bash
# Tests for the block-bare-cd hook.
#
# The hook refuses a top-level `cd` that would move the working directory for
# every later tool call, and passes anything that scopes the move — a
# subshell, an &&-chain doing the real work — or that only mentions cd. The
# argument is optional on both sides of the check: a bare `cd` goes to $HOME,
# which is the same permanent move as `cd /tmp`.
#
# The command reaches the hook JSON-encoded, and jq is the only thing that
# reads it: a quoted operand carries \" escapes, and the parser this replaced
# stopped at the first one, truncating the chain that scopes the move. A
# payload jq cannot read, or one naming a command that is not a string, is
# refused rather than skipped.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (the unguarded hook, a no-op hook) run against these same assertions.
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

run_payload() { # raw-json [PATH] -> rc, stderr in ERR_FILE
  set +e
  if [ -n "${2:-}" ]; then
    printf '%s' "$1" | env -i HOME="$HOME" PWD="$PWD" PATH="$2" "$BASH_BIN" "$HOOK" \
      >/dev/null 2>"$ERR_FILE"
  else
    printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  fi
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
run_hook 'cd "$repo"';    assert_eq "$rc" 2 'a quoted operand alone is still a bare cd'

echo "=== block-bare-cd: the refusal names the cause and the rewrite ==="
run_hook 'cd'
assert_contains "$ERR_FILE" 'across tool calls' 'the refusal names what it prevents'
assert_contains "$ERR_FILE" '(cd /path && command)' 'the refusal names the subshell rewrite'

echo "=== block-bare-cd: accepted shapes ==="
run_hook '(cd /tmp && ls)';   assert_eq "$rc" 0 'a subshell-scoped cd passes'
run_hook 'cd /tmp && ls';     assert_eq "$rc" 0 'a cd chained with the real work passes'
run_hook 'cd "$repo" && ls';  assert_eq "$rc" 0 'a quoted operand does not truncate the chain behind it'
run_hook 'cd "/a b" && make'; assert_eq "$rc" 0 'a quoted path with a space keeps its chain'
run_hook 'echo cd';           assert_eq "$rc" 0 'a command that only mentions cd passes'
run_hook 'cdr --version';     assert_eq "$rc" 0 'a command whose name merely starts with cd passes'
run_hook 'ls -la';            assert_eq "$rc" 0 'an unrelated command passes'
run_hook 'git checkout main'; assert_eq "$rc" 0 'a command with no cd at all passes'

echo "=== block-bare-cd: a payload it cannot read refuses ==="
run_payload '{"tool_input":{"command":"cd /tmp"'
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'not valid JSON' 'the parse refusal names the cause'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":false}}'
assert_eq "$rc" 2 'a command of false refuses, not read as an absent one'
run_payload '{"tool_input":"cd /tmp"}'
assert_eq "$rc" 2 'a tool_input that is not an object refuses'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'

echo "=== block-bare-cd: Copilot carries the command under toolArgs ==="
run_payload '{"sessionId":"s","timestamp":1,"cwd":"/w","toolName":"bash","toolArgs":{"command":"cd /tmp"}}'
assert_eq "$rc" 2 'a Copilot toolArgs object is read'
run_payload '{"toolName":"bash","toolArgs":"{\"command\":\"cd /tmp\"}"}'
assert_eq "$rc" 2 'a Copilot toolArgs JSON string is read'
run_payload '{"toolName":"bash","toolArgs":{"command":"(cd /tmp && ls)"}}'
assert_eq "$rc" 0 'a scoped cd under toolArgs passes, so the shape is read rather than refused'
run_payload '{"toolName":"bash","toolArgs":"not json"}'
assert_eq "$rc" 2 'a toolArgs string that is not JSON refuses rather than skipping the guard'

echo "=== block-bare-cd: without the tools that read the payload ==="
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
# type -P, not command -v: grep and friends are shell functions in some
# interactive environments, and a function name symlinks to nothing.
for tool in cat sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload '{"tool_input":{"command":"cd /tmp"}}' "$NOJQ_BIN"
assert_eq "$rc" 2 'no jq refuses rather than guessing at the payload'
assert_contains "$ERR_FILE" 'required to read the hook payload' 'the refusal names what is missing'
run_payload '{"tool_input":{"command":"cd /tmp"}}' /nonexistent
assert_eq "$rc" 2 'no text tools at all refuses too'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
