#!/usr/bin/env bash
# lib/escapes.sh: the escape count behind oversee-report's Escapes line.
#
# Each case builds a checkout whose origin holds merges and reverts at chosen
# times, stubs the Linear CLI's label list and issue list, and calls
# escapes_read at a fixed NOW. It asserts the per-week lines the renderer
# reads, or the return status and the cause an unread count names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "oversee_report_escapes: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_report_escapes: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_report_escapes: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/escapes-fixture.sh
source "$TEST_DIR/lib/escapes-fixture.sh"
# path_without, for the PATH that carries gtimeout alone.
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, for the must-fail controls.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
LIB="$TEST_DIR/../scripts/lib/escapes.sh"

at() { jq -rn --arg s "$1" '$s | fromdateiso8601'; }
# A Wednesday: the six weeks counted are the Mondays 2026-08-24 to 2026-09-28.
NOW="$(at 2026-09-30T12:00:00Z)"
# The repository lib/gh-repo.sh resolves: a number qualified with it names
# this repository's pull request.
REPO=owner/repo

# The Linear CLI, read live: the label list answers $ESCAPES_LABELS, or fails
# under $ESCAPES_LINEAR_FAIL; the issue list answers the issues of
# $ESCAPES_ISSUES created within --created-since days of $NOW, carrying the
# --label it names (every issue where it names none), in the team --team
# names, and archived only under --include-archived. Each issue's `team` and
# `archived` stand for what the filters read and the safe shape drops. An
# issue list that is no array passes through whole. Each issue read's
# arguments are kept in $ESCAPES_CALLS. Any other call fails, an empty --team
# among them.
LINEAR="$TMP_ROOT/linear"
cat > "$LINEAR" <<'EOF'
#!/usr/bin/env bash
[[ -z "${ESCAPES_LINEAR_FAIL:-}" ]] || { echo "linear stub: read failed" >&2; exit 1; }
unexpected() { echo "linear stub: unexpected call: $*" >&2; exit 1; }
case "$*" in
  "labels list --max --format=safe") exec cat -- "$ESCAPES_LABELS" ;;
  "issues list "*) printf '%s\n' "$*" >>"${ESCAPES_CALLS:-/dev/null}" ;;
  *) unexpected "$@" ;;
esac
args="$*" label="" days="" team="" archived=false
shift 2
while (($#)); do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --created-since) days="${2%d}"; shift 2 ;;
    --team) [[ -n "$2" ]] || exit 1; team="$2"; shift 2 ;;
    --include-archived) archived=true; shift ;;
    --max | --format=safe) shift ;;
    *) unexpected "$args" ;;
  esac
done
[[ "$days" =~ ^[0-9]+$ ]] || unexpected "$args"
jq --arg label "$label" --arg team "$team" --argjson archived "$archived" --argjson cut "$((NOW - days * 86400))" '
  if type == "array" then map(select(($label == "" or any(.labels[]; . == $label))
    and ($team == "" or .team == $team) and ($archived or (.archived | not))
    and (.created_at | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601) >= $cut) | del(.team, .archived)) else . end' \
  -- "$ESCAPES_ISSUES"
EOF
chmod +x "$LINEAR"
export ESCAPES_LABELS="$TMP_ROOT/labels.json"
echo '[{"name": "Feature"}, {"name": "Bug"}, {"name": "bug"}, {"name": "feature"}]' > "$ESCAPES_LABELS"

# count LIB ROOT [TRACKER] [NAME=VALUE ...] — escapes_read from LIB against
# ROOT at NOW, with LINEAR_TEAM the project's team, kendex, each NAME=VALUE set
# after the lib is sourced, so one may stand in for NOW, the team or a lib
# setting: `rc=N` then ESCAPE_WEEKS' lines, or `rc=N
# unread=<cause>` where it names one.
count() {
  local scratch
  scratch="$(mktemp -d "$TMP_ROOT/scratch.XXXXXX")" || return 1
  (
    unset WORKTREE_DEFAULT_BRANCH
    export GH_REPO="$REPO" LINEAR_TEAM=kendex
    # shellcheck source=../scripts/lib/escapes.sh
    source "$1"
    local assignment
    for assignment in "${@:4}"; do export "${assignment?}"; done
    # The stub's clock, as the CLI's is the report's.
    export NOW
    rc=0
    escapes_read "$2" "${3:-$LINEAR}" "$NOW" "$scratch" || rc=$?
    printf 'rc=%s%s\n%s' "$rc" "${ESCAPE_UNREAD:+ unread=$ESCAPE_UNREAD}" "$ESCAPE_WEEKS"
  )
}

