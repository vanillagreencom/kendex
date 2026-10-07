#!/usr/bin/env bash
# Pins for scripts/changelog-entries, the one judge of a repository's
# changelog fragments: a fragment is a real text file under a section
# directory holding exactly one list item of any length, every other tracked
# path in the fragment tree is refused, and the configured globs decide what
# is read, from the index. One table: a row builds its own repository, stages
# what it means, runs the judge once under its settings and reads back the
# exit status with each stable message record. Paths, entry previews and
# summary counts remain asserted. The --collate write path is
# changelog-collate.test.sh; the index readers this family shares are
# index-reads.test.sh and lane-readers.test.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_CHANGELOG_COLLATE \
  COMMIT_GUARDS_CHANGELOG_VERSION_PATHS COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS \
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
# stable message record, in order, joined by ';'. ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" ${envs[@]+"${envs[@]}"} "$CE" $2 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '
    /^changelog-entries: [a-z-]+=/ { print; next }
    /^[[:space:]]*dependency-order-control:/ { sub(/^[[:space:]]*/, ""); print }
  ')" || return 2
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
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
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

# Stable values emitted by each rule, independent of the English explanation.
DEFAULT_GLOB='changelog.d/*/*.md'
ERR="changelog-entries: "
NOMATCH="${ERR}no-matches=$DEFAULT_GLOB"
within() { printf 'changelog-entries: checked=%s' "$1"; } # ACCEPTED
summary() { printf 'changelog-entries: violations=%s:%s' "$1" "$2"; } # VIOLATIONS ACCEPTED
stray() { printf 'changelog-entries: fragment-stray=%s' "$1"; } # PATH
nosection() { printf 'changelog-entries: fragment-section=%s' "$1"; } # PATH
NO_ENTRY=fragment-empty
NO_MARKER=fragment-marker
MORE_THAN_ONE=fragment-continuation
shape() { printf 'changelog-entries: %s=%s' "$2" "$1"; } # PATH KEY
X250="$(rep x 250)"
TWO='- First entry.\n- Second entry.\n'

run_rows() { # label | fixture | env | args | expect
  local row label fx env args expect
  for row in "$@"; do
    IFS='|' read -r label fx env args expect <<<"$row"
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
  done
}

echo "=== an entry has no length limit; text the record cannot carry is a collection error ==="
fx_none() { repo none; put ok.rs 'fn main() {}\n'; stage; }
fx_long() { repo long; frag fixed short.md '- A short entry.\n'; frag fixed long.md "- $X250\n"; }
fx_six_long() { repo six-long; frag fixed six.md "- Six long lines\n  $(rep y 60)\n  $(rep y 60)\n  $(rep y 60)\n  $(rep y 60)\n"; }
fx_cr() { repo cr; frag fixed cr.md "- $X250\r\n"; }
fx_blank_first() { repo blank-first; frag fixed b.md "   \n- $X250\n"; }
fx_dashes() { repo dashes; frag fixed d.md "- $(rep '—' 250)\n"; }
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
  "a 250-character entry passes beside a short one: no character cap|fx_long|||rc=0 $(within 2)" \
  "a five-line entry of 260 characters passes: no line count either|fx_six_long|||rc=0 $(within 1)" \
  "a CR at the end of the line is accepted|fx_cr|||rc=0 $(within 1)" \
  "a whitespace-only line above the entry is accepted|fx_blank_first|||rc=0 $(within 1)" \
  "250 em dashes, 750 bytes of UTF-8, pass: no byte limit|fx_dashes|||rc=0 $(within 1)" \
  "a line that is not valid UTF-8 is a collection error naming the line, never a fragment|fx_stray_bytes|||rc=2 ${ERR}encoding-line=changelog.d/fixed/stray.md:2" \
  "a UTF-16 surrogate encoded as three bytes is not valid UTF-8|fx_surrogate|||rc=2 ${ERR}encoding-line=changelog.d/fixed/s.md:2" \
  "an overlong two-byte encoding is not valid UTF-8|fx_overlong|||rc=2 ${ERR}encoding-line=changelog.d/fixed/o.md:2" \
  "the first invalid line is named, and only it|fx_two_bad|||rc=2 ${ERR}encoding-line=changelog.d/fixed/t.md:2"

# Restoring the removed length refusal turns the long-entry case red.
mkdir -p "$TMP/cap-control"
cp -R "$SKILL_DIR/scripts" "$TMP/cap-control/scripts"
python3 - "$TMP/cap-control/scripts/changelog-entries" <<'EDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '  checked=$((checked + 1))'
assert s.count(needle) == 1
p.write_text(s.replace(needle, needle + '\n  [ "$(wc -c <"$GG_TMP/blob")" -le 200 ] || violations=$((violations + 1))'))
EDIT
repo long-control
frag fixed long.md "- $(rep x 10000)\n"
control_rc=0
(cd "$R" && "$TMP/cap-control/scripts/changelog-entries" >/dev/null 2>&1) || control_rc=$?
assert_eq "control: the removed character ceiling rejects the long fixture" 1 "$control_rc"

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
fx_exact_path() { repo exact-path; put changelog.d/added/only.md '- The one entry.\n'; put changelog.d/added/beside.txt 'not a fragment at all\n'; stage; }
fx_exact_path_control() { repo exact-path-control; put changelog.d/added/only.md '- The one entry.\n'; put changelog.d/added/beside.txt 'not a fragment at all\n'; stage; }
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
  "an exact-path pattern roots nowhere and sweeps nothing beside it|fx_exact_path|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/added/only.md||rc=0 $(within 1)" \
  "control: a globbed pattern over the same directory does root there and sweeps the neighbour|fx_exact_path_control|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/added/*.md||rc=1 $(stray changelog.d/added/beside.txt 'changelog.d/added/*.md');$(summary 1 1)" \
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
fx_high_bytes_two() { repo high-bytes-two; frag fixed h.md "- $(rep '—' 250)\n- $(rep '—' 250)\n"; }
fx_encoding_tool() {
  repo encoding-tool
  frag fixed e.md '- A valid entry.\n'
  mkdir -p "$R/shim"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *"UTF8 ="*) echo "dependency-order-control: encoding-read" >&2; exit 2 ;; esac; done\nexec %q "$@"\n' "$(command -v awk)" >"$R/shim/awk"
  chmod +x "$R/shim/awk"
}
run_rows \
  "a tracked symlink is refused, not followed and not skipped|fx_symlink|||rc=1 changelog-entries: fragment-symlink=changelog.d/fixed/link.md;$(summary 1 1)" \
  "control: the same tree without the link passes|fx_symlink_control|||rc=0 $(within 1)" \
  "a submodule gitlink is refused, not read as a file|fx_gitlink|||rc=1 changelog-entries: fragment-gitlink=changelog.d/fixed/sub.md;$(summary 1 1)" \
  "a binary blob is refused, not measured as text|fx_binary|||rc=1 changelog-entries: fragment-binary=changelog.d/fixed/bin.md;$(summary 1 0)" \
  "a blob git calls text, its NUL the first byte past the sample, is read as text, and the byte is refused rather than the file|fx_late_nul|||rc=2 ${ERR}encoding-line=changelog.d/added/late-nul.md:1" \
  "an encoding tool failure puts the stable record before awk's cause|fx_encoding_tool|PATH=$TMP/encoding-tool/shim:$PATH||rc=2 ${ERR}encoding-read=changelog.d/fixed/e.md;dependency-order-control: encoding-read" \
  "control: a NUL at the sample's last byte is binary|fx_last_nul|||rc=1 changelog-entries: fragment-binary=changelog.d/added/last-nul.md;$(summary 1 0)" \
  "control: NUL-free high bytes are text and are accepted|fx_high_bytes|||rc=0 $(within 1)" \
  "control: NUL-free high bytes are text and are read for their shape|fx_high_bytes_two|||rc=1 $(shape changelog.d/fixed/h.md "$MORE_THAN_ONE");$(summary 1 0)"
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
# carry, so it reaches the quoted line as itself. The one diagnostic that
# quotes tracked content is the version check's entry preview.
TAB="$(printf '\t')"
CONTROLS="- **Breaking:** An escape \033[31mred\033[0m, a CR \rhere, a tab\there and a DEL \177here."
fx_controls() { repo controls; put app.json '{"version":"1.9.0"}\n'; stage; git -C "$R" commit -qm base; put app.json '{"version":"1.10.0"}\n'; frag changed c.md "$CONTROLS\n"; }
run_rows \
  "escape, carriage-return and DEL bytes are replaced in the quoted entry, and a tab is kept|fx_controls|COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app.json||rc=1 ${ERR}minor-breaking=app.json:1.9.0:1.10.0;${ERR}entry-preview=- **Breaking:** An escape ?[31mred?[0m, a CR ?here, a tab${TAB}here and a DEL ?here.;$(summary 1 1)"

