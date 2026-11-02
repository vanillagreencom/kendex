#!/usr/bin/env bash
# Pins for scripts/md-type, the shape judge: what docs-writing's route table
# makes a finding for each file type, how a lane tells an introduced finding
# from an inherited one, that a file the block parser cannot end fails, that
# a broken or absent docs-writing is a gap rather than a pass, and what
# --route hands the reminder hook. Rows assert the keyed fields md-type
# prints and docs-audit relays, never the explanation under them. The rule
# lines a finding cites are read from the shipped docs-writing here, by line
# shape, so a row names the line a reader is sent to.
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

# The rule lines, found by line shape in the shipped docs-writing.
line_of() { # FILE ERE — the one matching line's number
  local n
  n="$(LC_ALL=C grep -nE -- "$2" "$1" | cut -d: -f1)"
  case "$n" in
    "" | *[!0-9]*) echo "harness: expected one line matching $2 in $1, got [$n]" >&2; exit 2 ;;
  esac
  printf '%s' "$n"
}
DWR=".agents/skills/docs-writing"
README_ROW="$DWR/SKILL.md:$(line_of "$DW_SOURCE/SKILL.md" '^\| `README.md`, ')"
ARCH_ROW="$DWR/SKILL.md:$(line_of "$DW_SOURCE/SKILL.md" '^\| `docs/architecture/\*')"
DESCRIPTION_ITEM="$DWR/references/readme.md:$(line_of "$DW_SOURCE/references/readme.md" '^1\. ')"
INSTALL_ITEM="$DWR/references/readme.md:$(line_of "$DW_SOURCE/references/readme.md" '^[0-9]+\. Install')"

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
F="md-type: finding="

# Fixture content is printf %b text whose pipes are written \174, so a row
# table's own '|' separator never splits it.
#
# The owner's reported plugin README, rebuilt from its description: a
# settings catalogue with defaults and a table of budgets.
PLUGIN='# vgs.jarvis\n\nA desktop assistant for one person across their machines.\n\n## Features\n\n- Reads and answers messages.\n\n## Install\n\n```sh\nkendex add example/vgs --skill jarvis\n```\n\n## Settings\n\n\174 Variable \174 Purpose \174 Default \174\n\174---\174---\174---\174\n\174 `JARVIS_HOME` \174 Where the home lives \174 `~/jarvis` \174\n\174 `JARVIS_POLL` \174 Poll interval \174 `30` \174\n\n## Budgets\n\n\174 Budget \174 Limit \174\n\174---\174---\174\n\174 Tokens per session \174 400000 \174\n\174 Cost per day \174 20 USD \174\n\n## Licence\n\nMIT\n'
# The README example's own document, which the rules must pass.
CONFORMING="$(LC_ALL=C awk '/^````markdown/ { inner = 1; next } /^````$/ { inner = 0 } inner' "$DW_SOURCE/examples/readme.md")"
[ -n "$CONFORMING" ] || { echo "harness: no inner document in examples/readme.md" >&2; exit 2; }
CONFORMING="${CONFORMING//\\/\\\\}"
CONFORMING="${CONFORMING//|/\\174}"
CONFORMING="${CONFORMING//$'\n'/\\n}\\n"

