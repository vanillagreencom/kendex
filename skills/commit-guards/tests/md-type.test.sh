#!/usr/bin/env bash
# Pins for scripts/md-type: that a file the block parser cannot end fails and
# any other passes, the size signal docs-audit relays, that a broken or absent
# docs-writing is a gap rather than a pass under --as and --route, and what
# --route hands the reminder hook. Rows assert the keyed fields md-type
# prints, never the explanation under them.
set -euo pipefail
# No globbing: fixture content and paths are passed as written.
set -f
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDT="${MDT:-$SKILL_DIR/scripts/md-type}"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_MD_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE \
  CI GITHUB_ACTIONS 2>/dev/null || true

DW_SOURCE="$SKILL_DIR/../docs-writing"
[ -f "$DW_SOURCE/SKILL.md" ] || { echo "harness: no docs-writing beside commit-guards at $DW_SOURCE" >&2; exit 2; }

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

DWR=".agents/skills/docs-writing"

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused. DOCS is a docs-writing directory to install, or none.
R=""
repo() { # NAME [DOCS]
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
  local docs="${2-$DW_SOURCE}"
  if [ "$docs" != none ]; then
    mkdir -p "$R/.agents/skills"
    cp -R "$docs" "$R/.agents/skills/docs-writing"
  fi
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -- "$1"; } # PATH CONTENT, staged
commit() { git -C "$R" commit -qm "${1:-seed}"; }

# A run's exit status and its keyed first lines, joined by ';'. Summary and
# signal lines are dropped unless KEEP names them.
keyed() { # RC OUTPUT [KEEP-ERE]
  local out
  out="$(printf '%s\n' "$2" | LC_ALL=C grep -E '^md-type: [a-z-]+=' | LC_ALL=C grep -Ev "^md-type: (summary|signal|judged)=" || true)"
  if [ -n "${3-}" ]; then
    out="$(printf '%s\n' "$2" | LC_ALL=C grep -E "$3" || true)"
  fi
  printf 'rc=%s%s' "$1" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}
as_run() { # PATH CONTENT [KEEP-ERE] — md-type --as over CONTENT in the current fixture
  local rc=0 out=""
  out="$(printf '%b' "$2" | "$MDT" --root "$R" --as "$1" - 2>&1)" || rc=$?
  keyed "$rc" "$out" "${3-}"
}
lane_run() { # ARGS [KEEP-ERE] — md-type in the current fixture
  local rc=0 out=""
  # shellcheck disable=SC2086
  out="$(cd "$R" && "$MDT" $1 2>&1)" || rc=$?
  keyed "$rc" "$out" "${2-}"
}

# Fixture content is printf %b text whose pipes are written \174, so a row
# table's own '|' separator never splits it.
#
# The owner's reported plugin README, rebuilt from its description: a
# settings catalogue with defaults and a table of budgets.
PLUGIN='# vgs.jarvis\n\nA desktop assistant for one person across their machines.\n\n## Features\n\n- Reads and answers messages.\n\n## Install\n\n```sh\nkendex add example/vgs --skill jarvis\n```\n\n## Settings\n\n\174 Variable \174 Purpose \174 Default \174\n\174---\174---\174---\174\n\174 `JARVIS_HOME` \174 Where the home lives \174 `~/jarvis` \174\n\174 `JARVIS_POLL` \174 Poll interval \174 `30` \174\n\n## Budgets\n\n\174 Budget \174 Limit \174\n\174---\174---\174\n\174 Tokens per session \174 400000 \174\n\174 Cost per day \174 20 USD \174\n\n## Licence\n\nMIT\n'
# The README example's own document, the size signal's yardstick.
CONFORMING="$(LC_ALL=C awk '/^````markdown/ { inner = 1; next } /^````$/ { inner = 0 } inner' "$DW_SOURCE/examples/readme.md")"
[ -n "$CONFORMING" ] || { echo "harness: no inner document in examples/readme.md" >&2; exit 2; }
CONFORMING="${CONFORMING//\\/\\\\}"
CONFORMING="${CONFORMING//|/\\174}"
CONFORMING="${CONFORMING//$'\n'/\\n}\\n"

echo "=== --as: an unended file fails, and a classified one is sized ==="
repo as
as_rows() { # label | path | content | expect
  local row label path content expect
  for row in "$@"; do
    IFS='|' read -r label path content expect <<<"$row"
    assert_eq "$label" "$expect" "$(as_run "$path" "$content")"
  done
}
as_rows \
  "a fence the parser cannot end fails, whatever the type|notes/plan.md|# Plan\n\n\`\`\`\nopen\n|rc=1 md-type: fence-unclosed=notes/plan.md:3" \
  "a CRLF file is normalized and parsed, not refused|README.md|# Tool\r\n\r\nA tool.\r\n|rc=0"

