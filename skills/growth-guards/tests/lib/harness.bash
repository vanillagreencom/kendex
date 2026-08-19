# shellcheck shell=bash
# Shared setup for the growth-guards suites. Sourced, never run as one: suite
# runners glob tests/*.sh, so both the subdirectory and the .bash name keep
# this file out of every run and out of the exec-bit lint.
#
# A suite sources this immediately after set -euo pipefail and gets:
#   TMP     a scratch root it owns, removed on exit
#   TMPDIR  inside that root, so scratch the code under test creates lands in
#           a namespace no other process writes to and can be counted
#   git     no system, global, XDG or template configuration and no repo or
#           identity variables from the caller: core.hooksPath,
#           init.templateDir and commit.gpgsign decide fixture results
#           otherwise, and GIT_DIR/GIT_INDEX_FILE leak in whenever a suite
#           runs from inside a git hook

set -euo pipefail

gg_suite="${0##*/}"
gg_suite="${gg_suite%.test.sh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-${gg_suite}.XXXXXX")" || {
  echo "harness: could not create a scratch root under ${TMPDIR:-/tmp}" >&2
  exit 2
}
trap 'rm -rf -- "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

unset GIT_TEMPLATE_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
  GIT_EDITOR GIT_PAGER GIT_CEILING_DIRECTORIES 2>/dev/null || true