echo "=== --as: what each file type makes a finding ==="
repo as
as_rows() { # label | path | content | expect
  local row label path content expect
  for row in "$@"; do
    IFS='|' read -r label path content expect <<<"$row"
    assert_eq "$label" "$expect" "$(as_run "$path" "$content")"
  done
}
TABLE='\174 Key \174 Default \174\n\174---\174---\174\n\174 poll \174 30 \174\n'
as_rows \
  "the plugin README is refused at both tables, each named by section and the route row|skills/vgs/README.md|$PLUGIN|rc=1 ${F}value-table path=skills/vgs/README.md type=readme line=17 rule=$README_ROW count=2 baseline=none introduced=yes section=Settings;${F}value-table path=skills/vgs/README.md type=readme line=24 rule=$README_ROW count=2 baseline=none introduced=yes section=Budgets" \
  "the README example's document passes|README.md|$CONFORMING|rc=0" \
  "a README section out of the list's order cites the list item|README.md|# Tool\n\nA tool.\n\n## Licence\n\nMIT\n\n## Install\n\nRun it.\n|rc=1 ${F}section-order path=README.md type=readme line=9 rule=$INSTALL_ITEM count=1 baseline=none introduced=yes section=Install" \
  "a README with nothing between its title and first section has no description|README.md|# Tool\n\n## Features\n\n- One.\n|rc=1 ${F}description-missing path=README.md type=readme line=3 rule=$DESCRIPTION_ITEM count=1 baseline=none introduced=yes section=top" \
  "a heading the list does not name is not ordered|README.md|# Tool\n\nA tool.\n\n## Licence\n\n## Troubleshooting\n|rc=0" \
  "a README titled with an H2 keeps its description under that title|README.md|## Tool\n\nA tool.\n\n## Features\n\n- One.\n|rc=0" \
  "a Setext title is a heading, never its own description|README.md|Tool\n====\n\n## Features\n|rc=1 ${F}description-missing path=README.md type=readme line=4 rule=$DESCRIPTION_ITEM count=1 baseline=none introduced=yes section=top" \
  "a Setext first section's text is that section, never the description|README.md|# Tool\n\nFeatures\n--------\n\n- One.\n|rc=1 ${F}description-missing path=README.md type=readme line=4 rule=$DESCRIPTION_ITEM count=1 baseline=none introduced=yes section=top" \
  "a Setext-titled README keeps its description under that title|README.md|Tool\n====\n\nA tool.\n\n## Features\n|rc=0" \
  "an architecture doc's value table cites its route row|docs/architecture/plugins.md|# Plugins\n\n## Rules\n\n$TABLE|rc=1 ${F}value-table path=docs/architecture/plugins.md type=architecture line=5 rule=$ARCH_ROW count=1 baseline=none introduced=yes section=Rules" \
  "a reference doc may hold a value table|skills/x/references/keys.md|# Keys\n\n$TABLE|rc=0" \
  "an unclassified file is parsed and judged for nothing more|notes/plan.md|# Plan\n\n$TABLE|rc=0" \
  "a table whose header names no value is no finding|README.md|# Tool\n\nA tool.\n\n## Setup\n\n\174 Setting \174 What it changes \174\n\174---\174---\174\n\174 a \174 b \174\n|rc=0" \
  "a CRLF README is normalized and judged, not refused|README.md|# Tool\r\n\r\nA tool.\r\n\r\n## Setup\r\n\r\n\174 Key \174 Default \174\r\n\174---\174---\174\r\n\174 a \174 1 \174\r\n|rc=1 ${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=1 baseline=none introduced=yes section=Setup" \
  "a fence the parser cannot end fails, whatever the type|notes/plan.md|# Plan\n\n\`\`\`\nopen\n|rc=1 md-type: fence-unclosed=notes/plan.md:3"

# The value-table vocabulary, over the header rows of kendex READMEs that
# carry a settings catalogue, and headers that name no value.
for header in '| Variable | Purpose | Default |' '| Key | **Default** | Meaning |' '| Budget | Limit |' '| Check | Threshold |'; do
  assert_eq "a header row like $header is a value table" "rc=1" \
    "$(as_run README.md "# T\n\nA tool.\n\n## Setup\n\n$header\n|---|---|\n| a | b |\n" '^$')"
done
for header in '| Setting | What it changes |' '| Path | Reader | Holds |' '| Default branch rule | Why |'; do
  assert_eq "a header row like $header is not" "rc=0" \
    "$(as_run README.md "# T\n\nA tool.\n\n## Setup\n\n$header\n|---|---|\n| a | b |\n" '^$')"
done

