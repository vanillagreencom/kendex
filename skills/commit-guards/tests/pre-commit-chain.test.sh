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
stub "$TMP/$PROJ" doc-limits "fixture=project-doc-limits" 0
stub "$TMP/$FULL" doc-limits "fixture=install-doc-limits" 0
stub "$TMP/$FULL" preflight "fixture=install-preflight" 0
stub "$TMP/$FULL" bot-instructions "fixture=install-bot-instructions" 0

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
  out="$(printf '%s\n' "$out" | sed '/^  /d')"
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
DL="pre-commit: step=doc-limits"
PF="pre-commit: step=preflight"
BOT="pre-commit: step=bot-instructions check --staged"
skip() { printf 'pre-commit: lane-absent=%s roots=<repo> and <root>/%s skills=%s fallback=<root>/%s/skills/commit-guards/scripts/../../%s' "$1" "${2:-other-checkout}" "$ROOTS" "${2:-other-checkout}" "$1"; } # LANE [CHECKOUT]
SKIPS="$(skip doc-limits);$(skip preflight);$(skip bot-instructions)"
BATCH="pre-commit: step=commit-guards all --staged;commit-guards: step=todo-ban --staged"
BATCH_OK="$BATCH;todo-ban: staged-count=0:0:tools/todo-ban-excludes;commit-guards: result=0:todo-ban"
LOCAL_NONE="pre-commit: local-entry=none"
LOCAL="pre-commit: step=repo-local: tools/local-check"
CHAIN_OK="pre-commit: result=0"
BLOCKED="pre-commit: result=1"
ERRORS="pre-commit: result=2"
incomplete() { printf 'pre-commit: step-incomplete=%s:%s' "$1" "$2"; } # LABEL STATUS
broken() { printf 'pre-commit: lane-missing=<repo>/.agents/skills/%s/scripts/%s' "$1" "$1"; } # SKILL

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
fx_tree_two() { repo tree-two; tree doc-limits "fixture=worktree-doc-limits" 0; ROOT=.github/skills tree preflight "fixture=worktree-preflight" 0; }
fx_tree_fails() { repo tree-fails; tree doc-limits "fixture=doc-limits-violation" 1; }
fx_tree_one() { repo tree-one; tree doc-limits "fixture=worktree-doc-limits" 0; }
fx_tree_none() { repo tree-none; }
fx_tree_over_project() { repo tree-over-project; tree doc-limits "fixture=worktree-doc-limits" 0; }
fx_project() { repo project; }
fx_tree_bot_fails() { repo tree-bot-fails; tree bot-instructions "fixture=bot-instructions-stale" 1; }
fx_tree_bot_broken() { repo tree-bot-broken; tree bot-instructions "never runs" 0; chmod -x "$R/.agents/skills/bot-instructions/scripts/bot-instructions"; }
fx_absent() { repo absent; }
run_rows \
  "the tree's doc-limits and preflight run, each under its own root, from an install carrying neither, and the third lane is a stated skip|fx_tree_two||$BARE||rc=0 $DL;fixture=worktree-doc-limits --staged;$PF;fixture=worktree-preflight --staged;$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a failing tree-carried gate blocks with its own line in front of the committer|fx_tree_fails||$BARE||rc=1 $DL;fixture=doc-limits-violation --staged;$(skip preflight);$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$BLOCKED" \
  "the tree's copy outranks the install's, and the siblings the tree lacks still come from the install|fx_tree_one||$FULL||rc=0 $DL;fixture=worktree-doc-limits --staged;$PF;fixture=install-preflight --staged;$BOT;fixture=install-bot-instructions check --staged;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a tree carrying no sibling gets all three from the install|fx_tree_none||$FULL||rc=0 $DL;fixture=install-doc-limits --staged;$PF;fixture=install-preflight --staged;$BOT;fixture=install-bot-instructions check --staged;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "the tree's copy outranks the one under the install's project root: the re-vendor rule|fx_tree_over_project||$PROJ||rc=0 $DL;fixture=worktree-doc-limits --staged;$(skip preflight other-checkout-project);$(skip bot-instructions other-checkout-project);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "control: a tree carrying none gets the project root's copy|fx_project||$PROJ||rc=0 $DL;fixture=project-doc-limits --staged;$(skip preflight other-checkout-project);$(skip bot-instructions other-checkout-project);$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "a failing tree-carried bot-instructions check blocks under its own announcement|fx_tree_bot_fails||$BARE||rc=1 $(skip doc-limits);$(skip preflight);$BOT;fixture=bot-instructions-stale check --staged;$BATCH_OK;$LOCAL_NONE;$BLOCKED" \
  "a tree-carried bot-instructions skill whose script is not executable is a broken install, never a skip|fx_tree_bot_broken||$BARE||rc=2 $(skip doc-limits);$(skip preflight);$(broken bot-instructions)" \
  "absence on both sides is a stated skip naming both probed sides and every root, and the chain passes|fx_absent||$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK"