echo "=== the paths are configurable, and validated ==="
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
run_rows \
  "the default glob reaches the fragment tree and keeps the README out|fx_paths_default|||rc=0 $(within 1)" \
  "control: named directly, the README is judged and refused|fx_paths_readme|COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/README.md||rc=1 $(nosection changelog.d/README.md);$(summary 1 0)" \
  "configured paths matching no tracked file are a clean pass|fx_paths_none|COMMIT_GUARDS_CHANGELOG_PATHS=docs/*/*.md||rc=0 changelog-entries: no-matches=docs/*/*.md" \
  "the SECOND glob of the list reaches the fragment the first does not, and judges it|fx_paths_second|COMMIT_GUARDS_CHANGELOG_PATHS=docs/*/*.md changelog.d/*/*.md||rc=0 $(within 1)" \
  "an absolute path is a config error|fx_paths_absolute|COMMIT_GUARDS_CHANGELOG_PATHS=/etc/CHANGELOG.md||rc=2 ${ERR}path-absolute=changelog:/etc/CHANGELOG.md" \
  "a path escaping the repository is a config error|fx_paths_escape|COMMIT_GUARDS_CHANGELOG_PATHS=../CHANGELOG.md||rc=2 ${ERR}path-escape=changelog:../CHANGELOG.md" \
  "an empty path list is a config error naming how to switch the check off|fx_paths_empty|COMMIT_GUARDS_CHANGELOG_PATHS=   ||rc=2 ${ERR}glob-empty=COMMIT_GUARDS_CHANGELOG_PATHS" \
  "an absolute record path is a config error|fx_record_absolute|COMMIT_GUARDS_CHANGELOG_RECORD=/etc/CHANGELOG.md||rc=2 ${ERR}path-absolute=changelog-record:/etc/CHANGELOG.md" \
  "a record inside the fragment globs is a config error: the two scopes judge by opposite rules|fx_record_in_globs|COMMIT_GUARDS_CHANGELOG_RECORD=changelog.d/fixed/ken-1.md||rc=2 ${ERR}changelog-overlap=changelog.d/fixed/ken-1.md" \
  "an unknown argument is a config error|fx_unknown_arg||--all|rc=2 ${ERR}argument=--all"

echo "=== the index is what is judged: a configured glob reaches index paths, never the work tree ==="
fx_staged_gone() { repo staged-gone; frag fixed ok.md '- A short fragment.\n'; frag fixed two.md "$TWO"; rm -f "$R/changelog.d/fixed/two.md"; }
fx_untracked_decoy() { repo untracked-decoy; frag fixed ok.md '- A short fragment.\n'; frag fixed two.md "$TWO"; rm -f "$R/changelog.d/fixed/two.md"; put changelog.d/fixed/decoy.md "$TWO"; }
fx_unstaged_edit() { repo unstaged-edit; frag fixed a.md '- A short entry.\n'; git -C "$R" commit -qm base; put changelog.d/fixed/a.md "$TWO"; }
fx_staged_edit() { repo staged-edit; frag fixed a.md '- A short entry.\n'; git -C "$R" commit -qm base; put changelog.d/fixed/a.md "$TWO"; stage; }
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
  "a staged fragment absent from the work tree is still judged|fx_staged_gone|||rc=1 $(shape changelog.d/fixed/two.md "$MORE_THAN_ONE");$(summary 1 1)" \
  "an untracked decoy under the same glob is never judged|fx_untracked_decoy|||rc=1 $(shape changelog.d/fixed/two.md "$MORE_THAN_ONE");$(summary 1 1)" \
  "an unstaged worktree edit is not judged|fx_unstaged_edit|||rc=0 $(within 1)" \
  "control: staging the same edit does fail it|fx_staged_edit|||rc=1 $(shape changelog.d/fixed/a.md "$MORE_THAN_ONE");$(summary 1 0)" \
  "an unmerged fragment is refused before the walk, never read stage by stage|fx_unmerged|||rc=2 ${ERR}unmerged-path=changelog.d/fixed/a.md;${ERR}unmerged-count=1" \
  "an unmerged path outside every glob refuses the run the same way|fx_unmerged_outside|||rc=2 ${ERR}unmerged-path=notes.txt;${ERR}unmerged-count=1"