assert_eq "the example document's words are the size signal's yardstick" \
  "words=example_words" \
  "$(as_run README.md "$CONFORMING" '^md-type: signal=' | LC_ALL=C sed -E 's/.* words=([0-9]+) example_words=([0-9]+) .*/\1=\2/; s/^([0-9]+)=\1$/words=example_words/')"

assert_eq "a decision record's size is measured against the decision example" \
  "type=decision-records example=$DWR/examples/decision.md" \
  "$(as_run docs/decisions/D001-one.md '# D001: One\n\nText.\n' '^md-type: signal=' | LC_ALL=C sed -E 's/.* (type=[^ ]+) .* (example=[^ ]+)$/\1 \2/')"

printf '# Plugins\n\n## Rules\n\n| Key | Default |\n|---|---|\n| a | 1 |\n' >"$TMP/arch.md"
rc=0
out="$(printf '# Tool\n\n## Features\n' | "$MDT" --root "$R" --as README.md - --as docs/architecture/x.md "$TMP/arch.md" 2>&1)" || rc=$?
assert_eq "one run judges each --as pair in order, each closed by its judged line" \
  "rc=1 ${F}description-missing path=README.md type=readme line=3 rule=$DESCRIPTION_ITEM count=1 baseline=none introduced=yes section=top;md-type: judged=1;${F}value-table path=docs/architecture/x.md type=architecture line=5 rule=$ARCH_ROW count=1 baseline=none introduced=yes section=Rules;md-type: judged=2" \
  "$(keyed "$rc" "$out" '^md-type: (finding|judged)=')"

