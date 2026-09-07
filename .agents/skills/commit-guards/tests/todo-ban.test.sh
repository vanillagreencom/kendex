#!/usr/bin/env bash
# Pins for scripts/todo-ban, the flat ban on work markers: both marker
# shapes fire and prose that quotes or names a marker word does not, an
# exclusion row needs its reason and a `!` row carves a subtree back in,
# --staged judges the lines the commit ADDS from the index while the default
# scope judges the whole index, and a collection step that cannot run is a
# collection error, never a pass. One table: a row builds its own
# repository, stages what it means, runs the check once under its settings
# and reads back the exit status with every line printed, so the verdict,
# the file and line it names, the quoted line, the remedy and the summary
# are one pin. The index readers this family shares — the carriers
# pre-filter, the content sniff, the blob read — are pinned once in
# lane-readers.test.sh, which drives them through this check.
#
# Marker words are assembled from split tokens throughout so this file
# never contains a marker shape itself — the kendex repository runs
# todo-ban over its own tree, tests included.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TB="$SKILL_DIR/scripts/todo-ban"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_TODO_EXCLUDES COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

TD="TO""DO"
FX="FIX""ME"
HK="HA""CK"
XX="XX""X"

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
# line printed, in order, joined by ';'. SHIM is a directory put ahead of
# PATH (empty for the real tools); ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # SHIM ENVS ARGS
  local envs=() rc=0 out="" path="$PATH"
  [ -z "$1" ] || path="$1:$PATH"
  [ -z "$2" ] || IFS=',' read -ra envs <<<"$2"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env PATH="$path" ${envs[@]+"${envs[@]}"} "$TB" $3 2>&1)" || rc=$?
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
add() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >>"$R/$1"; } # PATH CONTENT, appended
stage() { git -C "$R" add -A; }
commit() { git -C "$R" commit -qm "${1:-seed}"; } # [MESSAGE]
seeded() { repo "$1"; put ok.rs 'fn main() {}\n'; stage; commit; } # NAME — one committed clean file
excl() { put tools/todo-ban-excludes "$1"; stage; } # ROWS — the exclusion list, staged

# The lines the check prints, as functions of what a row put in.
EXCL=tools/todo-ban-excludes
remedy() { printf '  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in %s with a reason' "${1:-$EXCL}"; } # [EXCLUDES]
hit() { printf 'todo-ban FAIL work marker: %s:%s:%s;%s' "$1" "$2" "$3" "$(remedy "${4:-}")"; } # PATH LINE CONTENT [EXCLUDES]
idx() { printf 'todo-ban: %s work marker(s) — excludes %s' "$1" "${2:-$EXCL}"; } # COUNT [EXCLUDES]
stg() { printf 'todo-ban: %s work marker(s) added by the staged diff — excludes %s' "$1" "${2:-$EXCL}"; } # COUNT [EXCLUDES]
OK_IDX="todo-ban: OK — no work markers in tracked files"
OK_STG="todo-ban: OK — the staged diff adds no work markers"
ERR="::error::todo-ban: "
NO_REASON="expected 'pattern<TAB>reason' (every exclusion carries its justification)"

run_rows() { # label | fixture | shim | env | args | expect
  local row label fx shim env args expect
  for row in "$@"; do
    IFS='|' read -r label fx shim env args expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than six fields: $row" >&2; exit 2; }
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$shim" "$env" "$args")"
  done
}

