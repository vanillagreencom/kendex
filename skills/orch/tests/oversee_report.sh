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
# gh: `pr list --state merged` answers merged.json narrowed to --head and
# capped at --limit, as gh narrows it; `pr list --state open` open.json, and
# `issue view N` issue-N.json, each from the case directory. A file named
# <base>.<SLUG>.json answers that --repo alone, SLUG being the repo with `/`
# as `_`. gh-fail fails every list, gh-fail-open the open list alone.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-} ${2:-}"; number="${3:-}"
state=""; head=""; limit=1000; repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in --state) state="$2" ;; --head) head="$2" ;; --limit) limit="$2" ;; --repo) repo="$2" ;; esac
  shift
done
slug="${repo//\//_}"
pick() { if [[ -f "$CASE/$1.$slug.json" ]]; then printf '%s' "$CASE/$1.$slug.json"; else printf '%s' "$CASE/$1.json"; fi; }
case "$verb" in
  "pr list")
    [[ ! -f "$CASE/gh-fail" ]] || { echo "HTTP 502" >&2; exit 1; }
    [[ ! -f "$CASE/gh-fail-$state" ]] || { echo "HTTP 502" >&2; exit 1; }
    src="$(pick "$state")"
    [[ -f "$src" ]] || { echo '[]'; exit 0; }
    jq -c --arg head "$head" --argjson limit "$limit" \
      '[.[] | select($head == "" or .headRefName == $head)] | .[:$limit]' "$src" ;;
  "issue view")
    src="$(pick "issue-$number")"
    [[ -f "$src" ]] || { echo "no issue $number" >&2; exit 1; }
    cat "$src" ;;
  *) echo "unexpected gh call: $verb" >&2; exit 1 ;;
esac
EOF
# The Linear CLI: `cache issues get ID` answers linear-ID.json in the safe
# shape under --format=safe, and nested as {issue: ...} otherwise, the raw
# shape a project's LINEAR_FORMAT=raw gives a call that names no format.
cat > "$TMP_ROOT/bin/linear" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "cache issues get" && -f "$CASE/linear-$4.json" ]] || { echo "No cache entry for $4" >&2; exit 1; }
if [[ "${5:-}" == --format=safe ]]; then cat "$CASE/linear-$4.json"; else jq -c '{issue: .}' "$CASE/linear-$4.json"; fi
EOF
# github.sh: `pr-list-failing --all` answers failing.<SLUG>.json for the
# GH_REPO it runs under, else failing.json, [] without either.
cat > "$TMP_ROOT/bin/github" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "pr-list-failing --all" ]] || { echo "unexpected github.sh call: $*" >&2; exit 1; }
[[ -n "${GH_REPO:-}" ]] || { echo "github.sh stub: no GH_REPO" >&2; exit 1; }
slug="${GH_REPO//\//_}"
if [[ -f "$CASE/failing.$slug.json" ]]; then cat "$CASE/failing.$slug.json"
elif [[ -f "$CASE/failing.json" ]]; then cat "$CASE/failing.json"
else echo '[]'; fi
EOF
# lane-mail: `pending --item ITEM` answers pending-ITEM.jsonl, nothing
# without one; mail-fail makes it fail. The call must read the lane's own
# root, /w/ITEM, and a hosted lane's (hosted-ITEM names its host) through
# --host under that host's ORCH_LANE_HOST, a local one without --host.
cat > "$TMP_ROOT/bin/lane-mail" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pending --item" ]] || { echo "unexpected lane-mail call: $*" >&2; exit 2; }
want="--root /w/$3"; host=""
[[ ! -f "$CASE/hosted-$3" ]] || { host="$(cat "$CASE/hosted-$3")"; want+=" --host"; }
[[ "${*:4}" == "$want" && "${ORCH_LANE_HOST:-}" == "$host" ]] \
  || { echo "lane-mail stub: wrong route for $3: ${*:4} host=${ORCH_LANE_HOST:-}" >&2; exit 9; }
[[ ! -f "$CASE/mail-fail" ]] || { echo "lane-mail: mail-read-failed" >&2; exit 2; }
[[ ! -f "$CASE/pending-$3.jsonl" ]] || cat "$CASE/pending-$3.jsonl"
EOF
# lane-host: `cat --item ITEM PATH` answers host/PATH, exit 2 without it;
# `touch` succeeds. Every call must run under the ORCH_LANE_HOST its item's
# record names (hosted-ITEM).
cat > "$TMP_ROOT/bin/lane-host" <<'EOF'
#!/usr/bin/env bash
[[ -f "$CASE/hosted-$3" && "${ORCH_LANE_HOST:-}" == "$(cat "$CASE/hosted-$3")" ]] \
  || { echo "lane-host stub: $3 read under host=${ORCH_LANE_HOST:-}" >&2; exit 9; }
