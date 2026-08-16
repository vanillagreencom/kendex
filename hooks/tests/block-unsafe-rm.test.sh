#!/usr/bin/env bash
# Tests for the block-unsafe-rm hook.
#
# The hook refuses a recursive rm whose path operand starts with a variable
# that may expand empty — the shape the harness stops the whole session on
# with a "Dangerous rm operation on possibly-empty variable path" prompt —
# and names the accepted rewrite (${NAME:?} or a literal absolute path).
# Non-recursive rm, literal paths, ${NAME:?}, and commands that merely mention
# rm pass. HOOK_UNDER_TEST overrides the script under test so the must-fail
# controls (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-unsafe-rm.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
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
for tool in cat sed grep head tr; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_hook_path() { # PATH command -> rc
  set +e
  json_for "$2" | env -i HOME="$HOME" PWD="$PWD" TMPDIR=/tmp PATH="$1" "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

echo "=== block-unsafe-rm: refused shapes ==="
run_hook 'rm -rf $CACHE/$KEY';           assert_eq "$rc" 2 'rm -rf $CACHE/$KEY is refused'
run_hook 'rm -rf "$P/save"';             assert_eq "$rc" 2 'a quoted "$P/save" is refused (quotes do not stop an empty expansion)'
run_hook 'rm -r ${DIR}';                 assert_eq "$rc" 2 'rm -r ${DIR} is refused'
run_hook 'rm -fr $X';                    assert_eq "$rc" 2 'the -fr cluster counts as recursive'
run_hook 'rm -R $X';                     assert_eq "$rc" 2 'uppercase -R counts as recursive'
run_hook 'rm --recursive --force $X';    assert_eq "$rc" 2 '--recursive counts as recursive'
run_hook 'mkdir -p x && rm -rf $X/y';    assert_eq "$rc" 2 'a refused rm inside an && chain is still refused'
run_hook 'rm -rf "${P:-}/save"';         assert_eq "$rc" 2 '${P:-} can still expand empty and is refused'
run_hook 'rm -rf -- $X';                 assert_eq "$rc" 2 'the -- separator does not make a variable root safe'
run_hook '(rm -rf $X)';                  assert_eq "$rc" 2 'a subshell-wrapped rm is still refused'
run_hook 'cd y && { rm -rf $X/z; }';     assert_eq "$rc" 2 'a group-wrapped rm inside a chain is refused'
run_hook "$(printf 'rm\t-rf\t%s' '$X')"; assert_eq "$rc" 2 'tab-separated rm -rf is refused'
run_hook 'rm -rf -- -$DIR/sub';          assert_eq "$rc" 2 'a dash-leading operand after -- is still a variable root'
run_hook 'rm -rf $LOGS/*.log';           assert_eq "$rc" 2 'a glob in the operand does not disturb classification'

echo "=== block-unsafe-rm: the refusal names the cause and the rewrite ==="
run_hook 'rm -rf $CACHE/$KEY'
assert_contains "$ERR_FILE" 'possibly-empty variable path' 'the refusal names the harness prompt it prevents'
assert_contains "$ERR_FILE" '${NAME:?}' 'the refusal names the ${NAME:?} rewrite'
assert_contains "$ERR_FILE" '/absolute/literal/path' 'the refusal names the literal-path alternative'
assert_contains "$ERR_FILE" '$CACHE/$KEY' 'the refusal quotes the offending operand'

echo "=== block-unsafe-rm: accepted shapes ==="
run_hook 'rm -rf -- "${P:?}/save"';      assert_eq "$rc" 0 '${P:?} cannot expand empty and passes'
run_hook 'rm -rf "${VAR1:?}/x"';         assert_eq "$rc" 0 'digits after the first identifier char pass (${VAR1:?})'
run_hook 'rm -rf -- "-${P:?}/x"';        assert_eq "$rc" 0 'a dash-leading ${P:?} operand after -- passes'
run_hook 'rm -rf "${TMP_ROOT:?}"';       assert_eq "$rc" 0 'a bare ${TMP_ROOT:?} passes'
run_hook 'rm -rf /var/tmp/x';            assert_eq "$rc" 0 'a literal absolute path passes'
run_hook 'rm -rf ./build';               assert_eq "$rc" 0 'a literal relative path passes'
run_hook 'rm -f $X';                     assert_eq "$rc" 0 'a non-recursive rm on a variable passes (not the prompted shape)'
run_hook 'rm file.txt';                  assert_eq "$rc" 0 'plain rm passes'
run_hook 'echo "rm -rf $X" > note';      assert_eq "$rc" 0 'a command that only mentions rm passes'
run_hook 'git rm -r --cached $X';        assert_eq "$rc" 0 'git rm is not rm'
run_hook 'ls -la';                       assert_eq "$rc" 0 'an unrelated command passes'

echo "=== block-unsafe-rm: unreadable payload refuses ==="
set +e
printf '%s' '{"tool_input":{"command":"rm -rf $X"' | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"; rc=$?
set -e
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$ERR_FILE" 'not valid JSON' 'the parse refusal names the cause'

echo "=== block-unsafe-rm: enforcement without jq ==="
run_hook_path "$NOJQ_BIN" 'rm -rf "$P/save"';        assert_eq "$rc" 2 'without jq, an escaped-quote payload is still decoded and refused'
run_hook_path "$NOJQ_BIN" 'rm -rf -- "${P:?}/save"'; assert_eq "$rc" 0 'without jq, the ${P:?} form still passes'
run_hook_path "/nonexistent" 'git status --short';   assert_eq "$rc" 0 'a command without rm completes with no external tool reachable'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