echo
echo "--- the count, one world ---"

# Merges and reverts on origin/main, oldest first, and the issues. Each
# comment names the rule the row holds and the week it lands in. A row with a
# third field is a merge whose second parent carries that commit.
COMMITS=(
  # #9's first finding, this revert, falls before the window, so its later
  # bug issue does not count it inside the window.
  "2026-08-11T10:00:00Z|feat: merged before the window (#9)"
  # #10's first finding is a bug filed the next day, before the window, so
  # its revert in the week of 08-24 does not count either: the bug read
  # reaches back past the window to find it.
  "2026-08-12T10:00:00Z|feat: reverted 13 days later (#10)"
  "2026-08-15T10:00:00Z|Revert \"feat: merged before the window (#9)\" (#21)"
  # #12's revert comes 19 days after its merge: past the 14-day reach.
  "2026-08-20T10:00:00Z|feat: reverted too late (#12)"
  # Week of 08-24: the revert names #10 thirteen days after its merge, and a
  # bug names #23.
  "2026-08-24T08:00:00Z|feat: a bug names it the next day (#23)"
  "2026-08-25T10:00:00Z|Revert \"feat: reverted 13 days later (#10)\" (#20)"
  # Week of 08-31: an issue labelled Bug names #11 and #48 on one
  # Regressed-by line.
  "2026-08-31T10:00:00Z|fix: found by a bug issue (#11)"
  "2026-09-01T10:00:00Z|feat: backed out by a lowercase revert (#40)"
  "2026-09-01T12:00:00Z|feat: second on a Regressed-by line (#48)"
  # Week of 09-07: a lowercase revert is #40's one finding.
  "2026-09-08T10:00:00Z|Revert \"feat: reverted too late (#12)\" (#22)"
  "2026-09-08T12:00:00Z|revert: back out #40 (#41)"
  "2026-09-10T10:00:00Z|feat: reverted exactly 14 days later (#45)"
  # Week of 09-14: #13's bug issue predates its merge, an issue labelled
  # feature names it, and a commit a merge brought in on its second parent
  # reverts it: none counts. This revert names #99, never merged, beside its
  # own merge #14, which names no escape. A bug's bold Regressed-by line
  # names #42. Bugs name #47 only in a title and in Source and Reached by
  # lines: it does not count.
  "2026-09-14T10:00:00Z|feat: named before its merge (#13)"
  "2026-09-15T10:00:00Z|Revert \"feat: never merged here (#99)\" (#14)"
  "2026-09-15T12:00:00Z|feat: a bug names it in its description (#42)"
  "2026-09-15T13:00:00Z|feat: a bug cites it only as its source (#47)"
  "2026-09-16T10:00:00Z|Merge pull request #43 from owner/ken-43|Revert \"feat: named before its merge (#13)\" (#44)"
  # Week of 09-21: a bug issue and a revert both name #15; one escape, in the
  # week of the earlier. #45's revert comes exactly 14 days after its merge.
  # An archived bug names #16, the revert's own merge: it does not count.
  "2026-09-21T10:00:00Z|feat: found twice (#15)"
  "2026-09-23T10:00:00Z|revert: back out #15 (#16)"
  "2026-09-24T10:00:00Z|Revert \"feat: reverted exactly 14 days later (#45)\" (#46)"
  # Week of 09-28: a bug names #18 qualified with this repository, one names
  # #170, which is not #17, and one names #17 of another repository. A bug in
  # another team names #49: its bare number is that team's repository's.
  "2026-09-28T08:00:00Z|feat: another team's bug names it (#49)"
  "2026-09-28T09:00:00Z|feat: a number inside a longer one (#17)"
  "2026-09-28T10:00:00Z|Merge pull request #18 from owner/ken-18"
)
# id|created|title|description|label|team|archived; an empty description or
# label is the fixture's default, an empty team is kendex, and `\n` in a
# description is a newline.
BUGS=(
  "KEN-B9|2026-08-24T09:00:00Z|after its revert, #9 breaks again|Regressed-by: #9|"
  "KEN-B10|2026-08-13T10:00:00Z|the day after it merges|Regressed-by: #10|"
  "KEN-B23|2026-08-25T09:00:00Z|the day after it merges|Regressed-by: #23|"
  "KEN-A16|2026-09-24T12:00:00Z|archived since|Regressed-by: #16|||archived"
  "KEN-B11|2026-09-02T10:00:00Z|the report breaks|Regressed-by: #11, #48|Bug"
  "KEN-B13|2026-09-10T10:00:00Z|wrong before it merges|Regressed-by: #13|"
  "KEN-F13|2026-09-15T11:00:00Z|follow up|Regressed-by: #13|feature"
  "KEN-B42|2026-09-16T12:00:00Z|the watch hangs|**Symptom**: the watch hangs.\n**Regressed-by**: #42|"
  "KEN-T47|2026-09-16T13:00:00Z|#47 breaks the watch||"
  "KEN-S47|2026-09-16T14:00:00Z|the watch stalls|**Source**: review of owner/repo#47\n**Reached by**: every watch since #47\nSource PR: owner/repo#47|"
  "KEN-B15|2026-09-22T10:00:00Z|the watch breaks|Regressed-by: #15|"
  "KEN-B17|2026-09-29T10:00:00Z|the build breaks|Regressed-by: #170|"
  "KEN-X17|2026-09-29T10:30:00Z|the build breaks|Regressed-by: other/repo#17|"
  "KEN-B18|2026-09-29T11:00:00Z|the build breaks|Regressed-by: Owner/Repo#18|"
  "OTH-B49|2026-09-29T12:00:00Z|the build breaks|Regressed-by: #49||other"
)
WANT="rc=0
2026-08-24	1
2026-08-31	2
2026-09-07	1
2026-09-14	1
2026-09-21	2
2026-09-28	1"

