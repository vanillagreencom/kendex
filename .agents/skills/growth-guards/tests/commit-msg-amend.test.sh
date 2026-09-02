#!/usr/bin/env bash
# Pins for the one commit-msg rule that cannot be judged from an index alone:
# the changelog a commit owes is read against the parent the commit will HAVE,
# so an amend is judged against HEAD's parent, not the HEAD it replaces. Four
# pins, each firing one against its control: a real `git commit` for the rule
# end to end, and an argv FILE for which argv IS an amend.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=../scripts/lib/commit-parent.sh
source "$SKILL_DIR/scripts/lib/commit-parent.sh"
unset GROWTH_GUARDS_COMMIT_TYPES GROWTH_GUARDS_SUBJECT_MAX \
  GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
skip() { printf '  skip  %s\n' "$1"; }

# The widening is read off /proc/<pid>/cmdline and nowhere else, so a host
# without procfs — macOS, which this family supports — answers "not an amend",
# and the pair of pins asserting the widening is SKIPPED there rather than
# reporting a portability fact as a defect.
HAVE_PROC=0
if [ -r "/proc/$$/cmdline" ]; then HAVE_PROC=1; fi

mk_repo() { # DIR — a repo with the commit-msg hook installed and the rule armed
  mkdir -p "$1/crates/core" "$1/changelog.d/fixed"
  git -C "$1" -c init.defaultBranch=main init -q
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  printf '#!/bin/sh\nexec %s "$1"\n' "$CM" >"$1/.git/hooks/commit-msg"
  chmod +x "$1/.git/hooks/commit-msg"
  printf '[env]\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$1/kendex.settings.toml"
}
commit_in() { # DIR ARG... — a real commit; sets OUT and RC
  OUT=""; RC=0
  OUT="$(git -C "$1" commit "${@:2}" 2>&1)" || RC=$?
}
staged_on_fragment() { # NAME — HEAD carries a crate change and its fragment,
  R="$TMP/$1"          # more crate code is staged on top, and nothing else is.
  mk_repo "$R"         # One fixture per pin, named by R, so a pin skipped for
  printf 'seed\n' >"$R/README.md"   # want of /proc leaves nothing behind.
  git -C "$R" add -A
  git -C "$R" commit -qm "chore: base [no-changelog]" >/dev/null 2>&1
  printf 'fn one() {}\n' >"$R/crates/core/lib.rs"
  printf -- '- A fix consumers see.\n' >"$R/changelog.d/fixed/ken-1.md"
  git -C "$R" add -A
  commit_in "$R" -m 'fix(KEN-1): change a crate'
  printf 'fn two() {}\n' >>"$R/crates/core/lib.rs"
  git -C "$R" add -A
}
refused_naming_lib() { # 0 when RC/OUT are the refusal that names the crate path
  [ "$RC" -eq 1 ] || return 1
  case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) return 0 ;; esac
  return 1
}

echo "=== an amend is judged against the parent it will HAVE, not the HEAD it replaces ==="
# `git diff --cached` on an amend shows only what was staged ON TOP of the
# commit being replaced, so a fragment already inside that commit read as no
# fragment at all and a commit satisfying the rule was refused, the obvious
# escape being the flag that skips the whole hook chain. The control that reds
# when the widening goes too far, and the one pin here needing no /proc: the
# NEXT commit, whose parent really is that HEAD, is not excused by the fragment
# in the one before.
staged_on_fragment repo-next
commit_in "$R" -m 'fix(KEN-2): change a crate again'
refused_naming_lib \
  && ok "control: the commit AFTER a fragment commit still owes its own entry" \
  || bad "control: the commit after a fragment commit still owes its own entry" "rc=$RC out=$OUT"

if [ "$HAVE_PROC" -eq 0 ]; then
  skip "the widening pins need /proc/<pid>/cmdline, where the committing argv is read"
else
  staged_on_fragment repo-amend
  commit_in "$R" --amend --no-edit
  [ "$RC" -eq 0 ] && ok "an amend adding more code passes on the fragment the commit already carries" \
    || bad "an amend passes on the fragment the commit already carries" "rc=$RC out=$OUT"

  # MUST-FAIL: `--mess` is git's abbreviation of `--message`, so the `--amend`
  # behind it is the committer's message TEXT, not the flag. A scan reading the
  # flag out of a value fails open, excusing this commit with the fragment the
  # previous one carries; the widening is what that class attacks, and every
  # fail-open this lane had came from it.
  staged_on_fragment repo-value
  commit_in "$R" --mess '--amend'
  refused_naming_lib \
    && ok "must-fail: a message VALUE spelling the flag does not widen the base" \
    || bad "a message value spelling the flag must not widen the base" "rc=$RC out=$OUT"
fi

echo '=== which argv is an amend ==='
# The NUL-delimited bytes the kernel would hold. A message is an argument like
# any other, so the flag BEHIND one is still the flag: nothing dash-prefixed
# stands before it to have swallowed it.
ARGV="$TMP/argv"
printf '%s\0' git commit -m 'fix(KEN-1): change a crate' --amend >"$ARGV"
gg_argv_is_amend "$ARGV" \
  && ok "the flag behind a message is the flag" \
  || bad "the flag behind a message is the flag" "read as plain, wanted amend"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