echo "=== the lane: a finding blocks only where the change raised its count ==="
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
README_WITH='# Tool\n\nA tool.\n\n## Settings\n\n| Key | Default |\n|---|---|\n| a | 1 |\n'
fx_new() { repo "$1"; put README.md "$README_WITH"; }
fx_edited() { repo "$1"; put README.md "$README_WITH"; commit; put README.md "${README_WITH/A tool./A tool for people.}"; }
fx_renamed() { repo "$1"; put README.md "$README_WITH"; commit; put README.md "${README_WITH/Settings/Configuration}"; }
fx_grown() { repo "$1"; put README.md "$README_WITH"; commit; put README.md "$README_WITH\n## Budgets\n\n| Budget | Limit |\n|---|---|\n| a | 1 |\n"; }
fx_unended() { repo "$1"; put docs/plan.md '```\nopen\n'; }
# A README moved with an edit, which git records as a rename below exact
# content, carrying its inherited table.
fx_moved() { repo "$1"; put a/README.md "$README_WITH"; commit; mkdir -p "$R/b"; git -C "$R" mv a/README.md b/README.md; printf 'More.\n' >>"$R/b/README.md"; git -C "$R" add b/README.md; }
# A reference holding a defaults table, moved unchanged to a README: the
# table was allowed where it was and is not where it lands.
fx_retyped() { repo "$1"; put skills/x/references/settings.md "$README_WITH"; commit; git -C "$R" mv skills/x/references/settings.md skills/x/README.md; }
fx_retyped_pushed() { fx_retyped "$1"; commit move; }
# A README moved unchanged with a new README written at the path it left,
# which git records as a modification and an addition: only copy detection
# from the modified path pairs the moved file with its source.
fx_replaced() { repo "$1"; put README.md "$README_WITH"; commit; mkdir -p "$R/docs"; git -C "$R" mv README.md docs/README.md; put README.md '# Tool\n\nA tool.\n'; }
fx_replaced_pushed() { fx_replaced "$1"; commit move; }
# A README copied whole from one the change leaves alone: a new file, so the
# table it brings is introduced. Pairing it with its source would let any
# new README copied from an old one pass.
fx_copied() { repo "$1"; put README.md "$README_WITH"; commit; put docs/README.md "$README_WITH"; }
fx_copied_pushed() { fx_copied "$1"; commit copy; }
COPY_NEW="${F}value-table path=docs/README.md type=readme line=7 rule=$README_ROW count=1 baseline=none introduced=yes section=Settings"
COPY_SOURCE="${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings"
lane_rows \
  "a new README's value table is introduced and blocks|fx_new new|--staged|rc=1 ${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=1 baseline=none introduced=yes section=Settings" \
  "an edit beside an inherited table warns and passes|fx_edited edited|--staged|rc=0 ${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "renaming the heading over an inherited table keeps the count and passes|fx_renamed renamed|--staged|rc=0 ${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Configuration" \
  "a second table raises the count and blocks|fx_grown grown|--staged|rc=1 ${F}value-table path=README.md type=readme line=7 rule=$README_ROW count=2 baseline=1 introduced=yes section=Settings;${F}value-table path=README.md type=readme line=13 rule=$README_ROW count=2 baseline=1 introduced=yes section=Budgets" \
  "a staged file the parser cannot end fails|fx_unended unended|--staged|rc=1 md-type: fence-unclosed=docs/plan.md:1" \
  "a README moved with an edit keeps its inherited table's count and passes|fx_moved moved|--staged|rc=0 ${F}value-table path=b/README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "a reference moved unchanged into a README brings a table its new type refuses|fx_retyped retyped|--staged|rc=1 ${F}value-table path=skills/x/README.md type=readme line=7 rule=$README_ROW count=1 baseline=0 introduced=yes section=Settings" \
  "and the same move pushed is judged over the range|fx_retyped_pushed retyped-pushed|--against HEAD~1|rc=1 ${F}value-table path=skills/x/README.md type=readme line=7 rule=$README_ROW count=1 baseline=0 introduced=yes section=Settings" \
  "and the same move staged is judged by a bare run under touched|fx_retyped retyped-bare||rc=1 ${F}value-table path=skills/x/README.md type=readme line=7 rule=$README_ROW count=1 baseline=0 introduced=yes section=Settings" \
  "a sweep measures a staged move against the path it left|fx_moved moved-all|--all|rc=0 ${F}value-table path=b/README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "a README moved from a path the change refills keeps its inherited table's count|fx_replaced replaced|--staged|rc=0 ${F}value-table path=docs/README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "and the same move pushed keeps it over the range|fx_replaced_pushed replaced-pushed|--against HEAD~1|rc=0 ${F}value-table path=docs/README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "and a sweep measures it against the path it left|fx_replaced replaced-all|--all|rc=0 ${F}value-table path=docs/README.md type=readme line=7 rule=$README_ROW count=1 baseline=1 introduced=no section=Settings" \
  "a README copied from one the change leaves alone is new, and its table blocks|fx_copied copied|--staged|rc=1 $COPY_NEW" \
  "and the same copy pushed blocks over the range|fx_copied_pushed copied-pushed|--against HEAD~1|rc=1 $COPY_NEW" \
  "and a sweep blocks the copy while its source warns|fx_copied copied-all|--all|rc=1 $COPY_SOURCE;$COPY_NEW"

echo "=== a docs-writing md-type cannot read is a gap, never a pass ==="
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
broken_docs unknown-shape '| `order`, `value-table` |' '| `order`, `never` |'
broken_docs no-table '| Path | Section | Example | Shape |' '| Path | Section | Sample | Shape |'
cp -R "$DW_SOURCE" "$TMP/no-list"
LC_ALL=C sed -E 's/^([0-9]+)\. /\1) /' "$DW_SOURCE/references/readme.md" >"$TMP/no-list/references/readme.md"
gap_rows() { # label | docs | lane-expect | as-expect
  local row label docs lane as
  for row in "$@"; do
    IFS='|' read -r label docs lane as <<<"$row"
    repo "gap-lane-$docs" "$( [ "$docs" = none ] && echo none || echo "$TMP/$docs")"
    put README.md "$README_WITH"
    assert_eq "$label, in the lane" "$lane" "$(MDT="$LONE/md-type" lane_run --staged)"
    assert_eq "$label, under --as" "$as" "$(MDT="$LONE/md-type" as_run README.md "$README_WITH")"
  done
}
gap_rows \
  "no docs-writing|none|rc=0 md-type: gap=docs-writing-missing|rc=2 md-type: gap=docs-writing-missing" \
  "a route table classifying no README|no-readme-row|rc=0 md-type: rules=unreadable detector=floor path=$DWR/SKILL.md|rc=2 md-type: rules=unreadable detector=floor path=$TMP/gap-lane-no-readme-row/$DWR/SKILL.md" \
  "a shape name the judge does not know|unknown-shape|rc=0 md-type: rules=unreadable detector=shape path=$DWR/SKILL.md|rc=2 md-type: rules=unreadable detector=shape path=$TMP/gap-lane-unknown-shape/$DWR/SKILL.md" \
  "no route table|no-table|rc=0 md-type: rules=unreadable detector=route-table path=$DWR/SKILL.md|rc=2 md-type: rules=unreadable detector=route-table path=$TMP/gap-lane-no-table/$DWR/SKILL.md" \
  "an order row whose reference has no numbered list|no-list|rc=0 md-type: rules=unreadable detector=order path=$DWR/references/readme.md|rc=2 md-type: rules=unreadable detector=order path=$TMP/gap-lane-no-list/$DWR/references/readme.md"
repo gap-unended none
put docs/plan.md '```\nopen\n'
assert_eq "a gap still parses every file, and an unended one fails" \
  "rc=1 md-type: gap=docs-writing-missing;md-type: fence-unclosed=docs/plan.md:1" "$(MDT="$LONE/md-type" lane_run --staged)"

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

echo "=== must-fail controls ==="
gg_mutant NO_VALUES lib/md-type.awk 'split("default defaults budget budgets limit limits ceiling ceilings threshold thresholds", vt, " ")' 'split("", vt, " ")'
repo control-values
assert_eq "must-fail: with no value vocabulary the plugin README passes" \
  "rc=0" "$(MDT="${NO_VALUES%/lib/md-type.awk}/md-type" as_run skills/vgs/README.md "$PLUGIN")"
gg_mutant NO_BASELINE md-type '[ -z "$base" ] || baseline="$(count_of "$base" "$finding")"' ':'
fx_edited control-baseline
assert_eq "must-fail: with no baseline count an inherited table blocks the unrelated edit" \
  "rc=1" "$(MDT="$NO_BASELINE" lane_run --staged '^$')"
gg_mutant NO_FLOOR md-type '[ "$readme" -eq 1 ] && [ "$linked" -eq 1 ] || { rules_gap floor SKILL.md; return 0; }' ':'
repo control-floor "$TMP/no-readme-row"
put README.md "$README_WITH"
assert_eq "must-fail: with no discovery floor a route table classifying no README reads clean" \
  "rc=0" "$(MDT="$NO_FLOOR" lane_run --staged '^md-type: (gap|rules)=')"

gg_mutant NO_SOURCE md-type 'local earlier="${2:-$1}"' 'local earlier="$1"'
fx_moved control-moved
assert_eq "must-fail: measured at its new path alone, a moved README's inherited table blocks" \
  "rc=1" "$(MDT="$NO_SOURCE" lane_run --staged '^$')"
gg_mutant NO_MOVES md-type 'GG_MD_RENAMES=detect' 'GG_MD_RENAMES=exact'
fx_retyped control-retyped
assert_eq "must-fail: with exact renames dropped, a reference moved into a README is never opened" \
  "rc=0 md-type: no-match=staged:*.md" "$(MDT="$NO_MOVES" lane_run --staged)"
gg_mutant AMT_TRIGGER lib/md-scope.sh 'git diff --cached --quiet "${GG_WALK_DIFF[@]}"' 'git diff --cached --quiet --diff-filter=AMT'
fx_retyped control-trigger
assert_eq "must-fail: with the trigger blind to renames, a bare run finds nothing staged" \
  "rc=0 md-type: staged-count=0" "$(MDT="${AMT_TRIGGER%/lib/md-scope.sh}/md-type" lane_run "")"
gg_mutant NO_SWEEP_MOVES lib/md-scope.sh '[ "$GG_MD_RENAMES" = detect ] || return 0' 'return 0'
fx_moved control-sweep
assert_eq "must-fail: with no staged moves read, a sweep measures a moved README at its new path alone" \
  "rc=1" "$(MDT="${NO_SWEEP_MOVES%/lib/md-scope.sh}/md-type" lane_run --all '^$')"
gg_mutant NO_COPIES lib/configured-paths.sh 'detect) GG_WALK_DIFF=(--find-copies --diff-filter=AMTRC) ;;' 'detect) GG_WALK_DIFF=(--find-renames --diff-filter=AMTR) ;;'
for row in "fx_replaced|--staged" "fx_replaced_pushed|--against HEAD~1" "fx_replaced|--all"; do
  IFS='|' read -r fx args <<<"$row"
  "$fx" "control-${fx#fx_}${args%% *}"
  assert_eq "must-fail: with no copy pairing, $args measures a README moved from a refilled path at its new path alone" \
    "rc=1 ${F}value-table path=docs/README.md type=readme line=7 rule=$README_ROW count=1 baseline=none introduced=yes section=Settings" \
    "$(MDT="${NO_COPIES%/lib/configured-paths.sh}/md-type" lane_run "$args")"
done
gg_mutant ALL_COPIES lib/configured-paths.sh 'detect) GG_WALK_DIFF=(--find-copies --diff-filter=AMTRC) ;;' 'detect) GG_WALK_DIFF=(--find-copies-harder --diff-filter=AMTRC) ;;'
for row in "fx_copied|--staged|" "fx_copied_pushed|--against HEAD~1|" "fx_copied|--all|$COPY_SOURCE;"; do
  IFS='|' read -r fx args also <<<"$row"
  "$fx" "control-all-${fx#fx_}${args%% *}"
  assert_eq "must-fail: with copies paired from unchanged files, $args lets a README copied from an old one pass" \
    "rc=0 $also${COPY_NEW/baseline=none introduced=yes/baseline=1 introduced=no}" \
    "$(MDT="${ALL_COPIES%/lib/configured-paths.sh}/md-type" lane_run "$args")"
done
gg_mutant NO_DASH lib/md-type.awk 'function dash(s) { return (s == "") ? "-" : s }' 'function dash(s) { return s }'
repo control-dash
assert_eq "must-fail: with empty cells written empty, the decision row's example shifts into its reference" \
  "rc=0 md-type: type=decision-records;md-type: reference=$(cd "$R" && pwd -P)/$DWR/examples/decision.md" \
  "$(rc=0; out="$(cd "$R" && "${NO_DASH%/lib/md-type.awk}/md-type" --route docs/decisions/D001-one.md 2>&1)" || rc=$?; keyed "$rc" "$out")"
gg_mutant NO_SETEXT lib/md-type.awk 'if (run_start) start = run_start' 'if (0) start = run_start'
repo control-setext
assert_eq "must-fail: with a Setext heading's text kept as content, its section supplies the description" \
  "rc=0" "$(MDT="${NO_SETEXT%/lib/md-type.awk}/md-type" as_run README.md '# Tool\n\nFeatures\n--------\n\n- One.\n')"
gg_mutant NO_REPO md-type '[ ! -e "$at/.git" ] || gg_fail_cause route-repo' ': || gg_fail_cause route-repo'
assert_eq "must-fail: with no .git walk, a repository git refuses reads as outside every repository" \
  "rc=0 md-type: route=outside-repo" "$(route_refused "$NO_REPO")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