assert_eq "the example document's words are the size signal's yardstick" \
  "words=example_words" \
  "$(as_run README.md "$CONFORMING" '^md-type: signal=' | LC_ALL=C sed -E 's/.* words=([0-9]+) example_words=([0-9]+) .*/\1=\2/; s/^([0-9]+)=\1$/words=example_words/')"

printf '# Plan\n\n```\nopen\n' >"$TMP/plan.md"
rc=0
out="$(printf '# Tool\n\nA tool.\n' | "$MDT" --root "$R" --as README.md - --as docs/plan.md "$TMP/plan.md" 2>&1)" || rc=$?
assert_eq "one run reads each --as pair in order, each closed by its judged line" \
  "rc=1 md-type: signal=size path=README.md type=readme;md-type: judged=1;md-type: fence-unclosed=docs/plan.md:3;md-type: judged=2" \
  "$(keyed "$rc" "$out" '^md-type: (signal|fence-unclosed|judged)=' | LC_ALL=C sed -E 's/(signal=size path=[^ ]+ type=[^ ]+) [^;]*/\1/')"

echo "=== the lane: an unended file fails, and no shape is judged ==="
lane_rows() { # label | fixture | args | expect
  local row label fx args expect words
  for row in "$@"; do
    IFS='|' read -r label fx args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(lane_run "$args")"
  done
}
# The plugin README with its description dropped and an Install section
# after its Licence: value tables, no description and a section out of the
# readme list's order stop no reader, so the lane passes them.
fx_plugin() { repo "$1"; put skills/vgs/README.md "${PLUGIN/A desktop assistant for one person across their machines.\\n\\n/}\n## Install\n\nRun it.\n"; }
fx_unended() { repo "$1"; put docs/plan.md '```\nopen\n'; }
fx_unended_pushed() { repo "$1"; put README.md '# Tool\n'; commit; put docs/plan.md '```\nopen\n'; commit plan; }
fx_moved_in() { repo "$1"; put notes.txt '```\nopen\n'; commit; mkdir -p "$R/docs"; git -C "$R" mv notes.txt docs/notes.md; }
lane_rows \
  "the plugin README, with value tables, sections out of order and no description, passes|fx_plugin plugin|--staged|rc=0" \
  "a staged file the parser cannot end fails|fx_unended unended|--staged|rc=1 md-type: fence-unclosed=docs/plan.md:1" \
  "and the same file pushed fails over the range|fx_unended_pushed unended-pushed|--against HEAD~1|rc=1 md-type: fence-unclosed=docs/plan.md:1" \
  "a file moved unedited into the Markdown paths is parsed where it arrives|fx_moved_in moved-in|--staged|rc=1 md-type: fence-unclosed=docs/notes.md:1"

echo "=== a docs-writing --as cannot read is a gap, never a pass ==="
# A copy of the scripts with no docs-writing beside it, so the fixture's own
# install is the only one md-type can find.
LONE="$TMP/lone/scripts"
mkdir -p "$TMP/lone"
cp -R "$SKILL_DIR/scripts" "$LONE"
# A copy of the shipped docs-writing with one line of SKILL.md replaced.
broken_docs() { # NAME FROM TO — a docs-writing copy under $TMP/NAME
  local dir="$TMP/$1"
  cp -R "$DW_SOURCE" "$dir"
  FROM="$2" TO="$3" awk '{ i = index($0, ENVIRON["FROM"]); if (i) { $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])); n++ } print } END { if (n != 1) exit 3 }' \
    "$DW_SOURCE/SKILL.md" >"$dir/SKILL.md" || { echo "harness: $1 edit did not match once" >&2; exit 2; }
}
broken_docs no-readme-row '| `README.md`, `*/README.md` |' '| `READ.md` |'
broken_docs no-table '| Path | Section | Example |' '| Path | Section | Sample |'
gap_rows() { # label | docs | as-expect
  local row label docs as
  for row in "$@"; do
    IFS='|' read -r label docs as <<<"$row"
    repo "gap-$docs" "$( [ "$docs" = none ] && echo none || echo "$TMP/$docs")"
    assert_eq "$label" "$as" "$(MDT="$LONE/md-type" as_run README.md '# Tool\n\nA tool.\n')"
  done
}
gap_rows \
  "no docs-writing|none|rc=2 md-type: gap=docs-writing-missing" \
  "a route table classifying no README|no-readme-row|rc=2 md-type: rules=unreadable detector=floor path=$TMP/gap-no-readme-row/$DWR/SKILL.md" \
  "no route table|no-table|rc=2 md-type: rules=unreadable detector=route-table path=$TMP/gap-no-table/$DWR/SKILL.md"

