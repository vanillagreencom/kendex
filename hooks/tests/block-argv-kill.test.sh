#!/usr/bin/env bash
# Tests for the block-argv-kill hook.
#
# One regex decides: a `pkill` or `killall` word at a word edge, wherever in
# the command it stands. The verb, its edge and the rest of the command are
# each varied below, so a change that dropped one of them reds here rather
# than scoring on the others. `kill`, `pgrep` and `ps` are the control side:
# the commands the refusal sends the caller to must pass.
#
# Every refusal opens with `block-argv-kill: <key>=<value>`, and that line is
# the contract: the first-line table below pins the key and the value of each
# condition beside its exit status, and the English under it is not asserted.
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

run_payload() { # raw-json -> rc, stderr in ERR_FILE
  set +e
  printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The hook's dependency list, in the order it checks them: the shared table
# pins it as the value of the world that has none of them.
PAYLOAD_ADVISORY=1
PAYLOAD_TOOLS=jq,cat

# shellcheck source=lib/payload-rows.sh
. "$TEST_DIR/lib/payload-rows.sh"

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
run_hook '$(which pkill) -f a';                assert_eq "$rc" 0 'a verb closing a substitution is still the verb'

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
# Split executable spellings remain outside the lexical reader.
run_hook 'echo "never use pkill here"';        assert_eq "$rc" 0 'the verb inside a quoted string is refused'
run_hook "p'kill' -f x";                       assert_eq "$rc" 0 'a verb the shell assembles from quotes is not seen'
run_hook 'kill\all x';                         assert_eq "$rc" 0 'a verb the shell assembles from an escape is not seen'

echo "=== block-argv-kill: the first line of every condition ==="
first_table "\
the verb the command spelled is the value|command|2|block-argv-kill: refused=pkill|pkill -f mutation-stability
the other verb is a value of its own|command|2|block-argv-kill: refused=killall|killall node
a command it read and allows says nothing|command|0|-|kill 1234
an empty payload refuses rather than passing as an absent command|payload|0|block-argv-kill: payload=empty|-
a whitespace-only payload refuses the same way|payload|0|block-argv-kill: payload=empty| \t
a payload that is not JSON is refused unread|payload|0|block-argv-kill: payload=invalid-json|not JSON
"
set +e
"$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line) cause=$(cause_below)" \
  'rc=0 first=block-argv-kill: payload=unreadable cause=present' \
  'a stdin that cannot be read refuses with the keyed line first and the cause under it'

payload_table "$HOOK" 'pkill -f x' 'kill 1234'
# The shared reader is present in every disposable hook installation.
ln -s "$(cd -- "$TEST_DIR/../.." && pwd)/skills" "$TMP_ROOT/skills"
. "$TEST_DIR/lib/assert.sh"
command_position_rows() {
  first_table 'real pkill|command|2|block-argv-kill: refused=pkill|pkill -f x
quoted kill text|command|0|-|echo '\''pkill -f x'\''
kill argument|command|0|-|echo pkill
kill heredoc data|command|0|-|cat <<'\''EOF'\''\npkill killall\nEOF
else command|command|2|block-argv-kill: refused=pkill|if true; then true; else pkill -f x; fi
brace command|command|2|block-argv-kill: refused=pkill|{ pkill -f x; }
timeout command|command|2|block-argv-kill: refused=pkill|timeout 5 pkill -f x
nice command|command|2|block-argv-kill: refused=pkill|nice -n 5 pkill -f x
prefixed shell body|command|2|block-argv-kill: refused=pkill|true; bash <<EOF\npkill -f x\nEOF
pipeline shell body|command|2|block-argv-kill: refused=pkill|cat <<EOF | bash\npkill -f x\nEOF
prefixed data body|command|0|-|true; cat <<EOF\npkill -f x\nEOF
pipeline data body|command|0|-|cat <<EOF | cat\npkill -f x\nEOF
last shell body|command|2|block-argv-kill: refused=pkill|bash <<FIRST <<SECOND\ntrue\nFIRST\npkill -f x\nSECOND
grouped shell body|command|2|block-argv-kill: refused=pkill|cat <<EOF | (bash)\npkill -f x\nEOF
redirection-first shell body|command|2|block-argv-kill: refused=pkill|<<EOF bash\npkill -f x\nEOF
source-stdin shell body|command|2|block-argv-kill: refused=pkill|bash -c "source /dev/stdin" <<EOF\npkill -f x\nEOF
remote shell body|command|2|block-argv-kill: refused=pkill|ssh host "bash -s" <<EOF\npkill -f x\nEOF
later find semicolon action|command|2|block-argv-kill: refused=pkill|find . -exec echo {} \\; -execdir pkill -f x {} \\;
later find action|command|2|block-argv-kill: refused=pkill|find . -exec echo {} + -exec sh -c "pkill -f x" sh {} +
later find data|command|0|-|find . -exec echo {} + -exec echo "pkill -f x" {} +
multiple data bodies|command|0|-|cat <<FIRST <<SECOND\npkill -f x\nFIRST\npkill -f x\nSECOND
receiver input substitution|command|2|block-argv-kill: refused=pkill|cat <<'\''EOF'\'' | cat $(bash)\npkill x\nEOF
receiver quoted substitution data|command|0|-|cat <<'\''EOF'\'' | cat '\''$(bash)'\''\npkill x\nEOF
grouped later shell body|command|2|block-argv-kill: refused=pkill|cat <<EOF | (echo x; bash)\npkill -f x\nEOF
grouped later brace body|command|2|block-argv-kill: refused=pkill|cat <<EOF | { echo x; bash; }\npkill -f x\nEOF
grouped data guarded text|command|2|block-argv-kill: refused=pkill|cat <<EOF | (cat)\npkill -f x\nEOF
literal shell program|command|2|block-argv-kill: refused=pkill|find . -exec echo {} + -exec sh -c pkill {} +
literal shell data|command|0|-|find . -exec sh -c true "pkill x" {} +
pipe-and body|command|2|block-argv-kill: refused=pkill|cat <<EOF |\0046 bash\npkill -f x\nEOF
pipe-and quoted data|command|0|-|cat <<EOF |\0046 bash\necho "pkill -f x"\nEOF
redirection ampersand body|command|2|block-argv-kill: refused=pkill|cat <<EOF 2>&1 | bash\npkill -f x\nEOF
redirection ampersand quoted data|command|0|-|cat <<EOF 2>&1 | bash\necho "pkill -f x"\nEOF
backtick receiver body|command|2|block-argv-kill: refused=pkill|cat <<EOF | sed `x` | bash\npkill -f x\nEOF
backtick receiver quoted data|command|0|-|cat <<EOF | sed `x` | bash\necho "pkill -f x"\nEOF
lifted substitution receiver body|command|2|block-argv-kill: refused=pkill|cat <<EOF | cat "$(x)" | bash\npkill -f x\nEOF
lifted substitution receiver quoted data|command|0|-|cat <<EOF | cat "$(x)" | bash\necho "pkill -f x"\nEOF
process substitution receiver body|command|2|block-argv-kill: refused=pkill|cat <<EOF > >(bash)\npkill -f x\nEOF
process substitution receiver quoted data|command|0|-|cat <<EOF > >(bash)\necho "pkill -f x"\nEOF
quoted find terminators|command|2|block-argv-kill: refused=pkill|find . -exec echo {} ";" -exec pkill -f x {} ";"
quoted find data|command|0|-|find . -exec echo {} ";" -exec echo "pkill -f x" {} ";"
pending shell receiver|command|2|block-argv-kill: refused=pkill|cat <<'\''EOF'\'' |\npkill -f x\nEOF\nbash
pending harmless receiver|command|0|-|cat <<'\''EOF'\'' |\nprintf harmless-body\nEOF\nbash
'
}
command_position_rows
skill_load_control executable-selection "$HOOK" 'command_text "$segment"' 'COMMAND_TEXTS=""' HOOK command_position_rows 'real pkill'
delivered_reader_rows() {
  reader_layout_rows "$HOOK" '{"agent_type":"reviewer-quality","tool_name":"Bash","tool_input":{"command":"pkill -f x"}}' 'block-argv-kill: refused=pkill'
}
delivered_reader_rows
skill_load_control native-reader-lookup "$HOOK" \
  '  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do' \
  '    case "$candidate" in */../../skills/*) continue ;; esac' \
  HOOK delivered_reader_rows 'native-copy delivered reader'
skill_load_control shared-reader-lookup "$HOOK" \
  '  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do' \
  '    case "$candidate" in "$HOME/.agents/"*) continue ;; esac' \
  HOOK delivered_reader_rows 'shared-skill delivered reader' 'relocated-shared delivered reader'

echo
echo "block-argv-kill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
