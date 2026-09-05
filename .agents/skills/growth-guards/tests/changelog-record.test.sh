#!/usr/bin/env bash
# Ordinary changelog edits are prose. Only collation reads the record format.
set -euo pipefail

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

stage() { git -C "$R" add -A; }

frag() { # SECTION NAME — content on stdin, written and staged
  mkdir -p "$R/changelog.d/$1"
  cat >"$R/changelog.d/$1/$2"
  stage
}

new_repo record
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Existing note.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm seed
for text in '# Release notes' $'# Changelog\n\n## Upcoming release\n\n- Reworded note.' $'# Changelog\n\n## [Unreleased]\n\n### Details\n\nA new paragraph.'; do
  printf '%s\n' "$text" >"$R/CHANGELOG.md"
  stage
  cp "$R/CHANGELOG.md" "$TMP/before.md"
  run_ce
  [ "$RC" -eq 0 ] && cmp -s "$R/CHANGELOG.md" "$TMP/before.md" \
    && ok "record wording does not block fragment checks" || bad "record wording" "rc=$RC out=$OUT"
done
printf '%s\n' 'not a list item' | frag fixed invalid.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"invalid.md"*"list marker"*) true ;; *) false ;; esac \
  && ok "fragment structure still fails beside a reworded record" || bad "fragment control" "rc=$RC out=$OUT"
printf '%s\n' '- A fixed defect.' | frag fixed invalid.md
run_ce
[ "$RC" -eq 0 ] && ok "the repaired fragment passes" || bad "fragment repair" "rc=$RC out=$OUT"

for text in '# Release notes' $'# Log\n\n## [Unreleased]\n\n## [Unreleased]' $'# Log\n\n## [Unreleased]\n\n```\nunclosed' $'# Log\n\n## [Unreleased]\n\n### Details\n\n- Note.'; do
  printf '%s\n' "$text" >"$R/CHANGELOG.md"
  stage
  cp "$R/CHANGELOG.md" "$TMP/before.md"
  run_ce --collate
  [ "$RC" -gt 0 ] && cmp -s "$R/CHANGELOG.md" "$TMP/before.md" && [ -f "$R/changelog.d/fixed/invalid.md" ] \
    && ok "collation refuses an unusable destination without writes" || bad "collation destination" "rc=$RC out=$OUT"
done
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Reworded note.\n' >"$R/CHANGELOG.md"
stage
run_ce --collate
[ "$RC" -eq 0 ] && [ ! -e "$R/changelog.d/fixed/invalid.md" ] && grep -Fxq -- '- A fixed defect.' "$R/CHANGELOG.md" && grep -Fxq -- '- Reworded note.' "$R/CHANGELOG.md" \
  && ok "collation retains the edited notes and folds the fragment" || bad "collation control" "rc=$RC out=$OUT"

echo "=== collation destination refusals preserve every input ==="
for row in 'untracked|is not tracked' 'symlink|not a regular collation destination' 'gitlink|not a regular collation destination' 'binary|holds binary content' 'utf8|not valid UTF-8'; do
  shape="${row%%|*}"
  expected="${row#*|}"
  new_repo "destination-$shape"
  mkdir -p "$R/changelog.d/fixed"
  printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
  printf '%s\n' '- A pending change.' >"$R/changelog.d/fixed/pending.md"
  stage
  git -C "$R" commit -qm fixture
  case "$shape" in
    untracked) git -C "$R" rm -q --cached -- CHANGELOG.md ;;
    symlink)
      mv "$R/CHANGELOG.md" "$R/record-target.md"
      ln -s record-target.md "$R/CHANGELOG.md"
      stage
      ;;
    gitlink)
      oid="$(git -C "$R" rev-parse HEAD)"
      git -C "$R" update-index --add --cacheinfo "160000,$oid,CHANGELOG.md"
      ;;
    binary) printf '\000' >>"$R/CHANGELOG.md"; stage ;;
    utf8) printf '\377' >>"$R/CHANGELOG.md"; stage ;;
  esac
  cp -L "$R/CHANGELOG.md" "$TMP/record-before"
  cp "$R/changelog.d/fixed/pending.md" "$TMP/fragment-before"
  index_before="$(git -C "$R" ls-files -s)"
  run_ce --collate
  [ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md"*"$expected"*) true ;; *) false ;; esac \
    && ok "$shape refuses collation with its cause" || bad "$shape refusal" "rc=$RC out=$OUT"
  cmp -s "$R/CHANGELOG.md" "$TMP/record-before" && { [ "$shape" != symlink ] || { [ -L "$R/CHANGELOG.md" ] && [ "$(readlink "$R/CHANGELOG.md")" = record-target.md ]; }; } \
    && ok "$shape preserves the record" || bad "$shape record preservation" "$OUT"
  cmp -s "$R/changelog.d/fixed/pending.md" "$TMP/fragment-before" && [ "$(git -C "$R" ls-files -s)" = "$index_before" ] \
    && ok "$shape preserves fragments and index" || bad "$shape fragment preservation" "$OUT"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
