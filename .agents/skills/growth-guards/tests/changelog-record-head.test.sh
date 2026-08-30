#!/usr/bin/env bash
# Pins which COPY of the record scripts/changelog-entries judges. The staged
# copy is what a commit is making, so it is judged strictly; HEAD is history
# the committer cannot change, so a HEAD this guard would not accept is a
# comparison skipped with its reason rather than a refusal — otherwise the
# guard demands a repair and then blocks the commit performing it. One
# acceptance answer covers every dimension HEAD has: the entry's mode, its
# bytes, and its shape. The rules over the staged copy are pinned next door
# in changelog-record.test.sh. Every green assertion is paired with a control
# that proves it can fail.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_CHANGELOG_CAP GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_CHANGELOG_COLLATE \
  GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_ce() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$CE" "$@" 2>&1)" || RC=$?
}

run_ce_env() { # KEY=VALUE... — run in $R under those settings; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "$@" "$CE" 2>&1)" || RC=$?
}

stage() { git -C "$R" add -A; }

frag() { # SECTION NAME — content on stdin, written and staged
  mkdir -p "$R/changelog.d/$1"
  cat >"$R/changelog.d/$1/$2"
  stage
}

# N copies of a character, so a fixture states the length it means instead of
# carrying a literal nobody can count. The loop counts copies rather than
# measuring the string: ${#out} is characters or bytes depending on the
# caller's locale, which would make every multibyte fixture below a different
# size under LC_ALL=C than under a UTF-8 locale.
rep() { # CHAR N
  local c="$1" n="$2" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out="$out$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}


echo "=== a malformed HEAD is a comparison skipped, never a refusal ==="
# HEAD is history. Refusing on its shape would demand a repair and then block
# the commit performing it, and a record malformed in HEAD could never be
# fixed at all. Each state below is committed into HEAD with the guard out of
# the way, then repaired by the very next commit.
new_repo headhistory
printf -- '- A fragment.\n' | frag fixed ken-1.md
FIXED_RECORD='# Changelog\n\n## [Unreleased]\n\n- One line.\n'
# An unterminated fence, which leaves the section unlocatable.
printf '# Changelog\n\n```\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a record with an open fence"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"leaves a code fence unclosed"*"HEAD's copy"*) true ;; *) false ;; esac \
  && ok "the commit closing a fence HEAD left open is allowed, and says why" \
  || bad "the commit closing a fence HEAD left open is allowed, and says why" "rc=$RC out=$OUT"
# A second canonical heading, which leaves the section undecided.
new_repo headdup
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a record with two headings"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"more than one '## [Unreleased]' heading"*"HEAD's copy"*) true ;; *) false ;; esac \
  && ok "the commit removing a duplicate heading HEAD carries is allowed" \
  || bad "the commit removing a duplicate heading HEAD carries is allowed" "rc=$RC out=$OUT"
# A level-3 heading naming no section, which is the state the collator refuses.
new_repo headsection
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n### Notes\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a record with an unsupported section"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"not a Keep a Changelog section"*"HEAD's copy"*) true ;; *) false ;; esac \
  && ok "the commit renaming an unsupported heading HEAD carries is allowed" \
  || bad "the commit renaming an unsupported heading HEAD carries is allowed" "rc=$RC out=$OUT"
# No heading at all, the state that was already tolerated and now goes the
# same way as the others rather than by an exemption of its own.
new_repo headnone
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a record with no section"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"carries no '## [Unreleased]' heading"*"HEAD's copy"*) true ;; *) false ;; esac \
  && ok "the commit opening a section HEAD never had is allowed" \
  || bad "the commit opening a section HEAD never had is allowed" "rc=$RC out=$OUT"
# Bytes that are not changelog text at all, which is the same trap read from
# the other end: HEAD holding a binary record must not block replacing it.
new_repo headbinary
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One \000 line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a binary record"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"is not changelog text in HEAD's copy"*) true ;; *) false ;; esac \
  && ok "the commit replacing a binary record HEAD carries is allowed" \
  || bad "the commit replacing a binary record HEAD carries is allowed" "rc=$RC out=$OUT"
# The entry's MODE is a dimension of the same question. A gitlink and a tree
# have no blob to read at all, and a symlink's blob is a path rather than a
# document, so each was either an exit on a blob read that cannot answer or a
# link target parsed as though it were a record.
new_repo headsymlink
printf -- '- A fragment.\n' | frag fixed ken-1.md
ln -s changelog.d/fixed/ken-1.md "$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a symlink where the record goes"
rm -f "$R/CHANGELOG.md"
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"not a regular file in HEAD's copy"*"120000"*) true ;; *) false ;; esac \
  && ok "the commit replacing a symlink HEAD carries is allowed, naming the mode" \
  || bad "the commit replacing a symlink HEAD carries is allowed, naming the mode" "rc=$RC out=$OUT"