echo "=== hostile bytes in a name or a pattern never leave their line ==="
# A tracked filename carrying a newline, an ESC and a tab: all three are
# legal bytes in a path; the first two decide what a message does if they
# reach one raw, and the tab is the byte that ends the path field of an
# ls-files record, so a walk splitting on the wrong tab loses the file. The
# name reaches the verdict through %q, so the four lines stay four.
HOSTILE="$(printf 'KEN\n1\033X\t.md')"
fx_hostile_name() { repo hostile-name; mkdir -p "$R/changelog.d/fixed"; printf -- '%b' "$TWO" >"$R/changelog.d/fixed/$HOSTILE"; stage; }
fx_hostile_stray() { repo hostile-stray; mkdir -p "$R/changelog.d/fixed"; printf -- '- Fine.\n' >"$R/changelog.d/fixed/${HOSTILE%.md}"; stage; }
fx_hostile_pattern() { repo hostile-pattern; frag fixed ok.md '- Fine.\n'; }
run_rows \
  "the fragment under the hostile name is judged, and the message values stay on their own lines|fx_hostile_name|||rc=1 $(shape "\$'changelog.d/fixed/KEN\\n1\\EX\\t.md'" "$MORE_THAN_ONE");$(summary 1 0)" \
  "a refusal names the hostile path the same way, on its own line|fx_hostile_stray|||rc=1 $(stray "\$'changelog.d/fixed/KEN\\n1\\EX\\t'");$(summary 1 0)" \
  "a pattern carrying ESC that matches nothing is a clean pass on one line, the byte scrubbed|fx_hostile_pattern|$(printf 'COMMIT_GUARDS_CHANGELOG_PATHS=no\033match.md')||rc=0 changelog-entries: no-matches=no?match.md"

echo "=== a configured version bump matches its release's entries ==="
# npm version and app release edits stage JSON versions. The record field is
# the release author's pending or renamed section; each row owns its repository.
# The expected field is an exit status or the refusal key; a minor or patch
# refusal's preview line is the first offending entry, and every fixture spells
# its Added entry as ADD and its Breaking one as BREAK. The fragment section is
# the last field, changed when empty. A package.json beside the record is the
# app's version file (app-package rows); one elsewhere is a package (package-).
BREAK='- **Breaking:** Rename the mode setting; replace mode with profile.'
ADD='- Add a profile setting.'
for row in \
  "major-unnamed|app.json|1.9.0|2.0.0|||||major-breaking" \
  "major-named|app.json|1.9.0|2.0.0|$BREAK||||0" \
  "major-empty-callout|app.json|1.9.0|2.0.0|- **Breaking:**   ||||major-breaking" \
  "major-inline-mention|app.json|1.9.0|2.0.0|- Read **Breaking:** in the guide.||||major-breaking" \
  "patch|app.json|1.9.0|1.9.1|||||0" \
  "minor|app.json|1.9.0|1.10.0|||||0" \
  "minor-breaking|app.json|1.9.0|1.10.0|\n$BREAK||||minor-breaking" \
  "minor-added|app.json|1.9.0|1.10.0|$ADD||||0|added" \
  "patch-added|app.json|1.9.0|1.9.1|$ADD||||patch-added|added" \
  "patch-breaking|app.json|1.9.0|1.9.1|$BREAK||||patch-breaking" \
  "patch-fix-only|app.json|1.9.0|1.9.1|- Fix a typo.||||0|fixed" \
  "patch-changed|app.json|1.9.0|1.9.1|- Change the default profile.||||0" \
  "patch-record-added|app.json|1.9.0|1.9.1||CHANGELOG.md|## [Unreleased]\n\n### Added\n\n$ADD\n\n### Fixed\n\n- Fix a typo.\n||patch-added" \
  "patch-record-fixed|app.json|1.9.0|1.9.1||CHANGELOG.md|## [Unreleased]\n\n### Fixed\n\n- Fix a typo.\n\n## [1.9.0] - 2026-09-01\n\n### Added\n\n$ADD\n||0" \
  "suffix-only|app.json|1.9.1-rc.1|1.9.1|$ADD||||0|added" \
  "suffix-before-wider-patch|app.json|1.9.9-rc.1|1.9.10|$ADD||||patch-added|added" \
  "zero-patch-added|app.json|0.9.0|0.9.1|$ADD||||0|added" \
  "package-minor-breaking|packages/a/package.json|1.9.0|1.10.0||packages/a/CHANGELOG.md|### Unreleased\n\n$BREAK\n||minor-breaking" \
  "downgrade|app.json|2.0.0|1.9.0|$BREAK||||0" \
  "large-major|app.json|9223372036854775808.0.0|9223372036854775809.0.0|||||major-breaking" \
  "prerelease-major|app.json|1.9.0|2.0.0-rc.1+build.2|||||major-breaking" \
  "initial|app.json||2.0.0|||||0" \
  "invalid-new|app.json|1.9.0|2.0.0junk|||||2" \
  "invalid-old|app.json|bad|2.0.0|||||2" \
  "collated|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n### Changed\n\n$BREAK\n||0" \
  "released|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n## [2.0.0] - 2026-09-30\n\n### Changed\n\n$BREAK\n||0" \
  "historic|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n$BREAK\n||major-breaking" \
  "historic-reused-number|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n## [1.9.0] - 2026-09-01\n\n## [2.0.0] - 2025-01-01\n\n$BREAK\n||major-breaking" \
  "fenced|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n\140\140\140md\n$BREAK\n\140\140\140\n||major-breaking" \
  "unclosed-fence|app.json|1.9.0|2.0.0||CHANGELOG.md|## [Unreleased]\n\n\140\140\140md\n$BREAK\n||fence" \
  "package-unnamed|packages/a/package.json|1.9.0|2.0.0||packages/a/CHANGELOG.md|### Unreleased\n\n- Fix a typo.\n||major-breaking" \
  "package-named|packages/a/package.json|1.9.0|2.0.0||packages/a/CHANGELOG.md|### Unreleased\n\n$BREAK\n||0" \
  "package-released|packages/a/package.json|1.9.0|2.0.0||packages/a/CHANGELOG.md|### 2.0.0\n\n$BREAK\n\n### 1.9.0\n||0" \
  "app-package-patch-added|package.json|1.0.0|1.0.1|$ADD||||patch-added|added" \
  "app-package-record-added|package.json|1.0.0|1.0.1||CHANGELOG.md|## [Unreleased]\n\n### Added\n\n$ADD\n||patch-added" \
  "app-package-major|package.json|0.10.0|1.0.0|$BREAK||||0" \
  "app-package-package-heading|package.json|1.9.0|2.0.0||CHANGELOG.md|### Unreleased\n\n$BREAK\n||major-breaking" \
  "package-historic|packages/a/package.json|1.9.0|2.0.0||packages/a/CHANGELOG.md|### Unreleased\n\n### 1.9.0\n\n$BREAK\n||major-breaking" \
  "package-other|packages/a/package.json|1.9.0|2.0.0|$BREAK|packages/b/CHANGELOG.md|### Unreleased\n\n$BREAK\n||major-breaking" \
  "committed-base|app.json|1.9.0|2.0.0||||--base base|major-breaking" \
  "committed-against-unnamed|app.json|1.9.0|2.0.0||||--against base|major-breaking" \
  "committed-against|app.json|1.9.0|2.0.0|$BREAK|||--against base|0" \
  "committed-against-patch-added|app.json|1.9.0|1.9.1|$ADD|||--against base|patch-added|added" \
  "against-past-release|app.json|1.9.0|1.9.1|$ADD|CHANGELOG.md|## [Unreleased]\n\n### Added\n\n$ADD\n\n## [1.9.1] - 2026-10-02\n\n### Fixed\n\n- Fix a typo.\n|--against base|0|added" \
  "patch-added-own-release|app.json|1.9.0|1.9.1|$ADD|CHANGELOG.md|## [1.9.1] - 2026-10-02\n\n### Fixed\n\n- Fix a typo.\n||patch-added|added" \
  "base-own-release-pending-added|app.json|1.9.0|1.9.1||CHANGELOG.md|## [Unreleased]\n\n### Added\n\n$ADD\n\n## [1.9.1] - 2026-10-02\n\n### Fixed\n\n- Fix a typo.\n|--base base|patch-added" \
  "major-past-release|app.json|1.9.0|2.0.0|$BREAK|CHANGELOG.md|## [Unreleased]\n\n## [2.0.0] - 2026-10-02\n\n### Fixed\n\n- Fix a typo.\n|--against base|0" \
  "released-patch-added|app.json|1.9.0|1.9.1||CHANGELOG.md|## [Unreleased]\n\n## [1.9.1] - 2026-10-02\n\n### Added\n\n$ADD\n||patch-added"; do
  IFS='|' read -r label manifest prior next fragment record_path record args expected section <<<"$row"
  repo "version-$label"
  if [ -n "$prior" ]; then
    put "$manifest" "{\"version\":\"$prior\"}\n"
    stage
    git -C "$R" commit -qm base
    git -C "$R" tag base
  fi
  put "$manifest" "{\"version\":\"$next\"}\n"
  [ -z "$fragment" ] || put "changelog.d/${section:-changed}/entry.md" "$fragment\n"
  [ -z "$record_path" ] || put "$record_path" "$record"
  stage
  [ -z "$args" ] || git -C "$R" commit -qm release
  report="$NOMATCH"
  count=0
  if [ -n "$fragment" ]; then report="$(within 1)"; count=1; fi
  case "$expected" in
    major-breaking) expected=1; report="${ERR}major-breaking=$manifest:$prior:$next;$(summary 1 "$count")" ;;
    *-breaking) report="${ERR}$expected=$manifest:$prior:$next;${ERR}entry-preview=$BREAK;$(summary 1 "$count")"; expected=1 ;;
    patch-added) expected=1; report="${ERR}patch-added=$manifest:$prior:$next;${ERR}entry-preview=$ADD;$(summary 1 "$count")" ;;
    2) report="${ERR}version-read=$manifest" ;;
    fence) expected=2; report="${ERR}version-record-fence=$record_path" ;;
  esac
  assert_eq "$label" "rc=$expected $report" "$(run 'COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app.json packages/*/package.json package.json' "$args")"
