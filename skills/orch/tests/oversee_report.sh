#!/usr/bin/env bash
# oversee-report: when the overseer's status report is due, and the four rows
# it renders from the fleet state, GitHub and the tracker.
#
# Every case runs the real script against a fleet state under TMP_ROOT, with
# gh, the Linear CLI and the clock stubbed, and asserts its exit status, its
# stdout whole where stdout is the protocol, and the keyed first stderr line
# of a refusal. A report's age is its file's modification time, so each case
# stamps the files it plants against the stubbed clock.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_BIN="$(cd "$TEST_DIR/../scripts" && pwd)/oversee-report"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REAL_DATE="$(command -v date)"

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
    [[ ! -s "$CASE/err" ]] || sed 's/^/        stderr: /' "$CASE/err"
  fi
}

# The clock every case reads: `date -u +%s` answers NOW, every other call is
# the host's date.
NOW=1790000000
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/date" <<EOF
#!/usr/bin/env bash
[[ "\$*" != "-u +%s" ]] || { echo $NOW; exit 0; }
exec "$REAL_DATE" "\$@"
EOF
# gh: `pr list --state merged` answers merged.json, `pr list --state open`
# open.json, and `issue view N` issue-N.json, each from the case directory.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "pr list")
    state=""
    while [[ $# -gt 0 ]]; do [[ "$1" != --state ]] || state="$2"; shift; done
    [[ ! -f "$CASE/gh-fail" ]] || { echo "HTTP 502" >&2; exit 1; }
    if [[ -f "$CASE/$state.json" ]]; then cat "$CASE/$state.json"; else echo '[]'; fi ;;
  "issue view")
    [[ -f "$CASE/issue-$3.json" ]] || { echo "no issue $3" >&2; exit 1; }
    cat "$CASE/issue-$3.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
# The Linear CLI: `cache issues get ID` answers linear-ID.json.
cat > "$TMP_ROOT/bin/linear" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "cache issues get" && -f "$CASE/linear-$4.json" ]] || { echo "No cache entry for $4" >&2; exit 1; }
cat "$CASE/linear-$4.json"
EOF
chmod +x "$TMP_ROOT/bin/date" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/linear"

# at OFFSET — the UTC ISO stamp OFFSET seconds from NOW.
at() { "$REAL_DATE" -u -d "@$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || "$REAL_DATE" -u -r "$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ; }
# report OFFSET [NAME] — a prior report file whose modification time is
# OFFSET seconds from NOW.
report() {
  local file="$CASE/progress-reports/${2:-prior}.md" when
  mkdir -p "$CASE/progress-reports"
  echo "an earlier report" > "$file"
  when="$("$REAL_DATE" -u -d "@$((NOW + $1))" +%Y%m%d%H%M.%S 2>/dev/null || "$REAL_DATE" -u -r "$((NOW + $1))" +%Y%m%d%H%M.%S)"
  TZ=UTC touch -t "$when" "$file"
}
# issue KEY TITLE DONE_WHEN_LINE — the tracker's copy of a Linear issue.
issue() {
  jq -n --arg title "$2" --arg why "$3" \
    '{title: $title, description: ("Context first.\n\n## Done when\n\n* " + $why + "\n* A second line.\n\n## Context\n\nMore.")}' \
    > "$CASE/linear-$1.json"
}
# lane ITEM STATUS [LAUNCH_OFFSET] — one lanes[] record.
lane() {
  jq -cn --arg item "$1" --arg status "$2" --arg at "$(at "${3:--86400}")" \
    '{item: $item, status: $status, launched_at: $at, window: null, host: null}'
}
# fleet [JQ_EXTRA] LANE... — the case's fleet state; JQ_EXTRA adds fields.
fleet() {
  local extra="$1"; shift
  printf '%s\n' "$@" | jq -s "{issue_id: \"oversee\", triaged: [], lanes: .} $extra" > "$CASE/state.json"
}
# merged NUMBER BRANCH OFFSET SHA — one merged pull request.
merged_pr() {
  jq -cn --argjson n "$1" --arg b "$2" --arg at "$(at "$3")" --arg sha "$4" \
    '{number: $n, headRefName: $b, headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: $sha}}'
}
CASE=""
new_case() {
  CASE="$TMP_ROOT/cases/$1"
  mkdir -p "$CASE"
}
# run [ENV=VAL...] -- ARGS... — the script under test (REPORT_UNDER_TEST, the
# real one by default) in the case directory with every report setting unset.
OUT=""
RC=0
run() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  OUT="$(cd "$CASE" && env -u ORCH_REPORT -u ORCH_REPORT_EVERY_MINUTES -u ORCH_REPORT_EVERY_ISSUES \
    -u ORCH_REPORT_UPCOMING -u ORCH_REPORT_COLUMNS -u GH_TOKEN -u GITHUB_TOKEN \
    PATH="$TMP_ROOT/bin:$PATH" CASE="$CASE" OVERSEE_REPORT_TRACKER="$TMP_ROOT/bin/linear" \
    ${envs[@]+"${envs[@]}"} "${REPORT_UNDER_TEST:-$REPORT_BIN}" "$@" 2>"$CASE/err")" || RC=$?
}
first_err() { awk 'NR == 1' "$CASE/err"; }