WORLD="$TMP_ROOT/world"
escapes_checkout "$WORLD"
for row in "${COMMITS[@]}"; do
  IFS='|' read -r when subject side <<<"$row"
  if [[ -n "$side" ]]; then
    escapes_merge "$WORLD" "$(at "$when")" "$subject" "$side"
  else
    escapes_commit "$WORLD" "$(at "$when")" "$subject"
  fi
done
escapes_publish "$WORLD"
bug_lines=""
for row in "${BUGS[@]}"; do
  IFS='|' read -r id when title description label team archived <<<"$row"
  description="${description//\\n/$'\n'}"
  bug_lines+="$(escapes_bug "$id" "$(at "$when")" "$title" "$description" "$label" \
    | jq -c --arg team "${team:-kendex}" --arg archived "$archived" '. + {team: $team, archived: ($archived == "archived")}')"$'\n'
done
export ESCAPES_ISSUES="$TMP_ROOT/issues.json"
jq -s . <<<"$bug_lines" > "$ESCAPES_ISSUES"

assert_eq "$(count "$LIB" "$WORLD")" "$WANT" \
  "a revert or a bug's Regressed-by line naming a merged PR within 14 days counts once, in the week of its first finding; a late, early, self-named, unmerged, second-parent, non-bug, foreign, other-team, archived or source-only one does not"

# Months after the cap week, the count still reaches back to it.
LATER="$(at 2027-01-13T12:00:00Z)"
later_cap() { count "$1" "$WORLD" "" NOW="$LATER" | awk -F'\t' '$1 == "2026-09-28"'; }
assert_eq "$(later_cap "$LIB")" "2026-09-28	1" "months after the cap week, its count still prints"