done

# The released record's Breaking entries, copied from CHANGELOG.md with one
# unmarked Added entry each: the entry query reports every marked item of the
# first release section, 3 in 1.4.0 and 10 in 1.3.0, and no unmarked one.
released_breaking() { # VERSION FILE — the number of breaking rows the query reports
  (
    # shellcheck source=../scripts/lib/common.sh
    . "$SKILL_DIR/scripts/lib/common.sh"
    # shellcheck source=../scripts/lib/changelog-grammar.sh
    . "$SKILL_DIR/scripts/lib/changelog-grammar.sh"
    LC_ALL=C awk -v entry_query=1 -v release_version="$1" "$GG_UNRELEASED_AWK" <"$2"
  ) | LC_ALL=C awk -F '\t' '$1 == "breaking" { n++ } END { print n + 0 }'
}
cat >"$TMP/released-1.4.0.md" <<'EOF'
## [Unreleased]

## [1.4.0] - 2026-10-01

### Added

- Add the `swift` agent for SwiftUI and UIKit views, Swift app code, and Xcode and Swift Package Manager builds and tests across all supported agent harnesses.

### Changed

- **Breaking:** Update subscriptions and routes: generalist to maintainer; engineer to runtime. Frontend covers React/QML/JavaScript UI; runtime adds non-UI Go. Rust excludes Iced views.

### Removed

- **Breaking:** Pi fleet lanes refuse pi-hooks without mail wake. Repair the reported root and scope on the lane machine per the refusal; retry hosted launches with `--relaunch`.
- **Breaking:** GitHub approvals and thread resolution replace the custom review status. Remove the retired status from required checks before consumer refresh removes its workflow.

### Fixed

### Security
EOF
cat >"$TMP/released-1.3.0.md" <<'EOF'
## [Unreleased]

## [1.3.0] - 2026-09-30

### Added

- orch: an `ORCH_OVERSEER_PREFERENCE` entry may name Copilot CLI as `copilot:MODEL:EFFORT`; the overseer opens on the Copilot account `lanes` picks, with that model and effort.

### Changed

- **Breaking:** oversee: after upgrading, run `oversee register` in the overseer's pane; until then no session reads its mail, `oversee launch --predecessor` refuses it, and a watch start drops its launch identity.
- **Breaking:** harness-ci reads every change as queue-only until the base commit's `[env]` sets `HARNESS_CI_QUEUE_PATHS`; set it empty for none.
- **Breaking:** review-gate's standard scripts refuse until `kendex.settings.toml` `[env]` sets `REVIEW_GATE_STANDARD_APP`, `REVIEW_GATE_STANDARD_ENVIRONMENT` and `REVIEW_GATE_STANDARD_SECRETS`.
- **Breaking:** review-gate: `pr-watch.sh` reads GitHub's review state alone, with `disarmed` and `awaiting-stale` read from `reviewDecision`; `--heal`, `--no-evaluate` and the predicate kinds are gone.
- **Breaking:** review-gate: `standard-required-approvals` and `standard-stale-dismissal` fail until the organization ruleset's pull-request rule requires 1 approval and dismisses stale approvals.
- **Breaking:** review-gate: `standard-ruleset-source` fails an organization's required checks or merge queue (move both to repository rulesets) and an absent organization deletion or force-push rule.
- **Breaking:** review-gate: `standard-required-contexts` fails until `[env]` sets `REVIEW_GATE_STANDARD_CONTEXTS` to the required checks; drop `Review gate` from the ruleset before the writer goes.
- **Breaking:** `skill-load-check` runs on Copilot CLI; the `workflow` bundle adds `skill-load-record`. A scope that names the check alone must add that hook, or every guarded Copilot call is refused.
- **Breaking:** lanes: every lane brief, on every harness, carries the unattended words, and a `--cmd` launch naming a harness is refused without them.

