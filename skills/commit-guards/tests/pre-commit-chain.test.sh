#!/usr/bin/env bash
# Pins for scripts/pre-commit, the chain as the installed shim runs it:
# which copy of each sibling gate runs (the committing work tree's first,
# then the install's own, which may sit in another checkout since linked
# worktrees share one hooks directory), the announcement every lane makes,
# ran or skipped, run_step's three statuses folded into one verdict that
# fails closed, the repo-local entry, and the batch at commit scope. One
# table: a row builds its own repository, runs the chain from one of two
# shared installs in another checkout — one carrying no sibling, one
# carrying three stubs that say which copy ran — and reads back the exit
# status with every line printed. The shim's rediscovery, the project-root
# and awkward-name searches, the real doc-limits and preflight lanes with
# their forks and dangling installs, and the first-commit skip are the
# install-git-hooks suites'; the batch's own lines are dispatcher's.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_CHECKS COMMIT_GUARDS_PRE_COMMIT_LOCAL COMMIT_GUARDS_SETTINGS_FILE \
  GG_TMP GG_SETTINGS_INDEX_OWNED GG_SETTINGS_INDEX_DIR GG_SETTINGS_FROM_INDEX 2>/dev/null || true

# Assembled from split tokens so this file carries no marker shape of its
# own: the kendex repo runs todo-ban over its own tree, tests included.
TD="TO""DO"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# Three installs, each in another checkout, the tests subtree cut since a
# consumer install never carries it. The bare one sits under a skill root
# of its checkout, so the search's project side is that checkout and the
# skip lines name it; the full one sits outside every skill root, so its
# three stubs are reached only through the install's own side; the project
# one sits under a skill root beside a doc-limits stub, reached only
# through the project side.
stub() { # ROOT NAME LINE RC — a gate that proves which copy ran, and with what
  mkdir -p "$1/$2/scripts"
  printf '#!/bin/sh\necho "%s $*"\nexit %s\n' "$3" "$4" >"$1/$2/scripts/$2"
  chmod +x "$1/$2/scripts/$2"
}
install() { mkdir -p "$1"; cp -R "$SKILL_DIR" "$1/commit-guards"; rm -rf -- "${1:?}/commit-guards/tests"; } # SKILLS-DIR
BARE=other-checkout/skills
FULL=other-checkout-full/vendor
PROJ=other-checkout-project/skills
install "$TMP/$BARE"
install "$TMP/$FULL"
install "$TMP/$PROJ"
stub "$TMP/$PROJ" doc-limits "project doc-limits ran" 0
stub "$TMP/$FULL" doc-limits "install doc-limits ran" 0
stub "$TMP/$FULL" preflight "install preflight ran" 0
stub "$TMP/$FULL" bot-instructions "install bot-instructions ran" 0

# One line for a run in the row's repository from the named install: the
# exit status, then every line printed, in order, joined by ';', with the
# row's repository aliased as <repo> and the scratch root as <root>, each
# in its physical form first (the chain prints where it resolved to, which
# under a symlinked temp root such as macOS's /var is not the spelling the
# fixture was built with) and then its logical one. ENVS is a
# comma-separated list of assignments; ARGS are passed through. The batch
# runs one check, so its lines are one shape: its composition is
# dispatcher's subject.
R=""
TMP_P="$(cd "$TMP" && pwd -P)"
run() { # ENVS INSTALL ARGS
  local envs=() rc=0 out="" r_p
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  r_p="$(cd "$R" && pwd -P)"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env COMMIT_GUARDS_CHECKS=todo-ban ${envs[@]+"${envs[@]}"} "$TMP/$2/commit-guards/scripts/pre-commit" $3 2>&1)" || rc=$?
  out="${out//"$r_p"/<repo>}"
  out="${out//"$TMP_P"/<root>}"
  out="${out//"$R"/<repo>}"
  out="${out//"$TMP"/<root>}"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every repository is seeded (preflight --staged has a
# base) with one clean file staged; a name used twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '[]\n' >"$R/.kendex-generated.json"
  printf 'hello\n' >"$R/a.txt"
  git -C "$R" add -A
  git -C "$R" commit -qm 'feat: seed'
  printf 'more\n' >"$R/b.txt"
  git -C "$R" add b.txt
}
tree() { stub "$R/${ROOT:-.agents/skills}" "$@"; } # NAME LINE RC — a sibling the committing tree carries, under ROOT
local_entry() { mkdir -p "$R/tools"; printf '%b' "$1" >"$R/tools/local-check"; chmod +x "$R/tools/local-check"; } # BODY