# The count fetches first: a revert another clone pushed after this checkout
# last fetched is counted. The world's copy takes the push, so the world
# itself stays as WANT reads it. The copy keeps the origin's maintenance
# settings; a clone does not inherit them, so each clone sets its own.
cp -R "$WORLD.origin" "$TMP_ROOT/stale.origin"
git clone -q -c gc.auto=0 -c maintenance.auto=false "$TMP_ROOT/stale.origin" "$TMP_ROOT/stale"
git clone -q -c gc.auto=0 -c maintenance.auto=false "$TMP_ROOT/stale.origin" "$TMP_ROOT/other"
escapes_commit "$TMP_ROOT/other" "$(at 2026-09-30T06:00:00Z)" "Revert \"feat: a number inside a longer one (#17)\" (#19)"
git -C "$TMP_ROOT/other" push -q origin main
assert_eq "$(count "$LIB" "$TMP_ROOT/stale" | tail -n 1)" "2026-09-28	2" "a revert on origin that this checkout has not fetched is counted"

# The count asks Linear for the bugs alone, once per spelling of the label,
# created no earlier than the window's reach, in the project's team.
calls="$TMP_ROOT/escapes-calls"
: > "$calls"
count "$LIB" "$WORLD" "" ESCAPES_CALLS="$calls" >/dev/null
assert_eq "$(awk '{print $4}' "$calls" | LC_ALL=C sort | paste -sd, -)" "Bug,bug" "each spelling of bug is read, and nothing else"
assert_eq "$(awk '{print $9}' "$calls" | sort -u)" "kendex" "the bug read names the project's team"
# NOW is 2026-09-30T12:00Z and the window's reach starts 2026-08-10T00:00Z:
# 51 whole days back, with a day of margin either side.
assert_eq "$(awk '{print $6}' "$calls" | sort -u)" "53d" "the bug read reaches back from NOW past the window's reach"

# The base branch is the one origin's HEAD names, here trunk; the world has
# no main on origin.
TRUNK="$TMP_ROOT/trunk"
escapes_checkout "$TRUNK"
escapes_commit "$TRUNK" "$(at 2026-09-29T10:00:00Z)" "feat: on trunk (#50)"
escapes_commit "$TRUNK" "$(at 2026-09-29T12:00:00Z)" "Revert \"feat: on trunk (#50)\" (#51)"
git -C "$TRUNK" push -q origin main:trunk
git -C "$TRUNK" fetch -q origin
git -C "$TRUNK" remote set-head origin trunk
on_trunk() { count "$1" "$TRUNK" | tail -n 1; }
assert_eq "$(on_trunk "$LIB")" "2026-09-28	1" "a repository whose default branch is trunk is counted off trunk"

echo
echo "--- an unread count ---"

NO_ORIGIN="$TMP_ROOT/no-origin"
git init -q "$NO_ORIGIN"
git -C "$NO_ORIGIN" config gc.auto 0
git -C "$NO_ORIGIN" config maintenance.auto false
NOT_A_CHECKOUT="$TMP_ROOT/not-a-checkout"
mkdir "$NOT_A_CHECKOUT"
LOCAL_ORIGIN="$TMP_ROOT/local-origin"
git clone -q -c gc.auto=0 -c maintenance.auto=false "$WORLD.origin" "$LOCAL_ORIGIN"
# An origin whose transport never answers: the fetch outlives its bound.
HANGS="$TMP_ROOT/hangs"
git init -q "$HANGS"
git -C "$HANGS" config gc.auto 0
git -C "$HANGS" config maintenance.auto false
git -C "$HANGS" remote add origin ssh://example.invalid/owner/repo
git -C "$HANGS" config core.sshCommand "sleep 2; :"
NOT_EXECUTABLE="$TMP_ROOT/linear-not-executable"
: > "$NOT_EXECUTABLE"
SLOW_READ="$TMP_ROOT/linear-slow-read"
printf '#!/usr/bin/env bash\nsleep 2\nexit 1\n' > "$SLOW_READ"
chmod +x "$SLOW_READ"
# The label read answers at once; the issue read outlives its bound.
SLOW_ISSUES="$TMP_ROOT/linear-slow-issues"
printf '#!/usr/bin/env bash\n[[ "$1" == labels ]] && exec cat -- "$ESCAPES_LABELS"\nsleep 2\nexit 1\n' > "$SLOW_ISSUES"
chmod +x "$SLOW_ISSUES"
# The label read answers; the issue read fails.
FAILING="$TMP_ROOT/linear-failing"
printf '#!/usr/bin/env bash\n[[ "$1" == labels ]] && exec cat -- "$ESCAPES_LABELS"\necho "read failed" >&2\nexit 1\n' > "$FAILING"
chmod +x "$FAILING"
NOT_A_LIST="$TMP_ROOT/not-a-list.json"
echo '{"issues": []}' > "$NOT_A_LIST"
# A PATH whose one bound command is gtimeout, the name a Homebrew coreutils
# install gives timeout: a shim to whichever of the two this host carries.
GTIMEOUT_ONLY="$TMP_ROOT/gtimeout-only"
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
if [[ -n "$REAL_TIMEOUT" ]]; then
  path_without "$GTIMEOUT_ONLY" timeout
  rm -f -- "${GTIMEOUT_ONLY:?}/gtimeout"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$REAL_TIMEOUT" > "$GTIMEOUT_ONLY/gtimeout"
  chmod +x "$GTIMEOUT_ONLY/gtimeout"
