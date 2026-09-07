#!/usr/bin/env bash
# Pins for the WRITE path of scripts/changelog-entries --collate
# (lib/changelog-collate.sh over lib/changelog-record-scope.sh and
# lib/atomic-install.sh): it folds the fragments this run accepted into the
# record's [Unreleased] section under the heading each fragment's section
# names, in Keep a Changelog order and filename order within a section,
# splits the record at the line numbers the committed copy was accepted
# with, collapses two headings for one section into one, deletes the
# fragments and the section directory each leaves empty, and refuses
# without writing when the judgement refuses, the record's shape cannot be
# folded into, the index or working tree has pending changes, or the
# release flag is absent. One table: a row builds its own repository, runs
# the fold and reads back the exit status with every line printed, then
# the record (the seed it was, or the exact folded text) and what is left
# under the fragment tree beside any staging file. The judgement's own
# lines are changelog-entries.test.sh's; here they ride along where the
# fold carries them as its own refusal.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CE="$(cd "$TEST_DIR/.." && pwd)/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_CHANGELOG_CAP COMMIT_GUARDS_CHANGELOG_PATHS COMMIT_GUARDS_CHANGELOG_RECORD \
  COMMIT_GUARDS_CHANGELOG_COLLATE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

# One line for a fold in the row's repository: the exit status, then every
# line printed, in order, joined by ';'. The release flag is set unless the
# row's ENVS (a comma-separated list of assignments; -u,NAME unsets, and
# comes first) names it; SHIM names a directory of stand-in tools put ahead
# of PATH.
R=""
run() { # ENVS SHIM
  local envs=() rc=0 out="" path="$PATH"
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  case ",$1," in
    *,COMMIT_GUARDS_CHANGELOG_COLLATE,* | *,COMMIT_GUARDS_CHANGELOG_COLLATE=*) ;;
    *) envs+=(COMMIT_GUARDS_CHANGELOG_COLLATE=1) ;;
  esac
  [ -z "$2" ] || path="$TMP/shim-$2:$PATH"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} PATH="$path" "$CE" --collate 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}
# The record after the run: the name of the text it equals byte for byte
# (SEED is the file the fixture committed, kept beside the repository since
# a shell variable cannot hold every byte a record can), or a diff against
# the one the row named. cmp, not a substitution: that would drop a trailing
# blank line.
record() { # NAME
  local want="$R.seed"
  [ "$1" = SEED ] || want="$TMP/want-$1"
  [ "$1" = SEED ] || printf '%s' "${!1}" >"$want"
  if cmp -s "$want" "$R/CHANGELOG.md"; then printf '%s' "$1"; else diff "$want" "$R/CHANGELOG.md" || true; fi
}
# What is left under the fragment tree, sorted and joined by '~', with any
# staging file beside the record; '-' when nothing. Line-oriented, so a path
# carrying a newline is shown as two: the one row with such a path leaves
# nothing behind.
left() {
  local out
  out="$(cd "$R" && { find changelog.d -mindepth 1 2>/dev/null; ls -d CHANGELOG.md.* 2>/dev/null; } | LC_ALL=C sort | LC_ALL=C paste -sd '~' -)"
  printf '%s' "${out:--}"
}

# Fixture vocabulary. Every fixture builds its own repository, the record
# and one release input committed; a name used twice is refused.
RECORD='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
repo() { # NAME [RECORD]
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '%s' "${2:-$RECORD}" >"$R/CHANGELOG.md"
  printf 'Release input.\n' >"$R/release-input.txt"
  reseed
  git -C "$R" add -A
  git -C "$R" commit -qm 'chore: seed'
}
reseed() { cp -- "$R/CHANGELOG.md" "$R.seed"; } # the record as it stands is the row's SEED
frag() { mkdir -p "$R/changelog.d/$1"; printf '%b' "$3" >"$R/changelog.d/$1/$2"; git -C "$R" add -A -- changelog.d; git -C "$R" commit -qm 'chore: prepare release input'; } # SECTION NAME CONTENT (printf %b)
pending() { repo "$1"; frag fixed pending.md '- Folded in.\n'; } # NAME — one fragment, ready to fold
shim() { mkdir -p "$TMP/shim-$1"; printf '%b' "$2" >"$TMP/shim-$1/$1"; chmod +x "$TMP/shim-$1/$1"; } # NAME BODY
shim mv '#!/bin/sh\necho "mv: refused by the test stub" >&2\nexit 1\n'
# Refuses the fragment only: the run's own scratch is removed with rm too.
shim rm "#!/bin/sh\\ncase \"\$*\" in *changelog.d/*) echo \"rm: refused by the test stub\" >&2; exit 1 ;; esac\\nexec $(command -v rm) \"\$@\"\\n"
shim git "#!/usr/bin/env bash\\nif [ \"\$1\" = status ]; then exit 1; fi\\nexec $(printf '%q' "$(command -v git)") \"\$@\"\\n"

