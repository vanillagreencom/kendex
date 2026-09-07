#!/usr/bin/env bash
# Pins for scripts/md-reflow, the remedy md-format names: over a corpus of
# shapes a reflowed file is the bytes the format asks for, passes md-format,
# and reflows to itself again; the constructs the format leaves alone come
# out byte-identical; a clean file is untouched; CRLF and an open construct
# are refused with nothing written; --check writes nothing; a path resolves
# from the invoking directory inside the repository; --staged and --all
# select the files md-format would judge. Two tables: the corpus, and the
# runs over a built repository. A row runs the tool once and pins the exit
# status with every line printed, then the state it left behind.
set -euo pipefail
# No globbing: a row's ARGS column is word-split into the tool's arguments.
set -f
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDR="$SKILL_DIR/scripts/md-reflow"
MDF="$SKILL_DIR/scripts/md-format"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_MD_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

# One line for a run in $R: the exit status, then every line printed, in
# order, joined by ';'. ENVS is a comma-separated list of assignments; ARGS
# are passed through. TOOL is the script to run.
R=""
run() { # ENVS ARGS [TOOL]
  local envs=() rc=0 out="" tool="${3:-$MDR}"
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$tool" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused. `write` leaves the work tree only; `put` stages too.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
write() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; } # PATH CONTENT (printf %b)
put() { write "$1" "$2"; git -C "$R" add -A; }
commit() { git -C "$R" commit -qm "$1"; }
WRAPPED='Wrapped\ntext.\n'

# The state a row reads back after its run, rendered as one token each.
bytes() { local b; b="$(cat -- "$R/$1"; printf x)"; printf '%s=%q' "$1" "${b%x}"; } # PATH — the file's bytes, %q-rendered
mtime() { printf 'mtime=%s' "$(stat -c %Y -- "$R/$1" 2>/dev/null || stat -f %m -- "$R/$1")"; } # PATH
leftovers() { printf 'leftovers=%s' "$(find "$R" -maxdepth 1 -type f ! -name doc.md | LC_ALL=C sort | paste -sd ',' -)"; }
format_all() { git -C "$R" add -A; printf 'format:%s' "$(run '' --all "$MDF")"; } # the judge over what the row staged
q() { local b; b="$(printf '%b' "$1"; printf x)"; printf '%q' "${b%x}"; } # CONTENT — its bytes, %q-rendered

# The lines the tool prints, as functions of what a row put in.
ERR="::error::md-reflow: "
reflowed() { local n=$1 t=$2; shift 2; printf 'md-reflow: reflowed %s;' "$@"; printf 'md-reflow: %s of %s file(s) rewritten' "$n" "$t"; } # N T PATH...
unchanged() { printf 'md-reflow: 0 of %s file(s) rewritten' "$1"; } # T
would() { local n=$1 t=$2; shift 2; printf 'md-reflow: would reflow %s;' "$@"; printf 'md-reflow: %s of %s file(s) would change' "$n" "$t"; } # N T PATH...
in_format() { printf 'md-reflow: OK — %s file(s) already in the format' "$1"; } # T
refused() { printf '%s%s:%s: %s — refused, nothing written' "$ERR" "$1" "$2" "$3"; } # PATH LINE REASON
FORMAT_OK="format:rc=0 md-format: OK — 1 tracked markdown file(s) clean"

# Table one: doc.md holds CONTENT in a fresh repository; one reflow, then
# the bytes it left, md-format's verdict over them, and a --check pass that
# must find nothing more to do. A row whose WANT equals its CONTENT pins the
# clean file's untouched verdict instead.
ROW=0
corpus_rows() { # label | content | want
  local row label content want expect verdict
  for row in "$@"; do
    IFS='|' read -r label content want <<<"$row"
    ROW=$((ROW + 1))
    R=""
    repo "corpus-$ROW"
    write doc.md "$content"
    if [ "$(printf '%b' "$content")" = "$(printf '%b' "$want")" ]; then verdict="rc=0 $(unchanged 1)"; else verdict="rc=0 $(reflowed 1 1 doc.md)"; fi
    expect="$verdict / doc.md=$(q "$want") / $FORMAT_OK / rc=0 $(in_format 1)"
    assert_eq "$label" "$expect" "$(run '' doc.md) / $(bytes doc.md) / $(format_all) / $(run '' '--check doc.md')"
  done
}