fi
NO_BUG_LABEL="$TMP_ROOT/no-bug-label.json"
echo '[{"name": "Feature"}, {"name": "bugfix"}]' > "$NO_BUG_LABEL"
# root|tracker|the first line|NAME=VALUE ..., an empty tracker the stub
UNREAD=(
  "$NOT_A_CHECKOUT||rc=1 unread=the base branch did not resolve|"
  "$NO_ORIGIN||rc=1 unread=git fetch origin main failed|"
  "$LOCAL_ORIGIN||rc=1 unread=the repository's owner/name did not resolve|GH_REPO="
  "$WORLD|$NOT_EXECUTABLE|rc=1 unread=no Linear CLI|"
  "$WORLD||rc=1 unread=Linear read failed|ESCAPES_LINEAR_FAIL=1"
  "$WORLD|$FAILING|rc=1 unread=Linear read failed|"
  "$WORLD||rc=1 unread=no Linear label named bug|ESCAPES_LABELS=$NO_BUG_LABEL"
  "$WORLD||rc=1 unread=the Linear label list did not parse|ESCAPES_LABELS=$NOT_A_LIST"
  "$WORLD||rc=1 unread=the bug list did not parse|ESCAPES_ISSUES=$NOT_A_LIST"
  "$WORLD||rc=1 unread=the clock reads before the cap week 2026-09-28|NOW=$(at 2026-09-21T12:00:00Z)"
)
# The fetch and the Linear reads are bounded only where `timeout` or `gtimeout`
# exists; stock macOS ships neither. Each bound is one second, so each row
# waits that long.
if [[ -n "$REAL_TIMEOUT" ]]; then
  UNREAD+=("$HANGS||rc=1 unread=git fetch origin main timed out|ESCAPE_FETCH_SECONDS=1"
    "$WORLD|$SLOW_READ|rc=1 unread=Linear read timed out|ESCAPE_LINEAR_SECONDS=1"
    "$WORLD|$SLOW_ISSUES|rc=1 unread=Linear read timed out|ESCAPE_LINEAR_SECONDS=1"
    "$HANGS||rc=1 unread=git fetch origin main timed out|ESCAPE_FETCH_SECONDS=1 PATH=$GTIMEOUT_ONLY")
fi
for row in "${UNREAD[@]}"; do
  IFS='|' read -r root tracker want assignments <<<"$row"
  # shellcheck disable=SC2086 # the assignments are whitespace-separated words
  assert_eq "$(count "$LIB" "$root" "$tracker" $assignments)" "$want" "${want#*unread=}: no count, never 0"
done

echo
echo "--- planted controls ---"

