# shellcheck shell=bash
# Shared setup for the commit-guards suites. Sourced, never run as one: suite
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

# The trailing slash macOS puts on TMPDIR is dropped first: a `//` in a
# fixture path never matches the path a script normalises and prints back.
gg_tmpdir="${TMPDIR:-/tmp}"
gg_tmpdir="${gg_tmpdir%/}"
TMP="$(mktemp -d "$gg_tmpdir/gg-${gg_suite}.XXXXXX")" || {
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

# GIT_CONFIG_PARAMETERS and the GIT_CONFIG_COUNT/KEY_n/VALUE_n family carry
# configuration in the ENVIRONMENT, so a private HOME and GIT_CONFIG_NOSYSTEM
# do not stop them: either one still sets core.hooksPath or commit.gpgsign
# for every fixture below. git exports GIT_CONFIG_PARAMETERS into hooks
# whenever a caller used `git -c`, which is exactly how a suite run from a
# hook inherits them. The CLI scrubs the same names in refresh_sources.rs.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true
gg_kv=0
while [ "$gg_kv" -lt 64 ]; do
  unset "GIT_CONFIG_KEY_$gg_kv" "GIT_CONFIG_VALUE_$gg_kv" 2>/dev/null || true
  gg_kv=$((gg_kv + 1))
done
unset gg_kv

unset GIT_TEMPLATE_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
  GIT_EDITOR GIT_PAGER GIT_CEILING_DIRECTORIES 2>/dev/null || true

# A must-fail control's copy of the suite's scripts: SCRIPT, under
# $SKILL_DIR/scripts, with FROM, which must match exactly one line, replaced
# by TO. VAR gets the edited copy's path; the tracked file is never touched.
gg_mutants=0
gg_mutant() { # VAR SCRIPT FROM TO
  local dir="$TMP/mutant-$gg_mutants" matches
  gg_mutants=$((gg_mutants + 1))
  cp -R -- "$SKILL_DIR/scripts" "$dir"
  matches="$(FROM="$3" awk 'index($0, ENVIRON["FROM"]) { n++ } END { print n + 0 }' "$dir/$2")" || exit 2
  [ "$matches" -eq 1 ] || { echo "harness: control on $2 matched $matches lines: $3" >&2; exit 2; }
  FROM="$3" TO="$4" awk '{ i = index($0, ENVIRON["FROM"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])); print }' \
    "$dir/$2" >"$dir/$2.new" || exit 2
  ! cmp -s -- "$dir/$2" "$dir/$2.new" || { echo "harness: control on $2 changed nothing: $3" >&2; exit 2; }
  mv -- "$dir/$2.new" "$dir/$2"
  chmod -- +x "$dir/$2"
  eval "$1=\$dir/\$2"
}
