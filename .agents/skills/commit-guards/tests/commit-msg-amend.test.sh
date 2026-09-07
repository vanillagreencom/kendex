#!/usr/bin/env bash
# Pins for the one commit-msg rule that cannot be judged from an index alone:
# the changelog a commit owes is read against the parent the commit will
# HAVE, so an amend is judged against HEAD's parent, not the HEAD it
# replaces. The widening is read off /proc/<pid>/cmdline of the committing
# git and nowhere else, so a host without procfs (macOS, which this family
# supports) answers "not an amend" and the rows asserting the widening are
# SKIPPED there rather than reporting a portability fact as a defect. Two
# tables: a real `git commit` in a repository whose HEAD carries a crate
# change with its fragment and more crate code staged on top, pinned by
# git's exit status with every line the hook printed; and an argv as the
# kernel would hold it, pinned by whether it IS an amend.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=../scripts/lib/commit-parent.sh
source "$SKILL_DIR/scripts/lib/commit-parent.sh"
unset COMMIT_GUARDS_COMMIT_TYPES COMMIT_GUARDS_SUBJECT_MAX \
  COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}
skip() { printf '  skip  %s\n' "$1"; }

HAVE_PROC=0
if [ -r "/proc/$$/cmdline" ]; then HAVE_PROC=1; fi

# The fixture: the commit-msg hook installed with its output captured, the
# rule armed for crates/* and ui/*, HEAD carrying a crate change and its
# fragment, more crate code staged on top and nothing else. One repository
# per row, so a row skipped for want of /proc leaves nothing behind.
R=""
staged_on_fragment() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R/crates/core" "$R/changelog.d/fixed"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '#!/bin/sh\nexec %s "$1" >"%s/hook.out" 2>&1\n' "$CM" "$R" >"$R/.git/hooks/commit-msg"
  chmod +x "$R/.git/hooks/commit-msg"
  printf '[env]\nCOMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$R/kendex.settings.toml"
  printf 'seed\n' >"$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm "chore: base [no-changelog]" >/dev/null 2>&1
  printf 'fn one() {}\n' >"$R/crates/core/lib.rs"
  printf -- '- A fix consumers see.\n' >"$R/changelog.d/fixed/ken-1.md"
  git -C "$R" add -A
  git -C "$R" commit -qm 'fix(KEN-1): change a crate' >/dev/null 2>&1 || true
  # The hook judged that commit too: a fixture whose seed was refused would
  # amend the base commit, whose header waives the entry.
  [ "$(git -C "$R" log -1 --format=%s)" = 'fix(KEN-1): change a crate' ] \
    || { echo "harness: fixture $1's seed commit was refused" >&2; exit 2; }
  printf 'fn two() {}\n' >>"$R/crates/core/lib.rs"
  git -C "$R" add -A
}
# One line for a commit: git's exit status, then every line the hook wrote.
commit() { # ARGS...
  local rc=0
  : >"$R/hook.out"
  git -C "$R" commit "$@" >/dev/null 2>&1 || rc=$?
  printf 'rc=%s %s' "$rc" "$(LC_ALL=C paste -sd ';' - <"$R/hook.out")"
}
OWED="commit-msg FAIL crates/core/lib.rs changed without a changelog entry;  write one of: changelog.d/*/*.md;  or put [no-changelog] in the header when the commit changes nothing a consumer sees;  CHANGELOG.md counts only under COMMIT_GUARDS_CHANGELOG_COLLATE=1, which is the release commit collating the fragments"
header() { printf 'commit-msg: OK — conventional header: %s' "$1"; } # HEADER

echo "=== an amend is judged against the parent it will HAVE, not the HEAD it replaces ==="
# `git diff --cached` on an amend shows only what was staged ON TOP of the
# commit being replaced, so a fragment already inside that commit read as no
# fragment at all and a commit satisfying the rule was refused, the obvious
# escape being the flag that skips the whole hook chain. The control that
# reds when the widening goes too far needs no /proc: the NEXT commit,
# whose parent really is that HEAD, is not excused by the fragment in the
# one before.
staged_on_fragment next
assert_eq "control: the commit AFTER a fragment commit still owes its own entry" \
  "rc=1 $(header 'fix(KEN-2): change a crate again');$OWED" "$(commit -m 'fix(KEN-2): change a crate again')"
