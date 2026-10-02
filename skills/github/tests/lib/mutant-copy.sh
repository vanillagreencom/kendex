#!/usr/bin/env bash
# A must-fail control's subject, for every suite here whose control edits a
# script: a copy of this skill's scripts tree with one whole line of one file
# replaced and the rest kept, so the tracked file is never touched.
# Sourced, never run: CI's suite glob picks up skills/*/tests/*.sh only.

MUTANT_COPY_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)" || {
  echo "mutant-copy: scripts=unresolved" >&2
  exit 2
}

# mutant_copy_edit DEST FROM TO FILE — copy the scripts tree to
# DEST/skills/github/scripts, replace the line of FILE (a path under
# scripts/) that equals FROM with TO, and print the edited file's path.
# FROM must be exactly one whole line of FILE, and the edit must remove it;
# either miss exits 2, since a control whose edit planted nothing proves
# nothing.
mutant_copy_edit() { # DEST FROM TO FILE
  local dest="$1" from="$2" to="$3" script
  mkdir -p "$dest/skills/github"
  cp -R "$MUTANT_COPY_SCRIPTS" "$dest/skills/github/scripts"
  script="$dest/skills/github/scripts/$4"
  [[ "$(grep -cxF -- "$from" "$script")" == 1 ]] || {
    echo "FIXTURE: the ${dest##*/} line was not unique in $script" >&2
    exit 2
  }
  F="$from" T="$to" awk 'BEGIN { f = ENVIRON["F"]; t = ENVIRON["T"] } $0 == f { $0 = t } { print }' "$script" >"$script.edit"
  cat -- "$script.edit" >"$script"
  rm -f -- "${script:?}.edit"
  ! grep -qxF -- "$from" "$script" || {
    echo "FIXTURE: the ${dest##*/} edit matched nothing in $script" >&2
    exit 2
  }
  printf '%s\n' "$script"
}
