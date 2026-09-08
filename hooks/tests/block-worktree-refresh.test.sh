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
  local row label expected value clause command field global_form before=$((PASS + FAIL))
  echo "=== block-worktree-refresh: command forms from the linked worktree ==="
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label expected value clause command <<<"$row"
    for field in "$label" "$expected" "$value" "$clause" "$command"; do
      [ "$field" != "" ] || { printf 'command table: a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    command=$(printf '%b' "$command")
    run_in "$WT" "$command"
    if [ "${HOOKS_TABLE_PROBE:-}" = 1 ]; then
      printf '%s => rc=%s\n' "$label" "$rc"
      continue
    fi
    assert_eq "$rc" "$expected" "$label"
    if [ "$value" != - ]; then
      global_form=$(sed -n 's/.*or pass \(.*\) for a global change.*/\1/p' "$ERR_FILE")
      assert_eq "$global_form" "$value" "$label: global option value"
    fi
    if [ "$clause" != - ]; then assert_contains "$ERR_FILE" "$clause" "$label: checkout command value"; fi
  done <<<"$COMMAND_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo 'command table: no row was asserted (a probe run renders rows instead)' >&2; exit 2; }
}

directory_table() {
  local row label mode world expected clause command field dir before=$((PASS + FAIL))
  echo "=== block-worktree-refresh: directory and git state ==="
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label mode world expected clause command <<<"$row"
    for field in "$label" "$mode" "$world" "$expected" "$clause" "$command"; do
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
      printf '%s => rc=%s\n' "$label" "$rc"
      continue
    fi
    assert_eq "$rc" "$expected" "$label"
    if [ "$clause" != - ]; then assert_contains "$ERR_FILE" "$clause" "$label: refusal clause"; fi
  done <<<"$DIRECTORY_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo 'directory table: no row was asserted (a probe run renders rows instead)' >&2; exit 2; }
}