echo "=== both marker shapes fire, and prose that quotes or names a marker word does not ==="
fx_clean() { repo clean; put ok.rs 'fn main() {}\n'; stage; }
fx_colon() { repo colon; put a.rs "// $TD: wire this up\n"; stage; }
fx_paren() { repo paren; put a.rs "$FX(alice): assigned marker\n"; stage; }
fx_block() { repo block; put a.rs "code(); /* $HK: inline block */\n"; stage; }
fx_hash() { repo hash; put a.rs "# $TD implement the frobnicator\n"; stage; }
fx_glued() { repo glued; put a.rs "//$XX no space before the word\n"; stage; }
fx_leaders() { repo leaders; put a.rs "; $TD after a semicolon\n<!-- $FX after an HTML leader\n"; stage; }
# Each odd line reaches only the annotated arm (no leader), each even line
# only the after-a-leader arm (no colon), and line 6 is the one place the
# block-comment opener is the leader.
fx_four() { repo four; put a.rs "$TD: one\n//$TD two\n$FX(x): three\n//$FX four\n$HK: five\n/*$HK six\n$XX: seven\n//$XX eight\n"; stage; }
fx_prose() { repo prose; put a.rs "The $TD marker is banned in this repo.\n"; stage; }
fx_backticks() { repo backticks; put a.md "the \`$TD:\` shape and \`$FX(\` shape are banned\n"; stage; }
fx_joined() { repo joined; put a.sh "emit \"$TD:/$FX( marker without an issue reference\"\n"; stage; }
fx_escaped() { repo escaped; put a.sh "printf \"then\\\\n$TD: inside a literal\"\n"; stage; }
fx_lower() { repo lower; put a.rs '// todo: lowercase is prose, not a marker\n'; stage; }
fx_url() { repo url; put u.md "see http://$TD:8080/path for the mock\n"; stage; }
fx_url_control() { repo url-control; put u.md "see http://$TD:8080/path for the mock\nleft in: $TD: cleanup\n"; stage; }
run_rows \
  "control: a clean repository passes|fx_clean||||rc=0 $OK_IDX" \
  "a colon-annotated marker in a comment fails, naming file, line and the line itself, with the remedy|fx_colon||||rc=1 $(hit a.rs 1 "// $TD: wire this up");$(idx 1)" \
  "an attributed marker at line start fails|fx_paren||||rc=1 $(hit a.rs 1 "$FX(alice): assigned marker");$(idx 1)" \
  "an annotated marker inside a block comment fails|fx_block||||rc=1 $(hit a.rs 1 "code(); /* $HK: inline block */");$(idx 1)" \
  "a bare marker after a hash leader fails|fx_hash||||rc=1 $(hit a.rs 1 "# $TD implement the frobnicator");$(idx 1)" \
  "a bare marker glued to a slash leader fails|fx_glued||||rc=1 $(hit a.rs 1 "//$XX no space before the word");$(idx 1)" \
  "a semicolon and an HTML comment are leaders too|fx_leaders||||rc=1 $(hit a.rs 1 "; $TD after a semicolon");$(hit a.rs 2 "<!-- $FX after an HTML leader");$(idx 2)" \
  "each of the four words is a marker in each shape alone, and every hit is numbered|fx_four||||rc=1 $(hit a.rs 1 "$TD: one");$(hit a.rs 2 "//$TD two");$(hit a.rs 3 "$FX(x): three");$(hit a.rs 4 "//$FX four");$(hit a.rs 5 "$HK: five");$(hit a.rs 6 "/*$HK six");$(hit a.rs 7 "$XX: seven");$(hit a.rs 8 "//$XX eight");$(idx 8)" \
  "a bare word mid-prose, with no colon and no adjacent leader, passes|fx_prose||||rc=0 $OK_IDX" \
  "backtick-quoted marker shapes in a document pass|fx_backticks||||rc=0 $OK_IDX" \
  "quote- and slash-joined marker names in a string pass|fx_joined||||rc=0 $OK_IDX" \
  "a marker joined to an escape sequence in a literal passes|fx_escaped||||rc=0 $OK_IDX" \
  "a lowercase word is never a marker|fx_lower||||rc=0 $OK_IDX" \
  "a marker word inside a URL authority is not after a leader|fx_url||||rc=0 $OK_IDX" \
  "control: the same word after whitespace fires, at its own line|fx_url_control||||rc=1 $(hit u.md 2 "left in: $TD: cleanup");$(idx 1)"

