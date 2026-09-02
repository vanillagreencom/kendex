# shellcheck shell=bash
# The exact bytes the installer writes into .git/hooks.
#
# Its own file because it is not installer logic: it is a program, in a
# different dialect (POSIX sh, because git runs it and the package may be
# gone), that has to be reproducible byte for byte. `--check` compares a
# helper on disk against this, so what changes here changes what every armed
# repository is measured against.
#
# It cannot source anything. A helper runs from .git/hooks with no guarantee
# the package is still installed — the case its own search exists to survive
# — so what it needs is interpolated in or written out.
#
# Sourced by install-git-hooks, which owns SCRIPT_DIR, GG_SKILL_ROOTS and
# PROJECT_REL, and by lib/hook-check.sh, which compares against it.
set -euo pipefail

# One value, quoted so the helper reads it as data.
#
# Everything baked into the helper is a shell assignment inside single quotes, and a
# value carrying a single quote of its own ENDS that quote — after which the
# rest of the directory name is script. A directory called
# `kid'"'"'; exit 0; #` baked a helper that exited 0 before running anything,
# so both hooks passed every commit: the fail-open this package exists to
# refuse, written by the package itself.
#
# The escape is the POSIX one: close the quote, an escaped quote, reopen.
# Every value goes through here — SCRIPT_DIR did it by hand and the two
# added later did not, which is the whole of how this happened.
gg_shell_quote() { # VALUE -> the value, safe inside single quotes
  local sq="'"
  printf '%s' "${1//$sq/$sq\\$sq$sq}"
}

# The one baked value another checkout of the same project bakes
# differently.
#
# A linked worktree shares one hooks directory with the checkout that armed
# it, and `installed_scripts` is where THAT install sits — so the helper a
# worktree would write differs here and nowhere else while running exactly
# the same program. Comparing it would call every worktree's armed helper
# unverifiable forever, which is what this list exists to stop.
#
# `project_rel` is NOT on it and must not be. It names the project that
# armed the repository, which is the only thing telling two kendex projects
# in one repository apart: the helper is what licenses a session to run a
# checkout-supplied installer, so a project whose own `project_rel` differs
# from the armed one has not been armed and must not be served. Excusing it
# hands project B the consent project A gave. `skill_roots` is the
# package's own list and is not per-anything.
#
# Named as the variable the head interpolates, so the check blanks it and
# compares what is left, rather than finding the assignment in the text.
GG_PER_CHECKOUT_VAR='SCRIPT_DIR'

# A token no baked value carries, standing where the per-checkout value
# would. The head with it in place is a prefix and a suffix of fixed bytes,
# which is what lets the value between them be lifted out whatever it holds.
GG_PER_CHECKOUT_MARK='@@growth-guards-per-checkout@@'

# The head this install would bake, with the per-checkout value blanked.
helper_head_shape() { # -> the head around GG_PER_CHECKOUT_MARK, on stdout
  local "$GG_PER_CHECKOUT_VAR=$GG_PER_CHECKOUT_MARK"
  helper_head
}

# The head this install would bake. Split from the program below because
# only the program is the same bytes everywhere.
helper_head() { # -> the baked head, on stdout
  cat <<HELPER_HEAD
#!/bin/sh
# Scripts directory of the install that wrote this file.
installed_scripts='$(gg_shell_quote "$SCRIPT_DIR")'
# Baked: a helper in .git/hooks cannot source a package that may be gone.
skill_roots='$(gg_shell_quote "$GG_SKILL_ROOTS")'
# Baked too: a moved checkout still resolves the project this came from.
# The last project to arm this repository, which is the one the shims were
# written for; the search below falls back to the work-tree root, so a
# different project sharing these shims is still served.
project_rel='$(gg_shell_quote "$PROJECT_REL")'
HELPER_HEAD
}

# The helper is POSIX sh and self-contained. It runs this install's own
# scripts directory first, then rediscovers one from the MAIN checkout (linked
# worktrees share this hooks directory and may carry no skills of their own),
# so a moved or re-installed checkout repairs itself.
#
# Generating and VERIFYING both go through here, so a checker cannot drift
# from a writer and start blessing a helper that only resembles one. These
# bytes carry no per-checkout value, so they are compared exactly.
helper_program() { # -> the part of the helper every checkout writes alike
  cat <<'HELPER'
# kendex growth-guards git hooks. Managed by the growth-guards skill and
# rewritten on every install — do not edit.
#
# usage: kendex-guards pre-commit | kendex-guards commit-msg MSGFILE
#
# Blocks whenever the guard it should run cannot be reached: a gate that
# cannot run is never a pass.
mode="${1-}"
case "$mode" in
  pre-commit | commit-msg) shift ;;
  *)
    echo "kendex-guards: usage: kendex-guards pre-commit | commit-msg MSGFILE" >&2
    exit 2
    ;;
