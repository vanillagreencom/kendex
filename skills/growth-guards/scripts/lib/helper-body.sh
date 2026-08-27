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

helper_body() { # -> the helper this installer would write, on stdout
  cat <<HELPER_HEAD
#!/bin/sh
# Scripts directory of the install that wrote this file.
installed_scripts='$(gg_shell_quote "$SCRIPT_DIR")'
# Baked: a helper in .git/hooks cannot source a package that may be gone.
skill_roots='$(gg_shell_quote "$GG_SKILL_ROOTS")'
# Baked too: a moved checkout still resolves the project this came from.
project_rel='$(gg_shell_quote "$PROJECT_REL")'
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
gg_git_path() { # VAR ARG — VAR gets `git rev-parse ARG`, bytes intact
  __raw="$(git rev-parse "$2" 2>/dev/null && printf x)" || { eval "$1=''"; return 1; }
  __raw="${__raw%x}"
  eval "$1=\${__raw%\"\$gg_nl\"}"
}
gg_git_path common --git-common-dir || common=""
[ -n "$common" ] || fail "could not resolve the common git directory"
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
gg_git_path top --show-toplevel || top=""
[ -n "$top" ] || fail "could not resolve the working tree root"
# The main checkout owns the installed skills; a linked worktree shares this
# hooks directory but may not carry its own copy. Its own root is the
# fallback for layouts where the git directory is not <root>/.git.
main="${common%/*}"
[ -n "$main" ] || main="/"
if [ -n "$installed_scripts" ] && [ -x "$installed_scripts/$mode" ]; then
  exec "$installed_scripts/$mode" "$@"
fi
for root in "$main/$project_rel" "$top/$project_rel" "$main/" "$top/"; do
  for base in $skill_roots; do
    if [ -x "$root$base/growth-guards/scripts/$mode" ]; then
      exec "$root$base/growth-guards/scripts/$mode" "$@"
    fi
  done
done
fail "no executable growth-guards $mode script at $installed_scripts, nor under $main or $top (project '$project_rel', roots $skill_roots)"
HELPER
}