echo "=== an exclusion row silences exactly what it names, with a reason; a ! row carves a subtree back in ==="
vendored() { repo "$1"; put vendor/lib.rs "// $TD: vendored upstream marker\n"; stage; } # NAME
fx_vendored() { vendored vendored; }
fx_vendored_row() { vendored vendored-row; excl 'vendor/*\tvendored third-party code\n'; }
fx_no_reason() { vendored no-reason; excl 'vendor/*\n'; }
fx_comment_rows() { vendored comment-rows; excl '# a note\n\nvendor/*\tvendored third-party code'; }
fx_empty_pattern() { vendored empty-pattern; excl '\ta reason with no pattern\n'; }
fx_alt_env() { vendored alt-env; put alt-excludes 'vendor/*\tvendored third-party code\n'; stage; }
fx_alt_flag() { vendored alt-flag; put alt-excludes 'vendor/*\tvendored third-party code\n'; stage; }
fx_alt_eq() { vendored alt-eq; put alt-excludes 'vendor/*\tvendored third-party code\n'; stage; }
fx_alt_none() { vendored alt-none; put alt-excludes 'vendor/*\tvendored third-party code\n'; stage; }
fx_flag_bare() { vendored flag-bare; }
fx_unknown() { vendored unknown; }
# A row is a shell glob against the whole path, so every `*` in it crosses
# `/`: a row anchored at a root does not exempt that name elsewhere, and the
# crossing shorthand silences the first-party tree of the same name too.
crossing() { repo "$1"; put vendor/thing/lib.rs "// $TD: vendored upstream marker\n"; put crates/thing/src/lib.rs "// $TD: our own marker\n"; stage; } # NAME
fx_anchored() { crossing anchored; excl 'vendor/thing/**\tvendored third-party code\n'; }
fx_shorthand() { crossing shorthand; excl '**/thing/**\tthe shorthand that crosses\n'; }
# A rendered install can only be named by a tree wildcard, so hand-written
# source inside it (a skill declared in-place) is carved back by a ! row,
# above or below the row it cuts into: a list is a set of rules.
carved() { repo "$1"; put .agents/skills/rendered/lib.rs "// $TD: a marker in the render\n"; put .agents/skills/in-place/lib.rs "// $TD: a marker in the source of record\n"; stage; } # NAME
BLANKET='.agents/**\tkendex render, governed at its source\n'
CARVE='!.agents/skills/in-place/**\tin-place skill: this tree IS the source\n'
fx_blanket() { carved blanket; excl "$BLANKET"; }
fx_carve() { carved carve; excl "$BLANKET$CARVE"; }
fx_carve_above() { carved carve-above; excl "$CARVE$BLANKET"; }
fx_carve_no_reason() { carved carve-no-reason; excl '.agents/**\tkendex render\n!.agents/skills/in-place/**\n'; }
fx_carve_bare() { carved carve-bare; excl '.agents/**\tkendex render\n!\ta carve with no pattern\n'; }
# `\!name` opens with a backslash, so it never reaches the carve arm, and
# the matcher reads it as the literal path.
fx_bang() { repo bang; put '!bang.rs' "// $TD: a marker under a bang-leading name\n"; excl '\\!bang.rs\tan escaped literal bang path\n'; }
# The list is read from the index: a work-tree edit of it governs nothing
# until staged.
listed() { repo "$1"; put v.rs "// $TD: vendored\n"; put tools/commit-guards-todo-excludes 'v.rs\tvendored fixture\n'; stage; : >"$R/tools/commit-guards-todo-excludes"; } # NAME
fx_list_index() { listed list-index; }
fx_list_staged() { listed list-staged; git -C "$R" add tools/commit-guards-todo-excludes; }
ALT=COMMIT_GUARDS_TODO_EXCLUDES=alt-excludes
run_rows \
  "control: the vendored marker fails without a row, and the remedy names the default list|fx_vendored||||rc=1 $(hit vendor/lib.rs 1 "// $TD: vendored upstream marker");$(idx 1)" \
  "the row silences exactly the vendored tree|fx_vendored_row||||rc=0 $OK_IDX" \
  "a row without a tab-separated reason is a config error naming the line|fx_no_reason||||rc=2 ${ERR}$EXCL:1: $NO_REASON" \
  "a comment row and a blank row are skipped, and the last row is read without its newline|fx_comment_rows||||rc=0 $OK_IDX" \
  "a reason with no pattern before its tab is the same config error|fx_empty_pattern||||rc=2 ${ERR}$EXCL:1: $NO_REASON" \
  "the list path resolves through the environment key, and the verdict names that list|fx_alt_env||$ALT||rc=0 $OK_IDX" \
  "--excludes names the same list|fx_alt_flag|||--excludes alt-excludes|rc=0 $OK_IDX" \
  "--excludes=PATH is the same flag|fx_alt_eq|||--excludes=alt-excludes|rc=0 $OK_IDX" \
  "control: without either, the default path has no file and the marker fails|fx_alt_none||||rc=1 $(hit vendor/lib.rs 1 "// $TD: vendored upstream marker");$(idx 1)" \
  "--excludes with no path is a config error|fx_flag_bare|||--excludes|rc=2 ${ERR}--excludes requires a path" \
  "an unknown argument is a config error quoting it|fx_unknown|||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)" \
  "a row anchored at a root silences its own tree and not the first-party tree of the same name|fx_anchored||||rc=1 $(hit crates/thing/src/lib.rs 1 "// $TD: our own marker");$(idx 1)" \
  "must-fail control: the crossing shorthand silences the first-party tree too|fx_shorthand||||rc=0 $OK_IDX" \
  "control: the blanket row alone silences both planted markers|fx_blanket||||rc=0 $OK_IDX" \
  "a ! row carves its subtree back into the scanned set, and the sibling render stays silent|fx_carve||||rc=1 $(hit .agents/skills/in-place/lib.rs 1 "// $TD: a marker in the source of record");$(idx 1)" \
  "a carve above the row it cuts into carves just the same|fx_carve_above||||rc=1 $(hit .agents/skills/in-place/lib.rs 1 "// $TD: a marker in the source of record");$(idx 1)" \
  "a carve row without a reason is the same config error as any other|fx_carve_no_reason||||rc=2 ${ERR}$EXCL:2: $NO_REASON" \
  "a bare ! row is a config error naming its line|fx_carve_bare||||rc=2 ${ERR}$EXCL:2: '!' carves matching paths back into the scanned set and needs a pattern after it" \
  "an escaped row excludes the literal bang path rather than carving it|fx_bang||||rc=0 $OK_IDX" \
  "the staged list governs though the work-tree copy dropped the row|fx_list_index||COMMIT_GUARDS_TODO_EXCLUDES=tools/commit-guards-todo-excludes||rc=0 $OK_IDX" \
  "control: staging the emptied list re-exposes the marker|fx_list_staged||COMMIT_GUARDS_TODO_EXCLUDES=tools/commit-guards-todo-excludes||rc=1 $(hit v.rs 1 "// $TD: vendored" tools/commit-guards-todo-excludes);$(idx 1 tools/commit-guards-todo-excludes)"