echo "=== --route: the type, reference and example the reminder hook names ==="
repo route
put .gitignore 'tmp/\n'
RP="$(cd "$R" && pwd -P)"
route_rows() { # label | path | expect
  local row label path expect rc out
  for row in "$@"; do
    IFS='|' read -r label path expect <<<"$row"
    rc=0
    out="$(cd "$R" && "$MDT" --route "$path" 2>&1)" || rc=$?
    assert_eq "$label" "$expect" "$(keyed "$rc" "$out")"
  done
}
route_rows \
  "a README routes to its reference and example, even before the file exists|skills/new/README.md|rc=0 md-type: type=readme;md-type: reference=$RP/$DWR/references/readme.md;md-type: example=$RP/$DWR/examples/readme.md" \
  "a git-ignored path is not routed|tmp/plan.md|rc=0 md-type: route=ignored" \
  "a path outside every repository is not routed|$TMP/loose.md|rc=0 md-type: route=outside-repo" \
  "an unclassified path is sent to the route table|CHANGELOG.md|rc=0 md-type: route=unclassified;md-type: skill=$RP/$DWR/SKILL.md" \
  "a decision record, whose row has no reference file, routes to SKILL.md and its example|docs/decisions/D001-one.md|rc=0 md-type: type=decision-records;md-type: reference=$RP/$DWR/SKILL.md;md-type: example=$RP/$DWR/examples/decision.md"
route_refused() { # MDT — a route in a repository git refuses to read
  local rc=0 out
  out="$(cd "$R" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$1" --route README.md 2>&1)" || rc=$?
  keyed "$rc" "$out"
}
assert_eq "a repository git refuses to read fails the route, never reads as outside one" \
  "rc=2 md-type: route-repo=$RP" "$(route_refused "$MDT")"
repo route-none none
MDT="$LONE/md-type" route_rows "with no docs-writing the route fails for the hook to name|README.md|rc=2 md-type: gap=docs-writing-missing"
# The retired route table: a fourth Shape column on the header, the
# delimiter and every row, as a docs-writing render from before the
# three-column table carries it.
RETIRED="$TMP/retired-shape"
cp -R "$DW_SOURCE" "$RETIRED"
LC_ALL=C awk '
  $0 == "| Path | Section | Example |" { table = 1; print "| Path | Section | Example | Shape |"; next }
  table && $0 == "|---|---|---|" { print "|---|---|---|---|"; next }
  table && /^\|/ { print $0 " none |"; rows++; next }
  { table = 0; print }
  END { if (rows < 2) exit 3 }
' "$DW_SOURCE/SKILL.md" >"$RETIRED/SKILL.md" || { echo "harness: no route table to widen in SKILL.md" >&2; exit 2; }
RETIRED_HEADER="$(LC_ALL=C grep -n '^| Path | Section | Example | Shape |$' "$RETIRED/SKILL.md" | cut -d: -f1)"
repo route-retired "$RETIRED"
RP="$(cd "$R" && pwd -P)"
MDT="$LONE/md-type" route_rows "a retired route table with a Shape column still routes, with one warning|skills/new/README.md|rc=0 md-type: warning=route-table-shape path=$RP/$DWR/SKILL.md:$RETIRED_HEADER;md-type: type=readme;md-type: reference=$RP/$DWR/references/readme.md;md-type: example=$RP/$DWR/examples/readme.md"

echo "=== must-fail controls ==="
gg_mutant NO_FLOOR md-type '[ "$readme" -eq 1 ] && [ "$linked" -eq 1 ] || { rules_gap floor SKILL.md; return 0; }' ':'
repo control-floor "$TMP/no-readme-row"
assert_eq "must-fail: with no discovery floor a route table classifying no README reads clean" \
  "rc=0" "$(MDT="$NO_FLOOR" as_run README.md '# Tool\n\nA tool.\n' '^md-type: (gap|rules)=')"

gg_mutant NO_DASH lib/md-type.awk 'function dash(s) { return (s == "") ? "-" : s }' 'function dash(s) { return s }'
repo control-dash
assert_eq "must-fail: with empty cells written empty, the decision row's example shifts into its reference" \
  "rc=0 md-type: type=decision-records;md-type: reference=$(cd "$R" && pwd -P)/$DWR/examples/decision.md" \
  "$(rc=0; out="$(cd "$R" && "${NO_DASH%/lib/md-type.awk}/md-type" --route docs/decisions/D001-one.md 2>&1)" || rc=$?; keyed "$rc" "$out")"
gg_mutant NO_REPO md-type '[ ! -e "$at/.git" ] || gg_fail_cause route-repo' ': || gg_fail_cause route-repo'
assert_eq "must-fail: with no .git walk, a repository git refuses reads as outside every repository" \
  "rc=0 md-type: route=outside-repo" "$(route_refused "$NO_REPO")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
