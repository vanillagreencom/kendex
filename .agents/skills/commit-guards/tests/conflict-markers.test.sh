#!/usr/bin/env bash
# Pins for scripts/conflict-markers: each of the open/base/close trio at
# column 0 fires naming file:line and the remedy, indented, quoted, mid-prose
# and glued occurrences and the seven-equals separator do not, an excludes
# row with a reason carves a path out and the list resolves through the
# setting and the flag, the check's own source never trips it, and a
# carrier the sniff skips is named and qualifies the verdict. Two tables:
# one file of CONTENT judged, and the runs over a built repository. A row
# runs the scan once and pins the exit status with every line printed, so
# the hit, its line, the remedy, the count, the excludes list named and
# the unmeasured qualifier are one pin. The index readers this family
# shares are index-reads.test.sh and lane-readers.test.sh.
#
# Marker runs are assembled with printf throughout, so this file never
# contains a marker shape itself: the kendex repository runs the check over
# its own tree, tests included. A base marker in a row's content is seven
# octal pipes, which printf %b renders and the row grammar never sees.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/conflict-markers"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_CONFLICT_EXCLUDES COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

mk7() { printf '%s%s%s%s%s%s%s' "$1" "$1" "$1" "$1" "$1" "$1" "$1"; }
OPEN="$(mk7 '<')"
BASE="$(mk7 '|')"
BASE_OCT="$(mk7 '\174')" # the base marker as a row writes it
CLOSE="$(mk7 '>')"
SEP="$(mk7 '=')"

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
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$CM" $2 2>&1)" || rc=$?
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
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged

# The lines the scan prints, as functions of what a row put in.
EXCL='tools/conflict-markers-excludes'
ERR="::error::conflict-markers: "
hit() { printf 'conflict-markers FAIL conflict marker: %s:%s:%s;  remedies: finish the merge and delete the marker lines; a file that legitimately carries the trio at column 0 belongs in %s with a reason' "$1" "$2" "$3" "${4:-$EXCL}"; } # PATH LINE TEXT [EXCLUDES]
skip() { printf 'conflict-markers: not measured: %s — binary content, not text' "$1"; } # PATH
unmeasured() { printf '; %s matched path(s) not measured' "$1"; } # N
clean() { printf 'conflict-markers: OK — no conflict markers in tracked files%s' "${1-}"; } # [UNMEASURED]
failed() { printf 'conflict-markers: %s conflict marker(s) — excludes %s%s' "$1" "${2:-$EXCL}" "${3-}"; } # N [EXCLUDES] [UNMEASURED]

# Table one: a.rs holds CONTENT in a fresh repository.
ROW=0
content_rows() { # label | content | expect
  local row label content expect
  for row in "$@"; do
    IFS='|' read -r label content expect <<<"$row"
    ROW=$((ROW + 1))
    R=""
    repo "content-$ROW"
    put a.rs "$content"
    assert_eq "$label" "$expect" "$(run '' '')"
  done
}

echo "=== each marker of the trio at column 0 fails naming file:line; indented, quoted, glued and the separator do not ==="
content_rows \
  "control: a clean file passes|fn main() {}\n|rc=0 $(clean)" \
  "the open marker with its label fails, naming file:line and carrying the remedy|$OPEN HEAD\n|rc=1 $(hit a.rs 1 "$OPEN HEAD");$(failed 1)" \
  "the bare base marker at the end of its line fails|$BASE_OCT\n|rc=1 $(hit a.rs 1 "$BASE");$(failed 1)" \
  "the close marker with its label fails|$CLOSE theirs\n|rc=1 $(hit a.rs 1 "$CLOSE theirs");$(failed 1)" \
  "a marker on the second line is named by its line|fn main() {}\n$OPEN HEAD\n|rc=1 $(hit a.rs 2 "$OPEN HEAD");$(failed 1)" \
  "the open and close markers of one conflict are two hits and a count of two|$OPEN HEAD\nours\n$SEP\ntheirs\n$CLOSE other\n|rc=1 $(hit a.rs 1 "$OPEN HEAD");$(hit a.rs 5 "$CLOSE other");$(failed 2)" \
  "a space-indented open marker does not fire| $OPEN HEAD\n|rc=0 $(clean)" \
  "a tab-indented close marker does not fire|\t$CLOSE theirs\n|rc=0 $(clean)" \
  "a base marker mid-prose does not fire|the $BASE_OCT run mid-prose\n|rc=0 $(clean)" \
  "a quoted open marker does not fire|quoted: \"$OPEN ours\"\n|rc=0 $(clean)" \
  "an open marker glued to text does not fire|${OPEN}x glued to text\n|rc=0 $(clean)" \
  "an eight-character run is not the seven-character marker|$OPEN< eight then a space\n|rc=0 $(clean)" \
  "the seven-equals separator alone never fires: a setext underline is valid markdown|Title\n$SEP\n|rc=0 $(clean)"

