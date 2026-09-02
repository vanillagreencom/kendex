#!/usr/bin/env bash
# Pins for the one commit-msg rule that cannot be judged from an index alone:
# the changelog a commit owes is read against the parent the commit will HAVE,
# so an amend is judged against HEAD's parent and not against the HEAD it
# replaces. The rule pins run through a real `git commit`, because which parent
# the commit will have is read off that process and nowhere else — every other
# commit-msg RULE pin invokes the script directly and lives in commit-msg.test.sh
# (install-git-hooks.test.sh drives a real commit too, but only to prove the
# installed shim reaches the committer).
#
# Every firing pin is paired with the control that proves the widening is bound
# to the amend: the next commit, an amend carrying no fragment, an amend that
# drops the one it had, and a commit whose own bytes merely SPELL the flag are
# all still refused.
#
# The last section drives a FAKE `git` ancestor — a copy of bash under that
# name — because the arms a real `git commit` cannot reach are the ones that
# decide the answer: the GIT_INDEX_FILE guard (a real commit always sets it),
# the walk stopping at the NEAREST git ancestor, the depth walk past a
# generation carrying no git, and the argv scan reading a committer-chosen
# value that spells `--amend`.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
. "$TEST_DIR/lib/harness.bash"

unset GROWTH_GUARDS_COMMIT_TYPES GROWTH_GUARDS_SUBJECT_MAX \
  GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
skip() { printf '  skip  %s\n' "$1"; }

# The widening is read off /proc/<pid>/cmdline and nowhere else, so a host
# without procfs — macOS, which this family supports — answers "not an amend"
# and keeps the judgement the lane made before. A pin asserting the widening
# can only be measured where that file is readable; it is skipped elsewhere,
# named, rather than reporting a portability fact as a defect. The refusal
# controls are NOT gated: what they assert holds on every platform.
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
  OUT=""
  RC=0
  OUT="$(git -C "$1" commit -m "$2" "${@:3}" 2>&1)" || RC=$?
}