echo "=== --staged judges the lines the commit adds, read from the index, not the whole tree ==="
# Someone else's marker, committed and untouched by the commit under judgement.
scoped() { seeded "$1"; put fixture.rs "// $TD: left in a fixture\n"; stage; commit fixture; add ok.rs 'fn other() {}\n'; git -C "$R" add ok.rs; } # NAME
fx_scope() { scoped scope; }
fx_scope_index() { scoped scope-index; }
fx_scope_adds() { scoped scope-adds; add ok.rs "// $FX: added by this commit\n"; git -C "$R" add ok.rs; }
# Two hunks in one file: the line numbers come from each hunk header, so the
# second marker is numbered past the first insertion.
fx_two_hunks() { repo two-hunks; local i; for i in 1 2 3 4 5 6 7 8 9 10; do add ten.rs "fn f$i() {}\n"; done; stage; commit; put ten.rs "fn f1() {}\nfn f2() {}\n// $TD: after two\nfn f3() {}\nfn f4() {}\nfn f5() {}\nfn f6() {}\nfn f7() {}\nfn f8() {}\n// $HK: after eight\nfn f9() {}\nfn f10() {}\n"; stage; }
walked() { seeded "$1"; add ok.rs "// $TD: staged\n"; git -C "$R" add ok.rs; put ok.rs 'fn main() {}\n'; } # NAME — the work tree walks it back; the index still carries it
# The index blob keeps a second marker so the path stays a carrier and the
# parser really runs over a hunk that only removes.
fx_removed() { seeded removed; add ok.rs "// $TD: one\n// $TD: two\n"; stage; commit two; put ok.rs "fn main() {}\n// $TD: two\n"; git -C "$R" add ok.rs; }
fx_walked() { walked walked; }
fx_walked_staged() { walked walked-staged; git -C "$R" add ok.rs; }
fx_first() { repo first; put a.rs "// $TD: in the very first commit\n"; stage; }
# The blob carries a committed marker, so the pre-filter lists the path and
# the per-file scan really runs over the one lowercase line this commit adds.
fx_staged_lower() { seeded staged-lower; add ok.rs "// $TD: committed\n"; stage; commit marker; add ok.rs '// todo: lowercase is prose here too\n'; git -C "$R" add ok.rs; }
fx_first_clean() { repo first-clean; put a.rs 'fn main() {}\n'; stage; }
staged_vendored() { seeded "$1"; put vendor/lib.rs "// $TD: vendored upstream marker\n"; stage; } # NAME
fx_staged_vendored() { staged_vendored staged-vendored; }
fx_staged_vendored_row() { staged_vendored staged-vendored-row; excl 'vendor/*\tvendored third-party code\n'; }
# A symlink's blob is its target path and a gitlink has no blob here; the
# pre-filter never lists either (git grep reads no symlink and no gitlink),
# so the walk's mode arm is never reached and these pin the verdict alone.
fx_staged_link() { seeded staged-link; ln -s "$TD: target" "$R/link.rs"; stage; }
fx_staged_gitlink() { seeded staged-gitlink; git -C "$R" update-index --add --cacheinfo 160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,sub; }
# ls-files -s lists an unmerged path once per stage; the lane refuses the
# index before reading anything.
fx_unmerged() {
  seeded unmerged
  git -C "$R" checkout -qb other
  put ok.rs 'fn theirs() {}\n'
  stage
  commit theirs
  git -C "$R" checkout -q main
  put ok.rs 'fn ours() {}\n'
  stage
  commit ours
  git -C "$R" merge -q other >/dev/null 2>&1 || true
}
run_rows \
  "a commit adding no marker passes on a repository whose index holds one|fx_scope|||--staged|rc=0 $OK_STG" \
  "control: the index scan still refuses that same marker|fx_scope_index||||rc=1 $(hit fixture.rs 1 "// $TD: left in a fixture");$(idx 1)" \
  "a marker the staged diff adds is refused at the line it lands on, and the untouched fixture stays out of the verdict|fx_scope_adds|||--staged|rc=1 $(hit ok.rs 3 "// $FX: added by this commit");$(stg 1)" \
  "a second hunk is numbered from its own header|fx_two_hunks|||--staged|rc=1 $(hit ten.rs 3 "// $TD: after two");$(hit ten.rs 10 "// $HK: after eight");$(stg 2)" \
  "staged bytes decide, whatever the work tree says now|fx_walked|||--staged|rc=1 $(hit ok.rs 2 "// $TD: staged");$(stg 1)" \
  "control: staging the walked-back file clears it|fx_walked_staged|||--staged|rc=0 $OK_STG" \
  "a marker the commit removes is not a line it adds|fx_removed|||--staged|rc=0 $OK_STG" \
  "with no HEAD to diff against, the whole staged tree reads as added|fx_first|||--staged|rc=1 $(hit a.rs 1 "// $TD: in the very first commit");$(stg 1)" \
  "control: a clean first commit passes rather than erroring for want of a HEAD|fx_first_clean|||--staged|rc=0 $OK_STG" \
  "a lowercase word the commit adds to a marker-carrying file is prose in this scope too|fx_staged_lower|||--staged|rc=0 $OK_STG" \
  "control: a staged vendored marker fails without a row|fx_staged_vendored|||--staged|rc=1 $(hit vendor/lib.rs 1 "// $TD: vendored upstream marker");$(stg 1)" \
  "the row silences the staged vendored tree too|fx_staged_vendored_row|||--staged|rc=0 $OK_STG" \
  "a staged symlink whose target spells a marker has no lines to read|fx_staged_link|||--staged|rc=0 $OK_STG" \
  "a staged gitlink has no lines to read|fx_staged_gitlink|||--staged|rc=0 $OK_STG" \
  "an unmerged index is refused before the walk|fx_unmerged|||--staged|rc=2 ok.rs;${ERR}the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"

