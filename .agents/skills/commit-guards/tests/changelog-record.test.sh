#!/usr/bin/env bash
# Pins for the record's place in the changelog family: ordinary changelog
# edits are prose, and only collation reads the record format. Three tables:
# a record wording beside a valid fragment, pinned by the plain check's exit
# status and lines with the record byte-identical afterwards; a record shape
# under --collate, pinned by the exit status and lines with the record and
# the fragment untouched (the one usable shape folds, and is the control);
# and a destination shape (untracked, symlink, gitlink, binary, not UTF-8)
# under --collate, pinned by the refusal's cause with the record, the
# fragment and the index untouched. The fold's own grammar is
# changelog-collate.test.sh's; this file pins the refusals around it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_CHANGELOG_CAP COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_CHANGELOG_COLLATE \
  COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true
export COMMIT_GUARDS_CHANGELOG_COLLATE=1

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

# Fixture vocabulary: a fresh repository holding CHANGELOG.md with CONTENT
# (printf %b) and one fragment, committed; a name used twice is refused.
R=""
FRAGMENT="changelog.d/fixed/pending.md"
repo() { # NAME CONTENT [FRAGMENT-CONTENT]
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R/changelog.d/fixed"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '%b' "$2" >"$R/CHANGELOG.md"
  printf '%b' "${3:-- A pending change.\n}" >"$R/$FRAGMENT"
  git -C "$R" add -A
  git -C "$R" commit -qm fixture
}
# Tokens for what a run left behind: the record and the fragment compared
# byte for byte with what the fixture wrote, the index with what it held.
snapshot() { cp -L "$R/CHANGELOG.md" "$TMP/record-before"; cp "$R/$FRAGMENT" "$TMP/fragment-before"; git -C "$R" ls-files -s >"$TMP/index-before"; }
left() { # — record=<same|changed> fragment=<same|gone|changed> index=<same|changed>
  local record=changed fragment=changed index=changed
  if cmp -s "$R/CHANGELOG.md" "$TMP/record-before"; then record=same; fi
  if [ ! -e "$R/$FRAGMENT" ]; then fragment=gone; elif cmp -s "$R/$FRAGMENT" "$TMP/fragment-before"; then fragment=same; fi
  if git -C "$R" ls-files -s | cmp -s - "$TMP/index-before"; then index=same; fi
  printf 'record=%s fragment=%s index=%s' "$record" "$fragment" "$index"
}
# One line for a run: the exit status, every line printed joined by ';',
# then what it left behind.
run() { # ARGS...
  local rc=0 out=""
  snapshot
  out="$(cd "$R" && "$CE" "$@" 2>&1)" || rc=$?
  printf 'rc=%s%s %s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}" "$(left)"
}
ROW=0
rows() { # MODE — label | content | expect; MODE is the plain check or --collate
  local mode="$1" row label content expect
  shift
  for row in "$@"; do
    IFS='|' read -r label content expect <<<"$row"
    ROW=$((ROW + 1))
    R=""
    repo "row-$ROW" "$content"
    # shellcheck disable=SC2086
    assert_eq "$label" "$expect" "$(run $mode)"
  done
}
ERR="::error::changelog-entries: "
VIOLATION="changelog-entries: 1 violation(s) — cap 200 characters, 1 fragment(s) measured"
UNTOUCHED="record=same fragment=same index=same"

echo "=== the plain check reads fragments, never the record: any wording passes beside a valid fragment ==="
rows '' \
  "a record with no Unreleased heading|# Release notes\n|rc=0 changelog-entries: OK — 1 fragment(s) within the cap (200 characters) $UNTOUCHED" \
  "a record with a paragraph under a foreign section|# Changelog\n\n## [Unreleased]\n\n### Details\n\nA new paragraph.\n|rc=0 changelog-entries: OK — 1 fragment(s) within the cap (200 characters) $UNTOUCHED"

echo "=== control: a fragment's own structure still fails beside a reworded record ==="
ROW=$((ROW + 1))
repo "row-$ROW" '# Release notes\n' 'not a list item\n'
assert_eq "a fragment that is not a list item fails naming it, the record untouched" \
  "rc=1 changelog-entries FAIL $FRAGMENT does not open with a list marker — a fragment is the Markdown list item it becomes, opening with a hyphen and a space;changelog-entries: 1 violation(s) — cap 200 characters, 0 fragment(s) measured $UNTOUCHED" "$(run)"

