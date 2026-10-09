#!/usr/bin/env bash
# Tests for the block-bare-cd hook.
#
# The hook refuses a line that is only a `cd`, the move that re-roots every
# later tool call where the shell persists (Claude Code) and changes nothing
# where each command runs fresh (Codex, the Pi carrier), and passes anything
# that scopes the move — a subshell, an &&-chain doing the real work — or that
# only mentions cd. The argument is optional on both sides of the check: a
# bare `cd` goes to $HOME, which is the same move as `cd /tmp`.
#
# The command reaches the hook JSON-encoded, and jq is the only thing that
# reads it: a quoted operand carries \" escapes, and the parser this replaced
# stopped at the first one, truncating the chain that scopes the move. A
# payload jq cannot read, or one naming a command that is not a string, is
# refused rather than skipped.
#
# Every refusal opens with `block-bare-cd: <key>=<value>`, the fixed set
# hooks/AGENTS.md names: the first-line table pins the key and the value of
# each condition beside its exit status, and the English under it is not
# asserted.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (the unguarded hook, a no-op hook) run against these same assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-bare-cd.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo 'block-bare-cd.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "block-bare-cd.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'block-bare-cd.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1"; then pass "$3"; else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$1")"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it,
# with jq doing the encoding so every escape is JSON's own.
json_for() {
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
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
PAYLOAD_TOOLS=jq,cat,grep,sed

# shellcheck source=lib/payload-rows.sh
. "$TEST_DIR/lib/payload-rows.sh"

echo "=== block-bare-cd: refused shapes ==="
run_hook 'cd';            assert_eq "$rc" 2 'a bare cd with no argument is refused'
run_hook 'cd ';           assert_eq "$rc" 2 'a bare cd with a trailing space is refused'
run_hook '   cd';         assert_eq "$rc" 2 'leading whitespace does not hide a bare cd'
run_hook 'cd /tmp';       assert_eq "$rc" 2 'cd with a path is refused'
run_hook 'cd ~/dev';      assert_eq "$rc" 2 'cd to a home-relative path is refused'
run_hook 'cd ..';         assert_eq "$rc" 2 'cd .. is refused'
run_hook 'cd "$repo"';    assert_eq "$rc" 2 'a quoted operand alone is still a bare cd'

echo "=== block-bare-cd: the first line of every condition ==="
# The value is the line the hook refused, so the row that carries an operand
# and the row that carries none reach different values.
first_table "\
a line that is only a cd reaches the refused key|command|2|block-bare-cd: refused=bare-cd|cd /tmp
a bare cd with no operand reaches the same one|command|2|block-bare-cd: refused=bare-cd|cd
a scoped move says nothing|command|0|-|(cd /tmp && ls)
a payload that is not JSON is refused unread|payload|2|block-bare-cd: payload=invalid-json|not JSON
"
run_hook 'cd'
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

payload_table "$HOOK" 'cd /tmp' '(cd /tmp && ls)'

# Python launcher writers and cat file writers send these bodies as command
# input. A missing terminator grants no exemption to later command lines.
echo "=== block-bare-cd: here-document bodies ==="
first_table "\
a Python string containing a future cd is input|command|0|-|python3 - <<'PY'\nbody = '''#!/usr/bin/env bash\ncd /some/root\n'''\nPY
a cat body is input|command|0|-|cat > f.sh <<EOF\ncd /x\nEOF
a double-quoted delimiter closes the body|command|0|-|cat <<\"EOF\"\ncd /x\nEOF
tabs before a tab-stripped terminator close the body|command|0|-|cat <<-EOF\ncd /x\n\tEOF
a bare cd before the body is still refused|command|2|block-bare-cd: refused=bare-cd|cd /tmp\ncat <<EOF\ncd /x\nEOF
a bare cd on the opening line is still refused|command|2|block-bare-cd: refused=bare-cd|cd <<EOF\ntext\nEOF
a bare cd after the terminator is still refused|command|2|block-bare-cd: refused=bare-cd|cat <<EOF\ncd /x\nEOF\ncd /tmp
a missing terminator leaves later lines judged|command|2|block-bare-cd: refused=bare-cd|cat <<EOF\ncd /tmp
a here-string leaves later lines judged|command|2|block-bare-cd: refused=bare-cd|cat <<<x\ncd /tmp
a quoted marker with no terminator leaves later lines judged|command|2|block-bare-cd: refused=bare-cd|echo '<<EOF'\ncd /tmp
spaces before a tab-stripped terminator do not close the body|command|2|block-bare-cd: refused=bare-cd|cat <<-EOF\ncd /tmp\n EOF
an ordinary delimiter needs an exact terminator|command|2|block-bare-cd: refused=bare-cd|cat <<EOF\ncd /tmp\n\tEOF
a second body on one opening line keeps its judgement|command|2|block-bare-cd: refused=bare-cd|cat <<FIRST <<SECOND\ntext\nFIRST\ncd /tmp\nSECOND
"

# Each disposable hook runs this same suite. The legacy copy restores the
# original whole-command judgement; the other copy skips every later line.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  mkdir "$TMP_ROOT/legacy" "$TMP_ROOT/skip"
  marker_count=$(grep -cF 'STRIPPED=$(echo "$JUDGED"' "$HOOK")
  assert_eq "$marker_count" 1 'the legacy mutation has one target'
  sed 's/echo "\$JUDGED"/echo "$COMMAND"/' "$HOOK" >"$TMP_ROOT/legacy/block-bare-cd.sh"
  marker_count=$(grep -cF 'if [[ ${LINES[$i]} =~ $HEREDOC_RE ]]; then' "$HOOK")
  assert_eq "$marker_count" 1 'the skip mutation has one target'
  sed '/if \[\[ ${LINES\[\$i\]} =~ \$HEREDOC_RE \]\]; then/i\
  if [[ ${LINES[$i]} == *"<<"* ]]; then break; fi
' "$HOOK" >"$TMP_ROOT/skip/block-bare-cd.sh"
  for mutant in legacy skip; do
    if cmp -s "$HOOK" "$TMP_ROOT/$mutant/block-bare-cd.sh"; then
      assert_eq unchanged changed "$mutant changes its disposable hook"
      continue
    fi
    control_rc=0
    env -i HOME="$HOME" PATH="$PATH" PWD="$PWD" HOOK_UNDER_TEST="$TMP_ROOT/$mutant/block-bare-cd.sh" "$BASH_BIN" "$TEST_DIR/block-bare-cd.test.sh" >"$TMP_ROOT/$mutant.log" 2>&1 || control_rc=$?
    cat "$TMP_ROOT/$mutant.log"
    assert_eq "$control_rc" 1 "$mutant turns this suite red"
  done
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
