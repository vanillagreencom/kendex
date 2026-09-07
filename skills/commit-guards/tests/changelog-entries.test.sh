#!/usr/bin/env bash
# Pins for scripts/changelog-entries, the one judge of a repository's
# changelog fragments: a fragment is a real text file under a section
# directory holding exactly one list item within the character cap, every
# other tracked path in the fragment tree is refused, and the configured
# globs decide what is read, from the index. One table: a row builds its own
# repository, stages what it means, runs the judge once under its settings
# and reads back the exit status with every line printed, so a verdict, the
# file it names, the length it measured, the remedy and the summary are one
# pin. The --collate write path is changelog-collate.test.sh; the index
# readers this family shares are index-reads.test.sh and lane-readers.test.sh.
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

# One line for a run in the row's repository: the exit status, then every
# line printed, in order, joined by ';'. ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$CE" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository and stages
# what it wrote; a name used twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; } # PATH CONTENT (printf %b)
stage() { git -C "$R" add -A; }
frag() { put "changelog.d/$1/$2" "$3"; stage; } # SECTION NAME CONTENT
# N copies of a character, so a fixture states the length it means; the
# loop counts copies rather than measuring the string, whose length in
# ${#var} depends on the caller's locale for a multibyte character.
rep() { # CHAR N
  local c="$1" n="$2" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out="$out$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# The lines the judge prints, as functions of what a row put in.
DEFAULT_GLOB='changelog.d/*/*.md'
SECTIONS="added changed deprecated removed fixed security"
REMEDIES="  remedies: state the outcome and stop; a Breaking migration note stays inline, and the reasoning belongs in the commit"
ERR="::error::changelog-entries: "
NOMATCH="changelog-entries: OK — no tracked file matches COMMIT_GUARDS_CHANGELOG_PATHS ($DEFAULT_GLOB)"
within() { printf 'changelog-entries: OK — %s fragment(s) within the cap (%s characters)' "$1" "${2:-200}"; } # MEASURED [CAP]
summary() { printf 'changelog-entries: %s violation(s) — cap %s characters, %s fragment(s) measured' "$1" "${3:-200}" "$2"; } # VIOLATIONS MEASURED [CAP]
long() { printf 'changelog-entries FAIL long entry: %s — %s characters (cap %s);  entry: %s;%s' "$1" "$2" "${4:-200}" "$3" "$REMEDIES"; } # PATH CHARS FIRST-LINE [CAP]
stray() { printf 'changelog-entries FAIL %s is in the fragment tree but is not a fragment;  a fragment matches one of: %s' "$1" "${2:-$DEFAULT_GLOB}"; } # PATH [GLOBS]
nosection() { printf 'changelog-entries FAIL %s names no section;  a fragment sits where its pattern places it, <section>/<name> at that pattern'"'"'s own depth — section one of: %s' "$1" "$SECTIONS"; } # PATH
# The three shapes the grammar refuses, each with its remedy on the line.
NO_ENTRY='has no entry in it — a fragment is the Markdown list item it becomes'
NO_MARKER='does not open with a list marker — a fragment is the Markdown list item it becomes, opening with a hyphen and a space'
MORE_THAN_ONE='holds more than the one entry it becomes — every line after the first indents under it'
shape() { printf 'changelog-entries FAIL %s %s' "$1" "$2"; } # PATH COMPLAINT
X198="$(rep x 198)"
X205="$(rep x 205)"
X250="$(rep x 250)"
A60="$(rep a 60)"

run_rows() { # label | fixture | env | args | expect
  local row label fx env args expect
  for row in "$@"; do
    IFS='|' read -r label fx env args expect <<<"$row"
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
  done
}

echo "=== the cap is the whole length rule, measured in characters over the joined entry ==="
fx_none() { repo none; put ok.rs 'fn main() {}\n'; stage; }
fx_over() { repo over; frag fixed short.md '- A short entry.\n'; frag fixed long.md "- $X205\n"; }
fx_at_cap() { repo at-cap; frag fixed b.md "- $X198\n"; }
fx_past_cap() { repo past-cap; frag fixed b.md "- $(rep x 199)\n"; }
fx_six_short() { repo six-short; frag fixed six.md '- Six short lines\n  second\n  third\n  fourth\n  fifth\n  sixth.\n'; }
fx_six_long() { repo six-long; frag fixed six.md "- Six long lines\n  $(rep y 60)\n  $(rep y 60)\n  $(rep y 60)\n  $(rep y 60)\n"; }
# 2 for the marker, four runs joined by three collapsed spaces: 2 + 60*3 + 3 + 15.
fx_wrapped() { repo wrapped; frag fixed w.md "- $A60\n  $A60\n  $A60\n\n  $(rep a 15)\n"; }
fx_wrapped_over() { repo wrapped-over; frag fixed w.md "- $A60\n  $A60\n  $A60\n\n  $(rep a 16)\n"; }
fx_unwrapped_over() { repo unwrapped-over; frag fixed w.md "- $A60 $A60 $A60 $(rep a 16)\n"; }
fx_cr() { repo cr; frag fixed cr.md "- $X198\r\n"; }
fx_trailing() { repo trailing; frag fixed t.md "- $X198   \t  \n"; }
fx_runs() { repo runs; frag fixed r.md "- $(rep x 100)     $(rep x 97)\n"; }
fx_blank_first() { repo blank-first; frag fixed b.md "   \n- $X205\n"; }
fx_runs_over() { repo runs-over; frag fixed r.md "- $(rep x 100)     $(rep x 98)\n"; }
fx_dashes() { repo dashes; frag fixed d.md "- $(rep '—' 198)\n"; }
fx_dashes_over() { repo dashes-over; frag fixed d.md "- $(rep '—' 199)\n"; }
fx_stray_bytes() {
  repo stray-bytes
  mkdir -p "$R/changelog.d/fixed"
  { printf -- '- valid\n  '; LC_ALL=C awk 'BEGIN { for (i = 0; i < 300; i++) printf "%c", 191 }'; printf '\n'; } >"$R/changelog.d/fixed/stray.md"
  stage
}
# The two forms the UTF-8 grammar refuses that carry no stray byte at all: a
# surrogate (ED A0 80) and an overlong two-byte encoding (C0 80), each a
# sequence a byte-range check would accept.
fx_surrogate() { repo surrogate; frag fixed s.md '- valid\n  \0355\0240\0200\n'; }
fx_overlong() { repo overlong; frag fixed o.md '- valid\n  \0300\0200\n'; }
fx_two_bad() { repo two-bad; frag fixed t.md '- valid\n  \0277\n  \0277\n'; }
run_rows \
  "no fragment tree is a clean pass naming the paths it looked for|fx_none|||rc=0 $NOMATCH" \
  "an over-cap fragment fails naming file, length and cap, quotes its first line, carries the remedy, and the short one beside it is only counted|fx_over|||rc=1 $(long changelog.d/fixed/long.md 207 "- $X205");$(summary 1 2)" \
  "an entry of exactly the cap passes|fx_at_cap|||rc=0 $(within 1)" \
  "one character past the cap fails|fx_past_cap|||rc=1 $(long changelog.d/fixed/b.md 201 "- $(rep x 199)");$(summary 1 1)" \
  "a six-line entry inside the cap passes: no line count|fx_six_short|||rc=0 $(within 1)" \
  "control: the same shape past the cap fails|fx_six_long|||rc=1 $(long changelog.d/fixed/six.md 260 '- Six long lines');$(summary 1 1)" \
  "a wrapped entry with an indented second paragraph is measured whole|fx_wrapped|||rc=0 $(within 1)" \
  "control: one more real character in the same shape fails at 201|fx_wrapped_over|||rc=1 $(long changelog.d/fixed/w.md 201 "- $A60");$(summary 1 1)" \
  "the same text unwrapped onto one line measures identically|fx_unwrapped_over|||rc=1 $(long changelog.d/fixed/w.md 201 "- $A60 $A60 $A60 $(rep a 16)");$(summary 1 1)" \
  "a CR at the end of a line is not a character|fx_cr|||rc=0 $(within 1)" \
  "trailing whitespace spends no cap|fx_trailing|||rc=0 $(within 1)" \
  "an interior whitespace run collapses to one character|fx_runs|||rc=0 $(within 1)" \
  "control: the collapsed run leaves exactly one character to overflow, and the quoted first line keeps its raw spacing|fx_runs_over|||rc=1 $(long changelog.d/fixed/r.md 201 "- $(rep x 100)     $(rep x 98)");$(summary 1 1)" \
  "a whitespace-only line above the entry is not the quoted line|fx_blank_first|||rc=1 $(long changelog.d/fixed/b.md 207 "- $X205");$(summary 1 1)" \
  "200 em dashes are 200 characters, not 596 bytes|fx_dashes|||rc=0 $(within 1)" \
  "control: one em dash more is one character more|fx_dashes_over|||rc=1 $(long changelog.d/fixed/d.md 201 "- $(rep '—' 199)");$(summary 1 1)" \
  "a line that is not valid UTF-8 has no character count: a collection error naming the line, never a measurement|fx_stray_bytes|||rc=2 ${ERR}changelog.d/fixed/stray.md line 2 is not valid UTF-8 — text with no character count cannot be measured" \
  "a UTF-16 surrogate encoded as three bytes is not valid UTF-8|fx_surrogate|||rc=2 ${ERR}changelog.d/fixed/s.md line 2 is not valid UTF-8 — text with no character count cannot be measured" \
  "an overlong two-byte encoding is not valid UTF-8|fx_overlong|||rc=2 ${ERR}changelog.d/fixed/o.md line 2 is not valid UTF-8 — text with no character count cannot be measured" \
  "the first invalid line is named, and only it|fx_two_bad|||rc=2 ${ERR}changelog.d/fixed/t.md line 2 is not valid UTF-8 — text with no character count cannot be measured"

echo "=== a fragment is exactly one list item, or it is refused ==="
fx_empty() { repo empty; frag fixed e.md ''; }
fx_blank() { repo blank; frag fixed e.md '\n\n'; }
fx_marker_only() { repo marker-only; frag fixed e.md '- \n'; }
fx_prose() { repo prose; frag fixed e.md 'Not a list item.\n'; }
fx_no_space() { repo no-space; frag fixed e.md '-No space after the hyphen.\n'; }
fx_two_items() { repo two-items; frag fixed e.md '- First entry.\n- Second entry.\n'; }
fx_heading() { repo heading; frag fixed e.md '- An entry.\n\n## [9.9.9] - 2026-01-01\n'; }
fx_continued() { repo continued; frag fixed e.md '- An entry\n  continued over\n  three lines.\n'; }
fx_tab_continued() { repo tab-continued; frag fixed e.md '- An entry\n\tcontinued under a tab.\n'; }
run_rows \
  "a zero-byte fragment is refused, naming it|fx_empty|||rc=1 $(shape changelog.d/fixed/e.md "$NO_ENTRY");$(summary 1 0)" \
  "a whitespace-only fragment is refused|fx_blank|||rc=1 $(shape changelog.d/fixed/e.md "$NO_ENTRY");$(summary 1 0)" \
  "a marker with nothing after it is refused|fx_marker_only|||rc=1 $(shape changelog.d/fixed/e.md "$NO_ENTRY");$(summary 1 0)" \
  "a fragment opening with prose is refused|fx_prose|||rc=1 $(shape changelog.d/fixed/e.md "$NO_MARKER");$(summary 1 0)" \
  "a hyphen with no space after it is not a list marker|fx_no_space|||rc=1 $(shape changelog.d/fixed/e.md "$NO_MARKER");$(summary 1 0)" \
  "two list items in one fragment are refused|fx_two_items|||rc=1 $(shape changelog.d/fixed/e.md "$MORE_THAN_ONE");$(summary 1 0)" \
  "a heading inside a fragment is refused rather than ending the section it folds into|fx_heading|||rc=1 $(shape changelog.d/fixed/e.md "$MORE_THAN_ONE");$(summary 1 0)" \
  "control: indented continuation lines are the one entry|fx_continued|||rc=0 $(within 1)" \
  "a tab-indented continuation line is the one entry too|fx_tab_continued|||rc=0 $(within 1)"

echo "=== a fragment sits directly under a section directory, at its pattern's depth ==="
# Keep a Changelog's six, written out rather than read from the check's own
# list: a set derived from the subject cannot catch that set being narrowed.
fx_six_sections() { repo six-sections; local s; for s in added changed deprecated removed fixed security; do frag "$s" ken-1.md "- An entry filed under $s.\n"; done; }
fx_bogus() { repo bogus; frag bogus ken-1.md '- Wrong section.\n'; }
fx_deeper() { repo deeper; frag fixed/deeper ken-2.md '- Deeper.\n'; }
# `*` crosses `/`, so changelog.d/*/*.md reaches changelog.d/archive/fixed/x.md,
# whose immediate parent is a real section name; depth is counted from the
# root the pattern roots at.
fx_archive() { repo archive; frag archive/fixed ken-3.md '- Nested under a real section name.\n'; }
fx_archive_control() { repo archive-control; frag fixed ken-3.md '- Nested under a real section name.\n'; }
fx_flat() { repo flat; put flat.md '- Flat.\n'; stage; }
# The section list is space-separated, so a directory whose name spans two
# adjacent words is a substring of the list's text and a member of nothing in it.
fx_two_words() { repo two-words; frag 'added changed' x.md '- Two words.\n'; }
run_rows \
  "a fragment under each of the six sections passes|fx_six_sections|||rc=0 $(within 6)" \
  "an unknown section directory is refused, naming the accepted set|fx_bogus|||rc=1 $(nosection changelog.d/bogus/ken-1.md);$(summary 1 0)" \
  "a fragment below a section directory is refused|fx_deeper|||rc=1 $(nosection changelog.d/fixed/deeper/ken-2.md);$(summary 1 0)" \
  "a path two directories below the root is refused though its parent names a section, and the remedy states whose depth decides|fx_archive|||rc=1 $(nosection changelog.d/archive/fixed/ken-3.md);$(summary 1 0)" \
  "control: the same entry directly under the section passes|fx_archive_control|||rc=0 $(within 1)" \
  "a fragment in no directory at all names no section either|fx_flat|COMMIT_GUARDS_CHANGELOG_PATHS=flat.md||rc=1 $(nosection flat.md);$(summary 1 0)" \
  "a directory naming two sections at once names none|fx_two_words|||rc=1 $(nosection 'changelog.d/added\ changed/x.md');$(summary 1 0)"

echo "=== every other tracked path in the fragment tree is refused; a README directly under a root and the record are exempt ==="
tree() { repo "$1"; frag fixed ken-1.md '- A fragment.\n'; put changelog.d/README.md '# changelog.d\n\n- Format notes running past what an entry may say, at length.\n'; stage; } # NAME
fx_tree_clean() { tree tree-clean; }
fx_tree_notes() { tree tree-notes; put changelog.d/fixed/notes 'whatever\n'; stage; }
fx_tree_symlink() { tree tree-symlink; ln -s ../../CHANGELOG.md "$R/changelog.d/fixed/notes"; stage; }
fx_tree_top() { tree tree-top; put changelog.d/oops.md '- Stray.\n'; stage; }
fx_tree_orig() { tree tree-orig; put changelog.d/fixed/ken-1.md.orig '- A fragment.\n'; stage; }
fx_tree_sibling() { tree tree-sibling; put changelog.d-archive/old.md '- Not under the root.\n'; stage; }
fx_tree_readme_below() { tree tree-readme-below; put changelog.d/fixed/README.md '# notes\n'; stage; }
# A pattern carrying no glob names one file, and naming one file is not
# naming the directory it sits in, so it roots nowhere and sweeps nothing.
fx_exact_path() { repo exact-path; put changelog.d/added/only.md "- $X250\n"; put changelog.d/added/beside.txt 'not a fragment at all\n'; stage; }
fx_exact_path_control() { repo exact-path-control; put changelog.d/added/only.md "- $X250\n"; put changelog.d/added/beside.txt 'not a fragment at all\n'; stage; }
# The README exemption wins over every root, not merely the last one
# checked: with a nested pair, the deeper root exempts its own README while
# the shallower one still contains it.
NESTED='COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/nested/*/*.md changelog.d/*/legacy/*.md'
fx_nested_readme() { repo nested-readme; put changelog.d/nested/fixed/a.md '- A nested entry.\n'; put changelog.d/nested/README.md '# nested\n\n- Format notes.\n'; stage; }
fx_nested_notes() { repo nested-notes; put changelog.d/nested/fixed/a.md '- A nested entry.\n'; put changelog.d/nested/NOTES.md '# nested\n\n- Format notes.\n'; stage; }
# What is not a fragment is settled before any pattern is consulted: the
# same file, exempt or judged according to where the ROOT falls, not
# according to whether some glob happened to match it first.
exemptions() { repo "$1"; frag fixed x.md '- A proper entry.\n'; put changelog.d/fixed/README.md '# changelog.d/fixed\n\nHow to write one of these.\n'; put changelog.d/README.md '# changelog.d\n\nHow to write one of these.\n'; stage; } # NAME
fx_narrowed_readme() { exemptions narrowed-readme; }
fx_default_readme() { exemptions default-readme; }
fx_record_inside() { repo record-inside; frag fixed x.md '- A proper entry.\n'; put changelog.d/CHANGELOG.md '# Changelog\n\n## [Unreleased]\n'; stage; }
fx_record_inside_control() { repo record-inside-control; frag fixed x.md '- A proper entry.\n'; put changelog.d/NOTES.md '# Notes\n'; stage; }
run_rows \
  "control: the tree with only fragments and its README is clean|fx_tree_clean|||rc=0 $(within 1)" \
  "a path in a section directory that no glob covers is refused, naming what a fragment must match|fx_tree_notes|||rc=1 $(stray changelog.d/fixed/notes);$(summary 1 1)" \
  "a symlink the globs do not cover is refused the same way, never followed|fx_tree_symlink|||rc=1 $(stray changelog.d/fixed/notes);$(summary 1 1)" \
  "a stray at the top of the tree is refused|fx_tree_top|||rc=1 $(stray changelog.d/oops.md);$(summary 1 1)" \
  "a name that merely begins like a fragment's is a stray: the glob matches the whole path|fx_tree_orig|||rc=1 $(stray changelog.d/fixed/ken-1.md.orig);$(summary 1 1)" \
  "a sibling directory sharing the root's prefix is outside the tree|fx_tree_sibling|||rc=0 $(within 1)" \
  "a README below a section directory is a fragment position and is judged|fx_tree_readme_below|||rc=1 $(shape changelog.d/fixed/README.md "$NO_MARKER");$(summary 1 1)" \
  "an exact-path pattern roots nowhere and sweeps nothing beside it|fx_exact_path|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/added/only.md||rc=1 $(long changelog.d/added/only.md 252 "- $X250");$(summary 1 1)" \
  "control: a globbed pattern over the same directory does root there and sweeps the neighbour|fx_exact_path_control|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/added/*.md||rc=1 $(stray changelog.d/added/beside.txt 'changelog.d/added/*.md');$(long changelog.d/added/only.md 252 "- $X250");$(summary 2 1)" \
  "a README under the deeper of two nested roots is exempt|fx_nested_readme|$NESTED||rc=0 $(within 1)" \
  "control: the same file under any other name is swept by the shallower root|fx_nested_notes|$NESTED||rc=1 $(stray changelog.d/nested/NOTES.md 'changelog.d/nested/*/*.md changelog.d/*/legacy/*.md');$(summary 1 1)" \
  "a README under the root a narrowed pattern derives is exempt, though the glob reaches it|fx_narrowed_readme|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md||rc=0 $(within 1)" \
  "control: under the default pattern the same file is a fragment position and is judged, and the README at the default root stays exempt|fx_default_readme|||rc=1 $(shape changelog.d/fixed/README.md "$NO_MARKER");$(summary 1 1)" \
  "a record configured inside the fragment tree is not swept as a stray|fx_record_inside|COMMIT_GUARDS_CHANGELOG_RECORD=changelog.d/CHANGELOG.md||rc=0 $(within 1)" \
  "control: another file in that same place is swept|fx_record_inside_control|COMMIT_GUARDS_CHANGELOG_RECORD=changelog.d/CHANGELOG.md||rc=1 $(stray changelog.d/NOTES.md);$(summary 1 1)"

echo "=== the pattern says where the section sits, and at what depth ==="
# One rule for every pattern shape: a pattern is <root...>/<section>/<name>,
# so its own last two segments place a path and its own depth decides which
# paths it places.
fx_two_glob() { repo two-glob; frag fixed x.md '- A proper entry.\n'; put changelog.d/archive/fixed/y.md '- Nested under a real section name.\n'; stage; }
fx_narrowed() { repo narrowed; frag fixed x.md '- A proper entry.\n'; }
fx_narrowed_deeper() { repo narrowed-deeper; frag fixed x.md '- A proper entry.\n'; put changelog.d/fixed/deeper/z.md '- Deeper still.\n'; stage; }
fx_middle_glob() { repo middle-glob; frag fixed x.md '- A proper entry.\n'; put changelog.d/team/fixed/w.md '- Under a middle glob.\n'; stage; }
run_rows \
  "the two-glob pattern places changelog.d/fixed and refuses a path a directory deeper|fx_two_glob|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/*/*.md||rc=1 $(nosection changelog.d/archive/fixed/y.md);$(summary 1 1)" \
  "a pattern narrowed to one section still places its entries|fx_narrowed|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md||rc=0 $(within 1)" \
  "and refuses a path a directory deeper than it|fx_narrowed_deeper|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md||rc=1 $(nosection changelog.d/fixed/deeper/z.md);$(summary 1 1)" \
  "a pattern with a glob in the middle places paths at ITS depth, not two past its root|fx_middle_glob|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/*/fixed/*.md||rc=1 $(stray changelog.d/fixed/x.md 'changelog.d/*/fixed/*.md');$(summary 1 1)"

echo "=== a matched path that is not changelog text is refused, never skipped ==="
fx_symlink() { repo symlink; frag fixed real.md '- A real entry.\n'; ln -s real.md "$R/changelog.d/fixed/link.md"; stage; }
fx_symlink_control() { repo symlink-control; frag fixed real.md '- A real entry.\n'; }
# A gitlink is an index entry with no blob behind it in this repository, so
# the fixture writes the entry directly; the object need not exist.
fx_gitlink() { repo gitlink; frag fixed real.md '- A real entry.\n'; git -C "$R" update-index --add --cacheinfo 160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,changelog.d/fixed/sub.md; }
# Every byte value, so a NUL falls inside the sample git classifies on; awk
# writes them under LC_ALL=C so a value is a byte and not a character.
fx_binary() { repo binary; mkdir -p "$R/changelog.d/fixed"; { printf -- '- '; LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }'; } >"$R/changelog.d/fixed/bin.md"; stage; }
# git classifies on the leading 8000 bytes alone, and so does this check: a
# NUL at byte offset 8000, the first past that sample, is a blob both call
# text, refused as the byte it is; one at offset 7999, the sample's last
# byte, is binary. The marker takes two bytes, so the run of x is two short.
nul_at() { mkdir -p "$R/changelog.d/added"; { printf -- '- '; rep x "$(($1 - 2))"; LC_ALL=C awk 'BEGIN { printf "%c", 0 }'; printf 'tail\n'; } >"$R/changelog.d/added/$2"; } # OFFSET NAME
fx_late_nul() { repo late-nul; nul_at 8000 late-nul.md; stage; }
fx_last_nul() { repo last-nul; nul_at 7999 last-nul.md; stage; }
fx_high_bytes() { repo high-bytes; frag fixed h.md "- $(rep '—' 250)\n"; }
run_rows \
  "a tracked symlink is refused, not followed and not skipped|fx_symlink|||rc=1 changelog-entries FAIL changelog.d/fixed/link.md is tracked as a symlink;  a fragment is a file of its own;$(summary 1 1)" \
  "control: the same tree without the link passes|fx_symlink_control|||rc=0 $(within 1)" \
  "a submodule gitlink is refused, not read as a file|fx_gitlink|||rc=1 changelog-entries FAIL changelog.d/fixed/sub.md is tracked as a submodule gitlink;  a fragment is a file of its own;$(summary 1 1)" \
  "a binary blob is refused, not measured as text|fx_binary|||rc=1 changelog-entries FAIL changelog.d/fixed/bin.md holds binary content;  a fragment is the Markdown list item it becomes;$(summary 1 0)" \
  "a blob git calls text, its NUL the first byte past the sample, is read as text, and the byte is refused rather than the file|fx_late_nul|||rc=2 ${ERR}changelog.d/added/late-nul.md line 1 is not valid UTF-8 — text with no character count cannot be measured" \
  "control: a NUL at the sample's last byte is binary|fx_last_nul|||rc=1 changelog-entries FAIL changelog.d/added/last-nul.md holds binary content;  a fragment is the Markdown list item it becomes;$(summary 1 0)" \
  "control: NUL-free high bytes are text and are measured|fx_high_bytes|||rc=1 $(long changelog.d/fixed/h.md 252 "- $(rep '—' 250)");$(summary 1 1)"
# git itself calls the leading-NUL and last-byte blobs binary and the
# first-past blob text, which is the agreement the three rows above pin.
repo git-classifies
mkdir -p "$R/changelog.d/fixed"
{ printf -- '- '; LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }'; } >"$R/changelog.d/fixed/bin.md"
nul_at 7999 last-nul.md
nul_at 8000 late-nul.md
stage
assert_eq "fixture: git calls the leading-NUL and last-byte blobs binary and the first-past blob text" "changelog.d/added/late-nul.md" "$(git -C "$R" grep --cached -I -l . -- changelog.d)"

echo "=== control bytes never reach the terminal through a diagnostic ==="
# Every C0 control except tab, and DEL: a tab is whitespace the entry may
# carry, so it reaches the quoted line as itself. Measured: 65 characters of
# words and control bytes, the tab collapsed to one space, and 220 z.
TAB="$(printf '\t')"
fx_controls() { repo controls; frag fixed c.md "- An escape \033[31mred\033[0m, a CR \rhere, a tab\there and a DEL \177here $(rep z 220)\n"; }
run_rows \
  "escape, carriage-return and DEL bytes are replaced in the quoted entry, and a tab is kept|fx_controls|||rc=1 $(long changelog.d/fixed/c.md 285 "- An escape ?[31mred?[0m, a CR ?here, a tab${TAB}here and a DEL ?here $(rep z 220)");$(summary 1 1)"

echo "=== the cap and the paths are configurable, and validated ==="
fx_cap() { repo cap; frag fixed long.md "- $X250\n"; }
fx_cap_raised() { repo cap-raised; frag fixed long.md "- $X250\n"; }
fx_cap_zero() { repo cap-zero; frag fixed long.md "- $X250\n"; }
fx_cap_negative() { repo cap-negative; frag fixed long.md "- $X250\n"; }
fx_cap_word() { repo cap-word; frag fixed long.md "- $X250\n"; }
fx_cap_fraction() { repo cap-fraction; frag fixed long.md "- $X250\n"; }
fx_cap_empty() { repo cap-empty; frag fixed long.md "- $X250\n"; }
paths() { repo "$1"; frag fixed ken-1.md "- $X250\n"; put changelog.d/README.md "# changelog.d\n\n- A README bullet explaining the format at $(rep w 220) length.\n"; stage; } # NAME
fx_paths_default() { paths paths-default; }
fx_paths_readme() { paths paths-readme; }
fx_paths_none() { paths paths-none; }
fx_paths_second() { paths paths-second; }
fx_paths_absolute() { paths paths-absolute; }
fx_paths_escape() { paths paths-escape; }
fx_paths_empty() { paths paths-empty; }
fx_record_absolute() { paths record-absolute; }
fx_record_in_globs() { paths record-in-globs; }
fx_unknown_arg() { paths unknown-arg; }
bad_cap() { printf "%sCOMMIT_GUARDS_CHANGELOG_CAP must be a positive integer, got '%s'" "$ERR" "$1"; } # VALUE
run_rows \
  "control: the entry fails the default cap|fx_cap|||rc=1 $(long changelog.d/fixed/long.md 252 "- $X250");$(summary 1 1)" \
  "a raised cap passes it, and the verdict names the cap in force|fx_cap_raised|COMMIT_GUARDS_CHANGELOG_CAP=400||rc=0 $(within 1 400)" \
  "a cap of 0 is a config error|fx_cap_zero|COMMIT_GUARDS_CHANGELOG_CAP=0||rc=2 $(bad_cap 0)" \
  "a cap of -1 is a config error|fx_cap_negative|COMMIT_GUARDS_CHANGELOG_CAP=-1||rc=2 $(bad_cap -1)" \
  "a cap of abc is a config error|fx_cap_word|COMMIT_GUARDS_CHANGELOG_CAP=abc||rc=2 $(bad_cap abc)" \
  "a cap of 12.5 is a config error|fx_cap_fraction|COMMIT_GUARDS_CHANGELOG_CAP=12.5||rc=2 $(bad_cap 12.5)" \
  "an empty cap is a config error|fx_cap_empty|COMMIT_GUARDS_CHANGELOG_CAP=||rc=2 $(bad_cap "")" \
  "the default glob reaches the fragment tree and keeps the README out|fx_paths_default|||rc=1 $(long changelog.d/fixed/ken-1.md 252 "- $X250");$(summary 1 1)" \
  "control: named directly, the README is judged and refused|fx_paths_readme|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/README.md||rc=1 $(nosection changelog.d/README.md);$(summary 1 0)" \
  "configured paths matching no tracked file are a clean pass|fx_paths_none|COMMIT_GUARDS_CHANGELOG_PATHS=docs/*/*.md||rc=0 changelog-entries: OK — no tracked file matches COMMIT_GUARDS_CHANGELOG_PATHS (docs/*/*.md)" \
  "the SECOND glob of the list reaches the fragment the first does not, and measures it|fx_paths_second|COMMIT_GUARDS_CHANGELOG_PATHS=docs/*/*.md changelog.d/*/*.md||rc=1 $(long changelog.d/fixed/ken-1.md 252 "- $X250");$(summary 1 1)" \
  "an absolute path is a config error|fx_paths_absolute|COMMIT_GUARDS_CHANGELOG_PATHS=/etc/CHANGELOG.md||rc=2 ${ERR}changelog path must be repo-root-relative, got absolute: /etc/CHANGELOG.md" \
  "a path escaping the repository is a config error|fx_paths_escape|COMMIT_GUARDS_CHANGELOG_PATHS=../CHANGELOG.md||rc=2 ${ERR}changelog path escapes the repository or normalizes empty: ../CHANGELOG.md" \
  "an empty path list is a config error naming how to switch the check off|fx_paths_empty|COMMIT_GUARDS_CHANGELOG_PATHS=   ||rc=2 ${ERR}COMMIT_GUARDS_CHANGELOG_PATHS names no path — name at least one, or drop this check from COMMIT_GUARDS_CHECKS" \
  "an absolute record path is a config error|fx_record_absolute|COMMIT_GUARDS_CHANGELOG_RECORD=/etc/CHANGELOG.md||rc=2 ${ERR}changelog-record path must be repo-root-relative, got absolute: /etc/CHANGELOG.md" \
  "a record inside the fragment globs is a config error: the two scopes judge by opposite rules|fx_record_in_globs|COMMIT_GUARDS_CHANGELOG_RECORD=changelog.d/fixed/ken-1.md||rc=2 ${ERR}COMMIT_GUARDS_CHANGELOG_RECORD (changelog.d/fixed/ken-1.md) is also matched by COMMIT_GUARDS_CHANGELOG_PATHS — the collated record is not a fragment" \
  "an unknown argument is a config error|fx_unknown_arg||--all|rc=2 ${ERR}unknown argument --all (see --help)"

echo "=== the index is what is judged: a configured glob reaches index paths, never the work tree ==="
fx_staged_gone() { repo staged-gone; frag fixed ok.md '- A short fragment.\n'; frag fixed long.md "- $X250\n"; rm -f "$R/changelog.d/fixed/long.md"; }
fx_untracked_decoy() { repo untracked-decoy; frag fixed ok.md '- A short fragment.\n'; frag fixed long.md "- $X250\n"; rm -f "$R/changelog.d/fixed/long.md"; put changelog.d/fixed/decoy.md "- $(rep y 300)\n"; }
fx_unstaged_edit() { repo unstaged-edit; frag fixed a.md '- A short entry.\n'; git -C "$R" commit -qm base; put changelog.d/fixed/a.md "- $X250\n"; }
fx_staged_edit() { repo staged-edit; frag fixed a.md '- A short entry.\n'; git -C "$R" commit -qm base; put changelog.d/fixed/a.md "- $X250\n"; stage; }
# ls-files -s lists an unmerged path once per stage, so the walk would read
# the rival blobs as separate fragments; the judge refuses the index first.
fx_unmerged() {
  repo unmerged
  frag fixed a.md '- Base.\n'
  git -C "$R" commit -qm base
  git -C "$R" checkout -qb other
  frag fixed a.md '- Theirs.\n'
  git -C "$R" commit -qm theirs
  git -C "$R" checkout -q main
  frag fixed a.md '- Ours.\n'
  git -C "$R" commit -qm ours
  git -C "$R" merge -q other >/dev/null 2>&1 || true
}
# The refusal is index-wide: an unmerged path no glob reaches still stops
# the run, since every record of the index passes through the walk.
fx_unmerged_outside() {
  repo unmerged-outside
  frag fixed a.md '- Fine.\n'
  put notes.txt 'base\n'
  stage
  git -C "$R" commit -qm base
  git -C "$R" checkout -qb other
  put notes.txt 'theirs\n'
  stage
  git -C "$R" commit -qm theirs
  git -C "$R" checkout -q main
  put notes.txt 'ours\n'
  stage
  git -C "$R" commit -qm ours
  git -C "$R" merge -q other >/dev/null 2>&1 || true
}
run_rows \
  "a staged fragment absent from the work tree is still measured|fx_staged_gone|||rc=1 $(long changelog.d/fixed/long.md 252 "- $X250");$(summary 1 2)" \
  "an untracked decoy under the same glob is never measured|fx_untracked_decoy|||rc=1 $(long changelog.d/fixed/long.md 252 "- $X250");$(summary 1 2)" \
  "an unstaged worktree edit is not judged|fx_unstaged_edit|||rc=0 $(within 1)" \
  "control: staging the same edit does fail it|fx_staged_edit|||rc=1 $(long changelog.d/fixed/a.md 252 "- $X250");$(summary 1 1)" \
  "an unmerged fragment is refused before the walk, never read stage by stage|fx_unmerged|||rc=2 changelog.d/fixed/a.md;${ERR}the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run" \
  "an unmerged path outside every glob refuses the run the same way|fx_unmerged_outside|||rc=2 notes.txt;${ERR}the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"

echo "=== hostile bytes in a name or a pattern never leave their line ==="
# A tracked filename carrying a newline, an ESC and a tab: all three are
# legal bytes in a path; the first two decide what a message does if they
# reach one raw, and the tab is the byte that ends the path field of an
# ls-files record, so a walk splitting on the wrong tab loses the file. The
# name reaches the verdict through %q, so the four lines stay four.
HOSTILE="$(printf 'KEN\n1\033X\t.md')"
fx_hostile_name() { repo hostile-name; mkdir -p "$R/changelog.d/fixed"; printf -- '- %s\n' "$X250" >"$R/changelog.d/fixed/$HOSTILE"; stage; }
fx_hostile_stray() { repo hostile-stray; mkdir -p "$R/changelog.d/fixed"; printf -- '- Fine.\n' >"$R/changelog.d/fixed/${HOSTILE%.md}"; stage; }
fx_hostile_pattern() { repo hostile-pattern; frag fixed ok.md '- Fine.\n'; }
run_rows \
  "the entry under the hostile name is measured, and the verdict stays on its four lines|fx_hostile_name|||rc=1 $(long "\$'changelog.d/fixed/KEN\\n1\\EX\\t.md'" 252 "- $X250");$(summary 1 1)" \
  "a refusal names the hostile path the same way, on its own line|fx_hostile_stray|||rc=1 $(stray "\$'changelog.d/fixed/KEN\\n1\\EX\\t'");$(summary 1 0)" \
  "a pattern carrying ESC that matches nothing is a clean pass on one line, the byte scrubbed|fx_hostile_pattern|$(printf 'COMMIT_GUARDS_CHANGELOG_PATHS=no\033match.md')||rc=0 changelog-entries: OK — no tracked file matches COMMIT_GUARDS_CHANGELOG_PATHS (no?match.md)"

echo "=== the usage is answered ==="
repo help
assert_eq "--help prints the usage and exits 0" "rc=0 usage: changelog-entries [--collate]" "$(run "" --help | cut -d';' -f1)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