# The lines the chain prints, as functions of what a row put in.
ROOTS=".agents/skills .claude/skills .cursor/skills .gemini/skills .github/skills .opencode/skills skills"
DL="=== pre-commit: doc-limits (document byte ceilings)"
PF="=== pre-commit: preflight"
BOT="=== pre-commit: bot-instructions check --staged"
# A skip line: the tree, the install's checkout, the roots, the install's own side.
skip() { printf '=== pre-commit: %s not installed — skipped (no %s skill under <repo> and <root>/%s (%s), nor at <root>/%s/skills/commit-guards/scripts/../../%s)' "$1" "$1" "${2:-other-checkout}" "$ROOTS" "${2:-other-checkout}" "$1"; } # LANE [CHECKOUT]
SKIPS="$(skip doc-limits);$(skip preflight);$(skip bot-instructions)"
BATCH="=== pre-commit: commit-guards all --staged;=== commit-guards: todo-ban --staged"
BATCH_OK="$BATCH;todo-ban: OK — the staged diff adds no work markers;commit-guards: OK — enabled checks clean (todo-ban)"
LOCAL_NONE="=== pre-commit: repo-local entry: none configured"
LOCAL="=== pre-commit: repo-local: tools/local-check"
CHAIN_OK="pre-commit: OK — staged guard chain clean"
BLOCKED="pre-commit: violations — commit blocked; see the failures above"
# The verdict names git's bypass flag; assembled from split tokens so this
# file never carries the flag itself.
ERRORS="pre-commit: a guard could not complete — commit blocked; fix the errors above (bypass only with git commit --no-""verify)"
incomplete() { printf "pre-commit: step '%s' did not complete (exit %s)" "$1" "$2"; } # LABEL STATUS
ERR="::error::pre-commit: "
broken() { printf '%sthe %s skill is installed at <repo>/.agents/skills/%s but <repo>/.agents/skills/%s/scripts/%s is missing or not executable — reinstall it' "$ERR" "$1" "$1" "$1" "$1"; } # SKILL

# The table: label | fixture | env | install | args | expect.
run_rows() {
  local row label fx env inst args expect
  for row in "$@"; do
    IFS='|' read -r label fx env inst args expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than six fields: $row" >&2; exit 2; }
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$inst" "$args")"
  done
}

echo "=== the committing tree's copy of a sibling gate runs; the install's serves only a tree without one ==="
fx_tree_two() { repo tree-two; tree doc-limits "worktree doc-limits ran" 0; ROOT=.github/skills tree preflight "worktree preflight ran" 0; }
fx_tree_fails() { repo tree-fails; tree doc-limits "doc-limits: staged violation" 1; }
fx_tree_one() { repo tree-one; tree doc-limits "worktree doc-limits ran" 0; }
fx_tree_none() { repo tree-none; }
fx_tree_over_project() { repo tree-over-project; tree doc-limits "worktree doc-limits ran" 0; }
fx_project() { repo project; }
fx_tree_bot_fails() { repo tree-bot-fails; tree bot-instructions "bot-instructions: AGENTS.md differs from a fresh render" 1; }
fx_tree_bot_broken() { repo tree-bot-broken; tree bot-instructions "never runs" 0; chmod -x "$R/.agents/skills/bot-instructions/scripts/bot-instructions"; }
fx_absent() { repo absent; }
run_rows \
  "the tree's doc-limits and preflight run, each under its own root, from an install carrying neither, and the third lane is a stated skip|fx_tree_two||$BARE||rc=0 $DL;worktree doc-limits ran --staged;$PF;worktree preflight ran --staged;$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a failing tree-carried gate blocks with its own line in front of the committer|fx_tree_fails||$BARE||rc=1 $DL;doc-limits: staged violation --staged;$(skip preflight);$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$BLOCKED" \
  "the tree's copy outranks the install's, and the siblings the tree lacks still come from the install|fx_tree_one||$FULL||rc=0 $DL;worktree doc-limits ran --staged;$PF;install preflight ran --staged;$BOT;install bot-instructions ran check --staged;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a tree carrying no sibling gets all three from the install|fx_tree_none||$FULL||rc=0 $DL;install doc-limits ran --staged;$PF;install preflight ran --staged;$BOT;install bot-instructions ran check --staged;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "the tree's copy outranks the one under the install's project root: the re-vendor rule|fx_tree_over_project||$PROJ||rc=0 $DL;worktree doc-limits ran --staged;$(skip preflight other-checkout-project);$(skip bot-instructions other-checkout-project);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "control: a tree carrying none gets the project root's copy|fx_project||$PROJ||rc=0 $DL;project doc-limits ran --staged;$(skip preflight other-checkout-project);$(skip bot-instructions other-checkout-project);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a failing tree-carried bot-instructions check blocks under its own announcement|fx_tree_bot_fails||$BARE||rc=1 $(skip doc-limits);$(skip preflight);$BOT;bot-instructions: AGENTS.md differs from a fresh render check --staged;$BATCH_OK;$LOCAL_NONE;$BLOCKED" \
  "a tree-carried bot-instructions skill whose script is not executable is a broken install, never a skip|fx_tree_bot_broken||$BARE||rc=2 $(skip doc-limits);$(skip preflight);$(broken bot-instructions)" \
  "absence on both sides is a stated skip naming both probed sides and every root, and the chain passes|fx_absent||$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK"