# A fleet with one of each: KEN-1 landed after the last report, KEN-3 landed
# before it, KEN-9 is no fleet item, KEN-2 and KEN-3 still run, KEN-2 with an
# open PR; KEN-4 to KEN-6 wait in the queue and one question is open.
seed_fleet() {
  new_case "$1"
  report -3600
  fleet '+ {launch_queue: ["KEN-4", "KEN-5", "KEN-6"], owner_items: [{id: "a", text: "Merge the pricing change?"}, {id: "b", text: "Answered one", answered_at: "2026-09-01T00:00:00Z"}]}' \
    "$(lane KEN-1 done)" "$(lane KEN-2 running)" "$(lane KEN-3 running)"
  printf '%s\n' "$(merged_pr 11 ken-1 -60 abcdef1234)" "$(merged_pr 13 ken-3 -7200 1234567abc)" \
    "$(merged_pr 19 ken-9 -60 9999999aaa)" | jq -s . > "$CASE/merged.json"
  echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.json"
  local n
  for n in 1 2 3 4 5 6; do issue "KEN-$n" "Title $n" "Outcome $n | kept"; done
}

echo "=== render: the four rows from a fleet ==="
seed_fleet render_fleet
run -- render --state "$CASE/state.json" --repo owner/repo
WANT="Landed:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 \\| kept |

