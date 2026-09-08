#!/usr/bin/env bash
# Tests for the block-worktree-refresh hook.
#
# The hook refuses a project-scope kendex write from a linked worktree and
# passes the same command from the main checkout, with a global scope, outside
# a repository, and every kendex read. Each part is varied below: the verb,
# the scope words, the directory the command runs in, and the git that has to
# answer.
#
# Every refusal opens with `block-worktree-refresh: <key>=<value>`, and that
# line is the contract: every row pins it whole beside the exit status, and the
# English under it is not asserted. The remedy the refusal must carry is the
# verb's global option, pinned as the option spelling itself.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
# precondition: The outside rows prove the not-a-repository branch only where the fixture
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

# The shared first-line table runs a command in the linked worktree, the
# directory this hook exists to protect.
run_hook() { # command -> rc, stderr in ERR_FILE
  run_in "$WT" "$1"
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The hook's dependency list, in the order it checks them: the shared table
# pins it as the value of the world that has none of them.
PAYLOAD_TOOLS=jq,git,cat

# shellcheck source=lib/payload-rows.sh
. "$TEST_DIR/lib/payload-rows.sh"

BROKEN="$TMP_ROOT/broken"
mkdir -p "$BROKEN"
printf 'gitdir: %s/nowhere\n' "$TMP_ROOT" >"$BROKEN/.git"
MALFORMED="$TMP_ROOT/malformed"
mkdir -p "$MALFORMED/.git" "$MALFORMED/sub"

# The command is the last field, so read keeps literal pipes in it. printf %b
# decodes the newline and backslash-newline fixtures without splitting rows.
command_table() {
  local row label expected first command field got before=$((PASS + FAIL))
  echo "=== block-worktree-refresh: command forms from the linked worktree ==="
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label expected first command <<<"$row"
    for field in "$label" "$expected" "$first" "$command"; do
      [ "$field" != "" ] || { printf 'command table: a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    command=$(printf '%b' "$command")
    run_in "$WT" "$command"
    got="rc=$rc first=$(first_line)"
    if [ "${HOOKS_TABLE_PROBE:-}" = 1 ]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$expected first=$first" "$label"
  done <<<"$COMMAND_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo 'command table: no row was asserted (a probe run renders rows instead)' >&2; exit 2; }
}

directory_table() {
  local row label mode world expected first command field dir before=$((PASS + FAIL))
  echo "=== block-worktree-refresh: directory and git state ==="
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label mode world expected first command <<<"$row"
    for field in "$label" "$mode" "$world" "$expected" "$first" "$command"; do
      [ "$field" != "" ] || { printf 'directory table: a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    case "$world" in
      main) dir="$MAIN" ;;
      worktree) dir="$WT" ;;
      outside) dir="$OUTSIDE" ;;
      broken) dir="$BROKEN" ;;
      absent) dir="$TMP_ROOT/absent" ;;
      malformed) dir="$MALFORMED/sub" ;;
      *) printf 'directory table: unknown world: %s\n' "$world" >&2; exit 1 ;;
    esac
    case "$mode" in
      payload) run_in "$dir" "$command" ;;
      pwd) run_from "$dir" "$command" ;;
      *) printf 'directory table: unknown cwd mode: %s\n' "$mode" >&2; exit 1 ;;
    esac
    if [ "${HOOKS_TABLE_PROBE:-}" = 1 ]; then
      printf '%s => rc=%s first=%s\n' "$label" "$rc" "$(first_line)"
      continue
    fi
    assert_eq "rc=$rc first=$(first_line)" "rc=$expected first=$first" "$label"
  done <<<"$DIRECTORY_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo 'directory table: no row was asserted (a probe run renders rows instead)' >&2; exit 2; }
}