echo "=== every step runs before the verdict, and could-not-complete outranks violations ==="
fx_both() { repo both; tree doc-limits "doc-limits: staged violation" 1; tree preflight "preflight died" 2; }
fx_bot_dies() { repo bot-dies; tree bot-instructions "bot died" 3; }
run_rows \
  "a violation and a step that did not complete both print, every later lane still runs, and the verdict is the error's|fx_both||$BARE||rc=2 $DL;doc-limits: staged violation --staged;$PF;preflight died --staged;$(incomplete preflight 2);$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$ERRORS" \
  "a status past 1 is a step that did not complete, with its status|fx_bot_dies||$BARE||rc=2 $(skip doc-limits);$(skip preflight);$BOT;bot died check --staged;$(incomplete 'bot-instructions check --staged' 3);$BATCH_OK;$LOCAL_NONE;$ERRORS"

echo "=== the repo-local entry: announced, run last, and its status folded like every lane's ==="
fx_local_ran() { repo local-ran; local_entry '#!/bin/sh\necho "repo-local check ran"\nexit 0\n'; }
fx_local_fails() { repo local-fails; local_entry '#!/bin/sh\necho "repo-local: nope"\nexit 1\n'; }
fx_local_dies() { repo local-dies; local_entry '#!/bin/sh\necho "repo-local check died"\nexit 2\n'; }
fx_local_unexecutable() { repo local-unexecutable; local_entry '#!/bin/sh\nexit 0\n'; chmod -x "$R/tools/local-check"; }
LOCAL_ENV=COMMIT_GUARDS_PRE_COMMIT_LOCAL=tools/local-check
run_rows \
  "a configured entry announces itself in place of the none line, runs, and passes|fx_local_ran|$LOCAL_ENV|$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL;repo-local check ran;$CHAIN_OK" \
  "its violation blocks|fx_local_fails|$LOCAL_ENV|$BARE||rc=1 $SKIPS;$BATCH_OK;$LOCAL;repo-local: nope;$BLOCKED" \
  "its status past 1 is a step that did not complete|fx_local_dies|$LOCAL_ENV|$BARE||rc=2 $SKIPS;$BATCH_OK;$LOCAL;repo-local check died;$(incomplete 'repo-local: tools/local-check' 2);$ERRORS" \
  "an entry that is not executable is a config error naming it, after the batch ran|fx_local_unexecutable|$LOCAL_ENV|$BARE||rc=2 $SKIPS;$BATCH_OK;${ERR}COMMIT_GUARDS_PRE_COMMIT_LOCAL names 'tools/local-check', which is missing or not executable"

echo "=== the batch runs at commit scope: a marker the commit does not add belongs to CI ==="
# The fixture proves its marker landed in HEAD: a row over a repository
# without one passes for the wrong reason.
marker_committed() { # NAME
  repo "$1"
  printf '// %s: left in a fixture\n' "$TD" >"$R/fixture.rs"
  git -C "$R" add fixture.rs
  git -C "$R" commit -qm 'chore: fixture'
  git -C "$R" grep -q -- "$TD" HEAD -- fixture.rs || { echo "harness: $1: the committed marker is not in HEAD" >&2; exit 2; }
  # A staged file of its own, so the pass is the chain judging content
  # rather than an empty diff finding nothing to judge.
  printf 'fn main() {}\n' >"$R/clean.rs"
  git -C "$R" add clean.rs
}
fx_untouched_marker() { marker_committed untouched-marker; }
fx_added_marker() { marker_committed added-marker; printf '// %s: added by this commit\n' "$TD" >>"$R/b.txt"; git -C "$R" add b.txt; }
HIT="todo-ban FAIL work marker: b.txt:2:// $TD: added by this commit;  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in tools/todo-ban-excludes with a reason;todo-ban: 1 work marker(s) added by the staged diff — excludes tools/todo-ban-excludes;commit-guards: violations — see the failures above"
run_rows \
  "a marker committed earlier and untouched is not this commit's: the staged file is clean and the chain passes|fx_untouched_marker||$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "control: a marker this commit adds blocks it at its line|fx_added_marker||$BARE||rc=1 $SKIPS;$BATCH;$HIT;$LOCAL_NONE;$BLOCKED"

echo "=== the usage is answered, and an argument is refused ==="
fx_usage() { repo usage; }
fx_arg() { repo arg; }
run_rows \
  "an argument is a config error: git passes none|fx_arg||$BARE|--staged|rc=2 ${ERR}takes no arguments (see --help)"
fx_usage
assert_eq "--help prints the usage and exits 0" "rc=0 usage: pre-commit" "$(run "" "$BARE" --help | cut -d';' -f1)"
assert_eq "-h is the same flag" "$(run "" "$BARE" --help)" "$(run "" "$BARE" -h)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
