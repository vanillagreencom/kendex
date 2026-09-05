#!/usr/bin/env bash
# Tests for the block-argv-kill hook.
#
# One regex decides: a `pkill` or `killall` word at a word edge, wherever in
# the command it stands. The verb, its edge and the rest of the command are
# each varied below, so a change that dropped one of them reds here rather
# than scoring on the others. `kill`, `pgrep` and `ps` are the control side:
# the commands the refusal sends the caller to must pass.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-argv-kill.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

assert_eq() {
  if [ "$1" = "$2" ]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$1")"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
json_for() {
  jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
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

echo "=== block-argv-kill: a kill by name or pattern is refused ==="
run_hook 'pkill -f mutation-stability';        assert_eq "$rc" 2 'pkill with an argv pattern is refused'
assert_contains "$ERR_FILE" 'kill <pid>' 'the refusal names the PID form'
assert_contains "$ERR_FILE" '/proc/<pid>/cwd' 'the refusal names the cwd check'
run_hook 'pkill kendex';                       assert_eq "$rc" 2 'pkill by process name is refused'
run_hook 'pkill -x -TERM cargo';               assert_eq "$rc" 2 'flags between the verb and the name change nothing'
run_hook 'killall node';                       assert_eq "$rc" 2 'killall is refused'
run_hook 'sudo killall -9 vite';               assert_eq "$rc" 2 'a wrapper in front of the verb is still the verb'
run_hook '/usr/bin/pkill -f foo';              assert_eq "$rc" 2 'an absolute path in front of the verb is still the verb'
run_hook 'make stop; pkill -f serve';          assert_eq "$rc" 2 'the verb is found after a semicolon'
run_hook 'true && killall -q gulp';            assert_eq "$rc" 2 'the verb is found in an and-list'
run_hook "$(printf 'echo start\npkill -f watcher')"; assert_eq "$rc" 2 'the verb is found on the second line'
run_hook 'x=$(pkill -f a)';                    assert_eq "$rc" 2 'the verb is found inside a command substitution'
run_hook 'pkill';                              assert_eq "$rc" 2 'a bare pkill with no argument is refused'
run_hook '"pkill" -f a';                       assert_eq "$rc" 2 'a quoted verb is still the verb'
run_hook "$(printf 'pkill \\\n  -f a')";       assert_eq "$rc" 2 'a verb ending its line is still the verb'
run_hook '$(which pkill) -f a';                assert_eq "$rc" 2 'a verb closing a substitution is still the verb'

echo "=== block-argv-kill: the named forms pass ==="
run_hook 'kill 1234';                          assert_eq "$rc" 0 'kill on a PID passes'
run_hook 'kill -TERM 1234 5678';               assert_eq "$rc" 0 'kill with a signal and several PIDs passes'
run_hook 'kill -- -1234';                      assert_eq "$rc" 0 'kill on a process group passes'
run_hook 'pgrep -af mutation-stability';       assert_eq "$rc" 0 'pgrep passes: finding a PID is not killing by pattern'
run_hook 'ps -o pid,args -p 1234';             assert_eq "$rc" 0 'ps passes'
run_hook 'readlink /proc/1234/cwd';            assert_eq "$rc" 0 'reading a process cwd passes'
run_hook 'cat killall.log';                    assert_eq "$rc" 0 'the verb glued to a suffix is another word'
run_hook 'pkill-wrapper --dry-run';            assert_eq "$rc" 0 'the verb glued to a hyphenated suffix is another word'
run_hook 'echo unpkill';                       assert_eq "$rc" 0 'the verb glued to a prefix is another word'
run_hook 'git status';                         assert_eq "$rc" 0 'a command with neither verb passes'

echo "=== block-argv-kill: the stated limits ==="
# Reading words rather than shell costs in both directions, and both costs are
# rows so nobody grows a tokenizer to close either: a command that only spells
# the verb is refused as the kill it is not, and a spelling the shell assembles
# from quotes or escapes is not seen.
run_hook 'echo "never use pkill here"';        assert_eq "$rc" 2 'the verb inside a quoted string is refused'
run_hook "p'kill' -f x";                       assert_eq "$rc" 0 'a verb the shell assembles from quotes is not seen'
run_hook 'kill\all x';                         assert_eq "$rc" 0 'a verb the shell assembles from an escape is not seen'

echo "=== block-argv-kill: a payload it cannot read refuses ==="
run_payload ''
assert_eq "$rc" 2 'an empty payload refuses rather than passing as an absent command'
assert_contains "$ERR_FILE" 'payload is empty' 'the empty-payload refusal names the cause'
run_payload "$(printf ' \n\t')"
assert_eq "$rc" 2 'a whitespace-only payload refuses the same way'
set +e
"$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "$rc" 2 'a stdin that cannot be read refuses with the refusal status, not the read error'
assert_contains "$ERR_FILE" 'could not read the hook payload' 'the read refusal names the cause'
run_payload '{"tool_input":{"command":"pkill x"'
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'not valid JSON' 'the parse refusal names the cause'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":false}}'
assert_eq "$rc" 2 'a command of false refuses, not read as an absent one'
run_payload '{"tool_input":"pkill x"}'
assert_eq "$rc" 2 'a tool_input that is not an object refuses'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'
run_payload '{"command":"killall x"}'
assert_eq "$rc" 2 'a top-level command field is read like a nested one'

echo "=== block-argv-kill: Copilot carries the command under toolArgs ==="
run_payload '{"sessionId":"s","timestamp":1,"cwd":"/w","toolName":"bash","toolArgs":{"command":"pkill -f x"}}'
assert_eq "$rc" 2 'a Copilot toolArgs object is read'
run_payload '{"toolName":"bash","toolArgs":"{\"command\":\"killall x\"}"}'
assert_eq "$rc" 2 'a Copilot toolArgs JSON string is read'
run_payload '{"toolName":"bash","toolArgs":{"command":"kill 1234"}}'
assert_eq "$rc" 0 'a PID kill under toolArgs passes, so the shape is read rather than refused'
run_payload '{"toolName":"bash","toolArgs":"not json"}'
assert_eq "$rc" 2 'a toolArgs string that is not JSON refuses rather than skipping the guard'

echo "=== block-argv-kill: a missing reader refuses ==="
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat grep sed; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NOJQ_BIN/$tool"
done
run_payload '{"tool_input":{"command":"pkill x"}}' "$NOJQ_BIN"
assert_eq "$rc" 2 'without jq the guard refuses rather than skipping'
assert_contains "$ERR_FILE" 'required to read the hook payload' 'the refusal names what is missing'
run_payload '{"tool_input":{"command":"kill 1"}}' "$NOJQ_BIN"
assert_eq "$rc" 2 'without jq even a harmless command is refused: nothing was read'

echo
echo "block-argv-kill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