# Table two: FIXTURE (a function and its words) builds the repository; the
# scan runs with ARGS under ENVS.
run_rows() { # label | fixture | envs | args | expect
  local row label fx envs args expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(run "$envs" "$args")"
  done
}

echo "=== excludes: a declared path is exempt with a reason; the list resolves through the setting and the flag ==="
MERGE="$OPEN HEAD\nours\n$CLOSE theirs\n"
fixture() { repo "$1"; put fixtures/merge.txt "$MERGE"; } # NAME — a conflict under fixtures/
fx_excluded() { fixture excluded; put "$EXCL" 'fixtures/*\tmerge-conflict fixture data\n'; }
fx_no_reason() { fixture no-reason; put "$EXCL" 'fixtures/*\n'; }
alt() { fixture "$1"; put alt-excludes 'fixtures/*\tmerge-conflict fixture data\n'; } # NAME — the list at a non-default path
HITS="$(hit fixtures/merge.txt 1 "$OPEN HEAD");$(hit fixtures/merge.txt 3 "$CLOSE theirs");$(failed 2)"
run_rows \
  "control: the fixture conflict fails without an excludes row, naming both markers|fixture bare|||rc=1 $HITS" \
  "the excludes row silences the declared path|fx_excluded|||rc=0 $(clean)" \
  "a pattern without a tab-separated reason is exit 2 naming the line|fx_no_reason|||rc=2 ${ERR}$EXCL:1: expected 'pattern<TAB>reason' (every exclusion carries its justification)" \
  "the excludes path resolves through COMMIT_GUARDS_CONFLICT_EXCLUDES|alt alt-env|COMMIT_GUARDS_CONFLICT_EXCLUDES=alt-excludes||rc=0 $(clean)" \
  "--excludes FILE points at the same list|alt alt-flag||--excludes alt-excludes|rc=0 $(clean)" \
  "the equals form of --excludes resolves the same list|alt alt-eq||--excludes=alt-excludes|rc=0 $(clean)" \
  "control: without either the default path has no list and the conflict fails, the remedy naming the default list|alt alt-none|||rc=1 $HITS" \
  "--excludes without a path is exit 2|alt alt-bare||--excludes|rc=2 ${ERR}--excludes requires a path" \
  "an unknown flag is exit 2, quoting it|alt alt-unknown||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)"
assert_eq "--help prints usage at exit 0" "rc=0 usage: conflict-markers [--excludes FILE]" "$(run '' --help | LC_ALL=C cut -d';' -f1)"
assert_eq "-h is --help" "$(run '' --help)" "$(run '' -h)"

echo "=== the check's own source does not trip it; a carrier the sniff skips is named and qualifies the verdict ==="
fx_self() { repo "$1"; mkdir -p "$R/scripts"; cp "$CM" "$R/scripts/conflict-markers"; git -C "$R" add -A; } # NAME — the shipped script, tracked
fx_self_planted() { fx_self self-planted; put planted.txt "$OPEN HEAD\n"; }
# An asset whose bytes spell the open marker at column 0 behind a NUL in
# git's leading window: matched by the text-forced listing, refused by the
# content sniff. The same bytes without the NUL are text, and fire.
asset() { repo "$1"; put ok.rs 'fn main() {}\n'; put asset.png "\0211PNG\r\n\0032\n\0000\0000\n$OPEN HEAD\n"; } # NAME
fx_asset_planted() { asset asset-planted; put planted.txt "$CLOSE theirs\n"; }
fx_asset_text() { repo asset-text; put ok.rs 'fn main() {}\n'; put asset.png "\0211PNG\r\n\0032\n\n$OPEN HEAD\n"; }
# Premise: the self rows read a clean verdict, which an empty repository
# also gives, so the fixture must be shown to track the script.
fx_self self-premise
assert_eq "premise: the self fixture tracks the shipped script" "scripts/conflict-markers" "$(git -C "$R" ls-files scripts)"
run_rows \
  "the shipped script, tracked, scans clean: its patterns are interval-built|fx_self self|||rc=0 $(clean)" \
  "control: a planted marker fails while the script stays unnamed|fx_self_planted|||rc=1 $(hit planted.txt 1 "$OPEN HEAD");$(failed 1)" \
  "a clean verdict names the skipped carrier and says how many went unmeasured|asset asset|||rc=0 $(skip asset.png);$(clean "$(unmeasured 1)")" \
  "a violation verdict carries the same qualifier, the marker elsewhere deciding the exit|fx_asset_planted|||rc=1 $(skip asset.png);$(hit planted.txt 1 "$CLOSE theirs");$(failed 1 "$EXCL" "$(unmeasured 1)")" \
  "control: the same bytes without a NUL are read, fire on their line, and nothing goes unmeasured|fx_asset_text|||rc=1 $(hit asset.png 4 "$OPEN HEAD");$(failed 1)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
