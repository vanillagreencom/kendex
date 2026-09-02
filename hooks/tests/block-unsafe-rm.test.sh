#!/usr/bin/env bash
# Tests for the block-unsafe-rm hook.
#
# One regex decides, and it has three parts: an `rm`, a flag word carrying r or
# R, and an operand rooted in a variable that may expand empty — the shape the
# harness stops the whole session on with a "Dangerous rm operation on
# possibly-empty variable path" prompt. The parts count wherever they stand in
# the command; there is no command-position test to pin. Each part is varied
# independently below, so a change that dropped one of them reds here rather
# than scoring on the other two.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-unsafe-rm.sh}"

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
  if grep -qF -- "$2" "$ERR_FILE"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$ERR_FILE")"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
# jq does the encoding rather than sed: a Bash tool call is routinely several
# lines, and a raw newline inside a JSON string is not JSON, so a sed-built
# fixture could not express the multi-line rows at all.
json_for() {
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
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

echo "=== block-unsafe-rm: a variable-rooted operand is refused ==="
run_hook 'rm -rf $CACHE/$KEY';        assert_eq "$rc" 2 'a bare $NAME root is refused'
run_hook 'rm -r ${DIR}';              assert_eq "$rc" 2 'the braced form is refused'
run_hook 'rm -rf "$P/save"';          assert_eq "$rc" 2 'quotes do not stop an empty expansion'
run_hook 'rm -rf ""$X/sub';           assert_eq "$rc" 2 'an empty double-quote pair does not hide the root'
run_hook 'rm -rf "${P:-}/save"';      assert_eq "$rc" 2 '${P:-} can still expand empty and is refused'
run_hook 'rm -rf "${X+x:?}/save"';    assert_eq "$rc" 2 'an unset-guarded alternative whose text contains :? is refused'
run_hook 'rm -rf -- $X';              assert_eq "$rc" 2 'the -- separator does not make a variable root safe'
run_hook 'rm -rf $LOGS/*.log';        assert_eq "$rc" 2 'a glob in the operand does not disturb classification'
run_hook 'rm -rf $X > /var/tmp/log';  assert_eq "$rc" 2 'a redirection after the operand does not hide it'
# One rm invocation is wider than its first operand in both directions, and
# GNU rm accepts both shapes.
run_hook 'rm -rf /literal/path "$DIR/sub"'; assert_eq "$rc" 2 'a variable root in a LATER operand is refused'
run_hook 'rm $DIR/sub -rf';           assert_eq "$rc" 2 'a recursion flag standing after the operand is refused'
# The trailing flag ends at the end of the command or at whitespace, and a
# newline is the whitespace it ends at when the call carries a second line.
run_hook "$(printf 'rm %s/sub -rf\necho done' '$DIR')"; assert_eq "$rc" 2 'a newline ends that trailing flag as the end of the command does'
run_hook 'rm build -rf $X';           assert_eq "$rc" 2 'a literal operand before the flag does not hide a later variable root'

echo "=== block-unsafe-rm: the operand half of the predicate ==="
# Same verb, same flags, an operand that cannot collapse to /: the operand is
# what decides. Without these rows, refusing every recursive rm would score.
run_hook 'rm -rf -- "${P:?}/save"';   assert_eq "$rc" 0 '${P:?} cannot expand empty and passes'
run_hook 'rm -rf "${VAR1:?}/x"';      assert_eq "$rc" 0 'digits after the first identifier char pass'
run_hook "rm -rf '\$X'";              assert_eq "$rc" 0 'a single-quoted operand is a literal filename, not an expansion'
run_hook "rm -rf \$'/var/tmp/safe'";  assert_eq "$rc" 0 'an ANSI-C quoted operand is a literal, not a variable root'
run_hook 'rm -rf /var/tmp/x';         assert_eq "$rc" 0 'a literal absolute path passes'
run_hook 'rm -rf ./build';            assert_eq "$rc" 0 'a literal relative path passes'
run_hook 'rm -rf /var/tmp/safe > $LOG'; assert_eq "$rc" 0 'a variable redirection target is not the first operand'

echo "=== block-unsafe-rm: the recursion half of the predicate ==="
run_hook 'rm -fr $X';                 assert_eq "$rc" 2 'r anywhere in the cluster counts'
run_hook 'rm -R $X';                  assert_eq "$rc" 2 'uppercase -R counts'
run_hook 'rm --recursive --force $X'; assert_eq "$rc" 2 '--recursive counts'
# Same operand, no recursion: the harness does not prompt and neither does this.
run_hook 'rm -f $X';                  assert_eq "$rc" 0 'a non-recursive rm on a variable passes'
run_hook 'rm $X';                     assert_eq "$rc" 0 'an rm with no flag at all passes'
# A long flag is not a cluster, so an r inside one is a letter of its name.
run_hook 'rm --verbose "$X/f"';       assert_eq "$rc" 0 'a long flag merely holding an r is not recursion'
run_hook 'rm --interactive $X';       assert_eq "$rc" 0 'nor is --interactive'

echo "=== block-unsafe-rm: where the sequence stands, and how far it reaches ==="
# The sequence counts wherever it stands, a compound command's keyword arm
# included. A hand-written list of those keywords was tried and every revision
# of it missed more members than it named, so one row stands for the whole
# class rather than one row per keyword.
run_hook 'if rm -rf "$X/sub"; then echo done; fi'; assert_eq "$rc" 2 'a keyword-prefixed rm is refused like any other'
run_hook "$(printf 'rm\t-rf\t%s' '$X')";        assert_eq "$rc" 2 'tabs separate the words as spaces do'
# A Bash tool call is routinely several lines, and bash's =~ anchors ^ at the
# start of the WHOLE command, so nothing but the rm's left edge admitting a
# newline reaches line two at all.
run_hook "$(printf 'cd /x\nrm -rf "%s/x"' '$D')"; assert_eq "$rc" 2 'an rm on the second line is reached'
run_hook "$(printf 'cd /x\nrm -rf /var/tmp/x')"; assert_eq "$rc" 0 'and a literal path on the second line still passes'
# A newline also ENDS the command before it, and so does a `;` — the words of
# the next command are not this rm's operands. Each pair differs only in
# whether that next command is itself a variable-rooted rm.
run_hook "$(printf 'rm -rf /var/tmp/x\ncat %s' '$F')";    assert_eq "$rc" 0 'a later line is a command of its own, not an operand of this rm'
run_hook "$(printf 'rm -rf /var/tmp/x\nrm -rf %s' '$F')"; assert_eq "$rc" 2 'and a variable-rooted rm on that later line is still refused'
run_hook 'rm -rf /var/tmp/x; echo $HOME';                 assert_eq "$rc" 0 'a semicolon ends it the same way'
run_hook 'rm -rf /var/tmp/x; rm -rf $HOME';               assert_eq "$rc" 2 'and the rm after it is judged on its own operands'
run_hook 'rm -rf /var/tmp/x & cat $F';                    assert_eq "$rc" 0 'an ampersand ends it too'
run_hook 'rm -rf /var/tmp/x | cat $F';                    assert_eq "$rc" 0 'and so does a pipe'
# The rm's left edge is a word boundary and the only thing keeping the letters
# rm inside a longer word out of the match.
run_hook 'confirm -rf $X';            assert_eq "$rc" 0 'a word merely ending in rm is not the verb'
run_hook 'ls -la';                    assert_eq "$rc" 0 'an unrelated command passes'

echo "=== block-unsafe-rm: the refusal names the cause and the rewrite ==="
run_hook 'rm -rf $CACHE/$KEY'
assert_contains "$ERR_FILE" 'possibly-empty variable path' 'the refusal names the harness prompt it prevents'
assert_contains "$ERR_FILE" '${NAME:?}' 'the refusal names the ${NAME:?} rewrite'
assert_contains "$ERR_FILE" '/absolute/literal/path' 'the refusal names the literal-path alternative'
assert_contains "$ERR_FILE" 'rm -rf $CACHE/$KEY' 'the refusal quotes the command it judged'

echo "=== block-unsafe-rm: a payload it cannot read refuses ==="
run_payload '{"tool_input":{"command":"rm -rf $X"'
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'not valid JSON' 'the parse refusal names the cause'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":false}}'
assert_eq "$rc" 2 'a command of false refuses, not read as an absent one'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'
# The harness sends the command under tool_input; a payload naming it at the
# top level is read the same way, and that fallback is a branch of its own.
run_payload '{"command":"rm -rf $X"}'
assert_eq "$rc" 2 'a top-level command field is read like a nested one'
run_payload '{"command":false}'
assert_eq "$rc" 2 'and a top-level false is refused, not read as an absent one'

NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
# type -P, not command -v: cat and friends are shell functions in some
# interactive environments, and a function name symlinks to nothing.
for tool in cat sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload '{"tool_input":{"command":"rm -rf $X"}}' "$NOJQ_BIN"
assert_eq "$rc" 2 'no jq refuses rather than guessing at the payload'
assert_contains "$ERR_FILE" 'required to read the hook payload' 'the refusal names what is missing'
run_payload '{"tool_input":{"command":"ls -la"}}' /nonexistent
assert_eq "$rc" 2 'no text tools at all refuses too, whatever the command'

# cat is the other half of the same guard: jq reads the payload, cat is what
# hands it over. A PATH holding jq and not cat is what tells the two apart.
NOCAT_BIN="$TMP_ROOT/nocat"
mkdir -p "$NOCAT_BIN"
for tool in jq sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOCAT_BIN/$tool"
done
run_payload '{"tool_input":{"command":"ls -la"}}' "$NOCAT_BIN"
assert_eq "$rc" 2 'no cat refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'required to read the hook payload' 'the refusal names what is missing'
# The control that the exact PATH is what decided: the same benign command
# passes once cat is on it.
ln -sf "$(type -P cat)" "$NOCAT_BIN/cat"
run_payload '{"tool_input":{"command":"ls -la"}}' "$NOCAT_BIN"
assert_eq "$rc" 0 'and the same PATH with cat added passes'

echo "=== block-unsafe-rm: the stated limit ==="
# A flag the shell would assemble is not seen here. The harness prompt still
# stops the command; what it costs is the session stall this hook exists to
# spare, and that is the whole trade for reading text rather than shell.
run_hook 'rm "-rf" "$X/sub"';         assert_eq "$rc" 0 'a quoted flag word is not seen as recursion'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