case "$1" in
  cat) [[ -f "$CASE/host$4" ]] || exit 2; cat "$CASE/host$4" ;;
  touch) exit 0 ;;
  *) echo "unexpected lane-host call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/date" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/linear" "$TMP_ROOT/bin/github" \
  "$TMP_ROOT/bin/lane-mail" "$TMP_ROOT/bin/lane-host"

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
# lane ITEM STATUS [LAUNCH_OFFSET] [HOST] [TRACKER] [REPO] — one lanes[]
# record; an empty HOST, TRACKER or REPO is recorded as null. A HOST is also
# written to hosted-ITEM, the route the lane-mail and lane-host stubs hold
# every read of that item to.
lane() {
  [[ -z "${4:-}" ]] || printf '%s' "$4" > "$CASE/hosted-$1"
  jq -cn --arg item "$1" --arg status "$2" --arg at "$(at "${3:--86400}")" --arg host "${4:-}" \
    --arg tracker "${5:-}" --arg repo "${6:-}" \
    'def opt: if . == "" then null else . end;
     {item: $item, status: $status, launched_at: $at, window: null, mail_root: "/w/\($item)",
      host: ($host | opt), tracker: ($tracker | opt), repo: ($repo | opt)}'
}
# item_state ITEM JSON — the item's own workflow state on this host.
item_state() {
  mkdir -p "$CASE/ws"
  printf '%s\n' "$2" > "$CASE/ws/workflow-state-$1.json"
}
# fleet [JQ_EXTRA] LANE... — the case's fleet state; JQ_EXTRA adds fields.
fleet() {
  local extra="$1"; shift
  printf '%s\n' "$@" | jq -s "{issue_id: \"oversee\", triaged: [], lanes: .} $extra" > "$CASE/state.json"
}
# merged NUMBER BRANCH OFFSET SHA [OWNER] — one merged pull request; OWNER
# `-` is a head GitHub returns with no owner.
merged_pr() {
  jq -cn --argjson n "$1" --arg b "$2" --arg at "$(at "$3")" --arg sha "$4" --arg owner "${5:-owner}" \
    '{number: $n, headRefName: $b, headRepositoryOwner: (if $owner == "-" then null else {login: $owner} end),
      mergedAt: $at, mergeCommit: {oid: $sha}}'
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
    OVERSEE_REPORT_GITHUB="$TMP_ROOT/bin/github" OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/lane-mail" \
    OVERSEE_REPORT_LANE_HOST="$TMP_ROOT/bin/lane-host" ORCH_STATE_DIR="$CASE/ws" \
    ${envs[@]+"${envs[@]}"} "${REPORT_UNDER_TEST:-$REPORT_BIN}" "$@" 2>"$CASE/err")" || RC=$?
}
first_err() { awk 'NR == 1' "$CASE/err"; }