esac

# Exit 2 is the family's "could not complete", distinct from a check's
# exit 1 verdict. Both block the commit.
fail() {
  echo "kendex-guards: $*" >&2
  echo "  The commit is blocked because a guard could not run. Re-arm the shims with 'kendex guard install', or bypass this commit with 'git commit --no-verify'." >&2
  exit 2
}

# `$(...)` strips trailing newlines, and a checkout directory may end in
# one — so a naive capture names a directory that is not there and every
# search below finds nothing. The sentinel gives the shell something to
# strip that is not the path; then the one newline git added comes off.
# Written out rather than sourced: this file runs from .git/hooks, where
# the package it would source may be gone.
gg_nl='
'
# Same name and same shape as the package's, in lib/paths.sh. Two spellings
# of one contract is how every other pair in here drifted.
gg_git_path() { # VAR DIR ARG... — VAR gets git's answer, bytes intact
  __v="$1"
  __d="$2"
  shift 2
  __raw="$(git -C "$__d" "$@" 2>/dev/null && printf x)" || { eval "$__v=''"; return 1; }
  __raw="${__raw%x}"
  eval "$__v=\${__raw%\"\$gg_nl\"}"
}
gg_git_path common "$PWD" rev-parse --git-common-dir || common=""
[ -n "$common" ] || fail "could not resolve the common git directory"
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
gg_git_path top "$PWD" rev-parse --show-toplevel || top=""
[ -n "$top" ] || fail "could not resolve the working tree root"
# The main checkout owns the installed skills; a linked worktree shares this
# hooks directory but may not carry its own copy. Its own root is the
# fallback for layouts where the git directory is not <root>/.git.
# The directory holding the common git dir is the main checkout only in the
# ordinary <main>/.git layout. Under --separate-git-dir the git directory
# lives outside the checkout, so this is an unrelated directory — and one
# with a growth-guards of its own would run here as this repository's gate.
#
# Two tests, and the first alone is not enough. Owning it: its own common
# git dir has to be ours. And BEING a checkout root: git resolves upward, so
# every directory inside this work tree passes the ownership test — a git
# directory at <worktree>/meta/repo.git made <worktree>/meta the main
# checkout, and a growth-guards under it would have run as this
# repository's gate. So the work tree git resolves from the candidate has to
# be the candidate itself.
#
# Where either answer is no the root is dropped rather than guessed at, and
# a search that then finds nothing fails closed, which is what this helper
# is for.
main="${common%/*}"
[ -n "$main" ] || main="/"
# In a subshell with git's redirects unset: this helper runs AS a hook, so
# GIT_DIR is exported, and git honours it over `-C` — every directory then
# answers with THIS repository's common dir and looks owned. Asking about
# another directory means asking without the answer already in the room.
main_common="$(
  unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
  git -C "$main" rev-parse --git-common-dir 2>/dev/null && printf x
)" || main_common=""
main_common="${main_common%x}"
main_common="${main_common%"$gg_nl"}"
# git answers relative to the directory it was asked in, and $common was
# absolutized against $PWD — so both have to be absolute before they can
# disagree about anything but identity.
case "${main_common:-/}" in
  /*) ;;
  *) main_common="$main/$main_common" ;;
esac
main_top="$(
  unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
  git -C "$main" rev-parse --show-toplevel 2>/dev/null && printf x
)" || main_top=""
main_top="${main_top%x}"
main_top="${main_top%"$gg_nl"}"
if [ -z "$main_common" ] || [ "$main_common" != "$common" ] \
  || [ -z "$main_top" ] || [ "$main_top" != "$main" ]; then
  main=""
fi
if [ -n "$installed_scripts" ] && [ -x "$installed_scripts/$mode" ]; then
  exec "$installed_scripts/$mode" "$@"
fi
for root in ${main:+"$main/$project_rel"} "$top/$project_rel" ${main:+"$main/"} "$top/"; do
  for base in $skill_roots; do
    if [ -x "$root$base/growth-guards/scripts/$mode" ]; then
      exec "$root$base/growth-guards/scripts/$mode" "$@"
    fi
  done
done
fail "no executable growth-guards $mode script at $installed_scripts, nor under $main or $top (project '$project_rel', roots $skill_roots)"
HELPER
}

helper_body() { # -> the helper this installer would write, on stdout
  helper_head
  helper_program
}
