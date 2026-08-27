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

# Two directories are the same directory whatever they are called. Resolved
# on disk, which settles a symlinked checkout and a `..` together; a
# directory that is not there yet cannot be resolved and is compared as
# written, which is enough for spellings that differ only on paper.
same_dir() { # A B
  local a="" b=""
  a="$(cd -- "$1" 2>/dev/null && pwd -P)" || a="$1"
  b="$(cd -- "$2" 2>/dev/null && pwd -P)" || b="$2"
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