# Each control edits a copy of the lib and runs the row that holds its rule:
# the row must no longer read what it reads above. A mutant beside the
# github skill, which lib/gh-repo.sh sources.
mutant_lib() { # NAME
  local lib
  lib="$(mutant_scripts "$1/orch" lib/escapes.sh)/lib/escapes.sh" || exit 1
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/$1/github" || exit 1
  printf '%s\n' "$lib"
}
world() { count "$1" "$WORLD"; }
# name|the row it reddens|old|new
CONTROLS=(
  'no-reach|world|reach "$ESCAPE_REACH"|reach 999999999'
  'reach-exclusive|world|$f.t - $m.t <= $reach|$f.t - $m.t < $reach'
  'capital-revert-only|world|test("^[Rr]evert")|test("^Revert")'
  'every-number|world|def regressed: [split("\n")[] | capture("^(?:[*][*]Regressed-by[*][*]|Regressed-by):(?<v>.*)$").v | numbers[]];|def regressed: numbers;'
  'plain-key-only|world|(?:[*][*]Regressed-by[*][*]|Regressed-by):|Regressed-by:'
  'every-parent|world|log --first-parent|log'
  'label-case|world|select(ascii_downcase == "bug")|select(. == "bug")'
  'any-label|world|issues list --label "$label" \|issues list \'
  'any-repository|world|select(.repo == null or (.repo | ascii_downcase) == ($repo | ascii_downcase))|select(true)'
  'every-team|world|${LINEAR_TEAM:+--team "$LINEAR_TEAM"}|${LINEAR_TEAM:+}'
  'one-day|world|days=$(((now - since) / 86400 + 2))|days=1'
  'window-start|world|days=$(((now - since) / 86400 + 2))|days=$(((now - from) / 86400 + 2))'
  'archived|world|--created-since "${days}d" --max|--created-since "${days}d" --max --include-archived'
  'bare-only|world|select(.repo == null or (.repo | ascii_downcase) == ($repo | ascii_downcase))|select(.repo == null)'
  'window-only|later_cap|((cap >= from)) || from=$cap|true'
  'main-only|on_trunk|"$ESCAPES_LIB_DIR/../resolve-base-branch" "$root"|echo main'
)
hangs() { count "$1" "$HANGS" "" ESCAPE_FETCH_SECONDS=1; }
slow_read() { count "$1" "$WORLD" "$SLOW_READ" ESCAPE_LINEAR_SECONDS=1; }
slow_issues() { count "$1" "$WORLD" "$SLOW_ISSUES" ESCAPE_LINEAR_SECONDS=1; }
gtimeout_hangs() { count "$1" "$HANGS" "" ESCAPE_FETCH_SECONDS=1 PATH="$GTIMEOUT_ONLY"; }
if [[ -n "$REAL_TIMEOUT" ]]; then
  CONTROLS+=('unbounded-fetch|hangs|escapes_bounded "$bound" "$ESCAPE_FETCH_SECONDS" env|env'
    'unbounded-read|slow_read|escapes_bounded "$bound" "$ESCAPE_LINEAR_SECONDS" "$tracker" labels|"$tracker" labels'
    'unbounded-issue-read|slow_issues|escapes_bounded "$bound" "$ESCAPE_LINEAR_SECONDS" "$tracker" issues|"$tracker" issues'
    'timeout-only|gtimeout_hangs|for candidate in timeout gtimeout; do|for candidate in timeout; do')
fi
for row in "${CONTROLS[@]}"; do
  name="${row%%|*}"; rest="${row#*|}"
  reader="${rest%%|*}"; rest="${rest#*|}"
  # The old text may itself hold a bar; the new text never does.
  old="${rest%|*}"; new="${rest##*|}"
  mutant="$(mutant_lib "$name")" || exit 1
  mutate_file "$mutant" "$old" "$new"
  want="$("$reader" "$LIB")"
  got="$("$reader" "$mutant")"
  [[ "$got" != "$want" ]] && pass "control $name: the $reader row flags it" \
    || fail "control $name: the $reader row MISSED it" "got=$got"
done

# The label check dropped: a workspace with no bug label reads a count.
LABEL_LIB="$(mutant_lib no-label-check)" || exit 1
mutate_file "$LABEL_LIB" '[[ -z "$bug_labels" ]]' 'false'
got="$(count "$LABEL_LIB" "$WORLD" "" ESCAPES_LABELS="$NO_BUG_LABEL" | awk 'NR == 1')"
[[ "$got" != "rc=1 unread=no Linear label named bug" ]] && pass "control no-label-check: the no-bug-label row flags it" \
  || fail "control no-label-check: the no-bug-label row MISSED it" "got=$got"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