Running:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-2 (#12, running) | Title 2 | Outcome 2 \\| kept |
| KEN-3 (no PR, running) | Title 3 | Outcome 3 \\| kept |

Next:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-4 | Title 4 | Outcome 4 \\| kept |
| KEN-5 | Title 5 | Outcome 5 \\| kept |
| KEN-6 | Title 6 | Outcome 6 \\| kept |

Waiting on you:
- Merge the pricing change?"
assert_eq "$RC|$OUT" "0|$WANT" \
  "Landed holds only the fleet item merged since the last report, Running each live lane with its PR, Next the queue, Waiting on you the open question"

echo "=== render: nothing since the last report ==="
new_case render_empty
report -60
fleet '' "$(lane KEN-1 done)"
echo "[$(merged_pr 11 ken-1 -120 abcdef1234)]" > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|Landed: none

Running: none

Next: none

Waiting on you: none" "a fleet with nothing new renders each row as none and exits 0"

echo "=== render: ORCH_REPORT_UPCOMING caps Next ==="
for row in "2|KEN-4,KEN-5" "0|none" "|KEN-4,KEN-5,KEN-6"; do
  IFS='|' read -r upcoming want <<<"$row"
  seed_fleet "upcoming_${upcoming:-default}"
  if [[ -n "$upcoming" ]]; then run ORCH_REPORT_UPCOMING="$upcoming" -- render --state "$CASE/state.json" --repo owner/repo
  else run -- render --state "$CASE/state.json" --repo owner/repo; fi
  got="$(awk '/^Next/ { on = 1; if ($0 == "Next: none") print "none"; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print $2 }' <<<"$OUT" | paste -sd, -)"
  assert_eq "$RC|$got" "0|$want" "ORCH_REPORT_UPCOMING=${upcoming:-unset} renders Next as $want"
done

echo "=== render: ORCH_REPORT_COLUMNS picks and orders the columns ==="
seed_fleet columns
run ORCH_REPORT_COLUMNS="why it matters, issue" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk 'NR <= 4' <<<"$OUT")" "0|Landed:
| why it matters | issue |
| --- | --- |
| Outcome 1 \\| kept | KEN-1 (#11, abcdef1) |" "a custom column list renders those columns in its order"

echo "=== render: a GitHub item reads its issue from GitHub ==="
new_case github_item
report -60
fleet '' "$(lane issue-7 running)"
jq -n '{title: "GitHub title", body: "## Done when\n- GitHub outcome"}' > "$CASE/issue-7.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^\| issue-7/' <<<"$OUT")" "0|| issue-7 (no PR, running) | GitHub title | GitHub outcome |" \
  "an issue-N lane with no tracker recorded reads title and Done-when through gh"

echo "=== write: the chat and the file carry one report ==="
seed_fleet write_report
printf 'Two items landed and one waits on you.\n\n\n' > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
NAME="$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M)-succession.md"
FILE="$CASE/progress-reports/$NAME"
assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$FILE" "a succession write names its file MM-DD-HH-MM-succession.md"
assert_eq "printed=$([[ -n "$OUT" ]] && echo yes)|$OUT" "printed=yes|$(cat "$FILE" 2>/dev/null)" "what write prints is the file's content, byte for byte"
assert_eq "$(grep -c -E '^(Landed|Running|Next|Waiting on you):' <<<"$OUT")|$(awk 'NR == 1' <<<"$OUT")|$(awk 'NR == 3' <<<"$OUT")" \
  "4|Two items landed and one waits on you.|Landed:" "the report is the summary, one blank line, then the four rows"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
assert_eq "$RC|$(first_err)" "2|oversee-report: report-exists=$FILE" "a second report under the same name is refused, never overwritten"
: > "$CASE/empty.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/empty.txt"
assert_eq "$RC|$(first_err)" "2|oversee-report: summary=$CASE/empty.txt" "a write with an empty summary is refused"

echo "=== due: the cadence ==="
# Rows: case | report age in seconds, or none | settings | merged PR offsets | want.
while IFS='|' read -r name age settings merges want; do
  new_case "due_$name"
  [[ "$age" == none ]] || report "-$age"
  fleet '' "$(lane KEN-1 running -86400)"
  printf '%s\n' "[]" > "$CASE/merged.json"
  if [[ -n "$merges" ]]; then
    for offset in $merges; do merged_pr 11 ken-1 "$offset" abcdef1234; done | jq -s . > "$CASE/merged.json"
  fi
  read -r -a envs <<<"$settings"
  run ${envs[@]+"${envs[@]}"} -- due --state "$CASE/state.json" --repo owner/repo
  want="${want//@AGE/$(at "-${age/none/86400}")}"
  assert_eq "$RC|$OUT" "0|$want" "due, $name"
done <<'ROWS'
under_interval|7140|||
at_interval|7200|||report-due reason=minutes since=@AGE
custom_interval|600|ORCH_REPORT_EVERY_MINUTES=10||report-due reason=minutes since=@AGE
empty_minutes|999999|ORCH_REPORT_EVERY_MINUTES=||
zero_minutes|999999|ORCH_REPORT_EVERY_MINUTES=0||
off|999999|ORCH_REPORT=off||
no_report_yet|none|||report-due reason=minutes since=@AGE
issues_reached|60|ORCH_REPORT_EVERY_ISSUES=1|-30|report-due reason=issues since=@AGE landed=1
issues_before_marker|60|ORCH_REPORT_EVERY_ISSUES=1|-120|
ROWS
new_case due_no_lanes
fleet ''
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|" "due, a state with no lane record has no fleet start and nothing is due"

echo "=== refusals ==="
while IFS='|' read -r setting want; do
  seed_fleet "refuse_${setting%%=*}"
  run "$setting" -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: setting=$want" "$setting is refused"
done <<'ROWS'
ORCH_REPORT=maybe|ORCH_REPORT:maybe
ORCH_REPORT_EVERY_MINUTES=2h|ORCH_REPORT_EVERY_MINUTES:2h
ORCH_REPORT_EVERY_ISSUES=-1|ORCH_REPORT_EVERY_ISSUES:-1
ORCH_REPORT_UPCOMING=05|ORCH_REPORT_UPCOMING:05
ORCH_REPORT_COLUMNS=issue,owner|ORCH_REPORT_COLUMNS:issue,owner
ORCH_REPORT_COLUMNS=issue,issue|ORCH_REPORT_COLUMNS:issue,issue
ORCH_REPORT_COLUMNS=|ORCH_REPORT_COLUMNS:
ROWS
seed_fleet refuse_gh
touch "$CASE/gh-fail"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "a failing merged list refuses rather than render Landed as none"
seed_fleet refuse_tracker
rm -f "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "an issue the tracker cannot read refuses"

echo "=== must-fail control ==="
# Without the since filter, a merge older than the last report is news again.
MUTANT="$TMP_ROOT/mutant/scripts/oversee-report"
mkdir -p "$TMP_ROOT/mutant"
cp -R "$TEST_DIR/../scripts" "$TMP_ROOT/mutant/scripts"
filter='          | select(.at >= $since) ]'
assert_eq "$(grep -cxF -- "$filter" "$REPORT_BIN")" "1" "control: the since filter is one line to strip"
awk -v line="$filter" '$0 == line { print "          ]"; next } { print }' "$REPORT_BIN" > "$MUTANT"
seed_fleet render_mutant
REPORT_UNDER_TEST="$MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$(grep -c '^| KEN-3 (#13, 1234567)' <<<"$OUT")" "1" "control: without the filter Landed carries the merge from before the last report"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