# label|status|global option value|checkout command value|command
# The quoted pair and verb help are refused; the bare source shorthand is
# not read. These are stated limits, not requests for a tokenizer.
COMMAND_ROWS=$(cat <<'ROWS'
kendex refresh from the worktree is refused|2|-|-|kendex refresh
kendex apply from the worktree is refused|2|-|-|kendex apply
kendex add orch from the worktree is refused|2|-|-|kendex add orch
kendex remove orch from the worktree is refused|2|-|-|kendex remove orch
kendex update-pi from the worktree is refused|2|-|-|kendex update-pi
kendex pin orch from the worktree is refused|2|-|-|kendex pin orch
kendex fork orch from the worktree is refused|2|-|-|kendex fork orch
kendex adopt from the worktree is refused|2|-|-|kendex adopt
kendex drift-hook from the worktree is refused|2|-|-|kendex drift-hook
kendex source add x from the worktree is refused|2|-|-|kendex source add x
kendex source remove x from the worktree is refused|2|-|-|kendex source remove x
kendex source enable x from the worktree is refused|2|-|-|kendex source enable x
kendex source disable x from the worktree is refused|2|-|-|kendex source disable x
kendex marketplace subscribe x from the worktree is refused|2|-|-|kendex marketplace subscribe x
kendex marketplace unsubscribe x from the worktree is refused|2|--scope global (or --global)|git worktree list|kendex marketplace unsubscribe x
source list is a read|0|-|-|kendex source list
marketplace list is a read|0|-|-|kendex marketplace list
the verb is found after a chained command|2|-|-|true && kendex refresh
the verb is found on the second line|2|-|-|echo x\nkendex apply
an absolute path in front of kendex is still kendex|2|-|-|/home/u/.cargo/bin/kendex refresh
a quoted path in front of kendex is still kendex|2|-|-|"/home/u/.cargo/bin/kendex" refresh
a quoted verb is still the verb|2|-|-|kendex 'refresh'
the project scope spelled out is still the project scope|2|-|-|kendex refresh --scope project
the -g scope passes|0|-|-|kendex refresh -g
the --global scope passes|0|-|-|kendex refresh --global
the --scope global words pass|0|-|-|kendex remove --scope global orch
the --scope=global word passes|0|-|-|kendex remove --scope=global orch
add takes the global scope as --global|0|-|-|kendex add --global orch
update-pi --check previews and is a read|0|-|-|kendex update-pi --check
update-pi -c is the same read|0|-|-|kendex update-pi -c
add from the worktree is refused|2|--global|-|kendex add orch
update-pi from the worktree is refused|2|--scope global|-|kendex update-pi
a global write beside a read passes|0|-|-|kendex refresh -g; kendex verify
a global word in an earlier segment does not exempt a later write|2|-|-|kendex refresh -g && kendex refresh
a -g on another command does not exempt the write|2|-|-|ls -g && kendex refresh
the scope on a continued line is the write's own|0|-|-|kendex refresh \\\n  --scope global
--scope project beside -g is the project scope, which kendex gives precedence|2|-|-|kendex refresh -g --scope project
--scope all beside --global includes the project scope|2|-|-|kendex refresh --global --scope=all
a --scope value that is not the plain word global is not read as global|2|-|-|kendex refresh --global --scope "project"
a root option before the verb is dropped by the CLI and exempts nothing|2|-|-|kendex --global refresh
the -g after the verb is the one the CLI reads|0|-|-|kendex -g refresh -g
an option word between kendex and the verb does not hide the verb|2|-|-|kendex --verbose refresh
an option with a value between kendex and the verb does not hide the verb|2|-|-|kendex --harness claude-code refresh
the same before add|2|-|-|kendex --method copy add orch
a -g behind a comment marker is not an option|2|-|-|kendex refresh # -g
a -g inside a nested command is not this command's|2|-|-|kendex refresh $(echo -g)
a commented-out write is not a write|0|-|-|# kendex refresh
updates --apply delegates to refresh and is refused|2|-|-|kendex updates --apply
updates without --apply is a read|0|-|-|kendex updates
a global updates --apply passes|0|-|-|kendex updates --apply -g
kendex verify from the worktree passes|0|-|-|kendex verify
kendex check from the worktree passes|0|-|-|kendex check
kendex list from the worktree passes|0|-|-|kendex list
kendex report x from the worktree passes|0|-|-|kendex report x
kendex guard check from the worktree passes|0|-|-|kendex guard check
kendex --help from the worktree passes|0|-|-|kendex --help
a command without kendex passes|0|-|-|git status
the verb before the kendex word is not the command|0|-|-|refresh kendex
the two glued together are another word|0|-|-|kendexrefresh
the pair inside a quoted string is refused|2|-|-|echo "run kendex refresh from main"
a help read spelling the verb is refused; kendex --help is the read that passes|2|-|-|kendex refresh --help
the bare source shorthand for add is not read: it is every kendex word|0|-|-|kendex vanillagreencom/kendex
ROWS
)
command_table

# label|cwd source|world|status|refusal clause|command
DIRECTORY_ROWS=$(cat <<ROWS
a cd before the verb moves the write out of the directory git is asked about|payload|main|2|after a cd or pushd|cd $WT && kendex refresh
a pushd in an earlier segment is a move too|payload|outside|2|-|pushd $WT; kendex apply
a global write after a cd passes: no directory is written|payload|main|0|-|cd $WT && kendex refresh -g
a cd after the verb does not move the write|payload|main|0|-|kendex refresh && cd $WT
without a cwd in the payload the hook judges the directory it runs in|pwd|worktree|2|-|kendex refresh
the same write from the main checkout passes|payload|main|0|-|kendex refresh
outside a repository there is no worktree to protect|payload|outside|0|-|kendex refresh
a .git file pointing nowhere is a git that could not answer|payload|broken|2|could not say whether|kendex refresh
a cwd that does not exist is refused, not read as outside a repository|payload|absent|2|-|kendex refresh
an empty .git directory above the cwd is a repository git could not read, not the absence of one|payload|malformed|2|exists but git could not read|kendex refresh
ROWS
)
directory_table

echo "=== block-worktree-refresh: a payload it cannot read refuses ==="
run_payload ''
assert_eq "$rc" 2 'an empty payload refuses rather than passing as an absent command'
set +e
(cd "$WT" && "$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE")
rc=$?
set -e
assert_eq "$rc" 2 'a stdin that cannot be read refuses with the refusal status, not the read error'
run_payload '{"tool_input":{"command":"kendex refresh"},"cwd":5}'
assert_eq "$rc" 2 'a cwd that is not a string refuses'

payload_table "$HOOK" 'kendex refresh' 'kendex verify' "$WT"

echo "=== block-worktree-refresh: a missing git refuses ==="
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