### Removed

- **Breaking:** orch: an `ORCH_OVERSEER_PREFERENCE` tier rank is refused; write the model the rank named, so `claude:1:high` becomes `claude:fable:high`.

### Fixed

### Security
EOF
assert_eq "the released 1.4.0 section holds 3 Breaking entries" 3 "$(released_breaking 1.4.0 "$TMP/released-1.4.0.md")"
assert_eq "the released 1.3.0 section holds 10 Breaking entries" 10 "$(released_breaking 1.3.0 "$TMP/released-1.3.0.md")"

# No version-file configuration means no version policy for a catalog consumer.
repo version-off
put app.json '{"version":"1.0.0"}\n'; stage; git -C "$R" commit -qm base
put app.json '{"version":"2.0.0"}\n'; stage
assert_eq 'version discovery defaults off' "rc=0 $NOMATCH" "$(run '' '')"
# The staged major stays unnamed even if the working tree holds a call-out.
put changelog.d/changed/unstaged.md "$BREAK\n"
assert_eq 'unstaged call-out cannot justify a staged major' "rc=1 ${ERR}major-breaking=app.json:1.0.0:2.0.0;$(summary 1 0)" "$(run COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app.json '')"

# With the record off, a root package.json is a package judged by its own
# CHANGELOG.md at ### headings, as the app-package rows are not.
repo version-package-record-off
put package.json '{"version":"1.9.0"}\n'; stage; git -C "$R" commit -qm base
put package.json '{"version":"2.0.0"}\n'; put CHANGELOG.md "### Unreleased\n\n$BREAK\n"; stage
assert_eq 'a root package without a record reads its own changelog' "rc=0 $NOMATCH" "$(run COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=package.json,COMMIT_GUARDS_CHANGELOG_RECORD= '')"
# Beside a nested record, a nested package.json is the app's version file too.
repo version-package-nested-record
put app/package.json '{"version":"1.0.0"}\n'; stage; git -C "$R" commit -qm base
put app/package.json '{"version":"1.0.1"}\n'; frag added entry.md "$ADD\n"
assert_eq 'a package.json beside a nested record reads the fragments' \
  "rc=1 ${ERR}patch-added=app/package.json:1.0.0:1.0.1;${ERR}entry-preview=$ADD;$(summary 1 1)" \
  "$(run COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app/package.json,COMMIT_GUARDS_CHANGELOG_RECORD=app/CHANGELOG.md '')"

echo "=== a deleted version file has no version to judge ==="
repo version-deleted
put pi/a/package.json '{"version":"1.0.0"}\n'; stage; git -C "$R" commit -qm base
git -C "$R" rm -q pi/a/package.json; frag fixed f.md '- Fix a typo.\n'
assert_eq 'a deleted configured version file beside a program fragment passes' "rc=0 $(within 1)" "$(run 'COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=pi/*/package.json' '')"

echo "=== a package's entries move its own version, never the program's ==="
# A fragment a pattern places through its package slot names its package;
# skills/<name>/SKILL.md declares a versioned one, whose frontmatter
# metadata.version its change raises, or a versionless one where it states
# none, and hooks/<name>.sh a versionless one.
# Every row commits app.json at 1.9.0, skills/pkg at the row's prior
# version, skills/other at 1.0.0, hooks/hookx.sh and a nested
# hooks/tests/lib/helper.sh, plus the row's base fragment, then stages its
# own change and fragment. Fragment paths are under changelog.d.
PKG_GLOBS='COMMIT_GUARDS_CHANGELOG_PATHS=changelog.d/*/*.md changelog.d/*/*/*.md,COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS=skills/*/SKILL.md hooks/*.sh agents/*.md'
PKG_ENV="$PKG_GLOBS,COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app.json"
skill() { # NAME VERSION, none for a SKILL.md that states no version
  local version=""
  [ "$2" = none ] || version="$(printf '\n  version: "%s"' "$2")"
  printf -- '---\nname: %s\nmetadata:\n  author: test%s\ntags: [x]\n---\n\n# %s\n' "$1" "$version" "$1"
}
PKG='skills/pkg/SKILL.md'
RUN='skills/pkg/run.sh'
PKG_NOMATCH="${ERR}no-matches=changelog.d/*/*.md changelog.d/*/*/*.md"
APP_MINOR="${ERR}minor-breaking=app.json:1.9.0:1.10.0;${ERR}entry-preview=$BREAK"
UNBUMPED="rc=1 ${ERR}package-unbumped=$PKG:1.0.0;$(summary 1 0)"
pkg_repo() { # NAME PRIOR BASE-FRAGMENT — committed
  repo "$1"
  put app.json '{"version":"1.9.0"}\n'
  put "$PKG" "$(skill pkg "$2")\n"
  put skills/pkg/run.sh 'echo one\n'
  put skills/other/SKILL.md "$(skill other 1.0.0)\n"
  put hooks/hookx.sh 'echo hook\n'
  put hooks/tests/lib/helper.sh 'echo helper\n'
  [ -z "$3" ] || put "changelog.d/$3" "$BREAK\n"
  stage
  git -C "$R" commit -qm base
}
for row in \
  "package-only|package-only Breaking entry: the kendex minor passes and the package takes its major|1.10.0|1.0.0|2.0.0|$RUN||pkg/removed/entry.md|$BREAK|rc=0 $(within 1)" \
  "program-breaking|program Breaking entry: the kendex minor is refused, it proposes a major|1.10.0|1.0.0|1.0.0|||removed/entry.md|$BREAK|rc=1 $APP_MINOR;$(summary 1 1)" \
  "package-minor|package Breaking entry: the package's minor is refused|1.9.0|1.0.0|1.1.0|$RUN||pkg/removed/entry.md|$BREAK|rc=1 ${ERR}minor-breaking=$PKG:1.0.0:1.1.0;${ERR}entry-preview=$BREAK;$(summary 1 1)" \
  "package-patch|package Added entry: the package's patch is refused|1.9.0|1.0.0|1.0.1|$RUN||pkg/added/entry.md|$ADD|rc=1 ${ERR}patch-added=$PKG:1.0.0:1.0.1;${ERR}entry-preview=$ADD;$(summary 1 1)" \
  "zero-minor|a 0.x package minor with its own Breaking entry is not judged|1.9.0|0.1.0|0.2.0|$RUN||pkg/removed/entry.md|$BREAK|rc=0 $(within 1)" \
  "unbumped|a package change with no version raise is refused|1.9.0|1.0.0|1.0.0|$RUN||||$UNBUMPED" \
  "bumped|control: the same change with a patch raise passes|1.9.0|1.0.0|1.0.1|$RUN||||rc=0 $PKG_NOMATCH" \
  "fragment-only|a fragment alone is no package change|1.9.0|1.0.0|1.0.0|||pkg/fixed/entry.md|- Fix a typo.|rc=0 $(within 1)" \
  "earlier|an earlier change's Breaking entry is that release's, not this patch's|1.9.0|1.0.0|1.0.1|$RUN|pkg/removed/old.md|||rc=0 $(within 1)" \
  "edited|so is an earlier Breaking entry this patch edits|1.9.0|1.0.0|1.0.1|$RUN|pkg/removed/old.md|pkg/removed/old.md|$BREAK Spelled out.|rc=0 $(within 1)" \
  "other|another package's Breaking entry leaves this major unnamed|1.9.0|1.0.0|2.0.0|$RUN||other/removed/entry.md|$BREAK|rc=1 ${ERR}major-breaking=$PKG:1.0.0:2.0.0;$(summary 1 1)" \
  "hook|a versionless hook's change and fragment are accepted, no version read|1.9.0|1.0.0|1.0.0|hooks/hookx.sh||hookx/fixed/entry.md|- Fix a typo.|rc=0 $(within 1)" \
  "nested-helper|a fragment named for a nested hooks/tests helper names no package|1.9.0|1.0.0|1.0.0|||helper/fixed/entry.md|- Fix a typo.|rc=1 ${ERR}fragment-package=changelog.d/helper;$(summary 1 0)" \
  "duplicate|an agent and a skill of one name are refused, naming both files|1.9.0|1.0.0|1.0.0|agents/pkg.md||||rc=2 ${ERR}package-duplicate=agents/pkg.md:$PKG" \
  "misspelled|a Breaking fragment naming no declared package is refused, naming its directory|1.9.0|1.0.0|1.0.1|$RUN||linaer/removed/entry.md|$BREAK|rc=1 ${ERR}fragment-package=changelog.d/linaer;$(summary 1 0)" \
  "versionless|a SKILL.md stating no metadata.version is a versionless package: its change and fragment pass with no raise|1.9.0|none|none|$RUN||pkg/fixed/entry.md|- Fix a typo.|rc=0 $(within 1)" \
  "version-dropped|a change dropping metadata.version owes no raise|1.9.0|1.0.0|none|$RUN||||rc=0 $PKG_NOMATCH" \
  "first-version|a change stating a first metadata.version owes no raise|1.9.0|none|1.0.0|$RUN||||rc=0 $PKG_NOMATCH" \
  "nameless|a package file with no name is a collection error|1.9.0|1.0.0|nameless|$RUN||||rc=2 ${ERR}version-read=$PKG"; do
  IFS='|' read -r name label app_next pkg_prior pkg_next change base_frag frag fragment expected <<<"$row"
  pkg_repo "package-$name" "$pkg_prior" "$base_frag"
  put app.json "{\"version\":\"$app_next\"}\n"
  case "$pkg_next" in
    nameless) put "$PKG" '---\nmetadata:\n  version: "1.0.0"\n---\n' ;;
    *) put "$PKG" "$(skill pkg "$pkg_next")\n" ;;
  esac
  [ -z "$change" ] || put "$change" 'echo two\n'
  [ -z "$frag" ] || put "changelog.d/$frag" "$fragment\n"
  stage
  assert_eq "$label" "$expected" "$(run "$PKG_ENV" '')"
