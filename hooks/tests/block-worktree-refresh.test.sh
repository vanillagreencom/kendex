#!/usr/bin/env bash
# Tests for the block-worktree-refresh hook.
#
# The hook refuses a project-scope kendex write from a linked worktree and
# passes the same command from the main checkout, with a global scope, outside
# a repository, and every kendex read. In a linked worktree, the project
# kendex resolves from the working directory is the worktree's own where its
# manifest exists there, and the verbs that write one project by being typed
# inside it pass. Each part is varied below: the verb,
# the scope words, the directory the command runs in, whose manifest that
# worktree has, and the git that has to answer.
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
assert_not_contains() {
  if ! grep -qF -- "$2" "$1"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        unwanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$1")"; fi
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
# Two more linked worktrees whose roots carry a kendex.toml of their own, so
# each is its own project: one that parses and one with conflict markers,
# which is still the worktree's own file. The first worktree carries none.
OWN="$TMP_ROOT/own"
git -C "$MAIN" worktree add -q "$OWN" -b own
printf 'schema = 6\n' >"$OWN/kendex.toml"
OWN_BROKEN="$TMP_ROOT/own-broken"
git -C "$MAIN" worktree add -q "$OWN_BROKEN" -b own-broken
printf '<<<<<<< HEAD\nschema = 6\n=======\nschema = 5\n' >"$OWN_BROKEN/kendex.toml"
mkdir -p "$OWN/sub/deeper" "$WT/sub"
# The project kendex writes is the first directory up from the working one
# carrying a harness marker, which can sit below the worktree's root: one
# worktree whose project in app/ declares with none at its root, and a
# marker-only folder inside the declaring worktree, which is a project with
# no manifest of its own.
NESTED="$TMP_ROOT/nested"
git -C "$MAIN" worktree add -q "$NESTED" -b nested
mkdir -p "$NESTED/app/.claude"
printf 'schema = 6\n' >"$NESTED/app/kendex.toml"
mkdir -p "$OWN/marked/.claude"
# A source catalog declares in kendex-local.toml, its kendex.toml being the
# catalog it publishes: one worktree without that file and one with it. The
# hook reads any kendex.toml naming is_source_catalog as a catalog, so the key
# inside a table, after a multi-line string holding a table header, or quoted
# is a catalog too, and with no kendex-local.toml each is refused.
CATALOG="$TMP_ROOT/catalog"
git -C "$MAIN" worktree add -q "$CATALOG" -b catalog
printf 'schema = 6\nis_source_catalog = true\n' >"$CATALOG/kendex.toml"
CATALOG_LOCAL="$TMP_ROOT/catalog-local"
git -C "$MAIN" worktree add -q "$CATALOG_LOCAL" -b catalog-local
printf 'schema = 6\nis_source_catalog = true\n' >"$CATALOG_LOCAL/kendex.toml"
printf 'schema = 6\n' >"$CATALOG_LOCAL/kendex-local.toml"
# Claude Code puts a linked worktree inside the main checkout, under
# `.claude/worktrees/`, so the main checkout's marker and its untracked
# kendex.toml stand above the worktree's root; the walk stops at that root.
HOST="$TMP_ROOT/host"
git init -q "$HOST"
git -C "$HOST" commit -q --allow-empty -m init
mkdir -p "$HOST/.claude/worktrees"
printf 'schema = 6\n' >"$HOST/kendex.toml"
git -C "$HOST" worktree add -q "$HOST/.claude/worktrees/lane" -b lane
CATALOG_TABLED="$TMP_ROOT/catalog-tabled"
git -C "$MAIN" worktree add -q "$CATALOG_TABLED" -b catalog-tabled
printf 'schema = 6\n[marketplace]\nis_source_catalog = true\n' >"$CATALOG_TABLED/kendex.toml"
CATALOG_STRING="$TMP_ROOT/catalog-string"
git -C "$MAIN" worktree add -q "$CATALOG_STRING" -b catalog-string
printf 'description = """\n[not a table]\n"""\nis_source_catalog = true\n' >"$CATALOG_STRING/kendex.toml"
CATALOG_QUOTED="$TMP_ROOT/catalog-quoted"
git -C "$MAIN" worktree add -q "$CATALOG_QUOTED" -b catalog-quoted
printf '"is_source_catalog" = true\n' >"$CATALOG_QUOTED/kendex.toml"
# A project path with a space, which the refusal's remedy has to keep one word.
SPACED="$TMP_ROOT/sp/my app"
git -C "$MAIN" worktree add -q "$SPACED" -b spaced
printf 'schema = 6\n' >"$SPACED/kendex.toml"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"
# precondition: The outside rows prove the not-a-repository branch only where the fixture
# root itself is outside every repository; a TMPDIR inside a checkout would
# make them pass or fail for another reason.
if git -C "$OUTSIDE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "block-worktree-refresh: the fixture root $TMP_ROOT is inside a git repository; run with TMPDIR outside one" >&2
  exit 2
fi

json_for() { # command [cwd] [tool field] -> payload
  if [ -n "${3:-}" ]; then
    jq -nc --arg c "$1" --arg d "$2" --arg f "$3" --arg s "$WT" \
      '{tool_name: "Bash", cwd: $s, tool_input: ({command: $c} + {($f): $d})}'
  elif [ -n "${2:-}" ]; then
    jq -nc --arg c "$1" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'
  else
    jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
  fi
}

run_in() { # dir command [tool field] -> rc, stderr in ERR_FILE
  set +e
  json_for "$2" "$1" "${3:-}" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
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
# decodes the newline and backslash-newline fixtures without splitting rows,
# and the octal escapes `\0044`, `\0074` and `\0140` write the dollar sign, the
# less-than and the backtick a row needs: written literally inside this command
# substitution, tools/bash32-parse cannot follow the file to its end.
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
      own) dir="$OWN" ;;
      own-sub) dir="$OWN/sub/deeper" ;;
      own-broken) dir="$OWN_BROKEN" ;;
      worktree-sub) dir="$WT/sub" ;;
      nested-app) dir="$NESTED/app" ;;
      own-marked) dir="$OWN/marked" ;;
      catalog) dir="$CATALOG" ;;
      catalog-local) dir="$CATALOG_LOCAL" ;;
      catalog-tabled) dir="$CATALOG_TABLED" ;;
      catalog-string) dir="$CATALOG_STRING" ;;
      catalog-quoted) dir="$CATALOG_QUOTED" ;;
      hosted) dir="$HOST/.claude/worktrees/lane" ;;
      *) printf 'directory table: unknown world: %s\n' "$world" >&2; exit 1 ;;
    esac
    case "$mode" in
      payload) run_in "$dir" "$command" ;;
      tool-workdir) run_in "$dir" "$command" workdir ;;
      tool-cwd) run_in "$dir" "$command" cwd ;;
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
# The verb is read only where the shell would run it: the rows below vary the
# command position against a quoted argument, a heredoc body, a comment and
# the quoted argument of `-c` and `eval`. Verb help passes only on a plain
# tail; the bare source shorthand is not read.
# The verb is the first word after `kendex` that names one, so `source add`
# is read whole and a later verb word is an argument; the value decides which
# global option the refusal names, and `source` subcommands have none.
# The scope, target and apply options are the words Bash passes: a
# redirection's file is not one, a standalone `--` ends them, and a word the
# shell settles only when it runs grants nothing and counts as `--apply`.
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
kendex source add x from the worktree is refused, both words the verb read|2|block-worktree-refresh: refused=source add|kendex source add x
kendex source remove x from the worktree is refused, both words the verb read|2|block-worktree-refresh: refused=source remove|kendex source remove x
a later verb word is an argument, not the verb|2|block-worktree-refresh: refused=add|kendex add orch --skill refresh
a redirection glued to the verb ends the verb word|2|block-worktree-refresh: refused=refresh|kendex refresh>/dev/null
the same for update-pi|2|block-worktree-refresh: refused=update-pi|kendex update-pi>log
and for an input redirection|2|block-worktree-refresh: refused=refresh|kendex refresh\0074in
an operator glued to the verb takes the next word as its file|2|block-worktree-refresh: refused=refresh|kendex refresh> --global
a global option after a verb with a glued redirection passes|0|-|kendex refresh>out --global
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
help after a write verb is a read|0|-|kendex refresh --help
plan after a write verb is a read|0|-|kendex apply --plan
an escaped-space local path is not a help argument|2|block-worktree-refresh: refused=add|kendex add ./catalog\ --help -y
kendex verify from the worktree passes|0|-|kendex verify
kendex check from the worktree passes|0|-|kendex check
kendex list from the worktree passes|0|-|kendex list
kendex report x from the worktree passes|0|-|kendex report x
kendex guard check from the worktree passes|0|-|kendex guard check
kendex --help from the worktree passes|0|-|kendex --help
a command without kendex passes|0|-|git status
the verb before the kendex word is not the command|0|-|refresh kendex
the two glued together are another word|0|-|kendexrefresh
the pair inside a quoted argument is prose, not a command|0|-|echo "run kendex refresh from main"
a closing parenthesis inside an earlier quoted argument opens no command position for the next|0|-|dev-return-write --validate-note "pass (CI)." --no-summary --item 1 Applied "ran kendex update-pi from main"
nor does one inside an earlier single-quoted argument|0|-|echo 'pass (CI).' "run kendex refresh from main"
nor does a semicolon inside an earlier quoted argument|0|-|echo "a;." "run kendex refresh from main"
nor does a pipe|0|-|echo "a|eval" "run kendex refresh from main"
nor does an ampersand|0|-|echo "a&eval" "run kendex refresh from main"
nor does an opening parenthesis|0|-|echo 'a(.' "run kendex refresh from main"
nor does a backtick|0|-|echo 'a\0140.' "run kendex refresh from main"
a hash after a quoted separator starts no comment|2|block-worktree-refresh: refused=refresh|FOO="a;#" kendex refresh
an unquoted separator after a quoted argument still starts a command|2|block-worktree-refresh: refused=update-pi|dev-return-write --validate-note "pass (CI)." ; kendex update-pi
the pair inside a heredoc body is fed to a command, not run|0|-|cat <<EOF\nkendex refresh\nEOF
the pair behind a hash on the line is a comment|0|-|echo hi # kendex refresh
the quoted argument of -c is command text and is judged|2|block-worktree-refresh: refused=refresh|bash -c "kendex refresh"
the quoted argument of eval is command text too|2|block-worktree-refresh: refused=apply|eval "kendex apply"
a sudo before the verb does not hide it|2|block-worktree-refresh: refused=refresh|sudo kendex refresh
an unquoted eval before the verb does not hide it either|2|block-worktree-refresh: refused=refresh|eval kendex refresh
nor does a wrapper word the hook was never told about|2|block-worktree-refresh: refused=refresh|timeout 60 kendex refresh
a here-string fed to a shell is command text|2|block-worktree-refresh: refused=refresh|bash <<< "kendex refresh"
a heredoc body fed to a shell is command text|2|block-worktree-refresh: refused=refresh|bash <<EOF\nkendex refresh\nEOF
a redirection target is a file, not the interpreter of one|0|-|cat > script.sh <<EOF\nkendex refresh\nEOF
a marker only written down arms no heredoc, so the next line is still read|2|block-worktree-refresh: refused=refresh|echo '<<EOF'\nkendex refresh
a quoted interpreter path still runs what it is given|2|block-worktree-refresh: refused=refresh|"/bin/bash" -c "kendex refresh"
a quoted eval is still eval|2|block-worktree-refresh: refused=apply|"eval" "kendex apply"
two escaped quotes are literal arguments and pair with nothing|2|block-worktree-refresh: refused=refresh|echo \\" ; kendex refresh \\"
a hash after a semicolon begins a comment, so the marker behind it arms nothing|2|block-worktree-refresh: refused=refresh|echo hi;# <<EOF\nkendex refresh\nEOF
a substitution inside a double-quoted argument runs where it stands|2|block-worktree-refresh: refused=refresh|echo "\0044(kendex refresh)"
a substitution in a heredoc body the shell expands runs too|2|block-worktree-refresh: refused=refresh|cat \0074\0074EOF\n\0044(kendex refresh)\nEOF
a quoted delimiter stops the expansion, so the same body is data|0|-|cat \0074\0074'EOF'\n\0044(kendex refresh)\nEOF
a hash after a backtick begins a comment, so the marker behind it arms nothing|2|block-worktree-refresh: refused=refresh|echo hi \0140# <<EOF\nkendex refresh\nEOF\n\0140
the bare source shorthand for add is not read: it is every kendex word|0|-|kendex vanillagreencom/kendex
the named target on refresh passes: the write lands where the command says|0|-|kendex refresh --project-path /elsewhere
the named target on apply passes, spelled with an equals sign|0|-|kendex apply --project-path=/elsewhere
the named target on updates --apply passes|0|-|kendex updates --apply --project-path /elsewhere
a quoted target is still a target|0|-|kendex refresh --project-path "/else where"
the named target does not exempt a verb that has no such flag|2|block-worktree-refresh: refused=add|kendex add orch --project-path /elsewhere
nor does it exempt remove|2|block-worktree-refresh: refused=remove|kendex remove orch --project-path /elsewhere
the flag alone passes, a quoted value being cut into its own segment; kendex refuses a flag with no value|0|-|kendex refresh --project-path
a target on an earlier command does not exempt a later write|2|block-worktree-refresh: refused=refresh|kendex refresh --project-path /elsewhere && kendex refresh
a target before the verb is a root option the CLI drops and exempts nothing|2|block-worktree-refresh: refused=refresh|kendex --project-path /elsewhere refresh
a redirection target spelling --global is a file, not the scope|2|block-worktree-refresh: refused=refresh|kendex refresh -y > --global
a clobbering redirection target is a file, not a target|2|block-worktree-refresh: refused=refresh|kendex refresh -y >| --project-path
a redirection target spelling --project-path is a file, not a target|2|block-worktree-refresh: refused=refresh|kendex refresh -y > --project-path
a stderr redirection target is a file, not the scope|2|block-worktree-refresh: refused=refresh|kendex refresh -y 2> --scope=global
a redirection target glued to its operator is a file|2|block-worktree-refresh: refused=refresh|kendex refresh -y >--global
a quoted redirection target is a file|2|block-worktree-refresh: refused=refresh|kendex refresh -y > "--global"
an escaped-space redirection target is one file|2|block-worktree-refresh: refused=refresh|kendex refresh -y >\\ --global
a standalone -- ends the options before --global|2|block-worktree-refresh: refused=refresh|kendex refresh -y -- --global
a standalone -- ends the options before --project-path|2|block-worktree-refresh: refused=refresh|kendex refresh -y -- --project-path
a standalone -- ends the options before --apply|0|-|kendex updates -- --apply
a real global option before a redirection passes|0|-|kendex refresh --global >out
a real global option after a redirection passes|0|-|kendex refresh >out --global
a global option glued to a redirection passes|0|-|kendex refresh --global>out
a real target before a redirection passes|0|-|kendex refresh --project-path /elsewhere >out
a real target after a redirection passes|0|-|kendex refresh >out --project-path /elsewhere
a redirection target spelling --apply leaves updates a read|0|-|kendex updates > --apply
a real --apply before a redirection is a write|2|block-worktree-refresh: refused=updates|kendex updates --apply >out
a quoted option is the word bash passes|0|-|kendex remove orch "--global"
an expansion may be any word, so it grants no global scope|2|block-worktree-refresh: refused=add|kendex add --global \0044SRC
an expansion may be --apply, so updates is a write|2|block-worktree-refresh: refused=updates|kendex updates \0044ARGS
an expansion before --project-path may be --, so no target is named|2|block-worktree-refresh: refused=refresh|kendex refresh \0044X --project-path /elsewhere
an expansion after --project-path leaves the target named|0|-|kendex refresh --project-path /elsewhere \0044X
a backslash leaves the words unsure, so no global scope is read|2|block-worktree-refresh: refused=add|kendex add --global ./a\\ b
a > behind a quote may be quoted, so the word is unsure|2|block-worktree-refresh: refused=remove|kendex remove "a>b" --global
a --scope whose value the segment does not hold is not the global scope|2|block-worktree-refresh: refused=refresh|kendex refresh --global --scope "global"
the value spelled with an equals sign names a target whatever it holds|0|-|kendex refresh --project-path=\0044PWD -y
an expansion before --project-path= may be --, so no target is named|2|block-worktree-refresh: refused=refresh|kendex refresh \0044X --project-path=/elsewhere
--scope project before -g keeps the project scope|2|block-worktree-refresh: refused=refresh|kendex refresh --scope project -g
--scope=project before --global keeps it too|2|block-worktree-refresh: refused=refresh|kendex refresh --scope=project --global
--scope project before --scope global keeps it|2|block-worktree-refresh: refused=refresh|kendex refresh --scope project --scope global
--scope project before --scope=global keeps it|2|block-worktree-refresh: refused=refresh|kendex refresh --scope project --scope=global
ROWS
)
command_table

