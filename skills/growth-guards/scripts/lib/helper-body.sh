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

# The helper is POSIX sh and self-contained. It takes this install's own
# scripts directory first, then rediscovers one from the MAIN checkout (linked
# worktrees share this hooks directory and may carry no skills of their own),
# so a moved or re-installed checkout repairs itself.
# The exact bytes this installer writes as the helper. Generating and
# VERIFYING both go through here, so a checker cannot drift from a writer
# and start blessing a helper that only resembles one.
# One value, quoted so the helper reads it as data.
#
# Everything baked below is a shell assignment inside single quotes, and a
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

# The same value, on one line and reversibly.
#
# `%` first and the newline second, so that decoding in the other order is
# unambiguous: after encoding, a `%0A` in the output can only have come from
# a real newline, because a literal `%0A` in the input became `%250A`.
gg_encode_line() { # VALUE -> single-line, separator-safe encoding
  local v="${1//%/%25}"
  v="${v//$'\n'/%0A}"
  printf '%s' "${v// /%20}"
}

# One entry of the armed-projects record.
#
# A project relative path is either empty — the project IS the work tree —
# or ends in `/`, so a lone `.` can stand for the empty one and never
# collide with a real value.
gg_encode_rel() { # REL -> one list entry
  case "$1" in
    "") printf '.' ;;
    *) gg_encode_line "$1" ;;
  esac
}

gg_decode_rel() { # VAR ENTRY -> sets VAR to the rel
  local __name="$1" v="$2"
  case "$v" in
    ".") eval "$__name=''"; return 0 ;;
  esac
  v="${v//%0A/$'\n'}"
  v="${v//%20/ }"
  eval "$__name=\${v//%25/%}"
}

helper_body() { # -> the helper this installer would write, on stdout
  # Encoded before the heredoc, not inside it: a loop with nested quoting in
  # a heredoc is a parse this does not need to be right about.
  local __record="" __one=""
  for __one in ${PROJECT_RELS[@]+"${PROJECT_RELS[@]}"}; do
    __record="$__record $(gg_encode_rel "$__one")"
  done
  cat <<HELPER_HEAD
#!/bin/sh
# Scripts directory of the install that wrote this file.
installed_scripts='$(gg_shell_quote "$SCRIPT_DIR")'
# Baked: a helper in .git/hooks cannot source a package that may be gone.
skill_roots='$(gg_shell_quote "$GG_SKILL_ROOTS")'
# Baked too: a moved checkout still resolves the project this came from.
project_rel='$(gg_shell_quote "$PROJECT_REL")'
# Every project that has ever armed this helper, appended never replaced —
# an uninstall from any of them looks for survivors under all of them.
# Percent-encoded, space separated: %25 a percent, %0A a newline, %20 a
# space, and a lone dot the project that IS the work tree.
# armed-projects:$__record
HELPER_HEAD
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
# Owning it is the test: its own common git dir has to be ours. Where it is
# not, the root is dropped rather than guessed at, and a search that then
# finds nothing fails closed, which is what this helper is for.
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
if [ -z "$main_common" ] || [ "$main_common" != "$common" ]; then
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

# The project a helper was armed from, read back out of it.
#
# The shims are shared by every work tree of a repository, and the helper
# carries the project of whichever one armed them. Uninstalling from a
# DIFFERENT nested project has to know that, or it looks for survivors under
# its own project's path, finds none, and removes hooks another work tree is
# still committing through.
#
# Nonzero when the value cannot be read with confidence — no helper, no line,
# or a value carrying a newline, which a line-based read cannot see the end
# of. The caller treats that as unknown, and unknown never removes anything.
# The locals carry `__` names because the caller passes the NAME of its own
# variable: a local here that collides with it is assigned by the eval and
# then discarded on return, which reads as an empty record rather than an
# error. That is how this function first shipped.
gg_baked_project_rels() { # ARRAY HELPER -> sets ARRAY to every armed rel
  local __name="$1" __line="" __entry="" __one="" __out=()
  eval "$__name=()"
  [ -f "$2" ] || return 1
  # The record line, not the assignment above it: the assignment may span
  # lines, and answering "cannot tell" for a project plainly visible here
  # would stop an uninstall entirely — a repository nobody can disarm.
  __line="$(grep -m1 -- '^# armed-projects:' "$2")" || return 1
  __line="${__line#\# armed-projects:}"
  for __entry in $__line; do
    gg_decode_rel __one "$__entry" || return 1
    __out+=("$__one")
  done
  eval "$__name=(\${__out[@]+\"\${__out[@]}\"})"
}

# The record the next helper should carry: what this one already says, plus
# this project when this run is the arming.
#
# Appending is the whole point. The shims are shared, so a second project
# arming them does not un-arm the first, and an uninstall from any project
# has to look for survivors under all of them.
#
# `--check` must NOT append: it compares a helper on disk against the bytes
# an install would write, and a check run from a project that never armed
# anything would otherwise report every armed repository as drifted.
# Why a record and not the current project: the shims are SHARED, so a
# second project arming them does not un-arm the first, and two prefixes —
# the caller's and the last arming one — is still a guess about how many
# there are. The list is bounded by consent: it grows only when somebody
# runs the installer in a new project.
#
gg_arming_record() { # ARRAY HELPER REL MODE
  local __name="$1" __one="" __recorded=0 __record=()
  eval "$__name=()"
  if [ -f "$2" ]; then
    gg_baked_project_rels __record "$2" || __record=()
  fi
  if [ "$4" = "install" ]; then
    for __one in ${__record[@]+"${__record[@]}"}; do
      [ "$__one" = "$3" ] && __recorded=1
    done
    [ "$__recorded" -eq 1 ] || __record+=("$3")
  fi
  eval "$__name=(\${__record[@]+\"\${__record[@]}\"})"
}