done
R="$TMP/package-unbumped"
assert_eq 'the package check runs with no version files configured' "$UNBUMPED" "$(run "$PKG_GLOBS" '')"
# A new package has no prior version to raise.
repo package-new
put app.json '{"version":"1.9.0"}\n'; stage; git -C "$R" commit -qm base
put "$PKG" "$(skill pkg 1.0.0)\n"; put skills/pkg/run.sh 'echo one\n'; stage
assert_eq 'a new package needs no raise' "rc=0 $PKG_NOMATCH" "$(run "$PKG_ENV" '')"
# The version is the metadata block's, plain or quoted, and a package is
# versionless only where no frontmatter line holds a version key in any
# spelling: one the block reader cannot resolve to a non-empty version is a
# collection error, and the word in a value is no key.
for row in \
  "plain|a plain metadata.version above a top-level version line is the version read|metadata:\n  version: 1.0.0\nversion: 9.9.9|$UNBUMPED" \
  "single|a single-quoted metadata.version is read without its quotes|metadata:\n  version: '1.0.0'|$UNBUMPED" \
  "comment|a column-zero comment inside metadata leaves its version read|metadata:\n# note\n  version: \"1.0.0\"|$UNBUMPED" \
  "metadata-comment|a comment on the metadata line leaves its version read|metadata: # note\n  version: 1.0.0|$UNBUMPED" \
  "word|the word version inside a value is no key: the package reads versionless|summary: \"Cuts a version: bumps it, tags.\"|rc=0 $PKG_NOMATCH" \
  "flow|a flow-mapping version is a collection error, never a versionless package|metadata: {version: \"1.0.0\"}|rc=2 ${ERR}version-read=$PKG" \
  "quoted-key|a quoted version key is a collection error, never a versionless package|metadata:\n  \"version\": \"1.0.0\"|rc=2 ${ERR}version-read=$PKG" \
  "spaced|a version key with space before its colon is a collection error, never a versionless package|metadata:\n  version : 1.0.0|rc=2 ${ERR}version-read=$PKG" \
  "top-level|a version line outside metadata is a collection error, never a versionless package|version: 1.0.0|rc=2 ${ERR}version-read=$PKG" \
  "empty|an empty metadata.version is a collection error, never a versionless package|metadata:\n  version: \"\"|rc=2 ${ERR}version-read=$PKG"; do
  IFS='|' read -r name label frontmatter expected <<<"$row"
  repo "package-form-$name"
  put "$PKG" "---\nname: pkg\n$frontmatter\n---\n"; put skills/pkg/run.sh 'echo one\n'; stage; git -C "$R" commit -qm base
  put skills/pkg/run.sh 'echo two\n'; stage
  assert_eq "$label" "$expected" "$(run "$PKG_ENV" '')"
done
# A program pattern globbing deeper than its root has no package slot.
repo package-mid-glob
put app.json '{"version":"1.9.0"}\n'; put "$PKG" "$(skill pkg 1.0.0)\n"; stage; git -C "$R" commit -qm base
put app.json '{"version":"1.10.0"}\n'; put packages/app/changelog.d/removed/x.md "$BREAK\n"; stage
assert_eq 'a mid-path-glob pattern places program entries' "rc=1 $APP_MINOR;$(summary 1 1)" \
  "$(run 'COMMIT_GUARDS_CHANGELOG_PATHS=packages/*/changelog.d/*/*.md,COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS=skills/*/SKILL.md,COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=app.json' '')"