new_repo headtree
printf -- '- A fragment.\n' | frag fixed ken-1.md
mkdir -p "$R/CHANGELOG.md"
printf 'inner\n' >"$R/CHANGELOG.md/inner.md"
stage
git -C "$R" commit -qm "chore: a directory where the record goes"
rm -rf "${R:?}/CHANGELOG.md"
git -C "$R" rm -rq --cached CHANGELOG.md
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"not a regular file in HEAD's copy"*"040000"*) true ;; *) false ;; esac \
  && ok "the commit replacing a tree HEAD carries is allowed" \
  || bad "the commit replacing a tree HEAD carries is allowed" "rc=$RC out=$OUT"
new_repo headgitlink
printf -- '- A fragment.\n' | frag fixed ken-1.md
stage
git -C "$R" commit -qm base
git -C "$R" update-index --add --cacheinfo "160000,$(git -C "$R" rev-parse HEAD),CHANGELOG.md"
git -C "$R" commit -qm "chore: a gitlink where the record goes"
git -C "$R" rm -q --cached CHANGELOG.md
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"not a regular file in HEAD's copy"*"160000"*) true ;; *) false ;; esac \
  && ok "the commit replacing a gitlink HEAD carries is allowed" \
  || bad "the commit replacing a gitlink HEAD carries is allowed" "rc=$RC out=$OUT"
# And an executable record is a regular file, so the mode rule admits what it
# should rather than only what this repository happens to write.
new_repo headexec
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
chmod +x "$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"unchanged under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: an executable record in HEAD is compared, not skipped" \
  || bad "control: an executable record in HEAD is compared, not skipped" "rc=$RC out=$OUT"

# The controls that matter: the STAGED copy is judged as strictly as ever, in
# each of those states, so the tolerance above is HEAD's alone.
new_repo headcontrols
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf "$FIXED_RECORD" >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
printf '# Changelog\n\n```\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"leaves a code fence unclosed"*) true ;; *) false ;; esac \
  && ok "control: an open fence in the STAGED copy is still exit 2" \
  || bad "control: an open fence in the STAGED copy is still exit 2" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"more than one '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "control: a duplicate heading in the STAGED copy is still exit 2" \
  || bad "control: a duplicate heading in the STAGED copy is still exit 2" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n### Notes\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"not a Keep a Changelog section"*) true ;; *) false ;; esac \
  && ok "control: an unsupported section in the STAGED copy is still refused" \
  || bad "control: an unsupported section in the STAGED copy is still refused" "rc=$RC out=$OUT"
printf '# Changelog\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "control: no heading in the STAGED copy is still refused" \
  || bad "control: no heading in the STAGED copy is still refused" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n- One \000 line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"binary content in its staged copy"*) true ;; *) false ;; esac \
  && ok "control: a binary STAGED copy is still exit 2" \
  || bad "control: a binary STAGED copy is still exit 2" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