# label|cwd source|world|status|first line|command
DIRECTORY_ROWS=$(cat <<ROWS
a cd before the verb moves the write out of the directory git is asked about|payload|main|2|block-worktree-refresh: moved=refresh|cd $WT && kendex refresh
a named target after a cd passes: the command names the directory the write lands in|payload|main|0|-|cd $WT && kendex refresh --project-path /elsewhere
a pushd in an earlier segment is a move too|payload|outside|2|block-worktree-refresh: moved=apply|pushd $WT; kendex apply
a global write after a cd passes: no directory is written|payload|main|0|-|cd $WT && kendex refresh -g
a cd after the verb does not move the write|payload|main|0|-|kendex refresh && cd $WT
Codex tool_input.workdir takes precedence over the session cwd|tool-workdir|main|0|-|kendex refresh
A tool_input.cwd takes precedence over the session cwd|tool-cwd|main|0|-|kendex refresh
without a cwd in the payload the hook judges the directory it runs in|pwd|worktree|2|block-worktree-refresh: refused=refresh|kendex refresh
the same write from the main checkout passes|payload|main|0|-|kendex refresh
outside a repository there is no worktree to protect|payload|outside|0|-|kendex refresh
a .git file pointing nowhere is a git that could not answer, and its status is the value|payload|broken|2|block-worktree-refresh: git=128|kendex refresh
a cwd that does not exist is refused, not read as outside a repository|payload|absent|2|block-worktree-refresh: git=128|kendex refresh
an empty .git directory above the cwd is a repository git could not read, not the absence of one|payload|malformed|2|block-worktree-refresh: git=unreadable|kendex refresh
add in a worktree with its own kendex.toml writes that worktree and passes|payload|own|0|-|kendex add orch
remove there passes|payload|own|0|-|kendex remove orch
fork there passes|payload|own|0|-|kendex fork skill orch
pin there passes|payload|own|0|-|kendex pin skill orch v1
adopt there passes|payload|own|0|-|kendex adopt skill orch
drift-hook there passes|payload|own|0|-|kendex drift-hook -y
source add there passes|payload|own|0|-|kendex source add x owner/repo
source remove there passes|payload|own|0|-|kendex source remove x
source enable there passes|payload|own|0|-|kendex source enable x
source disable there passes|payload|own|0|-|kendex source disable x
marketplace subscribe there passes|payload|own|0|-|kendex marketplace subscribe owner/repo
marketplace unsubscribe there passes|payload|own|0|-|kendex marketplace unsubscribe x
refresh there still has to name its target|payload|own|2|block-worktree-refresh: refused=refresh|kendex refresh
apply there still has to name its target|payload|own|2|block-worktree-refresh: refused=apply|kendex apply
updates --apply there still has to name its target|payload|own|2|block-worktree-refresh: refused=updates|kendex updates --apply
refresh there naming its target passes|payload|own|0|-|kendex refresh --project-path $OWN
update-pi there is refused as before|payload|own|2|block-worktree-refresh: refused=update-pi|kendex update-pi
update-pi --scope global there passes|payload|own|0|-|kendex update-pi --scope global
a skill named refresh on an add there is an argument, and the add passes|payload|own|0|-|kendex add orch --skill refresh
a refresh after an add there is judged on its own|payload|own|2|block-worktree-refresh: refused=refresh|kendex add orch && kendex refresh
a tool call from a subdirectory of that worktree judges the worktree root|tool-workdir|own-sub|0|-|kendex add orch
and a refresh from there is still refused|tool-workdir|own-sub|2|block-worktree-refresh: refused=refresh|kendex refresh
a kendex.toml that will not parse is still the worktree's own|payload|own-broken|0|-|kendex add orch
a subdirectory of a worktree with no kendex.toml is refused|tool-workdir|worktree-sub|2|block-worktree-refresh: refused=add|kendex add orch
a cd into the worktree with its own kendex.toml is still a move|payload|main|2|block-worktree-refresh: moved=add|cd $OWN && kendex add orch
env -C starts kendex in another directory, which is a move|payload|own|2|block-worktree-refresh: moved=add|env -C $MAIN kendex add orch
env --chdir= is the same move|payload|own|2|block-worktree-refresh: moved=add|env --chdir=$MAIN kendex add orch
sudo -D is a move too|payload|own|2|block-worktree-refresh: moved=add|sudo -D $MAIN kendex add orch
sudo --chdir is the same move|payload|own|2|block-worktree-refresh: moved=add|sudo --chdir $MAIN kendex add orch
an env without a directory option moves nothing|payload|own|0|-|env FOO=1 kendex add orch
env -C inside a cluster of short options is the same move|payload|own|2|block-worktree-refresh: moved=add|env -iC $MAIN kendex add orch
sudo -D inside a cluster of short options is the same move|payload|own|2|block-worktree-refresh: moved=add|sudo -ED $MAIN kendex add orch
a project above the worktree's root is not the worktree's own|payload|hosted|2|block-worktree-refresh: refused=add|kendex add orch
a project below the worktree root with its own kendex.toml is that worktree's own|payload|nested-app|0|-|kendex remove gh
a marker-only project inside a declaring worktree has no manifest of its own|payload|own-marked|2|block-worktree-refresh: refused=add|kendex add orch
a source catalog without kendex-local.toml has no manifest of its own|payload|catalog|2|block-worktree-refresh: refused=add|kendex add orch
a source catalog with kendex-local.toml has one|payload|catalog-local|0|-|kendex add orch
is_source_catalog inside a table is read as a catalog, so without kendex-local.toml it is refused|payload|catalog-tabled|2|block-worktree-refresh: refused=add|kendex add orch
is_source_catalog after a multi-line string holding a table header is a catalog|payload|catalog-string|2|block-worktree-refresh: refused=add|kendex add orch
a quoted is_source_catalog key is a catalog|payload|catalog-quoted|2|block-worktree-refresh: refused=add|kendex add orch
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
assert_contains "$ERR_FILE" '--project-path PATH' 'and the refusal names the flag that names the project'
run_in "$WT" 'kendex add orch'
assert_contains "$ERR_FILE" 'add has no such form' 'a verb with no named-target form says so rather than offering one'
run_in "$WT" 'kendex source add x owner/repo'
assert_not_contains "$ERR_FILE" '--global' 'a source subcommand has no global flag, and the refusal offers none'
assert_not_contains "$ERR_FILE" '--scope global' 'nor a global scope'
run_in "$OWN" 'kendex refresh'
assert_contains "$ERR_FILE" "--project-path $OWN" 'a worktree with its own kendex.toml is named by its own root'
run_in "$SPACED" 'kendex refresh'
assert_contains "$ERR_FILE" "Name it in the command: kendex refresh --project-path $TMP_ROOT/sp/my\\ app, or pass" 'a project path with a space is one word in the remedy'
run_in "$OWN" 'kendex updates --apply'
assert_contains "$ERR_FILE" "kendex updates --apply --project-path $OWN" 'the updates remedy keeps the --apply that makes it a write'
run_in "$OWN" 'kendex update-pi --scope project'
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: refused=update-pi' 'update-pi at the project scope is refused where the project owns its manifest'
assert_contains "$ERR_FILE" 'kendex update-pi --scope global' 'and the refusal offers the one form update-pi runs as in a linked worktree'
assert_not_contains "$ERR_FILE" 'update-pi --project-path' 'never a flag update-pi does not take'
assert_not_contains "$ERR_FILE" 'main checkout' 'nor the main checkout, whose project is a different one'
run_in "$OWN/marked" 'kendex add orch'
assert_contains "$ERR_FILE" "$OWN/marked" 'the refusal names the project kendex would write, not the worktree root'
set +e
(cd "$WT" && "$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE")
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: payload=unreadable' \
  'a stdin that cannot be read refuses with the refusal status, not the read error'

payload_table "$HOOK" 'kendex refresh' 'kendex verify' "$WT"

echo "=== block-worktree-refresh: kendex's own project markers ==="
# The hook finds the project kendex writes by kendex's markers, so each one
# discover.rs lists is planted alone in a folder inside the declaring
# worktree: that folder is a project, kendex.toml aside it has no manifest,
# and an add typed there is refused. A marker the hook lacked would walk on
# to the worktree root, which declares, and pass. The set is read from
# discover.rs itself; a marker the hook adds beyond it only refuses more.
DISCOVER="$TEST_DIR/../../crates/core/src/discover.rs"
NL=$'\n'
discover_markers() { # CONST -> one marker per line
  sed -n "/^const $1: /,/^];/p" "$DISCOVER" | grep -o '"[^"]*"' | tr -d '"'
}
MARKED_DIRS=$(discover_markers MARKER_DIRS) || { echo "markers: MARKER_DIRS could not be read from $DISCOVER" >&2; exit 2; }
MARKED_FILES=$(discover_markers MARKER_FILES) || { echo "markers: MARKER_FILES could not be read from $DISCOVER" >&2; exit 2; }
case "$NL$MARKED_DIRS$NL" in *"$NL.claude$NL"*) ;; *) echo "markers: the MARKER_DIRS extractor lost .claude; it is broken" >&2; exit 2 ;; esac
case "$NL$MARKED_FILES$NL" in *"$NL.kendex-lock.json$NL"*) ;; *) echo "markers: the MARKER_FILES extractor lost .kendex-lock.json; it is broken" >&2; exit 2 ;; esac
index=0
while IFS='|' read -r kind marker; do
  [ -n "$marker" ] || continue
  index=$((index + 1))
  at="$OWN/marker-$index"
  case "$kind" in
    dir) mkdir -p "$at/$marker" ;;
    file) mkdir -p "$(dirname "$at/$marker")" && : >"$at/$marker" ;;
  esac
  run_in "$at" 'kendex add orch'
  if [ "$marker" = kendex.toml ]; then
    assert_eq "rc=$rc first=$(first_line)" 'rc=0 first=-' "the $marker marker is the manifest itself, and the add passes"
  else
    assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: refused=add' "the $marker marker alone makes a project with no manifest"
  fi