# The record's Packages part holds the packages' releases: its Breaking
# entry proposes no kendex major, as the same entry under Changed does.
for row in \
  "record-packages|a Breaking entry under the record's Packages part leaves the kendex minor alone|### Packages\n\n#### pkg 2.0.0\n\n$BREAK\n|rc=0 $PKG_NOMATCH" \
  "record-changed|control: under Changed it refuses the kendex minor|### Changed\n\n$BREAK\n|rc=1 $APP_MINOR;$(summary 1 0)"; do
  IFS='|' read -r name label part expected <<<"$row"
  repo "$name"
  put app.json '{"version":"1.9.0"}\n'; put CHANGELOG.md '## [Unreleased]\n'; stage; git -C "$R" commit -qm base
  put app.json '{"version":"1.10.0"}\n'; put CHANGELOG.md "## [Unreleased]\n\n$part"; stage
  assert_eq "$label" "$expected" "$(run "$PKG_ENV" '')"
done

echo "=== a staged run inside an amend compares against the amended commit's parent ==="
# A real pre-commit hook: the amend is read off the committing git's argv in
# /proc, which macOS lacks, so the amend rows are skipped there.
amend_repo() { # NAME JUDGE — the package raised 1.0.0 -> 1.1.0 in HEAD, a correction staged
  repo "$1"
  printf '#!/bin/sh\nexec %s --staged >"%s/hook.out" 2>&1\n' "$2" "$R" >"$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  put "$PKG" "$(skill pkg 1.0.0)\n"; put skills/pkg/run.sh 'echo one\n'; stage; git -C "$R" commit -qm base
  put "$PKG" "$(skill pkg 1.1.0)\n"; put skills/pkg/run.sh 'echo two\n'; stage; git -C "$R" commit -qm raise
  put skills/pkg/run.sh 'echo three\n'; stage
}
commit() { # ARGS — git's exit status, then the hook's stable records
  local rc=0
  : >"$R/hook.out"
  COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS='skills/*/SKILL.md' git -C "$R" commit "$@" >/dev/null 2>&1 || rc=$?
  printf 'rc=%s %s' "$rc" "$(LC_ALL=C awk '/^changelog-entries: [a-z-]+=/ { print }' "$R/hook.out" | paste -sd ';' -)"
}
amend_repo amend-next "$CE"
assert_eq 'control: a new commit after the raise owes its own' \
  "rc=1 ${ERR}package-unbumped=$PKG:1.1.0;$(summary 1 0)" "$(commit -qm next)"
if [ -r "/proc/$$/cmdline" ]; then
  amend_repo amend "$CE"
  assert_eq 'an amend adding a correction under the raised package passes' "rc=0 $NOMATCH" "$(commit -q --amend --no-edit)"
else
  printf '  skip  %s\n' 'the amend rows need /proc/<pid>/cmdline'
fi

# Must-fail controls on a disposable copy of the scripts: each plants the
# defect its rule exists against, and the row that pins the rule turns red.
control() { # LABEL FIXTURE EXPECT FROM TO [SCRIPT]
  local judge
  gg_mutant judge "${6:-changelog-entries}" "$4" "$5"
  judge="${judge%/*}"
  judge="${judge%/lib}/changelog-entries"
  R="$TMP/$2"
  assert_eq "control: $1" "$3" "$(CE="$judge" run "$PKG_ENV" '')"
}
control 'under the old rule a package-only Breaking entry refuses the kendex minor' package-package-only \
  "rc=1 $APP_MINOR;$(summary 1 1)" '[ -z "$GG_FRAGMENT_PACKAGE" ] || continue' ':'
control 'without the unbumped refusal the unraised change passes' package-unbumped \
  "rc=0 $PKG_NOMATCH" 'refuse package-unbumped' ': package-unbumped'
control 'without the package lookup a misspelled package directory passes' package-misspelled \
  "rc=0 $(within 1)" 'if [ -n "$GG_FRAGMENT_PACKAGE" ] && ! gg_package_row "$GG_FRAGMENT_PACKAGE"; then' 'if false; then'
control 'a package glob matching across / declares the nested helper' package-nested-helper \
  "rc=0 $(within 1)" 'gg_path_placer "$f" $GG_CHANGELOG_PACKAGES || continue' 'gg_path_matches "$f" $GG_CHANGELOG_PACKAGES || continue' lib/changelog-grammar.sh
control 'without the duplicate refusal the agent shadows the skill' package-duplicate \
  "rc=0 $PKG_NOMATCH" '! gg_package_row "$name"' '! false' lib/changelog-grammar.sh
control 'version-checking a versionless package refuses the hook change' package-hook \
  "rc=2 ${ERR}version-read=hooks/hookx.sh" '[ -n "$dir" ] || continue' '[ -n "$dir" ] || dir="$pf"'
control 'reading a SKILL.md that states no version as unreadable refuses its change' package-versionless \
  "rc=2 ${ERR}version-read=$PKG" '*) return 0 ;; esac' '*) gg_fail version-read "$(gg_shown "$3")" "planted" ;; esac' lib/changelog-grammar.sh
control 'judging a dropped version as a raise refuses the change' package-version-dropped \
  "rc=1 ${ERR}package-unbumped=$PKG:1.0.0;$(summary 1 0)" '[ -n "$new" ] || continue' ':'
control 'judging a first version against an absent one refuses the change' package-first-version \
  "rc=1 ${ERR}major-breaking=$PKG::1.0.0;$(summary 1 0)" '[ -n "$old" ] || continue' ':'
control 'reading an empty metadata.version as no version passes the change' package-form-empty \
  "rc=0 $PKG_NOMATCH" ' || (has && version == "")' '' lib/skill-roots.sh
control 'counting only metadata version lines reads a top-level one as versionless' package-form-top-level \
  "rc=0 $PKG_NOMATCH" '/(^[ \t]*|[{,][ \t]*)["\047]?version["\047]?[ \t]*:/ { has = 1 }' 'meta && /^[ \t]+version:/ { has = 1 }' lib/skill-roots.sh
control 'counting only a bare version key at a line start reads a flow mapping as versionless' package-form-flow \
  "rc=0 $PKG_NOMATCH" '/(^[ \t]*|[{,][ \t]*)["\047]?version["\047]?[ \t]*:/ { has = 1 }' '/^[ \t]*version:/ { has = 1 }' lib/skill-roots.sh
control 'counting the word version anywhere refuses a value holding it' package-form-word \
  "rc=2 ${ERR}version-read=$PKG" '/(^[ \t]*|[{,][ \t]*)["\047]?version["\047]?[ \t]*:/ { has = 1 }' '/version/ { has = 1 }' lib/skill-roots.sh
control 'a comment on the metadata line ending the block leaves its version unplaced' package-form-metadata-comment \
  "rc=2 ${ERR}version-read=$PKG" '/^metadata:[ \t]*($|[ \t]#)/' '/^metadata:[ \t]*$/' lib/skill-roots.sh
