#!/usr/bin/env bash
# Pins for the one commit-msg rule that cannot be judged from an index alone:
# the changelog a commit owes is read against the parent the commit will HAVE,
# so an amend is judged against HEAD's parent and not against the HEAD it
# replaces. These run through a real `git commit`, because which parent the
# commit will have is read off that process and nowhere else — every other
# commit-msg pin invokes the script directly and lives in commit-msg.test.sh.
# Every firing pin is paired with the control that proves the widening is
# bound to the amend: the next commit, an amend carrying no fragment, and an
# amend that drops the one it had are all still refused.
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

echo "=== an amend is judged against the parent it will HAVE, not the HEAD it replaces ==="
# `git diff --cached` on an amend shows only what was staged ON TOP of the
# commit being replaced, so a fragment already inside that commit read as no
# fragment at all and a commit satisfying the rule was refused — with the
# obvious escape being the flag that skips the whole hook chain. These run
# through a real `git commit`, because which parent the commit will have is
# read off that process and nowhere else.
AM_REPO="$TMP/repo-amend"
mkdir -p "$AM_REPO/crates/core" "$AM_REPO/changelog.d/fixed"
git -C "$AM_REPO" -c init.defaultBranch=main init -q
git -C "$AM_REPO" config user.email test@example.com
git -C "$AM_REPO" config user.name test
printf '#!/bin/sh\nexec %s "$1"\n' "$CM" >"$AM_REPO/.git/hooks/commit-msg"
chmod +x "$AM_REPO/.git/hooks/commit-msg"
printf '[env]\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$AM_REPO/kendex.settings.toml"
printf 'seed\n' >"$AM_REPO/README.md"
git -C "$AM_REPO" add -A
git -C "$AM_REPO" commit -qm "chore: base [no-changelog]" >/dev/null 2>&1

am_commit() { # MESSAGE [git-commit-arg...] — a real commit; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(git -C "$AM_REPO" commit -m "$1" "${@:2}" 2>&1)" || RC=$?
}

printf 'fn one() {}\n' >"$AM_REPO/crates/core/lib.rs"
printf -- '- A fix consumers see.\n' >"$AM_REPO/changelog.d/fixed/ken-1.md"
git -C "$AM_REPO" add -A
am_commit 'fix(KEN-1): change a crate'
[ "$RC" -eq 0 ] && ok "fixture: the crate change lands with its fragment" \
  || bad "fixture: the crate change lands with its fragment" "rc=$RC out=$OUT"

printf 'fn two() {}\n' >>"$AM_REPO/crates/core/lib.rs"
git -C "$AM_REPO" add -A
am_commit 'fix(KEN-1): change a crate' --amend
[ "$RC" -eq 0 ] && ok "an amend adding more code passes on the fragment the commit already carries" \
  || bad "an amend passes on the fragment the commit already carries" "rc=$RC out=$OUT"

# The control that reds when the amend case goes: the widening is bound to the
# amend, so the NEXT commit — a new one, whose parent really is that HEAD —
# is not excused by the fragment sitting in the commit before it.
printf 'fn three() {}\n' >>"$AM_REPO/crates/core/lib.rs"
git -C "$AM_REPO" add -A
am_commit 'fix(KEN-2): change a crate again'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: the commit AFTER a fragment commit still owes its own entry" \
  || bad "control: the commit after a fragment commit still owes its own entry" "rc=$RC out=$OUT"
git -C "$AM_REPO" reset -q --hard HEAD

# And an amend of a commit that carries no fragment is refused, naming the
# path: reading the whole commit is what widened, not the rule.
git -C "$AM_REPO" commit -q --allow-empty -m 'chore: nothing a consumer sees' >/dev/null 2>&1
printf 'fn four() {}\n' >>"$AM_REPO/crates/core/lib.rs"
git -C "$AM_REPO" add -A
am_commit 'fix(KEN-3): change a crate' --amend
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: an amend of a fragmentless commit is refused, naming the path" \
  || bad "control: an amend of a fragmentless commit is refused" "rc=$RC out=$OUT"
git -C "$AM_REPO" reset -q --hard HEAD
git -C "$AM_REPO" reset -q --hard HEAD~1

# An amend that DROPS the fragment owes one again: what counts is the tree the
# commit will have, never that HEAD once held an entry.
git -C "$AM_REPO" rm -q --cached changelog.d/fixed/ken-1.md
rm -f "$AM_REPO/changelog.d/fixed/ken-1.md"
am_commit 'fix(KEN-1): change a crate' --amend
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: an amend that drops the fragment owes one again" \
  || bad "control: an amend that drops the fragment owes one again" "rc=$RC out=$OUT"
git -C "$AM_REPO" reset -q --hard HEAD

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