if [ "$HAVE_PROC" -eq 0 ]; then
  skip "the widening rows need /proc/<pid>/cmdline, where the committing argv is read"
else
  staged_on_fragment amend
  assert_eq "an amend adding more code passes on the fragment the commit already carries" \
    "rc=0 $(header 'fix(KEN-1): change a crate')" "$(commit --amend --no-edit)"
  # MUST-FAIL: `--mess` is git's abbreviation of `--message`, so the `--amend`
  # behind it is the committer's message TEXT, not the flag. A scan reading
  # the flag out of a value fails open, excusing this commit with the
  # fragment the previous one carries; every fail-open this lane had came
  # from that class. The header refusal is the message's own; the owed entry
  # is the pin.
  staged_on_fragment value
  assert_eq "must-fail: a message VALUE spelling the flag does not widen the base" \
    "rc=1 commit-msg FAIL non-conventional header: --amend;  expected: type(scope)!: subject — scope and '!' optional; types: build chore ci docs feat fix perf refactor revert style test;  scope accepts uppercase issue keys and issue numbers, e.g. fix(ABC-123): tighten the gate / fix(#123): case-fold IDs;  git-generated headers (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged;$OWED" \
    "$(commit --mess '--amend')"
  # MUST-FAIL: a message merely CONTAINING the flag. The argv is read
  # NUL-delimited so this stays one argument; a scan joining argv with spaces
  # (what `ps` would give) would read the flag out of it and excuse the
  # commit with the fragment the previous one carries.
  staged_on_fragment mention
  assert_eq "must-fail: a message CONTAINING the flag is not the flag" \
    "rc=1 $(header 'fix(KEN-2): wire the --amend path');$OWED" \
    "$(commit -m 'fix(KEN-2): wire the --amend path')"
fi

echo "=== which argv is an amend: the NUL-delimited bytes the kernel would hold ==="
# The scan reads the token immediately before each `--amend`: a value-taking
# option consumes the next argument and nothing further, so it is the only
# token that can swallow it; `--no-amend` stands outside that guard; a bare
# `--` stops the scan; the wrapper's arguments ahead of `commit` are skipped.
is_amend() { # WORDS... — yes or no
  printf '%s\0' "$@" >"$TMP/argv"
  if gg_argv_is_amend "$TMP/argv"; then echo yes; else echo no; fi
}
argv_rows() { # label | argv words | expect
  local row label argv expect words
  for row in "$@"; do
    IFS='|' read -r label argv expect <<<"$row"
    read -ra words <<<"$argv"
    assert_eq "$label" "$expect" "$(is_amend "${words[@]}")"
  done
}
argv_rows \
  "the flag behind a message is the flag: a message is an argument like any other|git commit -m fix(KEN-1):_change --amend|yes" \
  "the flag behind a value-taking option is that option's value|git commit --mess --amend|no" \
  "the flag behind a clustered short option ending in -m is its value|git commit -am --amend|no" \
  "a flag behind a no-value option is the flag|git commit --no-edit --amend|yes" \
  "a flag behind a short valueless option is the flag|git commit -a --amend|yes" \
  "an option carrying its own value is read as swallowing: the conservative miss the scan accepts|git commit --message=x --amend|no" \
  "--no-amend after the flag withdraws it|git commit --amend --no-amend|no" \
  "--no-amend before the flag does not withdraw it: the last word wins|git commit --no-amend --amend|yes" \
  "git's abbreviation of the flag is the flag|git commit --ame|yes" \
  "a bare -- stops the scan: the flag behind it is a path|git commit -- lib.rs --amend|no" \
  "the wrapper's arguments ahead of commit are skipped: -c never reads as swallowing|git -c core.editor=true commit --amend|yes" \
  "a git that is not committing is not an amend|git rebase --amend|no"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