done <<ROWS
dir|${MARKED_DIRS//$NL/${NL}dir|}
file|${MARKED_FILES//$NL/${NL}file|}
ROWS

echo "=== block-worktree-refresh: a missing git refuses ==="
NOGIT_BIN="$TMP_ROOT/nogit"
mkdir -p "$NOGIT_BIN"
for tool in bash cat jq; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NOGIT_BIN/$tool"
done
run_payload '{"tool_input":{"command":"kendex refresh"}}' "$NOGIT_BIN"
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=block-worktree-refresh: missing-tools=git' \
  'without git the guard refuses rather than skipping, and the value names git alone'

echo "=== block-worktree-refresh: without the command reader it refuses ==="
# The hook alone, with no commit-guards install within reach of it.
mkdir -p "$TMP_ROOT/lone/hooks"
cp "$HOOK" "$TMP_ROOT/lone/hooks/block-worktree-refresh.sh"
set +e
json_for 'kendex verify' "$WT" | "$BASH_BIN" "$TMP_ROOT/lone/hooks/block-worktree-refresh.sh" >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" \
  'rc=2 first=block-worktree-refresh: missing-library=commit-guards/scripts/lib/command-position.sh' \
  'without the command-position library even a read is refused, and the value names the library'
# A global Pi install sits four directories under the home, and a harness root
# a setting relocated sits outside it; both find the reader in the home's
# shared tree.
mkdir -p "$HOME/.agents/skills/commit-guards/scripts/lib" "$HOME/.pi/agent/kendex/hooks" \
  "$TMP_ROOT/relocated/codex/hooks"
cp "$(cd "$TEST_DIR/../.." && pwd)/skills/commit-guards/scripts/lib/command-position.sh" \
  "$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh"
while IFS='|' read -r label at; do
  [ -n "$label" ] || continue
  cp "$HOOK" "$at/block-worktree-refresh.sh"
  set +e
  (cd "$WT" && json_for 'kendex verify' "$WT" | "$BASH_BIN" "$at/block-worktree-refresh.sh" >/dev/null 2>"$ERR_FILE")
  rc=$?
  set -e
  assert_eq "rc=$rc first=$(first_line)" 'rc=0 first=-' "$label"
done <<ROWS
a global Pi install four directories under the home finds the reader in the home's shared tree|$HOME/.pi/agent/kendex/hooks
a harness root relocated out of the home finds the reader in the home's shared tree|$TMP_ROOT/relocated/codex/hooks
ROWS

echo
echo "block-worktree-refresh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
