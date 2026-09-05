#!/usr/bin/env bash
# Tests for the block-worktree-refresh hook.
#
# The hook refuses a project-scope kendex write from a linked worktree and
# passes the same command from the main checkout, with a global scope, outside
# a repository, and every kendex read. Each part is varied below: the verb,
# the scope words, the directory the command runs in, and the git that has to
# answer.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-worktree-refresh.sh}"

PASS=0
FAIL=0
# The hook prints physical paths, so the fixture root is held as one: under a
# symlinked TMPDIR mktemp's spelling and pwd -P's differ.
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"
# The fixture's own git calls must build the fixture, not whatever repository
# a wrapper's redirection variables name.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
printf '[user]\n\temail = t@t\n\tname = t\n[init]\n\tdefaultBranch = main\n' >"$HOME/.gitconfig"

assert_eq() {
  if [ "$1" = "$2" ]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$1")"; fi
}

# A main checkout with one commit and a linked worktree beside it.
MAIN="$TMP_ROOT/main"
git init -q "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m init
WT="$TMP_ROOT/wt"
git -C "$MAIN" worktree add -q "$WT" -b lane
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"
# The outside rows prove the not-a-repository branch only where the fixture
# root itself is outside every repository; a TMPDIR inside a checkout would
# make them pass or fail for another reason.
if git -C "$OUTSIDE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "block-worktree-refresh: the fixture root $TMP_ROOT is inside a git repository; run with TMPDIR outside one" >&2
  exit 2
fi

json_for() { # command [cwd] -> payload as Claude Code sends it
  if [ -n "${2:-}" ]; then
    jq -nc --arg c "$1" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'
  else
    jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
  fi
}