echo "=== joining: paragraphs, list items, blockquotes, trailing breaks ==="
corpus_rows \
  "a hard-wrapped paragraph joins with single spaces, trailing space dropped|First line  \nsecond line   \n  third.\n|First line second line third.\n" \
  "a continued list item joins, and its nested item stays an item|- item one\n  continued\n  - nested\n    continued too\n- item two\n|- item one continued\n  - nested continued too\n- item two\n" \
  "an ordered item joins|1. first\n   continued\n2. second\n|1. first continued\n2. second\n" \
  "a blockquote paragraph joins, lazy continuation included|> quoted\n> continued\nlazy\n\n> next\n|> quoted continued lazy\n\n> next\n" \
  "a multi-paragraph item joins each paragraph on its own|- item\n\n  second\n  paragraph\n|- item\n\n  second paragraph\n"

echo "=== separating: the blank line before a heading, fence or list ==="
corpus_rows \
  "a heading under a paragraph gets its blank line, before and after|Para\n# Heading\nMore\n|Para\n\n# Heading\n\nMore\n" \
  "a fence under a paragraph gets its blank line, and one after the closer|Para\n\`\`\`sh\nwrapped\ncode\n\`\`\`\nAfter\n|Para\n\n\`\`\`sh\nwrapped\ncode\n\`\`\`\n\nAfter\n" \
  "a list under a paragraph gets its blank line|Para\n- item\n|Para\n\n- item\n" \
  "a fence directly under a list item gets its blank line, inside the item|- item\n  \`\`\`\n  code\n  \`\`\`\n|- item\n\n  \`\`\`\n  code\n  \`\`\`\n" \
  "a heading inside a blockquote gets a quoted blank line|> para\n> # heading\n|> para\n>\n> # heading\n" \
  "a heading gets its blank line before a table, a break, an HTML comment and a definition|# H\n\174 a \174\n\174---\174\n\n# I\n---\n\n# J\n<!-- x -->\n\n# K\n[a]: x\n|# H\n\n\174 a \174\n\174---\174\n\n# I\n\n---\n\n# J\n\n<!-- x -->\n\n# K\n\n[a]: x\n" \
  "a fence closer gets its blank line before a table|\`\`\`\nx\n\`\`\`\n\174 a \174\n\174---\174\n|\`\`\`\nx\n\`\`\`\n\n\174 a \174\n\174---\174\n" \
  "a heading beside a change of quote depth gets a blank line at the shallower depth|# H\n> q\n\n> p\n# I\n\n> # J\n>> deeper\n\n> # K\nafter\n|# H\n\n> q\n\n> p\n\n# I\n\n> # J\n>\n>> deeper\n\n> # K\n\nafter\n" \
  "a definition split over two lines joins into the one-line form|[ref]:\n  http://x\n|[ref]: http://x\n"