echo "=== every step runs before the verdict, and could-not-complete outranks violations ==="
fx_both() { repo both; tree doc-limits "fixture=doc-limits-violation" 1; tree preflight "fixture=preflight-error" 2; }
fx_bot_dies() { repo bot-dies; tree bot-instructions "fixture=bot-error" 3; }
run_rows \
  "a violation and a step that did not complete both print, every later lane still runs, and the verdict is the error's|fx_both||$BARE||rc=2 $DL;fixture=doc-limits-violation --staged;$PF;fixture=preflight-error --staged;$(incomplete preflight 2);$(skip bot-instructions);$BATCH_OK;$LOCAL_NONE;$ERRORS" \
  "a status past 1 is a step that did not complete, with its status|fx_bot_dies||$BARE||rc=2 $(skip doc-limits);$(skip preflight);$BOT;fixture=bot-error check --staged;$(incomplete 'bot-instructions check --staged' 3);$BATCH_OK;$LOCAL_NONE;$ERRORS"

echo "=== the repo-local entry: announced, run last, and its status folded like every lane's ==="
fx_local_ran() { repo local-ran; local_entry '#!/bin/sh\necho "fixture=local-clean"\nexit 0\n'; }
fx_local_fails() { repo local-fails; local_entry '#!/bin/sh\necho "fixture=local-violation"\nexit 1\n'; }
fx_local_dies() { repo local-dies; local_entry '#!/bin/sh\necho "fixture=local-error"\nexit 2\n'; }
fx_local_unexecutable() { repo local-unexecutable; local_entry '#!/bin/sh\nexit 0\n'; chmod -x "$R/tools/local-check"; }
LOCAL_ENV=COMMIT_GUARDS_PRE_COMMIT_LOCAL=tools/local-check
run_rows \
  "a configured entry announces itself in place of the none line, runs, and passes|fx_local_ran|$LOCAL_ENV|$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL;fixture=local-clean;$CHAIN_OK" \
  "its violation blocks|fx_local_fails|$LOCAL_ENV|$BARE||rc=1 $SKIPS;$BATCH_OK;$LOCAL;fixture=local-violation;$BLOCKED" \
  "its status past 1 is a step that did not complete|fx_local_dies|$LOCAL_ENV|$BARE||rc=2 $SKIPS;$BATCH_OK;$LOCAL;fixture=local-error;$(incomplete 'repo-local: tools/local-check' 2);$ERRORS" \
  "an entry that is not executable is a config error naming it, after the batch ran|fx_local_unexecutable|$LOCAL_ENV|$BARE||rc=2 $SKIPS;$BATCH_OK;pre-commit: local-missing=tools/local-check"

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
HIT="todo-ban: match=work marker:b.txt:2:// $TD: added by this commit;todo-ban: staged-count=1:0:tools/todo-ban-excludes;commit-guards: result=1"
run_rows \
  "a marker committed earlier and untouched is not this commit's: the staged file is clean and the chain passes|fx_untouched_marker||$BARE||rc=0 $SKIPS;$BATCH_OK;$LOCAL_NONE;$CHAIN_OK" \
  "control: a marker this commit adds blocks it at its line|fx_added_marker||$BARE||rc=1 $SKIPS;$BATCH;$HIT;$LOCAL_NONE;$BLOCKED"

echo "=== the usage is answered, and an argument is refused ==="
fx_usage() { repo usage; }
fx_arg() { repo arg; }
run_rows \
  "an argument is a config error: git passes none|fx_arg||$BARE|--staged|rc=2 pre-commit: argument-count=1"
fx_usage
assert_eq "--help prints the usage and exits 0" "rc=0 usage: pre-commit" "$(run "" "$BARE" --help | cut -d';' -f1)"
assert_eq "-h is the same flag" "$(run "" "$BARE" --help)" "$(run "" "$BARE" -h)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