# label|status|first line|command
# The quoted pair and verb help are refused; the bare source shorthand is
# not read. These are stated limits, not requests for a tokenizer.
# A `source add` and a `source remove` reach the values `add` and `remove`:
# the pattern's earlier alternative ends at the same word, and a POSIX match
# prefers the longer earlier subexpression, so the second word is the verb it
# reads. `source enable` and `source disable` have no earlier alternative and
# keep both words. The write is refused either way; what the value decides is
# which global option the refusal names.
COMMAND_ROWS=$(cat <<'ROWS'
kendex refresh from the worktree is refused|2|block-worktree-refresh: refused=refresh|kendex refresh
kendex apply from the worktree is refused|2|block-worktree-refresh: refused=apply|kendex apply
kendex add orch from the worktree is refused|2|block-worktree-refresh: refused=add|kendex add orch
kendex remove orch from the worktree is refused|2|block-worktree-refresh: refused=remove|kendex remove orch
kendex update-pi from the worktree is refused|2|block-worktree-refresh: refused=update-pi|kendex update-pi
kendex pin orch from the worktree is refused|2|block-worktree-refresh: refused=pin|kendex pin orch
kendex fork orch from the worktree is refused|2|block-worktree-refresh: refused=fork|kendex fork orch
kendex adopt from the worktree is refused|2|block-worktree-refresh: refused=adopt|kendex adopt
kendex drift-hook from the worktree is refused|2|block-worktree-refresh: refused=drift-hook|kendex drift-hook
kendex source add x from the worktree is refused, its second word the verb read|2|block-worktree-refresh: refused=add|kendex source add x
kendex source remove x from the worktree is refused, its second word the verb read|2|block-worktree-refresh: refused=remove|kendex source remove x
kendex source enable x from the worktree is refused|2|block-worktree-refresh: refused=source enable|kendex source enable x
kendex source disable x from the worktree is refused|2|block-worktree-refresh: refused=source disable|kendex source disable x
kendex marketplace subscribe x from the worktree is refused|2|block-worktree-refresh: refused=marketplace subscribe|kendex marketplace subscribe x
kendex marketplace unsubscribe x from the worktree is refused|2|block-worktree-refresh: refused=marketplace unsubscribe|kendex marketplace unsubscribe x
source list is a read|0|-|kendex source list
marketplace list is a read|0|-|kendex marketplace list
the verb is found after a chained command|2|block-worktree-refresh: refused=refresh|true && kendex refresh
the verb is found on the second line|2|block-worktree-refresh: refused=apply|echo x\nkendex apply
an absolute path in front of kendex is still kendex|2|block-worktree-refresh: refused=refresh|/home/u/.cargo/bin/kendex refresh
a quoted path in front of kendex is still kendex|2|block-worktree-refresh: refused=refresh|"/home/u/.cargo/bin/kendex" refresh
a quoted verb is still the verb|2|block-worktree-refresh: refused=refresh|kendex 'refresh'
the project scope spelled out is still the project scope|2|block-worktree-refresh: refused=refresh|kendex refresh --scope project
the -g scope passes|0|-|kendex refresh -g
the --global scope passes|0|-|kendex refresh --global
the --scope global words pass|0|-|kendex remove --scope global orch
the --scope=global word passes|0|-|kendex remove --scope=global orch
add takes the global scope as --global|0|-|kendex add --global orch
update-pi --check previews and is a read|0|-|kendex update-pi --check
update-pi -c is the same read|0|-|kendex update-pi -c
add from the worktree is refused|2|block-worktree-refresh: refused=add|kendex add orch
update-pi from the worktree is refused|2|block-worktree-refresh: refused=update-pi|kendex update-pi
a global write beside a read passes|0|-|kendex refresh -g; kendex verify
a global word in an earlier segment does not exempt a later write|2|block-worktree-refresh: refused=refresh|kendex refresh -g && kendex refresh
a -g on another command does not exempt the write|2|block-worktree-refresh: refused=refresh|ls -g && kendex refresh
the scope on a continued line is the write's own|0|-|kendex refresh \\\n  --scope global
--scope project beside -g is the project scope, which kendex gives precedence|2|block-worktree-refresh: refused=refresh|kendex refresh -g --scope project
--scope all beside --global includes the project scope|2|block-worktree-refresh: refused=refresh|kendex refresh --global --scope=all
a --scope value that is not the plain word global is not read as global|2|block-worktree-refresh: refused=refresh|kendex refresh --global --scope "project"
a root option before the verb is dropped by the CLI and exempts nothing|2|block-worktree-refresh: refused=refresh|kendex --global refresh
the -g after the verb is the one the CLI reads|0|-|kendex -g refresh -g
an option word between kendex and the verb does not hide the verb|2|block-worktree-refresh: refused=refresh|kendex --verbose refresh
an option with a value between kendex and the verb does not hide the verb|2|block-worktree-refresh: refused=refresh|kendex --harness claude-code refresh
the same before add|2|block-worktree-refresh: refused=add|kendex --method copy add orch
a -g behind a comment marker is not an option|2|block-worktree-refresh: refused=refresh|kendex refresh # -g
a -g inside a nested command is not this command's|2|block-worktree-refresh: refused=refresh|kendex refresh $(echo -g)
a commented-out write is not a write|0|-|# kendex refresh
updates --apply delegates to refresh and is refused|2|block-worktree-refresh: refused=updates|kendex updates --apply
updates without --apply is a read|0|-|kendex updates
a global updates --apply passes|0|-|kendex updates --apply -g
kendex verify from the worktree passes|0|-|kendex verify
kendex check from the worktree passes|0|-|kendex check
kendex list from the worktree passes|0|-|kendex list
kendex report x from the worktree passes|0|-|kendex report x
kendex guard check from the worktree passes|0|-|kendex guard check
kendex --help from the worktree passes|0|-|kendex --help
a command without kendex passes|0|-|git status
the verb before the kendex word is not the command|0|-|refresh kendex
the two glued together are another word|0|-|kendexrefresh
the pair inside a quoted string is refused|2|block-worktree-refresh: refused=refresh|echo "run kendex refresh from main"
a help read spelling the verb is refused; kendex --help is the read that passes|2|block-worktree-refresh: refused=refresh|kendex refresh --help
the bare source shorthand for add is not read: it is every kendex word|0|-|kendex vanillagreencom/kendex
ROWS
)
command_table