echo "=== byte-identical: fences, tables, HTML, indented code, front matter ==="
corpus_rows \
  "a fence keeps every line, backtick and tilde alike|\`\`\`\nwrapped\n  lines\n\n# not heading\n\`\`\`\n\n~~~\nmore\nlines\n~~~\n|\`\`\`\nwrapped\n  lines\n\n# not heading\n\`\`\`\n\n~~~\nmore\nlines\n~~~\n" \
  "a table keeps its rows, and a table under a paragraph is a boundary|Para\n\174 a \174 b \174\n\174---\174---\174\n\174 c \174 d \174\n|Para\n\174 a \174 b \174\n\174---\174---\174\n\174 c \174 d \174\n" \
  "a details block keeps its lines|<details>\n<summary>x</summary>\nwrapped\nlines\n\ninside\n</details>\n|<details>\n<summary>x</summary>\nwrapped\nlines\n\ninside\n</details>\n" \
  "a prompt-section block keeps its lines, blank lines included, to its closing tag|Para\n\n<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n\nAfter\nwrapped\n|Para\n\n<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n\nAfter wrapped\n" \
  "a prompt-section block indented under a list item keeps its lines|1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n|1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n" \
  "control: a prompt-section opener sharing its line with prose is a paragraph line|<delegation_format> Do it.\nwrapped\n\nWorktree: [W]\n\n</delegation_format>\n|<delegation_format> Do it. wrapped\n\nWorktree: [W]\n\n</delegation_format>\n" \
  "a table without outer pipes keeps its rows, and a row after it without a pipe is a row|Para\n\na \174 b\n--\174--\n1 \174 2\nrow\n\nAfter\n|Para\n\na \174 b\n--\174--\n1 \174 2\nrow\n\nAfter\n" \
  "control: a pipe line over a plain dash line is a setext heading, and one over prose a wrap|a \174 b\n---\n\na \174 b\nc \174 d\n|a \174 b\n---\n\na \174 b c \174 d\n" \
  "indented code keeps its lines|Para\n\n    code\n    more\n|Para\n\n    code\n    more\n" \
  "front matter keeps its lines|---\ntitle: x\nwrapped:\n  y\n---\n\nPara\n|---\ntitle: x\nwrapped:\n  y\n---\n\nPara\n" \
  "reference definitions keep their lines|[a]: https://x\n[b]: y.md\n|[a]: https://x\n[b]: y.md\n" \
  "a setext heading keeps its underline, and a wrapped one joins above it|Heading\n=======\n\nPara\n\nTwo line\nheading\n---\n|Heading\n=======\n\nPara\n\nTwo line heading\n---\n" \
  "a setext underline followed by prose is a heading, and the prose gets its blank line|Two line\nheading\n---\nNext para\n|Two line heading\n---\n\nNext para\n" \
  "a file without a trailing newline stays without one|Para|Para"

# Table two: FIXTURE (a function and its words) builds the repository; the
# tool runs with ARGS under ENVS; STATE names a function whose tokens are
# read back after the run.
run_rows() { # label | fixture | envs | args | state | expect
  local row label fx envs args state expect words actual
  for row in "$@"; do
    IFS='|' read -r label fx envs args state expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    actual="$(run "$envs" "$args")"
    [ -z "$state" ] || actual="$actual / $("$state")"
    assert_eq "$label" "$expect" "$actual"
  done
}

echo "=== a clean file is untouched, and --check says so without writing ==="
# The clean file's mtime is set, in UTC, so the pin is that value, not the clock.
clean_file() { repo "$1"; write clean.md 'Clean.\n\n- item\n'; TZ=UTC touch -t 200001010000 "$R/clean.md"; }
fx_check_pair() { clean_file check-pair; write wrapped.md "$WRAPPED"; }
st_clean() { bytes clean.md; printf ' '; mtime clean.md; }
st_wrapped() { bytes wrapped.md; }
run_rows \
  "a clean file is reported unchanged, its bytes stand, and it was not rewritten in place (mtime stands)|clean_file clean||clean.md|st_clean|rc=0 $(unchanged 1) / clean.md=$(q 'Clean.\n\n- item\n') mtime=946684800" \
  "--check names the file a reflow would change, exits 1 and writes nothing|fx_check_pair||--check wrapped.md clean.md|st_wrapped|rc=1 $(would 1 2 wrapped.md) / wrapped.md=$(q "$WRAPPED")" \
  "control: --check over a clean file exits 0|clean_file check-clean||--check clean.md||rc=0 $(in_format 1)"

