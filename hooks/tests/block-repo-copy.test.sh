#!/usr/bin/env bash
# Tests for the block-repo-copy hook.
#
# One regex decides, and it has three parts in the order the words stand: a
# copy verb, a source word whose last path component is `.git` or `target`, and
# a destination under /tmp, /var/tmp or $TMPDIR. Each part is varied
# independently below, so a change that dropped one of them reds here rather
# than scoring on the other two. Nothing is resolved or stat-ed, so there are no
# filesystem fixtures: the command's own text is the whole input.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-repo-copy.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

assert_eq() {
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
json_for() {
  local c
  c=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$c"
}

run_hook() { # command -> rc, stderr in $err
  set +e
  json_for "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    printf '%s' "$1" | env -i HOME="$HOME" PWD="$PWD" PATH="$2" "$BASH_BIN" "$HOOK" \
      >/dev/null 2>"$ERR_FILE"
  else
    printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  fi
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

REPO=/home/agent/dev/project

echo "=== block-repo-copy: every copy verb reaches the same verdict ==="
run_hook "cp -r $REPO/.git /tmp/copy";                 assert_eq "$rc" 2 'cp of a .git directory into /tmp is refused'
run_hook "rsync -a $REPO/target /tmp/copy";            assert_eq "$rc" 2 'rsync of a build tree into /tmp is refused'
run_hook "git clone $REPO/.git /tmp/copy";             assert_eq "$rc" 2 'a local git clone into /tmp is refused'
run_hook "tar -cf - $REPO/target | tar -xf - -C /tmp"; assert_eq "$rc" 2 'a tar create-to-extract pipe into /tmp is refused'
run_hook "mkdir -p /tmp/x && cp -a $REPO/.git /tmp/x"; assert_eq "$rc" 2 'the copy is found in a chained command'

echo "=== block-repo-copy: the source half of the predicate ==="
run_hook "cp -r $REPO/target/ /tmp/copy";      assert_eq "$rc" 2 'a trailing slash does not hide the component'
run_hook "cp -r \"$REPO/spaced dir/.git\" /tmp/copy"; assert_eq "$rc" 2 'a quoted source path containing a space is still read'
# Same verb, same destination, a source that is neither marker: the source half
# is what decides. Without this row, refusing every copy into /tmp would score.
run_hook "cp -r $REPO/docs /tmp/copy";         assert_eq "$rc" 0 'a source naming neither .git nor target is copied freely'
run_hook "cp $REPO/target/debug/kendex /tmp/kendex"; assert_eq "$rc" 0 'one file out of a build tree is not a tree copy'

echo "=== block-repo-copy: the destination half of the predicate ==="
run_hook "cp -r $REPO/.git /var/tmp/copy";   assert_eq "$rc" 2 '/var/tmp is a scratch destination'
run_hook 'cp -r '"$REPO"'/.git $TMPDIR/keep';   assert_eq "$rc" 2 'an unexpanded $TMPDIR destination is a scratch destination'
run_hook 'cp -r '"$REPO"'/.git ${TMPDIR}/keep'; assert_eq "$rc" 2 'the braced form of the same variable is too'
run_hook "cp -r $REPO/.git /tmp";            assert_eq "$rc" 2 'the temp root itself is a scratch destination'
# Same verb, same source, a destination outside every temp root: the
# destination half is what decides.
run_hook "cp -r $REPO/.git /srv/archive/keepme"; assert_eq "$rc" 0 'a repository copied outside scratch is allowed'
run_hook "cp -r $REPO/.git /home/agent/tmp/x";   assert_eq "$rc" 0 'a temp root spelled inside a longer path is not the temp root'

echo "=== block-repo-copy: commands that are not copies at all ==="
run_hook "git status --short";               assert_eq "$rc" 0 'a non-copy command passes'
run_hook "ls -la $REPO/.git /tmp";           assert_eq "$rc" 0 'reading a repository next to a scratch path is not a copy'
run_hook "grep -rn target /tmp/build.log";   assert_eq "$rc" 0 'a word merely containing tar is not the verb'
run_hook "cargo build --target x86_64-unknown-linux-gnu"; assert_eq "$rc" 0 'a --target flag is not a source operand'

echo "=== block-repo-copy: the refusal names the cause and the alternatives ==="
run_hook "cp -r $REPO/target /tmp/copy"
assert_contains "$err" "cp -r $REPO/target /tmp/copy" 'the refusal quotes the command it judged'
assert_contains "$err" "ENOSPC" 'the refusal names the failure the copy causes'
assert_contains "$err" "Read the source in place" 'the refusal offers reading in place'
assert_contains "$err" "MINIMAL synthetic fixture" 'the refusal offers a minimal fixture'
assert_contains "$err" 'mktemp -d' 'the refusal shows how to build the fixture'

echo "=== block-repo-copy: a payload it cannot read refuses ==="
run_payload "{\"tool_input\":{\"command\":\"cp -r $REPO/.git /tmp/copy"
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$err" 'not valid JSON' 'the parse refusal names the cause'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":false}}'
assert_eq "$rc" 2 'a command of false refuses, not read as an absent one'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'

NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
# type -P, not command -v: cat and friends are shell functions in some
# interactive environments, and a function name symlinks to nothing.
for tool in cat sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload "{\"tool_input\":{\"command\":\"cp -r $REPO/.git /tmp/copy\"}}" "$NOJQ_BIN"
assert_eq "$rc" 2 'no jq refuses rather than guessing at the payload'
assert_contains "$err" 'required to read the hook payload' 'the refusal names what is missing'
run_payload "{\"tool_input\":{\"command\":\"git status --short\"}}" /nonexistent
assert_eq "$rc" 2 'no text tools at all refuses too, whatever the command'

echo "=== block-repo-copy: the two stated limits ==="
# Reading the command's text rather than resolving its operands costs in both
# directions, and both costs are rows so nobody grows a tokenizer back to close
# either. A source spelled as the working tree that HOLDS the repository is not
# seen; a copy spelled inside a quoted string is read as the copy it is not.
run_hook "cp -r $REPO /tmp/copy"
assert_eq "$rc" 0 'a repository named by its working-tree path is not seen'
run_hook "echo \"cp -r $REPO/.git /tmp/copy\" >>notes.md"
assert_eq "$rc" 2 'a copy spelled inside a quoted string is refused as the copy it is not'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