# A fleet with one of each: KEN-1 landed after the last report, and a fork's
# PR on the ken-1 branch name and one with no head owner did not, KEN-3 landed
# before it, KEN-9 is no fleet item, KEN-2 and KEN-3 still run, KEN-2 with an
# open PR; KEN-4 to KEN-6 wait in the queue and one question is open. KEN-2
# waits on an ask and on red checks, KEN-3 on a post-PR stop. KEN-7 is still
# preparing on its host.
seed_fleet() {
  new_case "$1"
  report -3600
  fleet '+ {launch_queue: ["KEN-4", "KEN-5", "KEN-6"], owner_items: [{id: "a", text: "Merge the pricing change?"}]}' \
    "$(lane KEN-1 done)" "$(lane KEN-2 running)" "$(lane KEN-3 running)" "$(lane KEN-7 preparing -86400 ssh-a)"
  echo '{"id":"1790000000-1-a","kind":"ask","text":"Which schema?"}' > "$CASE/pending-KEN-2.jsonl"
  echo '[{"number": 12, "branch": "ken-2", "failed_checks": ["test", "lint"]}]' > "$CASE/failing.json"
  item_state KEN-3 '{"post_pr_stop": {"name": "review-round-cap", "gate": "review", "remaining": ["one unresolved review thread"]}}'
  item_state KEN-2 '{"post_pr_stop": null}'
  printf '%s\n' "$(merged_pr 11 ken-1 -60 abcdef1234)" "$(merged_pr 13 ken-3 -7200 1234567abc)" \
    "$(merged_pr 19 ken-9 -60 9999999aaa)" "$(merged_pr 21 ken-1 -30 2121212aaa someone-else)" \
    "$(merged_pr 23 ken-1 -30 2323232aaa -)" | jq -s . > "$CASE/merged.json"
  echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.json"
  local n
  for n in 1 2 3 4 5 6 7 8 9; do issue "KEN-$n" "Title $n" "Outcome $n | kept"; done
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
| KEN-7 (no PR, preparing) | Title 7 | Outcome 7 \\| kept |

Next:
| issue | what it is | why it matters |
| --- | --- | --- |
| KEN-4 | Title 4 | Outcome 4 \\| kept |
| KEN-5 | Title 5 | Outcome 5 \\| kept |
| KEN-6 | Title 6 | Outcome 6 \\| kept |

Waiting on you:
- Question for you: Merge the pricing change?
- KEN-2 waits on the overseer to answer: Which schema?
- KEN-2 waits on red checks on #12: test, lint
- KEN-3 waits on a stopped review gate, review-round-cap: one unresolved review thread"
assert_eq "$RC|$OUT" "0|$WANT" \
  "Landed holds only the fleet item merged since the last report, Running each live or preparing lane with its PR, Next the queue, Waiting on you the open question then each running lane's blockers"

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
# A queue of six, so the default cap of 5 is what stops it.
for row in "2|KEN-4,KEN-5" "0|none" "|KEN-4,KEN-5,KEN-6,KEN-7,KEN-8"; do
  IFS='|' read -r upcoming want <<<"$row"
  seed_fleet "upcoming_${upcoming:-default}"
  jq '.launch_queue = ["KEN-4", "KEN-5", "KEN-6", "KEN-7", "KEN-8", "KEN-9"]' "$CASE/state.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/state.json"
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

echo "=== render: the tracker is the record's, else the key's, and never a guess ==="
# Rows: tracker | repo | the issue-7 row it renders.
while IFS='|' read -r tracker repo want; do
  new_case "identity_${tracker:-none}_${repo:-none}"
  report -60
  fleet '' "$(lane issue-7 running -86400 "" "$tracker" "$repo")"
  jq -n '{title: "GitHub title", body: "## Done when\n- GitHub outcome"}' > "$CASE/issue-7.json"
  jq -n '{title: "Linear title", description: "## Done when\n- Linear outcome"}' > "$CASE/linear-issue-7.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(awk '/^\| issue-7/' <<<"$OUT")" "0|$want" \
    "an issue-N lane with tracker '${tracker:-none}' and repo '${repo:-none}' renders '$want'"
done <<'ROWS'
github|owner/repo|| issue-7 (no PR, running) | GitHub title | GitHub outcome |
linear|owner/repo|| issue-7 (no PR, running) | Linear title | Linear outcome |
||| issue-7 (no PR, running) | (tracker unknown) | - |
github||| issue-7 (no PR, running) | (repo unknown) | - |
ROWS

new_case identity_github_not_issue
report -60
fleet '' "$(lane KEN-7 running -86400 "" github owner/repo)"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^\| KEN-7/' <<<"$OUT")" "0|| KEN-7 (no PR, running) | (no issue number) | - |" \
  "a GitHub record whose key is not issue-N is not read, and says so"

echo "=== render: Landed lists each fleet branch on its own ==="
# Unrelated merges past a whole page never reach the report, which asks for
# the fleet's branches alone; one branch's own page filling refuses.
new_case landed_busy_repo
report -3600
fleet '' "$(lane KEN-1 done)"
issue KEN-1 "Title 1" "Outcome 1"
jq -n --arg at "$(at -60)" '[range(600) | {number: (1000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]
  + [{number: 11, headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "abcdef1234"}}]' > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk 'NR == 4' <<<"$OUT")" "0|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |" \
  "600 merges on other branches leave the fleet's own merge rendered"
for row in "499|0" "500|2"; do
  IFS='|' read -r count want <<<"$row"
  jq -n --arg at "$(at -60)" --argjson n "$count" '[range($n) | {number: (1000 + .), headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]' > "$CASE/merged.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  got="$RC"; [[ "$RC" -eq 0 ]] || got="$RC|$(first_err)"
  [[ "$want" == 0 ]] || want="2|oversee-report: pr-list-truncated=owner/repo:KEN-1"
  assert_eq "$got" "$want" "$count merges on one fleet branch against a page of 500"