echo "=== refusals: CRLF, an open construct, a symlink, a missing file, no path, a path beside a scope ==="
fx_crlf() { repo crlf; write crlf.md 'Line one\r\nLine two\r\n'; }
fx_open() { repo open; write open.md 'Para\n\n```\nopen\n'; }
fx_section() { repo section; write section.md 'Para\n\n<output_format>\nprose\n\nmore\n'; }
fx_symlink() { clean_file symlink; ln -s clean.md "$R/link.md"; }
fx_nul() { repo nul; write bin.md 'lead\0000Wrapped\ntext.\n'; }
fx_gone() { repo gone; put doc.md "$WRAPPED"; rm -- "$R/doc.md"; } # staged, then removed from the work tree
st_crlf() { bytes crlf.md; }
st_open() { bytes open.md; }
st_section() { bytes section.md; }
run_rows \
  "a CRLF file is refused at exit 2, naming the line, and is not converted|fx_crlf||crlf.md|st_crlf|rc=2 $(refused crlf.md 1 'a CRLF line ending') / crlf.md=$(q 'Line one\r\nLine two\r\n')" \
  "an unterminated fence is refused at exit 2, nothing written|fx_open||open.md|st_open|rc=2 $(refused open.md 3 'an unterminated fence') / open.md=$(q 'Para\n\n```\nopen\n')" \
  "a prompt-section block with no closing tag is refused at exit 2, naming the opener, nothing written|fx_section||section.md|st_section|rc=2 $(refused section.md 3 'a block with no closing </output_format>') / section.md=$(q 'Para\n\n<output_format>\nprose\n\nmore\n')" \
  "a symlink is refused rather than rewritten through|fx_symlink||link.md||rc=2 ${ERR}link.md is a symlink; reflow the file it points at" \
  "a file holding a NUL byte is refused|fx_nul||bin.md||rc=2 ${ERR}bin.md holds a NUL byte; it is not a markdown file this tool rewrites" \
  "a staged file missing from the work tree is refused: reflow works on the checkout|fx_gone||--staged||rc=2 ${ERR}doc.md is not a file in the work tree; reflow works on the checkout" \
  "a missing path is exit 2, named as resolved from the invoking directory|clean_file absent||absent.md||rc=2 ${ERR}$TMP/absent/absent.md is not a file" \
  "no path and no scope is exit 2|clean_file no-path||||rc=2 ${ERR}name the files to reflow, or pass --staged or --all (see --help)" \
  "a path beside --staged is exit 2|clean_file path-and-scope||--staged clean.md||rc=2 ${ERR}PATH arguments and --staged/--all are exclusive" \
  "an unknown flag is exit 2, quoting it|clean_file unknown-flag||--no-such-flag||rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)" \
  "-- ends the options, and what follows is a path|clean_file dashdash||-- clean.md||rc=0 $(unchanged 1)"
# The usage text carries a '|', which a row cannot: its first line and the
# exit status, beside the table.
assert_eq "--help prints usage at exit 0" "rc=0 usage: md-reflow [--check] PATH... | [--check] --staged | [--check] --all" "$(run '' --help | LC_ALL=C cut -d';' -f1)"
assert_eq "-h is --help" "rc=0 usage: md-reflow [--check] PATH... | [--check] --staged | [--check] --all" "$(run '' -h | LC_ALL=C cut -d';' -f1)"

echo "=== a path is taken from the invoking directory, inside the repository ==="
fx_deep() { repo deep; write docs/deep.md "$WRAPPED"; R="$R/docs"; } # the run happens in docs/
fx_outside() { repo "outside-$1"; write "../outside-$1.md" "$WRAPPED"; } # NAME — the file sits beside the repository, not in it
st_deep() { bytes deep.md; }
run_rows \
  "a relative path resolves from where md-reflow was run, and is named repo-relative|fx_deep||deep.md|st_deep|rc=0 $(reflowed 1 1 docs/deep.md) / deep.md=$(q 'Wrapped text.\n')" \
  "an absolute path outside the repository is refused, named as given|fx_outside abs||$TMP/outside-abs.md||rc=2 ${ERR}$TMP/outside-abs.md is outside this repository" \
  "a relative path climbing out of the repository is refused, named as resolved|fx_outside rel||../outside-rel.md||rc=2 ${ERR}$TMP/outside-rel/../outside-rel.md is outside this repository"

