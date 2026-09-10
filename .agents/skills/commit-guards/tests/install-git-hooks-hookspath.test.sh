#!/usr/bin/env bash
# core.hooksPath, in both modes: set at all is a stand-down. The install
# writes nothing into a directory git would not read, and `--check` verifies
# only the directory this package writes rather than grading a redirected
# one; the cost is pinned as a cost, a hand-wired directory that really does
# gate answered "could not determine", never "not armed". The stand-down is
# one statement, git's own report of where the value is set, and one
# sentence naming no path and no command. One table: a row builds its own
# repository, sets the value one way, runs one action and reads back the
# exit status with every line printed, the stderr block included, then the
# hooks directory as one line. Arming and the gate are
# install-git-hooks.test.sh, --check install-git-hooks-check.test.sh,
# rediscovery and the sibling lanes install-git-hooks-scope.test.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

# The stand-down block, as the installer prints it to stderr: the statement,
# git's report rendered by %q (scope, origin and value on one tab-separated
# line), the sentence. ORIGIN is the report line with the value aliased.
SET_LINE="install-git-hooks: hooks-path-set=core.hooksPath"
UNLISTED="install-git-hooks: hooks-path-origin-unavailable=core.hooksPath"
local_origin() { printf "install-git-hooks: hooks-path-origin=\$'local\\\\tfile:.git/config\\\\t%s'" "$1"; } # VALUE as %q renders it
block() { printf '%s;%s' "$SET_LINE" "$1"; } # ORIGIN-LINE
skipped() { printf 'install-git-hooks: hooks-path-configured=%s;%s;commit-guards git hooks: skipped-hooks-path=%s' "$1" "$2" "$1"; } # VALUE BLOCK
undetermined() { printf '%s;commit-guards git hooks: unknown=hooks-path-configured=%s' "$2" "$1"; } # VALUE BLOCK
OFF_WARN="install-git-hooks: hooks-path-disabled=''"
OFF_CHECK="commit-guards git hooks: not-armed=hooks-path-disabled=''"
NONE="helper=absent pre-commit=absent commit-msg=absent pre-push=absent"
set_value() { git -C "$R" config core.hooksPath "$1"; } # VALUE

echo "=== an empty value switches git hooks off, and neither mode reads the repository root instead ==="
# rev-parse reports ./ for the empty value, so a checker measuring that
# directory would grade the repository root: armed, if the root happens to
# hold the right shapes, which these fixtures make sure it does.
copies_at_root() { cp "$R/.git/hooks/kendex-guards" "$R/.git/hooks/pre-commit" "$R/.git/hooks/commit-msg" "$R/"; }
fx_off_check() { armed off-check; copies_at_root; set_value ""; }
fx_off_install() { R="$(new_repo off-install)"; set_value ""; }
fx_off_install_armed() { armed off-install-armed; copies_at_root; set_value ""; }
run_rows \
  "the empty value is NOT armed, never armed at the root|fx_off_check||check||rc=1 $(block "$(local_origin '')");$OFF_CHECK|helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath=''" \
  "the install says the same rather than writing|fx_off_install||install||rc=0 $OFF_WARN;$(block "$(local_origin '')");commit-guards git hooks: skipped-hooks-path=''|$NONE hooksPath=''" \
  "and leaves an earlier arming as it was|fx_off_install_armed||install||rc=0 $OFF_WARN;$(block "$(local_origin '')");commit-guards git hooks: skipped-hooks-path=''|helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath=''"

echo "=== set at all stands the install down, whatever the spelling ==="
# Whether the configured directory is in fact this repository's own would be
# worked out here: resolved on disk, `..` folded on paper, a relative value
# absolutized against the work tree. Each was another way to be subtly
# wrong, and two of them were. Set is set: exit 0, a stated skip, nothing
# written, no hand-wiring recipe, and no command to paste.
fx_default_relative() { R="$(new_repo default-relative)"; set_value ".git/hooks"; }
fx_default_absolute() { R="$(new_repo default-absolute)"; set_value "$R/.git/hooks"; }
fx_elsewhere() { R="$(new_repo elsewhere)"; set_value "$R/otherhooks"; }
run_rows \
  "the default directory spelled relative|fx_default_relative||install||rc=0 $(skipped '.git/hooks' "$(block "$(local_origin '.git/hooks')")")|$NONE hooksPath='.git/hooks'" \
  "the default directory spelled absolute|fx_default_absolute||install||rc=0 $(skipped '<repo>/.git/hooks' "$(block "$(local_origin '<repo>/.git/hooks')")")|$NONE hooksPath='<repo>/.git/hooks'" \
  "a directory elsewhere|fx_elsewhere||install||rc=0 $(skipped '<repo>/otherhooks' "$(block "$(local_origin '<repo>/otherhooks')")")|$NONE hooksPath='<repo>/otherhooks'"

