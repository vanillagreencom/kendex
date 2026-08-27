# shellcheck shell=bash
# What core.hooksPath means for THIS repository, asked once for every mode.
#
# Sourced by install-git-hooks, which owns REPO_ABS and HOOKS_DIR. Reads
# only: it decides which directory git executes hooks from and whether that
# is the directory this installer writes, and answers in three variables —
# CUSTOM_HOOKS (the configured value), HOOKS_PATH_SET, HOOKS_PATH_ELSEWHERE.
# Strict on its own terms rather than on its caller's: a reader of one of
# these functions should not have to go find out which shell options were on
# when the file was read.
set -euo pipefail

# A path with `.` dropped and `..` folded on paper, for comparing two
# spellings of one place when neither can be resolved on disk. Never a
# substitute for resolving: it settles no symlink, and a `..` across one
# lands somewhere else entirely.
lexical_dir() { # PATH -> folded path on stdout
  local rest="${1%/}" part="" out="" lead="" last=""
  case "$1" in /*) lead="/" ;; esac
  local IFS=/
  for part in $rest; do
    case "$part" in
      "" | .) continue ;;
      ..)
        last="${out##*/}"
        if [ -z "$out" ]; then
          # Absolute: `..` at the root is the root, which is where git and
          # the kernel land too. Relative: the climb is real and is kept.
          [ -n "$lead" ] || out=".."
        elif [ "$last" = ".." ]; then
          out="$out/.."
        else
          case "$out" in
            */*) out="${out%/*}" ;;
            *) out="" ;;
          esac
        fi
        ;;
      *) out="${out:+$out/}$part" ;;
    esac
  done
  printf '%s' "${lead}${out}"
}

# Two directories are the same directory whatever they are called. Resolved
# on disk first, which settles a symlinked checkout and a `..` together.
#
# A directory that is not there yet cannot be resolved, and comparing the
# raw spellings there answered "elsewhere" for `.git/refs/../hooks` on a
# repository whose hooks directory git had not created — so an install that
# should have created it stood down instead. Unresolvable falls back to the
# folded form, which settles every spelling that differs only on paper.
same_dir() { # A B
  local a="" b=""
  a="$(cd -- "$1" 2>/dev/null && pwd -P)" || a="$(lexical_dir "$1")"
  b="$(cd -- "$2" 2>/dev/null && pwd -P)" || b="$(lexical_dir "$2")"
  [ "$a" = "$b" ]
}

# HOOKS_PATH_ELSEWHERE is the question every mode actually asks: is git
# reading hooks from somewhere this installer does not write?
#
# A core.hooksPath naming this repository's own hooks directory is not a
# redirect — it is a project saying out loud where its hooks live, and the
# directory it names is the one written anyway. Treating it as foreign
# refused to arm a repository over its own spelling of the default.
#
# Empty is elsewhere for a different reason: it switches hooks off outright,
# so nothing installed in any directory would run.
classify_hooks_path() {
  CUSTOM_HOOKS=""
  HOOKS_PATH_SET=0
  HOOKS_PATH_ELSEWHERE=0
  CUSTOM_HOOKS="$(git -C "$REPO_ABS" config --get core.hooksPath 2>/dev/null)" \
    && HOOKS_PATH_SET=1
  [ "$HOOKS_PATH_SET" -eq 1 ] || return 0
  HOOKS_PATH_ELSEWHERE=1
  [ -n "$CUSTOM_HOOKS" ] || return 0
  local abs="$CUSTOM_HOOKS"
  case "$abs" in
    /*) ;;
    *) abs="$REPO_ABS/$abs" ;;
  esac
  same_dir "$abs" "$HOOKS_DIR" && HOOKS_PATH_ELSEWHERE=0
  return 0
}

# core.hooksPath set to the empty string switches git hooks off outright.
#
# Its own question because git's answer about it misleads everywhere else:
# `rev-parse --git-path hooks` reports `./`, so every caller that resolves
# the directory would measure the repository ROOT in place of a directory
# git never reads — and a root holding the right shapes then reads as armed
# for a repository whose commits nothing gates. Callers ask this before they
# resolve anything.
hooks_path_off() { # -> 0 when hooks are switched off
  [ "$HOOKS_PATH_SET" -eq 1 ] && [ -z "$CUSTOM_HOOKS" ]
}

# The one remedy line for that state, so install and check say the same
# thing. Arming is not the whole of it: the installer stands down under any
# value at all, empty included, so the unset has to come first.
HOOKS_OFF_REMEDY="run 'git config --unset core.hooksPath', then 'kendex guard install'"