echo "=== --staged and --all select the files md-format would judge ==="
selection() { # NAME — three wrapped files, the vendored one excluded, one.md re-wrapped and staged
  repo "$1"
  put one.md 'Wrapped\none.\n'
  put two.md 'Wrapped\ntwo.\n'
  put vendor/three.md 'Wrapped\nthree.\n'
  put tools/md-excludes 'vendor/*\tupstream docs\n'
  commit seed
  put one.md 'Wrapped\none more.\n'
}
fx_staged_excluded() { repo staged-excluded; put doc.md "$WRAPPED"; put tools/md-excludes 'doc.md\tvendored document\n'; }
fx_staged_included() { repo staged-included; put doc.md "$WRAPPED"; }
st_selection() { bytes one.md; printf ' '; bytes two.md; printf ' '; bytes vendor/three.md; printf ' '; format_all; }
st_doc() { bytes doc.md; }
run_rows \
  "--staged reflows the work-tree copy of the staged file and leaves the rest|selection staged||--staged|st_selection|rc=0 $(reflowed 1 1 one.md) / one.md=$(q 'Wrapped one more.\n') two.md=$(q 'Wrapped\ntwo.\n') vendor/three.md=$(q 'Wrapped\nthree.\n') format:rc=1 md-format FAIL format: two.md:2: a paragraph hard-wrapped over lines; put the whole paragraph on one line;  remedies: reflow the file with md-reflow (scripts/md-reflow PATH), then stage it;md-format: 1 format violation(s) in 2 tracked markdown file(s)" \
  "--all reflows every tracked markdown file minus the excludes, and md-format then passes on them|selection all||--all|st_selection|rc=0 $(reflowed 2 2 one.md two.md) / one.md=$(q 'Wrapped one more.\n') two.md=$(q 'Wrapped two.\n') vendor/three.md=$(q 'Wrapped\nthree.\n') format:rc=0 md-format: OK — 2 tracked markdown file(s) clean" \
  "staged reflow leaves the excluded document unchanged|fx_staged_excluded||--staged|st_doc|rc=0 $(unchanged 0) / doc.md=$(q "$WRAPPED")" \
  "control: the same staged document reflows without its exclusion|fx_staged_included||--staged|st_doc|rc=0 $(reflowed 1 1 doc.md) / doc.md=$(q 'Wrapped text.\n')"

echo "=== a failed replacement preserves the file and removes its staging file ==="
fx_failing_mv() { # NAME — a PATH whose mv refuses, ahead of the real one
  repo "$1"
  write doc.md "$WRAPPED"
  mkdir -p "$R/fail-bin"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf %s >&2 "injected rename failure\\n"\nexit 1\n' >"$R/fail-bin/mv"
  chmod +x "$R/fail-bin/mv"
}
fx_stray() { repo stray; write doc.md "$WRAPPED"; write stray.txt 'x\n'; } # a file beside doc.md the leftovers reader must see
st_replacement() { bytes doc.md; printf ' '; leftovers; }
run_rows \
  "a rename failure is an error naming the cause, preserves the original bytes and removes the staging file|fx_failing_mv failing-mv|PATH=$TMP/failing-mv/fail-bin:$PATH|doc.md|st_replacement|rc=2 ${ERR}could not replace the reflowed markdown at doc.md (injected rename failure) — inspect the file before trusting it / doc.md=$(q "$WRAPPED") leftovers=" \
  "control: the same file reflows when rename succeeds|fx_failing_mv working-mv||doc.md|st_replacement|rc=0 $(reflowed 1 1 doc.md) / doc.md=$(q 'Wrapped text.\n') leftovers=" \
  "control: the leftovers reader names a file beside doc.md|fx_stray||doc.md|st_replacement|rc=0 $(reflowed 1 1 doc.md) / doc.md=$(q 'Wrapped text.\n') leftovers=$TMP/stray/stray.txt"

echo "=== the skill's own shipped markdown is a fixed point ==="
fx_shipped() { # the four shipped documents
  local doc
  repo shipped
  mkdir -p "$R/skills/commit-guards"
  for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
    cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
  done
  git -C "$R" add -A
}
run_rows \
  "SKILL.md, README.md, CHECKS.md and DEVELOPMENT.md reflow to themselves|fx_shipped||--check --all||rc=0 $(in_format 4)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