run_in() { # dir command -> rc, stderr in ERR_FILE; the payload names the cwd
  set +e
  json_for "$2" "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

run_from() { # dir command -> rc; no cwd in the payload, the hook runs in dir
  set +e
  (cd "$1" && json_for "$2" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE")
  rc=$?
  set -e
}

run_payload() { # raw-json [PATH] -> rc, stderr in ERR_FILE, run in the worktree
  set +e
  if [ -n "${2:-}" ]; then
    (cd "$WT" && printf '%s' "$1" | env -i HOME="$HOME" PWD="$WT" PATH="$2" "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE")
  else
    (cd "$WT" && printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE")
  fi
  rc=$?
  set -e
}

echo "=== block-worktree-refresh: a project-scope write from a linked worktree is refused ==="
for verb in refresh apply 'add orch' 'remove orch' update-pi; do
  run_in "$WT" "kendex $verb"; assert_eq "$rc" 2 "kendex $verb from the worktree is refused"
done
assert_contains "$ERR_FILE" 'git worktree list' 'the refusal names how to find the main checkout'
assert_contains "$ERR_FILE" '--scope global' 'the refusal names the global scope'
run_in "$WT" 'true && kendex refresh';            assert_eq "$rc" 2 'the verb is found after a chained command'
run_in "$MAIN" "cd $WT && kendex refresh";        assert_eq "$rc" 2 'a cd before the verb moves the write out of the directory git is asked about'
assert_contains "$ERR_FILE" 'after a cd or pushd' 'the refusal names the move'
run_in "$OUTSIDE" "pushd $WT; kendex apply";      assert_eq "$rc" 2 'a pushd in an earlier segment is a move too'
run_in "$MAIN" "cd $WT && kendex refresh -g";     assert_eq "$rc" 0 'a global write after a cd passes: no directory is written'
run_in "$MAIN" "kendex refresh && cd $WT";        assert_eq "$rc" 0 'a cd after the verb does not move the write'
run_in "$WT" "$(printf 'echo x\nkendex apply')";  assert_eq "$rc" 2 'the verb is found on the second line'
run_in "$WT" '/home/u/.cargo/bin/kendex refresh'; assert_eq "$rc" 2 'an absolute path in front of kendex is still kendex'
run_in "$WT" '"/home/u/.cargo/bin/kendex" refresh'; assert_eq "$rc" 2 'a quoted path in front of kendex is still kendex'
run_in "$WT" "kendex 'refresh'";                  assert_eq "$rc" 2 'a quoted verb is still the verb'
run_in "$WT" 'kendex refresh --scope project';    assert_eq "$rc" 2 'the project scope spelled out is still the project scope'
run_from "$WT" 'kendex refresh';                  assert_eq "$rc" 2 'without a cwd in the payload the hook judges the directory it runs in'

echo "=== block-worktree-refresh: the right forms pass ==="
run_in "$MAIN" 'kendex refresh';                  assert_eq "$rc" 0 'the same write from the main checkout passes'
run_in "$WT" 'kendex refresh -g';                 assert_eq "$rc" 0 'the -g scope passes'
run_in "$WT" 'kendex refresh --global';           assert_eq "$rc" 0 'the --global scope passes'
run_in "$WT" 'kendex remove --scope global orch'; assert_eq "$rc" 0 'the --scope global words pass'
run_in "$WT" 'kendex remove --scope=global orch'; assert_eq "$rc" 0 'the --scope=global word passes'
run_in "$WT" 'kendex add --global orch';          assert_eq "$rc" 0 'add takes the global scope as --global'
run_in "$WT" 'kendex update-pi --check';          assert_eq "$rc" 0 'update-pi --check previews and is a read'
run_in "$WT" 'kendex update-pi -c';               assert_eq "$rc" 0 'update-pi -c is the same read'
run_in "$WT" 'kendex add orch';                   assert_eq "$rc" 2 'add from the worktree is refused'
assert_contains "$ERR_FILE" 'pass --global for a global change' 'the add refusal names the form add accepts'
run_in "$WT" 'kendex update-pi';                  assert_eq "$rc" 2 'update-pi from the worktree is refused'
assert_contains "$ERR_FILE" 'pass --scope global for a global change' 'the update-pi refusal names the form update-pi accepts'
run_in "$WT" 'kendex refresh -g; kendex verify';  assert_eq "$rc" 0 'a global write beside a read passes'
run_in "$WT" 'kendex refresh -g && kendex refresh'; assert_eq "$rc" 2 'a global word in an earlier segment does not exempt a later write'
run_in "$WT" 'ls -g && kendex refresh';            assert_eq "$rc" 2 'a -g on another command does not exempt the write'
run_in "$WT" "$(printf 'kendex refresh \\\n  --scope global')"; assert_eq "$rc" 0 'the scope on a continued line is the write'"'"'s own'
run_in "$WT" 'kendex refresh -g --scope project';  assert_eq "$rc" 2 '--scope project beside -g is the project scope, which kendex gives precedence'
run_in "$WT" 'kendex refresh --global --scope=all'; assert_eq "$rc" 2 '--scope all beside --global includes the project scope'
run_in "$WT" 'kendex refresh --global --scope "project"'; assert_eq "$rc" 2 'a --scope value that is not the plain word global is not read as global'
run_in "$WT" 'kendex --global refresh';            assert_eq "$rc" 2 'a root option before the verb is dropped by the CLI and exempts nothing'
run_in "$WT" 'kendex -g refresh -g';               assert_eq "$rc" 0 'the -g after the verb is the one the CLI reads'
run_in "$WT" 'kendex --verbose refresh';           assert_eq "$rc" 2 'an option word between kendex and the verb does not hide the verb'
run_in "$WT" 'kendex --harness claude-code refresh'; assert_eq "$rc" 2 'an option with a value between kendex and the verb does not hide the verb'
run_in "$WT" 'kendex --method copy add orch';      assert_eq "$rc" 2 'the same before add'
run_in "$WT" 'kendex refresh # -g';                assert_eq "$rc" 2 'a -g behind a comment marker is not an option'
run_in "$WT" 'kendex refresh $(echo -g)';          assert_eq "$rc" 2 'a -g inside a nested command is not this command'"'"'s'
run_in "$WT" '# kendex refresh';                   assert_eq "$rc" 0 'a commented-out write is not a write'
run_in "$WT" 'kendex updates --apply';             assert_eq "$rc" 2 'updates --apply delegates to refresh and is refused'
run_in "$WT" 'kendex updates';                     assert_eq "$rc" 0 'updates without --apply is a read'
run_in "$WT" 'kendex updates --apply -g';          assert_eq "$rc" 0 'a global updates --apply passes'
for verb in verify check list 'report x' 'guard check' '--help'; do
  run_in "$WT" "kendex $verb"; assert_eq "$rc" 0 "kendex $verb from the worktree passes"
done
run_in "$OUTSIDE" 'kendex refresh';               assert_eq "$rc" 0 'outside a repository there is no worktree to protect'
run_in "$WT" 'git status';                        assert_eq "$rc" 0 'a command without kendex passes'
run_in "$WT" 'refresh kendex';                    assert_eq "$rc" 0 'the verb before the kendex word is not the command'
run_in "$WT" 'kendexrefresh';                     assert_eq "$rc" 0 'the two glued together are another word'

echo "=== block-worktree-refresh: the stated limits ==="
# The pair counts wherever it stands, so a command that only spells it, or a
# help read that spells it, is refused as the write it is not. Rows, so nobody
# grows a tokenizer or an exemption list to close them.
run_in "$WT" 'echo "run kendex refresh from main"'; assert_eq "$rc" 2 'the pair inside a quoted string is refused'
run_in "$WT" 'kendex refresh --help';               assert_eq "$rc" 2 'a help read spelling the verb is refused; kendex --help is the read that passes'
run_in "$WT" 'kendex vanillagreencom/kendex';       assert_eq "$rc" 0 'the bare source shorthand for add is not read: it is every kendex word'

echo "=== block-worktree-refresh: a git that cannot answer refuses ==="
BROKEN="$TMP_ROOT/broken"
mkdir -p "$BROKEN"
printf 'gitdir: %s/nowhere\n' "$TMP_ROOT" >"$BROKEN/.git"
run_in "$BROKEN" 'kendex refresh';                assert_eq "$rc" 2 'a .git file pointing nowhere is a git that could not answer'
assert_contains "$ERR_FILE" 'could not say whether' 'the refusal names the unanswered question'
run_in "$TMP_ROOT/absent" 'kendex refresh';       assert_eq "$rc" 2 'a cwd that does not exist is refused, not read as outside a repository'
MALFORMED="$TMP_ROOT/malformed"
mkdir -p "$MALFORMED/.git" "$MALFORMED/sub"
run_in "$MALFORMED/sub" 'kendex refresh';         assert_eq "$rc" 2 'an empty .git directory above the cwd is a repository git could not read, not the absence of one'
assert_contains "$ERR_FILE" 'exists but git could not read' 'the refusal names the .git entry it found'

echo "=== block-worktree-refresh: a payload it cannot read refuses ==="
run_payload ''
assert_eq "$rc" 2 'an empty payload refuses rather than passing as an absent command'
set +e
(cd "$WT" && "$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE")
rc=$?
set -e
assert_eq "$rc" 2 'a stdin that cannot be read refuses with the refusal status, not the read error'
run_payload '{"tool_input":{"command":"kendex refresh"'
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":"kendex refresh"},"cwd":5}'
assert_eq "$rc" 2 'a cwd that is not a string refuses'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'
run_payload '{"command":"kendex apply"}'
assert_eq "$rc" 2 'a top-level command field is read like a nested one'
run_payload '{"sessionId":"s","timestamp":1,"cwd":"'"$WT"'","toolName":"bash","toolArgs":{"command":"kendex refresh"}}'
assert_eq "$rc" 2 'a Copilot toolArgs object is read'
run_payload '{"toolName":"bash","toolArgs":"{\"command\":\"kendex refresh\"}"}'
assert_eq "$rc" 2 'a Copilot toolArgs JSON string is read'
run_payload '{"toolName":"bash","toolArgs":{"command":"kendex verify"}}'
assert_eq "$rc" 0 'a read under toolArgs passes, so the shape is read rather than refused'

echo "=== block-worktree-refresh: a missing reader refuses ==="
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat git; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NOJQ_BIN/$tool"
done
run_payload '{"tool_input":{"command":"kendex refresh"}}' "$NOJQ_BIN"
assert_eq "$rc" 2 'without jq the guard refuses rather than skipping'
assert_contains "$ERR_FILE" 'required to read the hook payload' 'the refusal names what is missing'
NOGIT_BIN="$TMP_ROOT/nogit"
mkdir -p "$NOGIT_BIN"
for tool in bash cat jq; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NOGIT_BIN/$tool"
done
run_payload '{"tool_input":{"command":"kendex refresh"}}' "$NOGIT_BIN"
assert_eq "$rc" 2 'without git the guard refuses rather than skipping'

echo
echo "block-worktree-refresh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