# The lines the fold prints, as functions of what a row put in.
ERR="::error::changelog-entries: "
DIRTY="${ERR}--collate requires a clean index and working tree; commit, restore or remove these first:"
FLAG="${ERR}--collate requires COMMIT_GUARDS_CHANGELOG_COLLATE=1 for the release write"
folded() { printf "changelog-entries: folded %s %s into CHANGELOG.md's [Unreleased] section" "$1" "$2"; } # COUNT NOUN
refused() { printf 'changelog-entries FAIL CHANGELOG.md %s;  %s;changelog-entries: 1 violation(s) — cap 200 characters, 1 fragment(s) measured' "$1" "$2"; } # COMPLAINT REMEDY
SECTIONS="added changed deprecated removed fixed security"
FOLDED='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.

### Fixed

- Folded in.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
ONE="changelog.d/fixed~changelog.d/fixed/pending.md"

# The table: label | fixture | env | shim | expect | record | left.
run_rows() {
  local row label fx env sh expect rec want_left
  for row in "$@"; do
    IFS='|' read -r label fx env sh expect rec want_left <<<"$row"
    [ -n "$want_left" ] || { echo "harness: row has fewer than seven fields: $row" >&2; exit 2; }
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$sh")"
    assert_eq "$label — the record" "$rec" "$(record "$rec")"
    assert_eq "$label — left behind" "$want_left" "$(left)"
  done
}

echo "=== the release write needs its flag and committed inputs, and a refusal writes nothing ==="
fx_no_flag() { pending no-flag; }
fx_flag_off() { pending flag-off; }
edited() { pending "$1"; printf 'Pending version edit.\n' >"$R/release-input.txt"; } # NAME
fx_unstaged() { edited unstaged; }
fx_staged() { edited staged; git -C "$R" add release-input.txt; }
fx_untracked() { pending untracked; printf 'Pending release file.\n' >"$R/pending-release.txt"; }
fx_frag_edited() { pending frag-edited; printf -- '- Edited only on disk.\n' >"$R/changelog.d/fixed/pending.md"; }
fx_record_edited() { pending record-edited; printf -- '\n- An entry only the disk carries.\n' >>"$R/CHANGELOG.md"; }
DISK="$RECORD
- An entry only the disk carries.
"
fx_ignored() { pending ignored; printf 'scratch/\n.keep\n' >"$R/.git/info/exclude"; mkdir -p "$R/scratch"; printf 'Release scratch.\n' >"$R/scratch/note"; : >"$R/changelog.d/fixed/.keep"; }
fx_status_fails() { pending status-fails; }
run_rows \
  "the flag absent refuses, naming it|fx_no_flag|-u,COMMIT_GUARDS_CHANGELOG_COLLATE||rc=2 $FLAG|SEED|$ONE" \
  "the flag set to 0 is the same refusal|fx_flag_off|COMMIT_GUARDS_CHANGELOG_COLLATE=0||rc=2 $FLAG|SEED|$ONE" \
  "an unstaged edit refuses, listing the path as git shows it|fx_unstaged|||rc=2 $DIRTY;  \\ M\\ release-input.txt|SEED|$ONE" \
  "a staged edit refuses|fx_staged|||rc=2 $DIRTY;  M\\ \\ release-input.txt|SEED|$ONE" \
  "an untracked file refuses|fx_untracked|||rc=2 $DIRTY;  \\?\\?\\ pending-release.txt|SEED|$ONE" \
  "a fragment git and the disk disagree about refuses, and the disk copy survives|fx_frag_edited|||rc=2 $DIRTY;  \\ M\\ changelog.d/fixed/pending.md|SEED|$ONE" \
  "a record git and the disk disagree about refuses: the disk edit is neither published nor overwritten|fx_record_edited|||rc=2 $DIRTY;  \\ M\\ CHANGELOG.md|DISK|$ONE" \
  "ignored scratch, inside the fragment tree too, does not block; the section directory it keeps non-empty stays|fx_ignored|||rc=0 $(folded 1 entry)|FOLDED|changelog.d/fixed~changelog.d/fixed/.keep" \
  "a git status that fails cannot authorize the write|fx_status_fails||git|rc=2 ${ERR}could not read repository status; nothing was written|SEED|$ONE"