echo "=== --check stands down the same way, and claims nothing either way ==="
# What a redirected directory does is a question about somebody else's
# files; answering it took a whole-file grammar over shell text, and every
# construct nobody had thought of was another chance to report armed about a
# repository that gated nothing. The checker answers what the installer
# answers: not this package's directory, not this package's verdict. The
# cost is a directory wired by hand that really does gate, pinned here with
# the commit that proves it gates.
wired() { armed "$1"; wire_hooks_dir "$R" "$R/customhooks"; set_value customhooks; } # NAME
fx_wired() { wired wired; }
fx_wired_commit() { wired wired-commit; stage_marker; }
fx_default_spelling() { armed default-spelling; set_value .git/hooks; }
run_rows \
  "a hand-wired directory is could-not-determine|fx_wired||check||rc=2 $(undetermined customhooks "$(block "$(local_origin customhooks)")")|helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath='customhooks'" \
  "and the wiring it will not judge really does gate|fx_wired_commit|$ONE|commit|feat: add b|rc=1 $BLOCKED|" \
  "a value naming the default directory stands down too: git reads exactly the directory this package writes, and the verdict says nothing that spelling makes false|fx_default_spelling||check||rc=2 $(undetermined .git/hooks "$(block "$(local_origin .git/hooks)")")|"

echo "=== git's report of where the value is set reaches the reader as git wrote it ==="
# The architecture decision on recovery output: parameters as data, never a
# command line to paste. Three prior shapes of this remedy each composed a
# command and each was wrong about a configuration nobody here can see:
# include.path pulls the key in from another file that git names under the
# INCLUDING scope, and a value carried in the environment has no file at
# all. What is printed is git's own line, unedited.
fx_global() { armed global; git config --global core.hooksPath "$R/globalhooks"; UNDO="git config --global --unset-all core.hooksPath"; }
fx_global_install() { armed global-install; git config --global core.hooksPath "$R/globalhooks"; UNDO="git config --global --unset-all core.hooksPath"; }
fx_included() { armed included; printf '[core]\n\thooksPath = %s/includedhooks\n' "$R" >"$R/extra.cfg"; git -C "$R" config include.path "$R/extra.cfg"; }
fx_command_line() { armed command-line; }
# A global value shadowed by a local one: two sources to clear, both listed,
# in git's order; the summary names the value git reads.
fx_shadowed() { armed shadowed; git config --global core.hooksPath "$R/globalhooks"; UNDO="git config --global --unset-all core.hooksPath"; set_value "$R/localhooks"; }
GLOBAL_ORIGIN="install-git-hooks: hooks-path-origin=\$'global\\tfile:<root>/home/.gitconfig\\t<repo>/globalhooks'"
INCLUDED_ORIGIN="install-git-hooks: hooks-path-origin=\$'local\\tfile:<repo>/extra.cfg\\t<repo>/includedhooks'"
COMMAND_ORIGIN="install-git-hooks: hooks-path-origin=\$'command\\tcommand line:\\t<repo>/envhooks'"
run_rows \
  "a global value: the scope and the origin as git spells them|fx_global||check||rc=2 $(undetermined '<repo>/globalhooks' "$(block "$GLOBAL_ORIGIN")")|" \
  "and the install lane prints the same block|fx_global_install||install||rc=0 $(skipped '<repo>/globalhooks' "$(block "$GLOBAL_ORIGIN")")|helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath='<repo>/globalhooks'" \
  "an included file is named under the including scope, as git names it|fx_included||check||rc=2 $(undetermined '<repo>/includedhooks' "$(block "$INCLUDED_ORIGIN")")|" \
  "a value from the environment is reported as the command line, not a file|fx_command_line|GIT_CONFIG_COUNT=1,GIT_CONFIG_KEY_0=core.hooksPath,GIT_CONFIG_VALUE_0=$TMP/command-line/envhooks|check||rc=2 $(undetermined '<repo>/envhooks' "$(block "$COMMAND_ORIGIN")")|" \
  "a global value shadowed by a local one lists both sources, nothing dropped or reordered|fx_shadowed||check||rc=2 $(undetermined '<repo>/localhooks' "$SET_LINE;$GLOBAL_ORIGIN;$(local_origin '<repo>/localhooks')")|"