control 'a comment ending the metadata block leaves its version unplaced' package-form-comment \
  "rc=2 ${ERR}version-read=$PKG" '/^[ \t]*#/ { next }' '' lib/skill-roots.sh
if [ -r "/proc/$$/cmdline" ]; then
  gg_mutant judge changelog-entries '[ -z "$GG_COMMIT_BASE" ] || diff_args+=("$GG_COMMIT_BASE")' ':'
  amend_repo amend-head "$judge"
  assert_eq 'control: compared against HEAD the amend is refused' \
    "rc=1 ${ERR}package-unbumped=$PKG:1.1.0;$(summary 1 0)" "$(commit -q --amend --no-edit)"
fi

echo "=== --classify names what the settings make each path ==="
# One line per path, its kind and the path; the row reads the kinds in
# argument order. orch's restack-skip parses these lines.
classify() { # SCRIPT ENVS PATH...
  local script="$1" envs=() rc=0 out=""
  [ -z "$2" ] || IFS=',' read -ra envs <<<"$2"
  shift 2
  out="$(cd "$R" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" ${envs[@]+"${envs[@]}"} "$script" --classify "$@" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$out" | LC_ALL=C cut -f1 | LC_ALL=C paste -sd, -)"
}
repo classify
put CHANGELOG.md '# Changelog\n'
put changelog.d/fixed/a.md '- An entry.\n'
put pkg/package.json '{"version": "1.0.0"}\n'
put pkg/CHANGELOG.md '### Unreleased\n'
put skills/p/SKILL.md '---\nname: p\nmetadata:\n  version: "1.0.0"\n---\n'
put skills/p/deep/SKILL.md '---\nname: deep\nmetadata:\n  version: "1.0.0"\n---\n'
put .agents/skills/p/SKILL.md '---\nname: p\nmetadata:\n  version: "1.0.0"\n---\n'
put .kendex-generated.json '[".agents/skills/p/SKILL.md"]\n'
put code.sh 'echo\n'
stage
CLASSIFY_ENV='COMMIT_GUARDS_CHANGELOG_VERSION_PATHS=pkg/*.json,COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS=skills/*/SKILL.md'
CLASSIFY_PATHS='CHANGELOG.md changelog.d/fixed/a.md pkg/CHANGELOG.md pkg/package.json skills/p/SKILL.md .agents/skills/p/SKILL.md skills/p/deep/SKILL.md code.sh other/CHANGELOG.md'
CLASSIFY_WANT='rc=0 record,fragment,record,version,package,render,none,none,none'
# shellcheck disable=SC2086 # the path list, split on purpose
assert_eq 'the record, a fragment, a package record, a version file, a package file and a render are named, the rest none' \
  "$CLASSIFY_WANT" "$(classify "$CE" "$CLASSIFY_ENV" $CLASSIFY_PATHS)"
# shellcheck disable=SC2086
assert_eq 'with no version paths a package.json and its CHANGELOG.md are none' \
  'rc=0 none,none' "$(classify "$CE" 'COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS=skills/*/SKILL.md' pkg/CHANGELOG.md pkg/package.json)"
assert_eq '--classify beside a scope is refused' "rc=2 ${ERR}scope-conflict=1:0:1:0" "$(run "" '--staged --classify code.sh')"
# One control per rule: the mutant answers otherwise for the path that rule
# names.
R="$TMP/classify"
classify_control() { # LABEL FROM TO
  local got
  gg_mutant judge changelog-entries "$2" "$3"
  # shellcheck disable=SC2086
  got="$(classify "$judge" "$CLASSIFY_ENV" $CLASSIFY_PATHS)"
  if [ "$got" != "$CLASSIFY_WANT" ]; then
    PASS=$((PASS + 1))
    printf '  ok    control: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  control: %s\n        got the unmutated answer: %s\n' "$1" "$got"
  fi
}
classify_control 'with no package record pkg/CHANGELOG.md is none' \
  '&& package_record_of "$package_json" >/dev/null; then' '&& false; then'
classify_control 'a package glob matching across / declares the nested SKILL.md' \
  'elif gg_path_placer "$f" $GG_CHANGELOG_PACKAGES; then' 'elif gg_path_matches "$f" $GG_CHANGELOG_PACKAGES; then'
classify_control 'with no render inventory the render is none' 'elif generated_path_contains "$f"; then' 'elif false; then'

echo "=== --unversion drops only the version the bump check reads ==="
# The version file on stdin, less its top-level version; orch's restack-skip
# compares two sides through it, so the output is read as JSON, compacted.
unversion() { # SCRIPT INPUT
  local rc=0 out=""
  out="$(printf '%s' "$2" | (cd "$R" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$1" --unversion 2>/dev/null))" || rc=$?
  [ "$rc" -ne 0 ] || out="$(printf '%s' "$out" | jq -c .)" || out=unreadable
  printf 'rc=%s %s' "$rc" "$out"
}
# label|input|answer
UNVERSION_ROWS=(
  'the top-level version is dropped and an npm scripts.version kept|{"name":"p","version":"1.0.0","scripts":{"version":"echo v","test":"t"}}|rc=0 {"name":"p","scripts":{"version":"echo v","test":"t"}}'
  'a file with no top-level version is printed whole|{"name":"p","scripts":{"version":"echo v"}}|rc=0 {"name":"p","scripts":{"version":"echo v"}}'
  'a blob that is not JSON exits 2|{"name": "p",|rc=2 '
  'a JSON array exits 2|["version"]|rc=2 '
  'an empty blob exits 2||rc=2 '
)
for row in "${UNVERSION_ROWS[@]}"; do
  IFS='|' read -r label input want <<<"$row"
  assert_eq "$label" "$want" "$(unversion "$CE" "$input")"
done
assert_eq '--unversion beside a scope is refused' "rc=2 ${ERR}scope-conflict=1:0:0:1" "$(run "" '--staged --unversion')"
# Control: a filter that drops "version" at every depth turns the first row
# red, the copy restack-skip once carried.
gg_mutant judge changelog-entries '  jq -e "del($VERSION_FIELD)" \' "  jq -e 'walk(if type == \"object\" then del(.version) else . end)' \\"
IFS='|' read -r label input want <<<"${UNVERSION_ROWS[0]}"
got="$(unversion "$judge" "$input")"
if [ "$got" != "$want" ]; then
  PASS=$((PASS + 1))
  printf '  ok    control: a depth-free version filter changes: %s\n' "$label"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  control: a depth-free version filter leaves green: %s\n' "$label"
fi

echo "=== the usage is answered ==="
repo help
assert_eq "--help prints the usage and exits 0" "rc=0 changelog-entries: usage=changelog-entries" "$(run "" --help | cut -d';' -f1)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