done

echo "=== render: every --repo is read, and a record's repo is its own ==="
new_case multi_repo
report -3600
# KEN-1's merge on the first --repo is newer than KEN-3's on the second, so
# Landed runs in merge order, not in item or --repo order. KEN-2's red check
# is on the second --repo alone.
fleet '' "$(lane KEN-1 done)" "$(lane KEN-3 done)" "$(lane KEN-2 running)" "$(lane issue-8 running -86400 "" github owner/b)"
issue KEN-1 "Title 1" "Outcome 1"
issue KEN-2 "Title 2" "Outcome 2"
issue KEN-3 "Title 3" "Outcome 3"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.owner_a.json"
echo "[$(merged_pr 13 ken-3 -90 1234567abc)]" > "$CASE/merged.owner_b.json"
echo '[{"number": 12, "branch": "ken-2", "failed_checks": ["test"]}]' > "$CASE/failing.owner_b.json"
echo '[]' > "$CASE/failing.owner_a.json"
echo '[]' > "$CASE/open.owner_a.json"
echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.owner_b.json"
jq -n '{title: "Issue in b", body: "## Done when\n- b outcome"}' > "$CASE/issue-8.owner_b.json"
jq -n '{title: "Issue in a", body: "## Done when\n- a outcome"}' > "$CASE/issue-8.owner_a.json"
run -- render --state "$CASE/state.json" --repo owner/a --repo owner/b
assert_eq "$RC|$(awk '/^\| (KEN-|issue-)/' <<<"$OUT")" "0|| KEN-3 (#13, 1234567) | Title 3 | Outcome 3 |
| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |
| KEN-2 (#12, running) | Title 2 | Outcome 2 |
| issue-8 (no PR, running) | Issue in b | b outcome |" \
  "merges in both --repo values land oldest first, an open PR in the second is rendered, and the issue is read in the repo its record names"
assert_eq "$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "- KEN-2 waits on red checks on #12: test" \
  "a red check in the second --repo is read under that repo"

echo "=== render: tracker text is fitted to one line ==="
new_case cell_text
report -60
fleet '+ {owner_items: [{id: "a", text: "line one\nline two"}]}' "$(lane KEN-1 running)"
jq -n '{title: ("T" * 200), description: "Intro\r\n## Done when\r\n* CRLF outcome\r\n"}' > "$CASE/linear-KEN-1.json"
run -- render --state "$CASE/state.json" --repo owner/repo
LONG="$(printf 'T%.0s' $(seq 157))..."
# Rows: what | the rendered line | want.
while IFS='|' read -r what line want; do
  assert_eq "$RC|$line" "0|$want" "$what"
done <<ROWS
a title past 160 characters keeps 157 and an ellipsis|$(awk -F' [|] ' '/^\| KEN-1/ { print $2 }' <<<"$OUT")|$LONG
a CRLF description still yields its Done-when line|$(awk -F' [|] ' '/^\| KEN-1/ { sub(/ \|$/, "", $3); print $3 }' <<<"$OUT")|CRLF outcome
an owner question with a newline is one list line|$(awk '/^- Question for you/' <<<"$OUT")|- Question for you: line one line two
ROWS

echo "=== render: a hosted lane's stop is read from its clone ==="
new_case hosted_stop
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"post_pr_stop": {"name": "ci-fix-cap", "gate": "ci", "remaining": ["test"]}}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|- KEN-7 waits on a stopped ci gate, ci-fix-cap: test" \
  "a hosted lane's post-PR stop is read from the clone its worktree's .git names"