echo "=== a report git will not produce is said to be missing ==="
# The verdict does not depend on the listing: a git that cannot produce it
# still stands the checker down, and the text says the origin is missing
# rather than inventing one. The shim refuses --show-origin and passes
# everything else through, so the same repository under the real git is the
# control that reports an origin (the elsewhere rows above).
fx_unlistable() {
  armed unlistable
  set_value "$R/somehooks"
  mkdir -p "$TMP/gitshim"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--show-origin" ] && exit 1; done\nexec %s "$@"\n' "$(command -v git)" >"$TMP/gitshim/git"
  chmod +x "$TMP/gitshim/git"
}
run_rows \
  "an unlistable origin changes the text, never the verdict|fx_unlistable|PATH=$TMP/gitshim:$PATH|check||rc=2 $(undetermined '<repo>/somehooks' "$SET_LINE;$UNLISTED")|"

# A configuration git cannot read has no row: lib/paths.sh's gg_path returns 1
# for every failure, so classify_hooks_path never sees the 128 a broken
# .git/config exits with and its could-not-read branch is unreachable
# (recorded in the audit, not pinned as the contract).

echo "=== the repository's own path cannot break the one-line summary ==="
# The repository path reaches the same one-line summary the configured value
# does, and carries the same class of bytes: a newline would end the line
# early and ESC would hand the terminal control codes, from the name of the
# directory being reported. Rendered by %q, both survive as escapes.
NL=$'\n'
ESCB=$'\033'
wild() { # NAME — a repository at a path holding a newline and ESC
  R="$TMP/$1${NL}po${ESCB}x"
  mkdir -p "$R/.agents/skills"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  cp -R "$GG_SKILL_TEMPLATE" "$R/.agents/skills/commit-guards"
  ln -s "$SKILL_DIR/../doc-limits" "$R/.agents/skills/doc-limits"
  assert_eq "fixture: $1: the path spans two lines" "1" "$(printf '%s' "$R" | wc -l | tr -d ' ')"
}
wild_armed() { wild "$1"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
fx_wild_install() { wild wild-install; }
fx_wild_check() { wild_armed wild-check; }
fx_wild_drift() { wild_armed wild-drift; rm "$R/.git/hooks/pre-commit"; }
wild_hooks() { printf "\$'<root>/%s\\\\npo\\\\Ex/.git/hooks'" "$1"; } # NAME -> the hooks directory as %q renders it
run_rows \
  "an install under that path reports one line, the path escaped|fx_wild_install||install||rc=0 commit-guards git hooks: installed=$(wild_hooks wild-install)|" \
  "the armed verdict is one line as well|fx_wild_check||check||rc=0 commit-guards git hooks: armed=$(wild_hooks wild-check)|" \
  "the drift verdict folds its reason into that one line|fx_wild_drift||check||rc=1 commit-guards git hooks: not-armed=hook-missing=pre-commit|"

echo "=== a repository path that begins with a dash is a path ==="
# `cd "$REPO"` reads a leading dash as an option: `--repo -P` became `cd -P`,
# which succeeds in the WRONG directory rather than failing. Run from the
# parent with the relative name, which the table's absolute --repo cannot
# spell, so this one sits beside it.
R="$TMP/-P"
mkdir -p "$R/.agents/skills"
git -C "$R" init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
cp -R "$GG_SKILL_TEMPLATE" "$R/.agents/skills/commit-guards"
R_PHYS="$(cd -- "$R" && pwd -P)"
DASH_RC=0
DASH_OUT="$(cd "$TMP" && "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo -P 2>&1)" || DASH_RC=$?
assert_eq "an install named by a dash-led relative path arms that repository" "rc=0 $ARMED" "rc=$DASH_RC $(aliased "${DASH_OUT%%$'\n'*}")"
assert_eq "and the shims land there, not in the caller's directory" "$FRESH" "$(state)"

assert_eq "every seeded fixture landed its seed commit" "" "$SEEDS_FAILED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