echo "=== collation reads the record: an unusable shape is refused without a write, a usable one folds ==="
rows --collate \
  "no Unreleased heading is a violation naming the remedy|# Release notes\n|rc=1 changelog-entries FAIL CHANGELOG.md carries no '## [Unreleased]' heading;  open one — a release folds the fragments into it and has nowhere to put them otherwise;$VIOLATION $UNTOUCHED" \
  "two Unreleased headings cannot be decided between|# Log\n\n## [Unreleased]\n\n## [Unreleased]\n|rc=2 ${ERR}CHANGELOG.md carries more than one '## [Unreleased]' heading — which one is the section cannot be decided $UNTOUCHED" \
  "an unclosed code fence hides the section|# Log\n\n## [Unreleased]\n\n\`\`\`\nunclosed\n|rc=2 ${ERR}CHANGELOG.md leaves a code fence unclosed — the [Unreleased] section cannot be located $UNTOUCHED" \
  "a section name outside Keep a Changelog is a violation naming the set|# Log\n\n## [Unreleased]\n\n### Details\n\n- Note.\n|rc=1 changelog-entries FAIL CHANGELOG.md names 'Details' under [Unreleased], which is not a Keep a Changelog section;  section one of: added changed deprecated removed fixed security;$VIOLATION $UNTOUCHED" \
  "control: a usable record folds the fragment and keeps its edited note|# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Reworded note.\n|rc=0 changelog-entries: folded 1 entry into CHANGELOG.md's [Unreleased] section record=changed fragment=gone index=same"
assert_eq "control: the fold appends the fragment under the edited note" \
  "$(printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Reworded note.\n- A pending change.\n')" "$(cat "$R/CHANGELOG.md")"

echo "=== collation destination shapes are refused with their cause, every input preserved ==="
# Each shape is applied to a usable record after the fixture commit and
# committed again, so the refusal is the destination's, not the grammar's.
shape() { # NAME SHAPE
  repo "$1" '# Changelog\n\n## [Unreleased]\n'
  case "$2" in
    untracked) git -C "$R" rm -q --cached -- CHANGELOG.md ;;
    symlink) mv "$R/CHANGELOG.md" "$R/record-target.md"; ln -s record-target.md "$R/CHANGELOG.md"; git -C "$R" add -A ;;
    gitlink) git -C "$R" update-index --add --cacheinfo "160000,$(git -C "$R" rev-parse HEAD),CHANGELOG.md" ;;
    binary) printf '\000' >>"$R/CHANGELOG.md"; git -C "$R" add -A ;;
    utf8) printf '\377' >>"$R/CHANGELOG.md"; git -C "$R" add -A ;;
  esac
  git -C "$R" commit -qm "prepare destination"
}
link() { if [ -L "$R/CHANGELOG.md" ] && [ "$(readlink "$R/CHANGELOG.md")" = record-target.md ]; then echo " link=same"; fi; }
shape_rows() { # label | shape | expect
  local row label sh expect
  for row in "$@"; do
    IFS='|' read -r label sh expect <<<"$row"
    R=""
    shape "destination-$sh" "$sh"
    assert_eq "$label" "$expect" "$(run --collate)$(link)"
  done
}
shape_rows \
  "an untracked record is refused: commit it first|untracked|rc=2 ${ERR}CHANGELOG.md is not tracked; commit the collation destination first $UNTOUCHED" \
  "a symlinked record is not a regular destination, and the link is kept|symlink|rc=2 ${ERR}CHANGELOG.md is not a regular collation destination $UNTOUCHED link=same" \
  "a gitlink at the record's path is not a regular destination|gitlink|rc=2 ${ERR}CHANGELOG.md is not a regular collation destination $UNTOUCHED" \
  "a record holding binary content is refused|binary|rc=2 ${ERR}CHANGELOG.md holds binary content; collation needs text $UNTOUCHED" \
  "a record that is not valid UTF-8 is refused naming its line|utf8|rc=2 ${ERR}CHANGELOG.md line 4 is not valid UTF-8 — text with no character count cannot be measured $UNTOUCHED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