echo "=== content decides what --staged reads: never an attribute, never a name ==="
# A committed '-diff' rule makes git call every .rs file binary, so the
# unforced staged diff carries no hunks; the fixture proves the rule took.
attributed() { # NAME
  seeded "$1"
  put .gitattributes '*.rs -diff\n'
  stage
  commit attrs
  add ok.rs "// $TD: behind an attributes rule\n"
  git -C "$R" add ok.rs
  case "$(git -C "$R" diff --cached -- ok.rs)" in
    *"Binary files"*) ;;
    *) echo "harness: fixture $1: the attributes rule did not suppress the staged diff" >&2; exit 2 ;;
  esac
}
fx_attr() { attributed attr; }
# The marker committed, then a clean addition under the same rule: the
# index blob still carries a marker, so the pre-filter lists the path and
# the forced diff really runs, and the verdict is the one line this commit
# adds.
fx_attr_clean() { attributed attr-clean; commit "the marker, now committed"; add ok.rs 'fn clean() {}\n'; git -C "$R" add ok.rs; }
# A real asset whose bytes spell a marker: the pre-filter lists it (no -I),
# and the content sniff — a NUL in the leading bytes, git's own test — keeps
# it out of the verdict, named as unmeasured. The same bytes without the
# NULs are text, and text is read whatever it is called.
fx_binary() { seeded binary; put asset.png "\\0211PNG\\r\\n\\032\\n\\0000\\0000 $TD: in the pixels\\n"; git -C "$R" add asset.png; }
fx_binary_control() { seeded binary-control; put asset.png "\\0211PNG\\r\\n\\032\\n $TD: in the pixels\\n"; git -C "$R" add asset.png; }
# A violation and a skipped carrier in one run: the qualifier rides on the
# violation summary too, in each lane.
fx_binary_beside() { seeded binary-beside; put asset.png "\\0211PNG\\r\\n\\032\\n\\0000\\0000 $TD: in the pixels\\n"; add ok.rs "// $TD: beside the asset\\n"; stage; }
fx_binary_beside_index() { seeded binary-beside-index; put asset.png "\\0211PNG\\r\\n\\032\\n\\0000\\0000 $TD: in the pixels\\n"; add ok.rs "// $TD: beside the asset\\n"; stage; }
# git's window is 8000 bytes: a NUL past it leaves the blob text for git
# (`diff --numstat` counts lines rather than printing '-'), so the sniff
# must read it too, or a marker that fails the index scan passes the commit.
fx_late_nul() {
  seeded late-nul
  { head -c 8050 /dev/zero | LC_ALL=C tr '\000' 'x'; printf '\000\n// %s: past the 8000-byte window\n' "$TD"; } >"$R/late-nul.rs"
  git -C "$R" add late-nul.rs
  [ "$(git -C "$R" diff --cached --numstat -- late-nul.rs | cut -f1)" = 2 ] \
    || { echo "harness: fixture late-nul: git does not call the late-NUL blob text" >&2; exit 2; }
}
# A symlink-to-file change emits a deletion section and a creation section
# for the one path, the creation header between them at the deletion
# hunk's numbering; the path itself spells a marker shape, so a header read
# as content fires.
typechanged() { seeded "$1"; ln -s ok.rs "$R/a $TD: x.md"; stage; commit; rm -- "$R/a $TD: x.md"; put "a $TD: x.md" "$2"; stage; } # NAME CONTENT
fx_type_clean() { typechanged type-clean 'fn clean() {}\n'; }
fx_type_marker() { typechanged type-marker "// $FX: added with the regular file\nfn clean() {}\n"; }
# Rename detection held to EXACT content: a file that moved AND changed
# arrives as an addition and is read whole; a pure move adds no line.
fx_moved() { repo moved; local i=1; while [ "$i" -le 40 ]; do add old.rs "fn f$i() {}\n"; i=$((i + 1)); done; stage; commit; git -C "$R" mv old.rs new.rs; add new.rs "// $TD: added in the move\n"; git -C "$R" add new.rs; }
pure_move() { repo "$1"; put legacy.rs "// $TD: committed long ago\n"; stage; commit; git -C "$R" mv legacy.rs moved.rs; } # NAME
fx_pure_move() { pure_move pure-move; }
fx_pure_move_index() { pure_move pure-move-index; }
run_rows \
  "a marker added under a non-diffable path is refused, at its own line|fx_attr|||--staged|rc=1 $(hit ok.rs 2 "// $TD: behind an attributes rule");$(stg 1)" \
  "control: a clean addition to a marker-carrying file under the same rule passes, the committed marker out of this commit's verdict|fx_attr_clean|||--staged|rc=0 $OK_STG" \
  "a genuinely binary blob whose bytes spell a marker is named as unmeasured and carried into the verdict|fx_binary|||--staged|rc=0 todo-ban: not measured: asset.png — binary content, not text;$OK_STG; 1 matched path(s) not measured" \
  "control: the same bytes without a NUL are text, and fire|fx_binary_control|||--staged|rc=1 $(hit asset.png 3 " $TD: in the pixels");$(stg 1)" \
  "a skipped carrier qualifies a violation verdict too|fx_binary_beside|||--staged|rc=1 todo-ban: not measured: asset.png — binary content, not text;$(hit ok.rs 2 "// $TD: beside the asset");$(stg 1); 1 matched path(s) not measured" \
  "and the index lane's violation verdict the same way|fx_binary_beside_index||||rc=1 todo-ban: not measured: asset.png — binary content, not text;$(hit ok.rs 2 "// $TD: beside the asset");$(idx 1); 1 matched path(s) not measured" \
  "a NUL past git's 8000-byte window leaves the blob text, and it fires|fx_late_nul|||--staged|rc=1 $(hit late-nul.rs 2 "// $TD: past the 8000-byte window");$(stg 1)" \
  "a type change to a clean regular file passes: a marker shape in the path is not content|fx_type_clean|||--staged|rc=0 $OK_STG" \
  "a marker in the new regular file fires at its own line, the section header and the clean line beside it never records|fx_type_marker|||--staged|rc=1 $(hit "a $TD: x.md" 1 "// $FX: added with the regular file");$(stg 1)" \
  "a file that moved and gained a marker is read whole, at its new path|fx_moved|||--staged|rc=1 $(hit new.rs 41 "// $TD: added in the move");$(stg 1)" \
  "a pure move of a committed marker adds no line, so it passes|fx_pure_move|||--staged|rc=0 $OK_STG" \
  "control: the index scan still refuses that marker at its new path|fx_pure_move_index||||rc=1 $(hit moved.rs 1 "// $TD: committed long ago");$(idx 1)"