# label|cwd source|world|status|first line|command
DIRECTORY_ROWS=$(cat <<ROWS
a cd before the verb moves the write out of the directory git is asked about|payload|main|2|block-worktree-refresh: moved=refresh|cd $WT && kendex refresh
a pushd in an earlier segment is a move too|payload|outside|2|block-worktree-refresh: moved=apply|pushd $WT; kendex apply
a global write after a cd passes: no directory is written|payload|main|0|-|cd $WT && kendex refresh -g
a cd after the verb does not move the write|payload|main|0|-|kendex refresh && cd $WT
without a cwd in the payload the hook judges the directory it runs in|pwd|worktree|2|block-worktree-refresh: refused=refresh|kendex refresh
the same write from the main checkout passes|payload|main|0|-|kendex refresh
outside a repository there is no worktree to protect|payload|outside|0|-|kendex refresh
a .git file pointing nowhere is a git that could not answer, and its status is the value|payload|broken|2|block-worktree-refresh: git=128|kendex refresh
a cwd that does not exist is refused, not read as outside a repository|payload|absent|2|block-worktree-refresh: git=128|kendex refresh
an empty .git directory above the cwd is a repository git could not read, not the absence of one|payload|malformed|2|block-worktree-refresh: git=unreadable|kendex refresh
ROWS
)
directory_table

echo "=== block-worktree-refresh: payloads it cannot read ==="
first_table "\
an empty payload refuses rather than passing as an absent command|payload|2|block-worktree-refresh: payload=empty|-
a cwd that is not a string refuses|payload|2|block-worktree-refresh: payload=invalid-cwd|{\"tool_input\":{\"command\":\"kendex refresh\"},\"cwd\":5}
the global option of the verb is what the refusal offers|command|2|block-worktree-refresh: refused=add|kendex add orch
"
assert_contains "$ERR_FILE" '--global' 'the add refusal names the global option add takes'
run_in "$WT" 'kendex update-pi'
assert_contains "$ERR_FILE" '--scope global' 'and update-pi names the one it takes'
run_in "$WT" 'kendex refresh'
assert_contains "$ERR_FILE" '--scope global (or --global)' 'while a verb taking either names both'
assert_contains "$ERR_FILE" 'git worktree list' 'the refusal names the command that finds the main checkout'
set +e
(cd "$WT" && "$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE")
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: payload=unreadable' \
  'a stdin that cannot be read refuses with the refusal status, not the read error'

payload_table "$HOOK" 'kendex refresh' 'kendex verify' "$WT"

echo "=== block-worktree-refresh: a missing git refuses ==="
NOGIT_BIN="$TMP_ROOT/nogit"
mkdir -p "$NOGIT_BIN"
for tool in bash cat jq; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NOGIT_BIN/$tool"
done
run_payload '{"tool_input":{"command":"kendex refresh"}}' "$NOGIT_BIN"
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: missing-tools=git' \
  'without git the guard refuses rather than skipping, and the value names git alone'

echo
echo "block-worktree-refresh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
