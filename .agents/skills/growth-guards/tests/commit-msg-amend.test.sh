#!/usr/bin/env bash
# Pins for the one commit-msg rule that cannot be judged from an index alone:
# the changelog a commit owes is read against the parent the commit will HAVE,
# so an amend is judged against HEAD's parent, not the HEAD it replaces. Three
# kinds of pin, because the answer is read off a process — a real `git commit`
# for the rule end to end, each firing pin against its control; an argv FILE for
# which argv IS an amend; and a FAKE `git`, for the arms that need a process.
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
# and a pin asserting the widening is SKIPPED there rather than reporting a
# portability fact as a defect. On Linux it is not a portability fact: a
# hardened kernel or a break in the detection would hide every widening pin
# below behind a green run, so that pair REDS rather than skipping.
HAVE_PROC=0
if [ -r "/proc/$$/cmdline" ]; then HAVE_PROC=1; fi
if [ "$(uname -s)" = Linux ] && [ "$HAVE_PROC" -eq 0 ]; then
  bad "the /proc gate is honest" "Linux with /proc/$$/cmdline unreadable: every widening pin would skip"
else
  ok "the /proc gate is honest — a skip below means /proc is absent by design"
fi

mk_repo() { # DIR — a repo with the commit-msg hook installed and the rule armed
  mkdir -p "$1/crates/core" "$1/changelog.d/fixed"
  git -C "$1" -c init.defaultBranch=main init -q
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  printf '#!/bin/sh\nexec %s "$1"\n' "$CM" >"$1/.git/hooks/commit-msg"
  chmod +x "$1/.git/hooks/commit-msg"
  printf '[env]\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$1/kendex.settings.toml"
}
seed_commit() { # DIR — the base commit an amend below sits on
  printf 'seed\n' >"$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm "chore: base [no-changelog]" >/dev/null 2>&1
}
crate_commit() { # DIR — a commit changing a crate and carrying its fragment
  printf 'fn one() {}\n' >"$1/crates/core/lib.rs"
  printf -- '- A fix consumers see.\n' >"$1/changelog.d/fixed/ken-1.md"
  git -C "$1" add -A
  commit_in "$1" 'fix(KEN-1): change a crate'
}
more_code() { # DIR — another crate change, staged
  printf 'fn two() {}\n' >>"$1/crates/core/lib.rs"
  git -C "$1" add -A
}
commit_in() { # DIR MESSAGE [git-commit-arg...] — a real commit; sets OUT and RC
  # The flag goes AHEAD of `-m`, which is where the scan reads it: `-m` is a
  # token the scan does not understand, because the argument behind it is the
  # committer's to choose, and one of those ends the scan at "not an amend".
  OUT=""; RC=0
  OUT="$(git -C "$1" commit "${@:3}" -m "$2" 2>&1)" || RC=$?
}
new_repo() { # NAME — a fresh seeded repo at $TMP/NAME, named by R; one fixture
  R="$TMP/$1"          # per pin, so a pin skipped for want of /proc leaves
  mk_repo "$R"         # nothing for the next to inherit
  seed_commit "$R"
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
# when that goes, and the one pin here needing no /proc: the NEXT commit, whose
# parent really is that HEAD, is not excused by the fragment in the one before.
new_repo repo-next
crate_commit "$R"
more_code "$R"
commit_in "$R" 'fix(KEN-2): change a crate again'
refused_naming_lib \
  && ok "control: the commit AFTER a fragment commit still owes its own entry" \
  || bad "control: the commit after a fragment commit still owes its own entry" "rc=$RC out=$OUT"

if [ "$HAVE_PROC" -eq 0 ]; then
  skip "the widening pins need /proc/<pid>/cmdline, where the committing argv is read"
else
  new_repo repo-amend
  crate_commit "$R"
  more_code "$R"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  [ "$RC" -eq 0 ] && ok "an amend adding more code passes on the fragment the commit already carries" \
    || bad "an amend passes on the fragment the commit already carries" "rc=$RC out=$OUT"

  # What counts is the tree the commit will have, never that HEAD once held an
  # entry. Gated too: without the widening the base is HEAD, the dropped
  # fragment is the only change the diff shows, and no required path is in it.
  new_repo repo-dropped
  crate_commit "$R"
  git -C "$R" rm -q --cached changelog.d/fixed/ken-1.md
  rm -f "$R/changelog.d/fixed/ken-1.md"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  refused_naming_lib \
    && ok "control: an amend that drops the fragment owes one again" \
    || bad "control: an amend that drops the fragment owes one again" "rc=$RC out=$OUT"

  # Amending a repository's FIRST commit: HEAD^ does not resolve, so the base
  # is the hashed empty tree. Same branch on the tip of a shallow clone.
  R="$TMP/repo-root"
  mk_repo "$R"
  crate_commit "$R"
  more_code "$R"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  [ "$RC" -eq 0 ] && [ -z "$(git -C "$R" rev-parse --verify --quiet HEAD^ 2>/dev/null)" ] \
    && ok "an amend of the ROOT commit passes on the fragment it carries" \
    || bad "an amend of the root commit passes on the fragment it carries" "rc=$RC out=$OUT"
fi

echo '=== which argv is an amend ==='
# One spelling per pin, as the NUL-delimited bytes the kernel would hold. git
# takes any unambiguous ABBREVIATION and resolves a boolean to its LAST
# spelling, so the refusals below are what a scan matching full names by
# equality got wrong in the FAIL-OPEN direction: it read the flag out of a
# value the committer chose, and the previous commit's fragment excused a
# commit carrying none.
ARGV="$TMP/argv"
argv_pin() { # LABEL WANT ARG... — WANT is `amend` or `plain`
  local label="$1" want="$2" got=plain
  shift 2
  printf '%s\0' "$@" >"$ARGV"
  if gg_argv_is_amend "$ARGV"; then got=amend; fi
  [ "$got" = "$want" ] && ok "$label" || bad "$label" "read as $got, wanted $want"
}
argv_pin "the flag itself is the flag" amend git commit --amend
argv_pin "--am is git's abbreviation of it, an amend this lane must widen for" amend git commit --am
argv_pin "a no-value option ahead of the flag is stepped over" amend git commit --no-edit --amend
argv_pin "a rebase reword's own argv widens" amend git commit --amend --no-gpg-sign -e --allow-empty
argv_pin "the wrapper's arguments, ahead of the subcommand, are not the commit's" amend git -c user.name=x commit --amend --no-edit
argv_pin "the flag BEFORE a value-taking option is still the flag" amend git commit --amend -m 'fix(KEN-1): change a crate'
argv_pin "must-fail: the argument -m consumes is a message" plain git commit -m --amend
argv_pin "must-fail: --mess is that same option, abbreviated" plain git commit --mess --amend
argv_pin "must-fail: --templ takes a template path" plain git commit --templ --amend
argv_pin "must-fail: --trail takes a trailer" plain git commit --trail --amend
argv_pin "must-fail: --fil takes a message file" plain git commit --fil --amend
argv_pin "must-fail: an attached --message=… carries its value in the token" plain git commit --message=--amend
argv_pin "must-fail: a short BUNDLE's -m consumes the argument behind it" plain git commit -am --amend
argv_pin "must-fail: an argument after the bare -- is a pathspec" plain git commit -- --amend
argv_pin "must-fail: --no-amend behind the flag is git's last-spelling boolean" plain git commit --amend --no-amend -m 'fix(KEN-2): change a crate'
argv_pin "must-fail: an argv that never reaches the commit subcommand is not one" plain git rebase --amend

echo "=== what the WALK reads, through a FAKE git ancestor ==="
# The fixture stands still: HEAD carries the crate change and its fragment,
# HEAD^ carries neither, and the index holds HEAD's tree plus more code. Judged
# against HEAD^ the fragment is in the diff and the run passes; judged against
# HEAD only the crate change is, and the run is refused. One bit, either way.
if [ "$HAVE_PROC" -eq 0 ]; then
  skip "the ancestor-walk pins need /proc/<pid>/cmdline: with no procfs there is no argv to read"
else
  FK_REPO="$TMP/repo-fake"
  mk_repo "$FK_REPO"
  rm -f "$FK_REPO/.git/hooks/commit-msg"
  seed_commit "$FK_REPO"
  crate_commit "$FK_REPO"
  more_code "$FK_REPO"
  FK_MSG="$TMP/fake-message.txt"
  printf 'fix(KEN-1): change a crate\n' >"$FK_MSG"
  FAKE_BIN="$TMP/fake-bin"
  mkdir -p "$FAKE_BIN"
  cp -- "${BASH:-$(command -v bash)}" "$FAKE_BIN/git"
  # The fake ancestor is bash, and its `-c` script is all it is given, so it
  # reads these out of the environment. `exit $s` LAST is load-bearing: bash
  # execs the final command of a `-c` script, which for a lone `"$CM" …` would
  # replace the fake ancestor with commit-msg and erase the very process the
  # scan is about. A builtin is the one ending it cannot exec away.
  export CM FK_MSG FAKE_BIN
  FAKE_RUN='"$CM" "$FK_MSG"; s=$?; exit $s'
  export FAKE_RUN
  fake_git() { # ARG... — commit-msg under a `git` ancestor whose argv is ARG...
    OUT=""; RC=0
    OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
      "$FAKE_BIN/git" -c "$FAKE_RUN" "$@" 2>&1)" || RC=$?
  }

  # MUST-FAIL: git sets GIT_INDEX_FILE for the hooks it runs a commit through,
  # so its absence means a DIRECT run — a person, a script, one of this
  # family's own suites under a developer's `git commit --amend` — whose
  # ancestors say nothing about what it judges.
  OUT=""; RC=0
  OUT="$(cd "$FK_REPO" && "$FAKE_BIN/git" -c "$FAKE_RUN" commit --amend 2>&1)" || RC=$?
  refused_naming_lib \
    && ok "must-fail: a git ancestor with the flag but no GIT_INDEX_FILE is not this run's commit" \
    || bad "a git ancestor with no GIT_INDEX_FILE must not widen" "rc=$RC out=$OUT"

  fake_git commit --amend
  [ "$RC" -eq 0 ] && ok "the walk finds the flag on the nearest git ancestor and widens" \
    || bad "the walk finds the flag on the nearest git ancestor" "rc=$RC out=$OUT"

  # MUST-FAIL: the walk stops at the NEAREST git ancestor, the command doing
  # the committing. A `git rebase` above it answers for something else, so a
  # climb past the inner git judges a commit against a parent it does not have.
  OUT=""
  RC=0
  NEST_RUN='"$FAKE_BIN/git" -c "$FAKE_RUN" commit; s=$?; exit $s'
  OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
    "$FAKE_BIN/git" -c "$NEST_RUN" commit --amend 2>&1)" || RC=$?
  refused_naming_lib \
    && ok "must-fail: an inner git WITHOUT the flag answers, not an outer git with it" \
    || bad "the walk must stop at the nearest git ancestor" "rc=$RC out=$OUT"

  # The depth walk: a generation carrying no git sits between the committing
  # process and the hook, so a cap of one generation would never reach the git
  # above it.
  OUT=""
  RC=0
  DEPTH_RUN='bash -c "$FAKE_RUN"; s=$?; exit $s'
  OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
    "$FAKE_BIN/git" -c "$DEPTH_RUN" commit --amend 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && ok "the walk climbs past a generation carrying no git" \
    || bad "the walk climbs past a generation carrying no git" "rc=$RC out=$OUT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