# Each pin gets its own fixture: an amend either lands or is refused, and a pin
# that is skipped for want of /proc must leave nothing for the next one to
# inherit.
new_repo() { # NAME — a fresh seeded repo at $TMP/NAME, named by R
  R="$TMP/$1"
  mk_repo "$R"
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
# fragment at all and a commit satisfying the rule was refused — with the
# obvious escape being the flag that skips the whole hook chain.
new_repo repo-fixture
crate_commit "$R"
[ "$RC" -eq 0 ] && ok "fixture: the crate change lands with its fragment" \
  || bad "fixture: the crate change lands with its fragment" "rc=$RC out=$OUT"

new_repo repo-amend
crate_commit "$R"
more_code "$R"
if [ "$HAVE_PROC" -eq 1 ]; then
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  [ "$RC" -eq 0 ] && ok "an amend adding more code passes on the fragment the commit already carries" \
    || bad "an amend passes on the fragment the commit already carries" "rc=$RC out=$OUT"
else
  skip "the amend pin needs /proc/<pid>/cmdline, where the committing argv is read"
fi

# The control that reds when the amend case goes: the widening is bound to the
# amend, so the NEXT commit — a new one, whose parent really is that HEAD — is
# not excused by the fragment sitting in the commit before it.
new_repo repo-next
crate_commit "$R"
more_code "$R"
commit_in "$R" 'fix(KEN-2): change a crate again'
refused_naming_lib \
  && ok "control: the commit AFTER a fragment commit still owes its own entry" \
  || bad "control: the commit after a fragment commit still owes its own entry" "rc=$RC out=$OUT"

# And an amend of a commit that carries no fragment is refused, naming the
# path: reading the whole commit is what widened, not the rule.
new_repo repo-fragmentless
git -C "$R" commit -q --allow-empty -m 'chore: nothing a consumer sees' >/dev/null 2>&1
more_code "$R"
commit_in "$R" 'fix(KEN-3): change a crate' --amend
refused_naming_lib \
  && ok "control: an amend of a fragmentless commit is refused, naming the path" \
  || bad "control: an amend of a fragmentless commit is refused" "rc=$RC out=$OUT"

# An amend that DROPS the fragment owes one again: what counts is the tree the
# commit will have, never that HEAD once held an entry. Gated, because without
# the widening the base is HEAD and the dropped fragment is the only change the
# diff shows — no required path in it, and nothing to refuse.
new_repo repo-dropped
crate_commit "$R"
if [ "$HAVE_PROC" -eq 1 ]; then
  git -C "$R" rm -q --cached changelog.d/fixed/ken-1.md
  rm -f "$R/changelog.d/fixed/ken-1.md"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  refused_naming_lib \
    && ok "control: an amend that drops the fragment owes one again" \
    || bad "control: an amend that drops the fragment owes one again" "rc=$RC out=$OUT"
else
  skip "the dropped-fragment pin needs /proc/<pid>/cmdline: without it the base is HEAD and no required path moved"
fi

echo "=== a commit whose own bytes SPELL the flag is not an amend ==="
# The committer chooses some of the bytes in that argv. A message or a pathspec
# equal to `--amend` reached the scan as the flag before it read argv the way
# git's parser does, and the previous commit's fragment then excused a commit
# that carries none. These are refusals, so they hold on every platform.
new_repo repo-spelled
: >"$R/--amend"
git -C "$R" add -A
git -C "$R" commit -qm 'chore: a tracked file named for the flag [no-changelog]' >/dev/null 2>&1
crate_commit "$R"
more_code "$R"
commit_in "$R" 'fix(KEN-2): change a crate again' -m '--amend'
refused_naming_lib \
  && ok "control: the flag text as a -m body paragraph is a message, not the flag" \
  || bad "control: the flag text as a -m body paragraph is a message" "rc=$RC out=$OUT"

new_repo repo-pathspec
: >"$R/--amend"
git -C "$R" add -A
git -C "$R" commit -qm 'chore: a tracked file named for the flag [no-changelog]' >/dev/null 2>&1
crate_commit "$R"
printf 'fn two() {}\n' >>"$R/crates/core/lib.rs"
commit_in "$R" 'fix(KEN-2): change a crate again' -- crates/core/lib.rs --amend
refused_naming_lib \
  && ok "control: a --amend PATHSPEC after the bare -- is a path, not the flag" \
  || bad "control: a --amend pathspec after the bare -- is a path" "rc=$RC out=$OUT"

echo "=== amending a repository's first commit: the parent is the empty tree ==="
# HEAD^ does not resolve there, so the base is the hashed empty tree. Same
# branch on the tip of a `git clone --depth 1` shallow clone, where git writes
# a parentless commit.
R="$TMP/repo-root"
mk_repo "$R"
crate_commit "$R"
if [ "$HAVE_PROC" -eq 1 ]; then
  more_code "$R"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  [ "$RC" -eq 0 ] && [ -z "$(git -C "$R" rev-parse --verify --quiet HEAD^ 2>/dev/null)" ] \
    && ok "an amend of the ROOT commit passes on the fragment it carries" \
    || bad "an amend of the root commit passes on the fragment it carries" "rc=$RC out=$OUT"

  git -C "$R" rm -q --cached changelog.d/fixed/ken-1.md
  rm -f "$R/changelog.d/fixed/ken-1.md"
  commit_in "$R" 'fix(KEN-1): change a crate' --amend
  refused_naming_lib \
    && ok "control: the same root amend is refused once the fragment is dropped" \
    || bad "control: the root amend is refused once the fragment is dropped" "rc=$RC out=$OUT"
else
  skip "the root-commit amend pins need /proc/<pid>/cmdline, where the committing argv is read"
fi

echo "=== what the walk reads, through a FAKE git ancestor ==="
# A real `git commit` cannot put these shapes on the tree: it always sets
# GIT_INDEX_FILE, it is always the nearest git ancestor, and it rejects an
# argv git itself would not parse. A copy of bash named `git` can, and the
# hook is invoked directly beneath it.
#
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
  # The fake ancestor reads these out of the environment: it is bash, and its
  # `-c` script is the only thing it is given.
  export CM FK_MSG FAKE_BIN
  # `sleep 0; exit $s` is load-bearing. bash EXECS a lone `-c` command, which
  # would replace the fake ancestor with commit-msg itself and erase the very
  # process the scan is about.
  FAKE_RUN='"$CM" "$FK_MSG"; s=$?; sleep 0; exit $s'
  export FAKE_RUN

  fake_git() { # ARG... — commit-msg under a `git` ancestor whose argv is ARG...
    OUT=""
    RC=0
    OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
      "$FAKE_BIN/git" -c "$FAKE_RUN" "$@" 2>&1)" || RC=$?
  }

  # MUST-FAIL: git sets GIT_INDEX_FILE for the hooks it runs a commit through,
  # so its absence means a DIRECT run — a person, a script, one of this
  # family's own suites under a developer's `git commit --amend` — whose
  # ancestors say nothing about what it judges. Drop the guard and this run is
  # excused by a fragment the commit does not carry.
  OUT=""
  RC=0
  OUT="$(cd "$FK_REPO" && "$FAKE_BIN/git" -c "$FAKE_RUN" --amend 2>&1)" || RC=$?
  refused_naming_lib \
    && ok "must-fail: a git ancestor with the flag but no GIT_INDEX_FILE is not this run's commit" \
    || bad "a git ancestor with no GIT_INDEX_FILE must not widen" "rc=$RC out=$OUT"

  fake_git --amend
  [ "$RC" -eq 0 ] && ok "the walk finds the flag on the nearest git ancestor and widens" \
    || bad "the walk finds the flag on the nearest git ancestor" "rc=$RC out=$OUT"

  # MUST-FAIL: the walk stops at the NEAREST git ancestor, which is the command
  # doing the committing. A `git rebase` above it would be answering for
  # something else, so a climb past the inner git is a commit judged against a
  # parent it does not have.
  OUT=""
  RC=0
  NEST_RUN='"$FAKE_BIN/git" -c "$FAKE_RUN" commit; s=$?; sleep 0; exit $s'
  OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
    "$FAKE_BIN/git" -c "$NEST_RUN" --amend 2>&1)" || RC=$?
  refused_naming_lib \
    && ok "must-fail: an inner git WITHOUT the flag answers, not an outer git with it" \
    || bad "the walk must stop at the nearest git ancestor" "rc=$RC out=$OUT"

  # The depth walk: a generation carrying no git sits between the committing
  # process and the hook, so a cap of one generation reads only that generation
  # and never reaches the git above it.
  OUT=""
  RC=0
  DEPTH_RUN='bash -c "$FAKE_RUN"; s=$?; sleep 0; exit $s'
  OUT="$(cd "$FK_REPO" && GIT_INDEX_FILE="$FK_REPO/.git/index" \
    "$FAKE_BIN/git" -c "$DEPTH_RUN" --amend 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && ok "the walk climbs past a generation carrying no git" \
    || bad "the walk climbs past a generation carrying no git" "rc=$RC out=$OUT"

  # MUST-FAIL, the argv scan itself: a value the committer chose is not the
  # flag. git's own parser stops at the bare `--` and hands a value-taking
  # option the argument behind it, and the scan reads argv the same way.
  fake_git -m --amend
  refused_naming_lib \
    && ok "must-fail: the argument -m consumes is a message, not the flag" \
    || bad "the argument -m consumes must not read as the flag" "rc=$RC out=$OUT"

  fake_git --message --amend
  refused_naming_lib \
    && ok "must-fail: the argument a LONG value-taking option consumes is a message too" \
    || bad "the argument a long value-taking option consumes must not read as the flag" "rc=$RC out=$OUT"

  fake_git -am --amend
  refused_naming_lib \
    && ok "must-fail: the argument a SHORT BUNDLE's -m consumes is a message too" \
    || bad "the argument a short bundle's -m consumes must not read as the flag" "rc=$RC out=$OUT"

  fake_git commit -- --amend
  refused_naming_lib \
    && ok "must-fail: an argument after the bare -- is a pathspec, not the flag" \
    || bad "an argument after the bare -- must not read as the flag" "rc=$RC out=$OUT"

  # The control that keeps those three honest: the flag itself, in the same
  # argv shapes, still widens.
  fake_git --amend -m 'fix(KEN-1): change a crate'
  [ "$RC" -eq 0 ] && ok "control: the flag BEFORE a value-taking option is still the flag" \
    || bad "control: the flag before a value-taking option is still the flag" "rc=$RC out=$OUT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