echo "=== fail-closed: a collection step that cannot run is exit 2, never a pass and never a violation ==="
# One shim per collection step, so each error path is proven on its own.
REAL_GIT="$(command -v git)"
REAL_AWK="$(command -v awk)"
diff_shim() { # DIR MATCH — a git whose `diff` fails when MATCH is in argv
  mkdir -p "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
saw_diff=0
saw_match=0
for a in "\$@"; do
  [ "\$a" = "diff" ] && saw_diff=1
  [ "\$a" = "$2" ] && saw_match=1
done
if [ "\$saw_diff" = 1 ] && [ "\$saw_match" = 1 ]; then
  echo "git diff: simulated execution failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$1/git"
}
diff_shim "$TMP/raw-shim" --raw
diff_shim "$TMP/hunk-shim" -U0
# The awk shim exits 1 on purpose: 1 is this family's "violations", so a
# parser status read as the lane's own would fold a measurement that never
# ran into a violation verdict.
mkdir -p "$TMP/awk-shim"
cat >"$TMP/awk-shim/awk" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *hunk*)
      echo "awk: simulated hunk-parser failure" >&2
      exit 1
      ;;
  esac
done
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$TMP/awk-shim/awk"
# The per-file grep exits 2 on purpose: 1 is "no marker in this file's
# additions", so a 2 read as a 1 would skip the file silently.
REAL_GREP="$(command -v grep)"
mkdir -p "$TMP/grep-shim"
cat >"$TMP/grep-shim/grep" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" != "-aE" ] || { echo "grep: simulated scan failure" >&2; exit 2; }
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$TMP/grep-shim/grep"
fx_shim_clean() { seeded shim-clean; add ok.rs 'fn other() {}\n'; git -C "$R" add ok.rs; }
fx_shim_raw() { seeded shim-raw; add ok.rs 'fn other() {}\n'; git -C "$R" add ok.rs; }
# The per-file read and the parser are reached only for a path the
# pre-filter named, so these stage a marker to give the shim a file to fail on.
marked() { seeded "$1"; add ok.rs "// $TD: staged for the per-file read\n"; git -C "$R" add ok.rs; } # NAME
fx_shim_control() { marked shim-control; }
fx_shim_hunk() { marked shim-hunk; }
fx_shim_awk() { marked shim-awk; }
fx_shim_grep() { marked shim-grep; }
# The carriers pre-filter is chunked at 256 paths; a chunk that overwrote
# its predecessors would drop the carrier named by a prior one and print
# OK. This repository's render-propagation commits stage several hundred
# files at a time.
fx_chunked() { seeded chunked; put a000.rs "// $TD: in the first chunk\n"; local i=1; while [ "$i" -lt 300 ]; do put "$(printf 'a%03d' "$i").rs" "fn f$i() {}\n"; i=$((i + 1)); done; stage; }
run_rows \
  "shim-free control: the clean fixture passes with the real git|fx_shim_clean|||--staged|rc=0 $OK_STG" \
  "a failed change-set collection is exit 2 carrying git's own line|fx_shim_raw|$TMP/raw-shim||--staged|rc=2 git diff: simulated execution failure;${ERR}could not collect the staged changes (git diff --cached --raw failed)" \
  "shim-free control: the staged marker fires with the real tools|fx_shim_control|||--staged|rc=1 $(hit ok.rs 2 "// $TD: staged for the per-file read");$(stg 1)" \
  "a file whose added lines cannot be read is exit 2, naming it|fx_shim_hunk|$TMP/hunk-shim||--staged|rc=2 git diff: simulated execution failure;${ERR}could not read the staged additions in 'ok.rs' (git diff exit 128)" \
  "a hunk parser that fails is exit 2 naming the file, with no violation and no OK|fx_shim_awk|$TMP/awk-shim||--staged|rc=2 awk: simulated hunk-parser failure;${ERR}could not parse the staged additions in 'ok.rs' (awk exit 1)" \
  "a per-file scan that fails is exit 2 naming the file, never a file skipped|fx_shim_grep|$TMP/grep-shim||--staged|rc=2 grep: simulated scan failure;${ERR}could not scan the staged additions in 'ok.rs' (grep exit 2)" \
  "a marker in the first of 300 staged paths survives every later chunk|fx_chunked|||--staged|rc=1 $(hit a000.rs 1 "// $TD: in the first chunk");$(stg 1)"

echo "=== the usage is answered ==="
repo help
assert_eq "--help prints the usage and exits 0" "rc=0 usage: todo-ban [--staged] [--excludes FILE]" "$(run "" "" --help | cut -d';' -f1)"
assert_eq "-h is the same flag" "$(run "" "" --help)" "$(run "" "" -h)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