echo "=== the record's shape is judged before the fold, and a shape the fold cannot use is refused ==="
fx_misspelled() { repo misspelled "$(printf '%s' "$RECORD" | sed 's/^### Added$/### Add/')"; frag fixed pending.md '- Folded in.\n'; }
fx_no_heading() { repo no-heading "$(printf '%s' "$RECORD" | sed 's/^## \[Unreleased\]$/## Unreleased/')"; frag fixed pending.md '- Folded in.\n'; }
fx_two_headings() { repo two-headings "$(printf '%s\n## [Unreleased]\n' "$RECORD")"; frag fixed pending.md '- Folded in.\n'; }
fx_open_fence() { repo open-fence "$(printf '%s\n```\nopen\n' "$RECORD")"; frag fixed pending.md '- Folded in.\n'; }
fx_untracked_record() { repo untracked-record; git -C "$R" rm -q --cached CHANGELOG.md; printf '/CHANGELOG.md\n' >"$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -qm 'chore: untrack'; frag fixed pending.md '- Folded in.\n'; }
fx_scope_off() { pending scope-off; }
fx_symlink_record() { pending symlink-record; mv "$R/CHANGELOG.md" "$R/real.md"; ln -s real.md "$R/CHANGELOG.md"; git -C "$R" add -A; git -C "$R" commit -qm 'chore: link'; }
# A NUL in the record: written with printf's own escape, since no shell
# variable carries the byte.
fx_nul_record() { pending nul-record; printf '%s\0' "$RECORD" >"$R/CHANGELOG.md"; reseed; git -C "$R" add -A; git -C "$R" commit -qm 'chore: nul'; }
fx_bad_beside() { pending bad-beside; frag fixed bad.md 'Prose, not a list item.\n'; }
run_rows \
  "a heading that is not a section refuses, naming it and the sections|fx_misspelled|||rc=1 $(refused "names 'Add' under [Unreleased], which is not a Keep a Changelog section" "section one of: $SECTIONS")|SEED|$ONE" \
  "a record with no [Unreleased] heading refuses with the remedy|fx_no_heading|||rc=1 $(refused "carries no '## [Unreleased]' heading" "open one — a release folds the fragments into it and has nowhere to put them otherwise")|SEED|$ONE" \
  "two [Unreleased] headings are a shape nothing can decide: a collection error|fx_two_headings|||rc=2 ${ERR}CHANGELOG.md carries more than one '## [Unreleased]' heading — which one is the section cannot be decided|SEED|$ONE" \
  "an unclosed fence is the same class|fx_open_fence|||rc=2 ${ERR}CHANGELOG.md leaves a code fence unclosed — the [Unreleased] section cannot be located|SEED|$ONE" \
  "a record git does not track is refused: nothing measured it|fx_untracked_record|||rc=2 ${ERR}CHANGELOG.md is not tracked; commit the collation destination first|SEED|$ONE" \
  "the record scope off leaves the fold nowhere to write|fx_scope_off|COMMIT_GUARDS_CHANGELOG_RECORD=||rc=2 ${ERR}no collation destination: COMMIT_GUARDS_CHANGELOG_RECORD is empty|SEED|$ONE" \
  "a record tracked as a symlink is not a destination|fx_symlink_record|||rc=2 ${ERR}CHANGELOG.md is not a regular collation destination|SEED|$ONE" \
  "a record carrying a NUL is binary, not a destination|fx_nul_record|||rc=2 ${ERR}CHANGELOG.md holds binary content; collation needs text|SEED|$ONE" \
  "a fragment the judge refuses stops the run as its own refusal, and the acceptable one beside it is neither folded nor deleted|fx_bad_beside|||rc=1 changelog-entries FAIL changelog.d/fixed/bad.md does not open with a list marker — a fragment is the Markdown list item it becomes, opening with a hyphen and a space;changelog-entries: 1 violation(s) — cap 200 characters, 1 fragment(s) measured|SEED|changelog.d/fixed~changelog.d/fixed/bad.md~changelog.d/fixed/pending.md"

echo "=== every guarantee of the fold, on one record and one exact expected output ==="
# One fixture, because these rules only meet in a file: all six section
# headings spelled from the section names alone, two fragments in one
# section to make within-section filename order observable, a lead carrying
# a blank RUN so the collapse to one blank is visible, and a second section
# heading further down so the collapse of two headings into one is too.
ALL_IN='# Changelog

Preamble.

## [Unreleased]

A lead paragraph the section carries.


A second lead paragraph, after the blank run above.

### Added

- An entry the record already carries.

### Fixed

- A fixed entry the record already carries.

### Added

- A second Added heading further down.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
ALL_OUT='# Changelog

Preamble.

## [Unreleased]
A lead paragraph the section carries.

A second lead paragraph, after the blank run above.

### Added

- An entry the record already carries.
- A second Added heading further down.
- Added, first by filename.
- Added, second by filename.

### Changed

- Changed something.

### Deprecated

- Deprecated something.

### Removed

- Removed something.

### Fixed

- A fixed entry the record already carries.
- Fixed something.

### Security

- Tightened something.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
fx_all() {
  repo all "$ALL_IN"
  frag added ken-1.md '- Added, first by filename.\n'
  frag added ken-2.md '- Added, second by filename.\n'
  frag changed ken-3.md '- Changed something.\n'
  frag deprecated ken-4.md '- Deprecated something.\n'
  frag removed ken-5.md '- Removed something.\n'
  frag fixed ken-6.md '- Fixed something.\n'
  # No trailing newline: two entries glued into one line is what normalizing
  # it prevents, and only a fixture written this way can catch that.
  frag security ken-7.md '- Tightened something.'
}
# The heading further down than the seed's: the split runs at the line
# numbers this record was accepted with, and no preamble is lost.
MOVED_IN='# Changelog

Preamble the record adds.

More preamble.

## [Unreleased]

### Added

- An entry the record already carries.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
MOVED_OUT='# Changelog

Preamble the record adds.

More preamble.

## [Unreleased]

### Added

- An entry the record already carries.

### Fixed

- Folded in below the moved heading.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
fx_moved() { repo moved "$MOVED_IN"; frag fixed ken-1.md '- Folded in below the moved heading.\n'; }
# The section ends with the file: nothing follows it, and no separator is written.
TAIL_IN='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.
'
TAIL_OUT='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.
- Folded in at the end of the file.
'
fx_tail() { repo tail "$TAIL_IN"; frag added ken-1.md '- Folded in at the end of the file.\n'; }
fx_newline_name() { repo newline-name; frag fixed $'a\nb.md' '- Folded in.\n'; }
fx_readme() { repo readme; mkdir -p "$R/changelog.d"; printf 'The format.\n' >"$R/changelog.d/README.md"; git -C "$R" add -A; git -C "$R" commit -qm 'chore: readme'; frag fixed pending.md '- Folded in.\n'; }
fx_nothing() { repo nothing "$(printf '%s' "$RECORD" | sed 's/^## \[Unreleased\]$/## Unreleased/')"; }
fx_mv_fails() { pending mv-fails; }
fx_rm_fails() { pending rm-fails; frag fixed 'a b.md' '- Folded in, first by filename.\n'; }
FOLDED2="${FOLDED/- Folded in./- Folded in, first by filename.
- Folded in.}"
run_rows \
  "every section in Keep a Changelog order, filename order within one, two headings collapsed, the lead trimmed, a newline-less fragment normalized|fx_all|||rc=0 $(folded 7 entries)|ALL_OUT|-" \
  "a heading further down is split at its own line numbers, losing no preamble|fx_moved|||rc=0 $(folded 1 entry)|MOVED_OUT|-" \
  "a section that ends with the file is folded into with no separator after it|fx_tail|||rc=0 $(folded 1 entry)|TAIL_OUT|-" \
  "a fragment whose name carries a newline is folded in and removed like any other|fx_newline_name|||rc=0 $(folded 1 entry)|FOLDED|-" \
  "the format's README is neither folded nor swept, and its directory stays|fx_readme|||rc=0 $(folded 1 entry)|FOLDED|changelog.d/README.md" \
  "nothing to fold is a stated no-op that reads no destination: a record with no heading passes|fx_nothing|||rc=0 changelog-entries: no fragments — nothing to collate|SEED|-" \
  "a rename that fails is a loud refusal carrying what mv said, the record byte-identical, no staging file, the fragment kept|fx_mv_fails||mv|rc=2 ${ERR}could not replace the collated changelog at CHANGELOG.md (mv: refused by the test stub) — inspect the file before trusting it|SEED|$ONE" \
  "every fragment that survives its delete is named, escaped, after the record was replaced|fx_rm_fails||rm|rc=2 rm: refused by the test stub;rm: refused by the test stub;${ERR}CHANGELOG.md is collated, but these fragments survived and would fold in a second time — delete them by hand:;  changelog.d/fixed/a\\ b.md;  changelog.d/fixed/pending.md|FOLDED2|changelog.d/fixed~changelog.d/fixed/a b.md~changelog.d/fixed/pending.md"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
