#!/usr/bin/env bash
# Tests for the block-bare-cd hook.
#
# The hook refuses a top-level `cd` that would move the working directory for
# every later tool call, and passes anything that scopes the move — a
# subshell, an &&-chain doing the real work — or that only mentions cd. The
# argument is optional on both sides of the check: a bare `cd` goes to $HOME,
# which is the same permanent move as `cd /tmp`.
#
# The command reaches the hook JSON-encoded, so the decode is pinned too: a
# quoted operand carries \" escapes, and a parser that stops at the first
# quote truncates the chain that scopes the move. Both decode paths are
# exercised — jq, and the fallback on a PATH without it.
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

# A PATH without jq exercises the escape-aware fallback decoder.
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in cat sed grep head; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_hook_nojq() { # command -> rc, stderr in ERR_FILE
  set +e
  json_for "$1" | env -i HOME="$HOME" PWD="$PWD" PATH="$NOJQ_BIN" "$BASH_BIN" "$HOOK" \
    >/dev/null 2>"$ERR_FILE"
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

echo "=== block-bare-cd: a quoted operand does not truncate the command ==="
run_hook 'cd "$repo" && ls';       assert_eq "$rc" 0 'cd "$repo" && ls is scoped work, not a bare cd'
run_hook 'cd "$repo"';             assert_eq "$rc" 2 'cd "$repo" alone is still a bare cd'
run_hook 'cd "/a b" && make';      assert_eq "$rc" 0 'a quoted path with a space does not hide the chain'
run_hook 'echo "cd \"x\"" > note'; assert_eq "$rc" 0 'a quoted cd inside a string is not a bare cd'

echo "=== block-bare-cd: the same decisions without jq ==="
run_hook_nojq 'cd "$repo" && ls';  assert_eq "$rc" 0 'without jq, the escape-aware fallback keeps the chain'
run_hook_nojq 'cd "$repo"';        assert_eq "$rc" 2 'without jq, a quoted bare cd is still refused'
run_hook_nojq 'cd';                assert_eq "$rc" 2 'without jq, a bare cd with no target is refused'
run_hook_nojq 'ls -la';            assert_eq "$rc" 0 'without jq, an unrelated command passes'

echo "=== block-bare-cd: an undecodable payload refuses ==="
set +e
printf '%s' '{"tool_input":{"command":"cd /tmp"' | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"; rc=$?
set -e
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'not valid JSON' 'the parse refusal names the cause'
set +e
printf '%s' '{"tool_input":{"command":"cd /tmp' \
  | env -i HOME="$HOME" PWD="$PWD" PATH="$NOJQ_BIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"; rc=$?
set -e
assert_eq "$rc" 2 'without jq, an unterminated command string refuses'
assert_contains "$ERR_FILE" 'could not decode' 'the no-jq refusal names the cause'
set +e
printf '%s' '{"tool_input":{"command":""}}' | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"; rc=$?
set -e
assert_eq "$rc" 0 'an empty command is decoded, not a decode failure'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