echo "gitdir: /clone/.git" > "$CASE/host/w/KEN-7/.git"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: item-state=KEN-7" "a .git that names no linked worktree refuses rather than read as no state"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
rm -f -- "${CASE:?}/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/' <<<"$OUT")" "0|Waiting on you: none" "a hosted lane with no state file on its host waits on nothing"
# ../workflows/merge-pr.md § 5 removes a merged lane's worktree before
# lane-close runs: the host answers touch and has no .git there.
rm -f -- "${CASE:?}/host/w/KEN-7/.git"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/' <<<"$OUT")" "0|Waiting on you: none" "a hosted lane whose worktree is gone renders, waiting on nothing"

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
    n=11
    for offset in $merges; do merged_pr "$n" ken-1 "$offset" abcdef1234; n=$((n + 1)); done | jq -s . > "$CASE/merged.json"
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
issues_under|60|ORCH_REPORT_EVERY_ISSUES=2|-30|
issues_two|60|ORCH_REPORT_EVERY_ISSUES=2|-30 -20|report-due reason=issues since=@AGE landed=2
ROWS
new_case due_two_lanes
fleet '' "$(lane KEN-1 running -40000)" "$(lane KEN-2 running -86400)"
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -86400)" "due, with no report yet the fleet start is the earliest launch, not the first record's"
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
seed_fleet refuse_open
touch "$CASE/gh-fail-open"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "a failing open list alone refuses rather than render every lane with no PR"
seed_fleet refuse_tracker_missing
run OVERSEE_REPORT_TRACKER="$CASE/no-linear" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-missing=$CASE/no-linear" "a Linear CLI that is not executable refuses by name"
seed_fleet refuse_write_only
run -- render --state "$CASE/state.json" --repo owner/repo --succession
assert_eq "$RC|$(first_err)" "2|oversee-report: args=write-only-option" "--succession on render is refused"
new_case refuse_gh_issue
report -60
fleet '' "$(lane issue-7 running -86400 "" github owner/repo)"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=issue-7" "a failing gh issue view refuses rather than render blank cells"
seed_fleet refuse_mail
touch "$CASE/mail-fail"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-2" "a mailbox that cannot be read refuses rather than render the lane as waiting on nothing"
seed_fleet refuse_title
echo '{"description": "## Done when\n- no title here"}' > "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "a tracker read with no title refuses rather than render a blank cell"
seed_fleet refuse_tracker
rm -f "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "an issue the tracker cannot read refuses"

echo "=== must-fail controls ==="
# Without the shared filter's since clause, a merge older than the last report
# is news again. The clause lives in lib/lane-state.sh, which the watch's
# merged check reads too.
MUTANT="$TMP_ROOT/mutant/scripts/oversee-report"
LIB="$(cd "$TEST_DIR/../scripts/lib" && pwd)/lane-state.sh"
mkdir -p "$TMP_ROOT/mutant"
cp -R "$TEST_DIR/../scripts" "$TMP_ROOT/mutant/scripts"
filter="    | select(.at >= \$since) ];'"
assert_eq "$(grep -cxF -- "$filter" "$LIB")" "1" "control: the since clause is one line to strip"
awk -v line="$filter" '$0 == line { print "    ];'"'"'"; next } { print }' "$LIB" > "$TMP_ROOT/mutant/scripts/lib/lane-state.sh"
seed_fleet render_mutant
REPORT_UNDER_TEST="$MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$(grep -c '^| KEN-3 (#13, 1234567)' <<<"$OUT")" "1" "control: without the clause Landed carries the merge from before the last report"
cp -- "$LIB" "$TMP_ROOT/mutant/scripts/lib/lane-state.sh"

# Without the page guard, one branch's full page renders as if it were whole.
guard='        if length >= $page then "page-full"'
assert_eq "$(grep -cxF -- "$guard" "$REPORT_BIN")" "1" "control: the page guard is one line to strip"
awk -v line="$guard" '$0 == line { print "        if false then \"page-full\""; next } { print }' "$REPORT_BIN" > "$MUTANT"
new_case page_mutant
report -3600
fleet '' "$(lane KEN-1 done)"
issue KEN-1 "Title 1" "Outcome 1"
jq -n --arg at "$(at -60)" '[range(500) | {number: (1000 + .), headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]' > "$CASE/merged.json"
REPORT_UNDER_TEST="$MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC" "0" "control: without the guard a full page of one branch renders instead of refusing"

# Without the stop line, a lane held by a post-PR stop reads as waiting on
# nothing.
line='      [[ -z "$stop" ]] || BLOCKERS+="$stop"$'"'"'\n'"'"''
assert_eq "$(grep -cxF -- "$line" "$REPORT_BIN")" "1" "control: the stop line is one line to strip"
# ENVIRON, not -v: awk -v would turn the line's backslash-n into a newline.
line="$line" awk '$0 == ENVIRON["line"] { print "      :"; next } { print }' "$REPORT_BIN" > "$MUTANT"
seed_fleet render_stop_mutant
REPORT_UNDER_TEST="$MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(grep -c '^- KEN-3 waits on a stopped' <<<"$OUT")" "0|0" "control: without it the stopped lane is missing from Waiting on you"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
