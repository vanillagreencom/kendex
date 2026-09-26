#!/usr/bin/env bash
# oversee-report: when the overseer's status report is due, and the rows
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
# mutant_scripts, for the must-fail control and the missing-helper row.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
REPORT_BIN="$(cd "$TEST_DIR/../scripts" && pwd)/oversee-report"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REAL_DATE="$(command -v date)"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# The clock every case reads: `date -u +%s` answers the case's now file, else
# NOW; every other call is the host's date.
NOW=1790000000
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/date" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "-u +%s" ]]; then
  if [[ -f "\$CASE/now" ]]; then cat "\$CASE/now"; else echo $NOW; fi
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
# gh: `pr list --state merged` answers merged.json narrowed to --head and
# capped at --limit, as gh narrows it; `pr list --state open` open.json, and
# `issue view N` issue-N.json, each from the case directory; a `--search
# merged:>=STAMP` keeps what merged at or after STAMP. A file named
# <base>.<SLUG>.json answers that --repo alone, SLUG being the repo with `/`
# as `_`. gh-fail fails every list, gh-fail-open the open list alone. Every
# call's argv is appended to gh.calls. `auth status`, the keyring's answer,
# fails where the case holds auth-fail; `api user`, an env token's check, and
# every list fail for a GH_TOKEN starting ghp_stale, as a revoked token does.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$CASE/gh.calls"
verb="${1:-} ${2:-}"; number="${3:-}"
state=""; head=""; limit=1000; repo=""; search=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) state="$2" ;; --head) head="$2" ;; --limit) limit="$2" ;; --repo) repo="$2" ;; --search) search="$2" ;;
  esac
  shift
done
slug="${repo//\//_}"
pick() { if [[ -f "$CASE/$1.$slug.json" ]]; then printf '%s' "$CASE/$1.$slug.json"; else printf '%s' "$CASE/$1.json"; fi; }
case "$verb" in
  "auth status")
    [[ ! -f "$CASE/auth-fail" ]] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    echo "Logged in" ;;
  "api user")
    [[ "${GH_TOKEN:-}" != ghp_stale* ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo "someone" ;;
  "pr list")
    [[ "${GH_TOKEN:-}" != ghp_stale* ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    [[ ! -f "$CASE/gh-fail" ]] || { echo "HTTP 502" >&2; exit 1; }
    [[ ! -f "$CASE/gh-fail-$state" ]] || { echo "HTTP 502" >&2; exit 1; }
    src="$(pick "$state")"
    [[ -f "$src" ]] || { echo '[]'; exit 0; }
    # A merged:>= search keeps what merged at or after its stamp, as GitHub's does.
    jq -c --arg head "$head" --argjson limit "$limit" --arg since "${search#merged:>=}" \
      '[.[] | select($head == "" or .headRefName == $head) | select($since == "" or .mergedAt >= $since)] | .[:$limit]' "$src" ;;
  "issue view")
    src="$(pick "issue-$number")"
    [[ -f "$src" ]] || { echo "no issue $number" >&2; exit 1; }
    cat "$src" ;;
  *) echo "unexpected gh call: $verb" >&2; exit 1 ;;
esac
EOF
# The Linear CLI: `cache issues get ID` answers linear-ID.json in the safe
# shape under --format=safe, and nested as {issue: ...} otherwise, the raw
# shape a project's LINEAR_FORMAT=raw gives a call that names no format. A
# merge-on-read-ID.json file is a pull request that merges while ID is read:
# it joins merged.json, once, mid-render.
cat > "$TMP_ROOT/bin/linear" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "cache issues get" && -f "$CASE/linear-$4.json" ]] || { echo "No cache entry for $4" >&2; exit 1; }
if [[ -f "$CASE/merge-on-read-$4.json" ]]; then
  jq -c --slurpfile pr "$CASE/merge-on-read-$4.json" '. + $pr' "$CASE/merged.json" > "$CASE/merged.next" || exit 1
  mv -- "$CASE/merged.next" "$CASE/merged.json" || exit 1
  rm -f -- "$CASE/merge-on-read-$4.json"
fi
if [[ "${5:-}" == --format=safe ]]; then cat "$CASE/linear-$4.json"; else jq -c '{issue: .}' "$CASE/linear-$4.json"; fi
EOF
# github.sh: `pr-list-failing --all` answers failing.<SLUG>.json for the
# GH_REPO it runs under, else failing.json, [] without either. It picks its
# token as github.sh's router does, GH_TOKEN before a non-empty GH_BOT_TOKEN,
# and one starting ghp_stale fails the list, as a revoked token does.
cat > "$TMP_ROOT/bin/github" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "pr-list-failing --all" ]] || { echo "unexpected github.sh call: $*" >&2; exit 1; }
[[ -n "${GH_REPO:-}" ]] || { echo "github.sh stub: no GH_REPO" >&2; exit 1; }
[[ "${GH_TOKEN:-${GH_BOT_TOKEN:-}}" != ghp_stale* ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
slug="${GH_REPO//\//_}"
if [[ -f "$CASE/failing.$slug.json" ]]; then cat "$CASE/failing.$slug.json"
elif [[ -f "$CASE/failing.json" ]]; then cat "$CASE/failing.json"
else echo '[]'; fi
EOF
# lane-mail: `pending --item ITEM` answers pending-ITEM.jsonl, nothing
# without one; mail-fail-ITEM makes it fail with that file as its stderr and
# mail-exit-ITEM's status, 2 without one. The call must read the lane's own
# root, /w/ITEM, and a hosted lane's (hosted-ITEM names its host) through
# --host under that host's ORCH_LANE_HOST, a local one without --host.
cat > "$TMP_ROOT/bin/lane-mail" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pending --item" ]] || { echo "unexpected lane-mail call: $*" >&2; exit 2; }
want="--root /w/$3"; host=""
[[ ! -f "$CASE/hosted-$3" ]] || { host="$(cat "$CASE/hosted-$3")"; want+=" --host"; }
[[ "${*:4}" == "$want" && "${ORCH_LANE_HOST:-}" == "$host" ]] \
  || { echo "lane-mail stub: wrong route for $3: ${*:4} host=${ORCH_LANE_HOST:-}" >&2; exit 9; }
[[ ! -f "$CASE/mail-fail-$3" ]] || { cat "$CASE/mail-fail-$3" >&2; exit "$(cat "$CASE/mail-exit-$3" 2>/dev/null || echo 2)"; }
[[ ! -f "$CASE/pending-$3.jsonl" ]] || cat "$CASE/pending-$3.jsonl"
EOF
# lane-host: `cat --item ITEM PATH` answers host/PATH, exit 2 without it,
# and is refused at the per-home cap for the PATH host-busy names; `touch`
# succeeds; host-gone-ITEM fails every call as a host that no longer knows
# the item. Every call must run under the ORCH_LANE_HOST its item's
# record names (hosted-ITEM).
cat > "$TMP_ROOT/bin/lane-host" <<'EOF'
#!/usr/bin/env bash
[[ -f "$CASE/hosted-$3" && "${ORCH_LANE_HOST:-}" == "$(cat "$CASE/hosted-$3")" ]] \
  || { echo "lane-host stub: $3 read under host=${ORCH_LANE_HOST:-}" >&2; exit 9; }
[[ ! -f "$CASE/host-gone-$3" ]] || { echo "lane-host: item-unknown=$3" >&2; exit 2; }
case "$1" in
  cat)
    [[ ! -f "$CASE/host-busy" || "$4" != "$(cat "$CASE/host-busy")" ]] \
      || { echo "lane-host: lane-host-busy count=1 cap=1 verb=cat item=$3" >&2; exit 69; }
    [[ -f "$CASE/host$4" ]] || exit 2; cat "$CASE/host$4" ;;
  touch) exit 0 ;;
  *) echo "unexpected lane-host call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/date" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/linear" "$TMP_ROOT/bin/github" \
  "$TMP_ROOT/bin/lane-mail" "$TMP_ROOT/bin/lane-host"

# at OFFSET — the UTC ISO stamp OFFSET seconds from NOW.
at() { "$REAL_DATE" -u -d "@$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || "$REAL_DATE" -u -r "$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ; }
# report OFFSET [FILE] — a prior report whose modification time is OFFSET
# seconds from NOW, named MM-DD-HH-MM.md for that time in UTC as
# `workflow-state progress-report-path` names one, or FILE, in the directory
# ORCH_PROGRESS_REPORT_DIR names for every case.
report() {
  local when name
  when="$("$REAL_DATE" -u -d "@$((NOW + $1))" +%Y%m%d%H%M.%S 2>/dev/null || "$REAL_DATE" -u -r "$((NOW + $1))" +%Y%m%d%H%M.%S)"
  name="${2:-${when:4:2}-${when:6:2}-${when:8:2}-${when:10:2}.md}"
  mkdir -p "$CASE/progress-reports"
  echo "an earlier report" > "$CASE/progress-reports/$name"
  TZ=UTC touch -t "$when" "$CASE/progress-reports/$name"
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
    -u ORCH_REPORT_UPCOMING -u ORCH_REPORT_COLUMNS -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    PATH="$TMP_ROOT/bin:$PATH" CASE="$CASE" OVERSEE_REPORT_TRACKER="$TMP_ROOT/bin/linear" \
    OVERSEE_REPORT_GITHUB="$TMP_ROOT/bin/github" OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/lane-mail" \
    OVERSEE_REPORT_LANE_HOST="$TMP_ROOT/bin/lane-host" ORCH_STATE_DIR="$CASE/ws" \
    ORCH_PROGRESS_REPORT_DIR="$CASE/progress-reports" \
    ${envs[@]+"${envs[@]}"} "${REPORT_UNDER_TEST:-$REPORT_BIN}" "$@" 2>"$CASE/err")" || RC=$?
}
first_err() { awk 'NR == 1' "$CASE/err"; }

# A fleet with one of each: KEN-1 landed after the last report, and a fork's
# PR on the ken-1 branch name and one with no head owner did not, KEN-3 landed
# before it, KEN-9 is no fleet item, KEN-2 and KEN-3 still run, KEN-2 with an
# open PR; KEN-4 to KEN-6 wait in the queue and one question is open. KEN-2
# waits on an ask and on red checks, KEN-3 on a post-PR stop. KEN-7 is still
# preparing on its host. KEN-3 has validated twice, a full implement round
# and a range fix round; KEN-2 not yet.
seed_fleet() {
  new_case "$1"
  report -3600
  fleet '+ {launch_queue: ["KEN-4", "KEN-5", "KEN-6"], owner_items: [{id: "a", text: "Merge the pricing change?"}]}' \
    "$(lane KEN-1 done)" "$(lane KEN-2 running)" "$(lane KEN-3 running)" "$(lane KEN-7 preparing -86400 ssh-a)"
  echo '{"id":"1790000000-1-a","kind":"ask","text":"Which schema?"}' > "$CASE/pending-KEN-2.jsonl"
  echo '[{"number": 12, "branch": "ken-2", "failed_checks": ["test", "lint"]}]' > "$CASE/failing.json"
  item_state KEN-3 '{"post_pr_stop": {"name": "review-round-cap", "gate": "review", "remaining": ["one unresolved review thread"]},
    "validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 3300},
      {"round_id": "r2", "kind": "fix", "mode": "range", "seconds": 290}]}'
  item_state KEN-2 '{"post_pr_stop": null}'
  printf '%s\n' "$(merged_pr 11 ken-1 -60 abcdef1234)" "$(merged_pr 13 ken-3 -7200 1234567abc)" \
    "$(merged_pr 19 ken-9 -60 9999999aaa)" "$(merged_pr 21 ken-1 -30 2121212aaa someone-else)" \
    "$(merged_pr 23 ken-1 -30 2323232aaa -)" | jq -s . > "$CASE/merged.json"
  echo '[{"number": 12, "headRefName": "ken-2"}]' > "$CASE/open.json"
  local n
  for n in 1 2 3 4 5 6 7 8 9; do issue "KEN-$n" "Title $n" "Outcome $n | kept"; done
}

echo "=== render: the rows from a fleet ==="
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

Validation:
- KEN-2: no validation run recorded
- KEN-3: 60 min over 2 rounds: implement full 55, fix range 5

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
  "Landed holds only the fleet item merged since the last report, Running each live or preparing lane with its PR, Validation each running lane's minutes in total and per round, Next the queue, Waiting on you the open question then each running lane's blockers"

echo "=== render: Waiting on you holds a lane's asks, not its unread directives ==="
# lane-mail pending lists the directives the overseer sent and the lane has
# not read beside the asks; the directive waits on the lane, not on the owner.
seed_fleet pending_directive
echo '{"id":"1790000000-2-b","kind":"directive","text":"Rebase first."}' >> "$CASE/pending-KEN-2.jsonl"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "an unread directive beside an ask leaves Waiting on you with the ask alone"

echo "=== render and due: the GitHub auth ladder ==="
# A revoked env token with no keyring falls through to the project's
# GH_BOT_TOKEN, as the watch's own ladder does; with no working credential the
# report refuses by name rather than read GitHub unauthenticated.
seed_fleet auth_bot_fallback
touch "$CASE/auth-fail"
run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "render, a revoked GH_TOKEN and no keyring: GH_BOT_TOKEN reads the same rows"
seed_fleet auth_none
touch "$CASE/auth-fail"
run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_stale_bot -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-failed=github" "render, no credential works: refused as auth-failed"
# A keyring the ladder settles on holds for the failing-check list too: an
# inherited GH_BOT_TOKEN that GitHub rejects is not picked up behind it.
seed_fleet auth_keyring_stale_bot
run GH_BOT_TOKEN=ghp_stale_bot -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|$WANT" "render, the keyring works beside a revoked inherited GH_BOT_TOKEN: the keyring reads the same rows"
# A revoked env token the keyring replaces warns on stderr; a later refusal
# still names its key on the first line, and the warning follows it.
seed_fleet auth_keyring_refusal
touch "$CASE/gh-fail"
run GH_TOKEN=ghp_stale0000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)|$(grep -c '^Warning: GH_TOKEN' "$CASE/err" || true)" "2|oversee-report: pr-list=owner/repo|1" \
  "render, keyring replaces a revoked GH_TOKEN, then the list fails: the key is the first stderr line, the warning after it"
new_case auth_due_fallback
report -60
fleet '' "$(lane KEN-1 running -86400)"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.json"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=issues since=$(at -60) landed=1" "due, a revoked GH_TOKEN and no keyring: GH_BOT_TOKEN counts the landing"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-failed=github" "due, no credential works: refused as auth-failed"

echo "=== render: nothing since the last report ==="
new_case render_empty
report -60
fleet '' "$(lane KEN-1 done)"
echo "[$(merged_pr 11 ken-1 -120 abcdef1234)]" > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|Landed: none

Running: none

Validation: none

Next: none

Waiting on you: none" "a fleet with nothing new renders each row as none and exits 0"

echo "=== render: ORCH_REPORT_UPCOMING caps Next ==="
# A queue of six, so the default cap of 5 is what stops it.
for row in "2|KEN-4,KEN-5" "0|none" "|KEN-4,KEN-5,KEN-6,KEN-8,KEN-9"; do
  IFS='|' read -r upcoming want <<<"$row"
  seed_fleet "upcoming_${upcoming:-default}"
  jq '.launch_queue = ["KEN-4", "KEN-5", "KEN-6", "KEN-8", "KEN-9", "KEN-1"]' "$CASE/state.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/state.json"
  if [[ -n "$upcoming" ]]; then run ORCH_REPORT_UPCOMING="$upcoming" -- render --state "$CASE/state.json" --repo owner/repo
  else run -- render --state "$CASE/state.json" --repo owner/repo; fi
  got="$(awk '/^Next/ { on = 1; if ($0 == "Next: none") print "none"; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print $2 }' <<<"$OUT" | paste -sd, -)"
  assert_eq "$RC|$got" "0|$want" "ORCH_REPORT_UPCOMING=${upcoming:-unset} renders Next as $want"
done

echo "=== render: Next leaves out what has launched ==="
seed_fleet next_launched
jq '.launch_queue = ["KEN-2", "KEN-1", "KEN-4", "KEN-7", "KEN-5"]' "$CASE/state.json" > "$CASE/state.next"
mv -- "$CASE/state.next" "$CASE/state.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Next/ { on = 1; next } on && /^$/ { on = 0 } on && /^\| KEN-/ { print $2 }' <<<"$OUT" | paste -sd, -)" "0|KEN-4,KEN-5" \
  "a queued item with a lanes[] record of any status, running, preparing or done, is not Next's"

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

echo "=== render: Landed reads one merged search per repository ==="
# Unrelated merges are read and matched away; a search that reaches GitHub's
# ceiling refuses, since merges past it would be missing.
new_case landed_busy_repo
report -3600
fleet '' "$(lane KEN-1 done)"
issue KEN-1 "Title 1" "Outcome 1"
jq -n --arg at "$(at -60)" '[range(600) | {number: (1000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]
  + [{number: 11, headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "abcdef1234"}}]' > "$CASE/merged.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk 'NR == 4' <<<"$OUT")" "0|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |" \
  "600 merges on other branches leave the fleet's own merge rendered"
for row in "999|0" "1000|2"; do
  IFS='|' read -r count want <<<"$row"
  jq -n --arg at "$(at -60)" --argjson n "$count" '[range($n) | {number: (1000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $at, mergeCommit: {oid: "ffffffffff"}}]' > "$CASE/merged.json"
  run -- render --state "$CASE/state.json" --repo owner/repo
  got="$RC"; [[ "$RC" -eq 0 ]] || got="$RC|$(first_err)"
  [[ "$want" == 0 ]] || want="2|oversee-report: pr-list-truncated=owner/repo"
  assert_eq "$got" "$want" "$count merges in one repository's search against its ceiling of 1000"
done

# Lane records outlive their lanes, so the reads must not grow with them: one
# merged search per repository, whatever the fleet has launched.
new_case landed_call_count
report -3600
fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 done)" "$(lane KEN-3 done)" "$(lane KEN-4 done)" "$(lane KEN-5 running)"
issue KEN-5 "Title 5" "Outcome 5"
run -- render --state "$CASE/state.json" --repo owner/a --repo owner/b
assert_eq "$RC|$(grep -c -- '--state merged' "$CASE/gh.calls")|$(grep -c -- '--head' "$CASE/gh.calls" || true)" "0|2|0" \
  "five lane records over two repositories take two merged searches and no per-branch read"

# A first report inside the 7-day lookback reaches the fleet start, whatever
# the minutes setting says.
new_case landed_first_report
fleet '' "$(lane KEN-1 done -86400)" "$(lane KEN-2 done -86400)"
issue KEN-1 "Title 1" "Outcome 1"
issue KEN-2 "Title 2" "Outcome 2"
printf '%s\n' "$(merged_pr 11 ken-1 -10000 abcdef1234)" "$(merged_pr 12 ken-2 -3600 1212121aaa)" | jq -s . > "$CASE/merged.json"
for minutes in unset 0 ""; do
  : > "$CASE/gh.calls"
  if [[ "$minutes" == unset ]]; then run -- render --state "$CASE/state.json" --repo owner/repo
  else run ORCH_REPORT_EVERY_MINUTES="$minutes" -- render --state "$CASE/state.json" --repo owner/repo; fi
  assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")|$(awk '/^\| KEN-/' <<<"$OUT")|$(grep -c -- "merged:>=$(at -86400)" "$CASE/gh.calls")" \
    "0|Landed:|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |
| KEN-2 (#12, 1212121) | Title 2 | Outcome 2 ||1" \
    "a first report with ORCH_REPORT_EVERY_MINUTES '$minutes' lists every merge since the fleet start"
done

# Past the lookback, on every path: a thousand old merges no longer reach the
# search, the report renders, and its Landed row says where it stopped.
LOOKBACK_START="$(at -604800)"
while IFS='|' read -r name settings report_age verb want; do
  new_case "landed_lookback_$name"
  [[ "$report_age" == none ]] || report "-$report_age"
  fleet '' "$(lane KEN-1 done -2592000)" "$(lane KEN-2 running -2592000)"
  issue KEN-1 "Title 1" "Outcome 1"
  issue KEN-2 "Title 2" "Outcome 2"
  jq -n --arg old "$(at -1728000)" --arg new "$(at -86400)" '[range(1000) | {number: (2000 + .), headRefName: "other-\(.)", headRepositoryOwner: {login: "owner"}, mergedAt: $old, mergeCommit: {oid: "ffffffffff"}}]
    + [{number: 11, headRefName: "ken-1", headRepositoryOwner: {login: "owner"}, mergedAt: $new, mergeCommit: {oid: "abcdef1234"}}]' > "$CASE/merged.json"
  read -r -a envs <<<"$settings"
  run ${envs[@]+"${envs[@]}"} -- "$verb" --state "$CASE/state.json" --repo owner/repo
  got="$RC|$(grep -c -- "merged:>=$LOOKBACK_START" "$CASE/gh.calls" || true)"
  if [[ "$verb" == due ]]; then got+="|$OUT"
  else got+="|$(awk '/^Landed/' <<<"$OUT");rows=$(grep -c '^| KEN-1 (#11, abcdef1) ' <<<"$OUT" || true)"; fi
  want="${want//@START/$LOOKBACK_START}"
  want="${want//@FLEET/$(at -2592000)}"
  assert_eq "$got" "0|1|$want" "$name: past the 7-day lookback the window stops there and the call succeeds"
done <<'ROWS'
minutes_off_issues_no_report|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=1|none|due|report-due reason=issues since=@FLEET landed=1
report_older_than_lookback||2592000|render|Landed (since @START, earlier merges not listed):;rows=1
ROWS

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
# A read lane-host refused at its per-home cap names that cause, never a
# state that could not be read. Rows: the path refused.
for path in /w/KEN-7/.git /clone/tmp/workflow-state-KEN-7.json; do
  printf '%s' "$path" > "$CASE/host-busy"
  run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: lane-host-busy=KEN-7" "a $path read lane-host refused at its cap refuses as lane-host-busy"
done
rm -f -- "${CASE:?}/host-busy"
# ../workflows/merge-pr.md § 5 removes a merged lane's worktree before
# lane-close runs: the host answers touch and has no .git there.
rm -f -- "${CASE:?}/host/w/KEN-7/.git"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/' <<<"$OUT")" "0|Waiting on you: none" "a hosted lane whose worktree is gone renders, waiting on nothing"

echo "=== render: a lane's validation minutes are its own state's ==="
# A hosted lane's rounds are read from its clone as its stop is; one round
# reads singular, and a round list the state cannot sum refuses rather than
# render a total it did not read.
new_case hosted_validation
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": 89}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "0|- KEN-7: 1 min over 1 round: implement full 1" \
  "a hosted lane's validation minutes are read from the clone its worktree's .git names"
echo '{"validate_rounds": [{"round_id": "r1", "kind": "implement", "mode": "full", "seconds": "89"}]}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: item-state=KEN-7" "a round whose seconds are no number refuses rather than render a total"
rm -f -- "${CASE:?}/host/clone/tmp/workflow-state-KEN-7.json"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Validation/ { on = 1; next } on && /^$/ { on = 0 } on' <<<"$OUT")" "0|- KEN-7: no validation run recorded" \
  "a lane with no state on its host has no validation run recorded"
echo "=== render and write: a lane whose mailbox cannot be read is marked, the rest reported ==="
# KEN-8 runs on a host that no longer knows the item: its mailbox read fails,
# and its state, on that host too, is not read (the host fails every call, so
# a read would refuse as item-state).
seed_unreadable() {
  seed_fleet "$1"
  jq -c --argjson lane "$(lane KEN-8 running -86400 ssh-b)" '.lanes += [$lane]' "$CASE/state.json" > "$CASE/state.next"
  mv -- "$CASE/state.next" "$CASE/state.json"
  printf 'lane-mail: host-unreachable=KEN-8 state=unknown\nThe lane host could not be reached.\n' > "$CASE/mail-fail-KEN-8"
  touch "$CASE/host-gone-KEN-8"
}
seed_unreadable mail_unreadable
MARK="- KEN-8 mailbox unreadable (mail-read=KEN-8): lane-mail: host-unreachable=KEN-8 state=unknown"
run -- render --state "$CASE/state.json" --repo owner/repo
ROW7='| KEN-7 (no PR, preparing) | Title 7 | Outcome 7 \| kept |'
ROW8='| KEN-8 (no PR, running) | Title 8 | Outcome 8 \| kept |'
VAL3='- KEN-3: 60 min over 2 rounds: implement full 55, fix range 5'
VAL8='- KEN-8: validation unread, its host unreachable'
WANT8="$(row7="$ROW7" row8="$ROW8" val3="$VAL3" val8="$VAL8" awk '{ print }
  $0 == ENVIRON["row7"] { print ENVIRON["row8"] } $0 == ENVIRON["val3"] { print ENVIRON["val8"] }' <<<"$WANT")"
assert_eq "$RC|$OUT" "0|$WANT8
$MARK" "render lists KEN-8 under Running, marks its validation unread and its mailbox under Waiting on you, and every other lane as before"
echo "One lane is unreadable." > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC|$(awk 'END { print }' <<<"$OUT")" "0|$MARK" "write writes the report with the unreadable lane marked"
echo '{"lanes": [' > "$CASE/state.json"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
assert_eq "$RC|$(first_err)" "2|oversee-report: state=$CASE/state.json" "a fleet state file that cannot be read still refuses"
# A local lane's state is on this host, so its stop is still read even where
# the refusal names a host.
seed_fleet mail_unreadable_local
echo 'lane-mail: host-unreachable=KEN-3' > "$CASE/mail-fail-KEN-3"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(grep '^- KEN-3 ' <<<"$OUT")" "0|- KEN-3 mailbox unreadable (mail-read=KEN-3): lane-mail: host-unreachable=KEN-3
- KEN-3 waits on a stopped review gate, review-round-cap: one unresolved review thread" \
  "a local lane whose mailbox read fails is marked and its stored stop still listed"
# A hosted lane whose host answers but whose mailbox read fails still has its
# stop read from that host.
new_case mail_read_failed_hosted
report -60
fleet '' "$(lane KEN-7 running -86400 ssh-a)"
issue KEN-7 "Title 7" "Outcome 7"
mkdir -p "$CASE/host/w/KEN-7" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-7" > "$CASE/host/w/KEN-7/.git"
echo '{"post_pr_stop": {"name": "ci-fix-cap", "gate": "ci", "remaining": ["test"]}}' > "$CASE/host/clone/tmp/workflow-state-KEN-7.json"
echo 'lane-mail: mail-read-failed=KEN-7' > "$CASE/mail-fail-KEN-7"
run ORCH_STATE_DIR=tmp -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^Waiting on you/ { on = 1; next } on' <<<"$OUT")" "0|- KEN-7 mailbox unreadable (mail-read=KEN-7): lane-mail: mail-read-failed=KEN-7
- KEN-7 waits on a stopped ci gate, ci-fix-cap: test" "a hosted lane whose host answers keeps its stop when its mailbox read fails"
# Only a refusal naming the lane's own host or mailbox is marked: a missing
# helper, a crash, a global refusal or another item's refusal still refuses.
while IFS='|' read -r name status text; do
  seed_unreadable "mail_$name"
  echo "$status" > "$CASE/mail-exit-KEN-8"
  printf '%s\n' "$text" > "$CASE/mail-fail-KEN-8"
  run -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-8" "a mailbox failure of kind $name refuses the report"
done <<'ROWS'
crash|1|lane-mail: host-unreachable=KEN-8 state=unknown
global|2|lane-mail: root-unresolved=/w/KEN-8
other-item|2|lane-mail: host-unreachable=KEN-9 state=unknown
prefix-item|2|lane-mail: mail-read-failed=KEN-80
other-key|2|lane-mail: item-case-variant=KEN-8
ROWS
seed_fleet mail_helper_missing
run OVERSEE_REPORT_LANE_MAIL="$CASE/no-lane-mail" -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-2" "a lane-mail helper that is not there refuses the report"

echo "=== write: each merge lands in exactly one report ==="
# KEN-3 merged at the second the lists are read, and KEN-2 merges while the
# render reads KEN-1's issue, after its lists were read. Neither is in this
# report; both are in the next.
new_case merge_mid_render
report -3600
fleet '' "$(lane KEN-1 running)" "$(lane KEN-2 done)" "$(lane KEN-3 done)"
for n in 1 2 3; do issue "KEN-$n" "Title $n" "Outcome $n"; done
echo "[$(merged_pr 9 ken-3 0 9999999aaa)]" > "$CASE/merged.json"
merged_pr 7 ken-2 1 7777777aaa > "$CASE/merge-on-read-KEN-1.json"
echo "One lane is running." > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
FILE="$(awk -F= 'NR == 1 { print $2 }' "$CASE/err")"
STAMPED="$(stat -c %Y -- "$FILE" 2>/dev/null || stat -f %m -- "$FILE")"
assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")|$STAMPED|$([[ -f "$CASE/merge-on-read-KEN-1.json" ]] && echo unmerged || echo merged)" \
  "0|Landed: none|$NOW|merged" "a write covers merges before the moment it read its lists, and its file carries that moment"
echo "$((NOW + 120))" > "$CASE/now"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(awk '/^\| KEN-[23] /' <<<"$OUT")" "0|| KEN-3 (#9, 9999999) | Title 3 | Outcome 3 |
| KEN-2 (#7, 7777777) | Title 2 | Outcome 2 |" "the next report lists both merges the written one left out"

echo "=== write: the chat and the file carry one report ==="
seed_fleet write_report
printf 'Two items landed and one waits on you.\n\n\n' > "$CASE/summary.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
NAME="$("$REAL_DATE" -u -d "@$NOW" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$NOW" +%m-%d-%H-%M)-succession.md"
FILE="$CASE/progress-reports/$NAME"
assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$FILE" "a succession write names its file MM-DD-HH-MM-succession.md"
assert_eq "printed=$([[ -n "$OUT" ]] && echo yes)|$OUT" "printed=yes|$(cat "$FILE" 2>/dev/null)" "what write prints is the file's content, byte for byte"
assert_eq "$(grep -c -E '^(Landed|Running|Validation|Next|Waiting on you):' <<<"$OUT")|$(awk 'NR == 1' <<<"$OUT")|$(awk 'NR == 3' <<<"$OUT")" \
  "5|Two items landed and one waits on you.|Landed:" "the report is the summary, one blank line, then the five rows"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
assert_eq "$RC|$(first_err)" "2|oversee-report: report-exists=$FILE" "a second report under the same name is refused, never overwritten"
: > "$CASE/empty.txt"
run -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/empty.txt"
assert_eq "$RC|$(first_err)" "2|oversee-report: summary=$CASE/empty.txt" "a write with an empty summary is refused"
seed_fleet write_report_off
echo "The overseer hands over." > "$CASE/summary.txt"
run ORCH_REPORT=off -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt" --succession
assert_eq "$RC|$(first_err)" "0|oversee-report: report-written=$CASE/progress-reports/$NAME" \
  "ORCH_REPORT=off silences due alone: a succession write still writes"

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
issues_one_item_two_prs|60|ORCH_REPORT_EVERY_ISSUES=2|-30 -20|
issues_past_lookback|691200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2|-86400|report-due reason=issues since=@AGE landed=1
issues_past_lookback_none|691200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2||
issues_inside_lookback|259200|ORCH_REPORT_EVERY_MINUTES=0 ORCH_REPORT_EVERY_ISSUES=2|-86400|
ROWS
# A due judged on minutes reaches no gh call, so a credential that would
# refuse is never asked.
new_case due_minutes_no_gh
report -7200
fleet '' "$(lane KEN-1 running -86400)"
touch "$CASE/auth-fail"
run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT|$([[ -s "$CASE/gh.calls" ]] && echo asked || echo unasked)" "0|report-due reason=minutes since=$(at -7200)|unasked" \
  "due, minutes reached: GitHub is not asked, so a failing credential does not refuse it"
new_case due_issues_two_items
report -60
fleet '' "$(lane KEN-1 running)" "$(lane KEN-2 done)"
printf '%s\n' "$(merged_pr 11 ken-1 -30 abcdef1234)" "$(merged_pr 12 ken-2 -20 1212121aaa)" | jq -s . > "$CASE/merged.json"
run ORCH_REPORT_EVERY_ISSUES=2 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=issues since=$(at -60) landed=2" "due, two items landed reach ORCH_REPORT_EVERY_ISSUES=2"
new_case due_two_lanes
fleet '' "$(lane KEN-1 running -40000)" "$(lane KEN-2 running -86400)"
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -86400)" "due, with no report yet the fleet start is the earliest launch, not the first record's"
# Only a file named as a report is one: a newer note beside the reports moves
# nothing, and a succession report counts like any other.
new_case due_report_names
fleet '' "$(lane KEN-1 running -86400)"
report -7300
report -60 notes.md
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -7300)" "due, a file not named as a report is not the last report"
when="$("$REAL_DATE" -u -d "@$((NOW - 60))" +%m-%d-%H-%M 2>/dev/null || "$REAL_DATE" -u -r "$((NOW - 60))" +%m-%d-%H-%M)"
report -60 "$when-succession.md"
run -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$OUT" "0|" "due, a succession report is the last report"
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
seed_fleet refuse_mail_busy
echo 'lane-mail: lane-host-busy=KEN-2' > "$CASE/mail-fail-KEN-2"
echo 69 > "$CASE/mail-exit-KEN-2"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: lane-host-busy=KEN-2" "a mailbox read lane-host refused at its cap refuses as lane-host-busy, not a row marked unreadable"
seed_fleet refuse_title
echo '{"description": "## Done when\n- no title here"}' > "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "a tracker read with no title refuses rather than render a blank cell"
seed_fleet refuse_tracker
rm -f "$CASE/linear-KEN-2.json"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: tracker-read=KEN-2" "an issue the tracker cannot read refuses"
# The settings loader names the file and the fault on stderr before the
# refusal runs; that text is held, so the key is still the first line and the
# loader's line follows it.
seed_fleet refuse_settings
echo '[env] # a comment' > "$CASE/kendex.settings.toml"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)|$(grep -c '^kendex-env: table-header ' "$CASE/err" || true)" "2|oversee-report: settings-load=$CASE|1" \
  "a malformed settings file refuses as settings-load, the loader's line after the key"

# Without the github skill beside orch, the shared auth helper cannot load,
# and the report refuses by its own key rather than end on the helper's.
NOHELPER="$(mutant_scripts nohelper/orch)" || exit 1
seed_fleet auth_helper_missing
REPORT_UNDER_TEST="$NOHELPER/oversee-report" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: auth-helper=$NOHELPER/lib/gh-auth.sh" \
  "render, no github skill beside orch: refused as auth-helper"

echo "=== must-fail control ==="
# One mutant for both verbs: without the auth ladder, a revoked env token reads
# GitHub as it stands, and render's list and due's count each refuse on it.
# The copy sits in a skills layout beside the github skill, whose shared auth
# helper lib/gh-auth.sh reaches through ../../../github.
MUTANT="$(mutant_scripts mutant/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/mutant/github"
ladder='  github_auth'
assert_eq "$(grep -cxF -- "$ladder" "$MUTANT")" "2" "control: the ladder is two call lines to strip"
awk -v line="$ladder" '$0 == line { print "  :"; next } { print }' "$REPORT_BIN" > "$MUTANT"
assert_eq "$(grep -cxF -- "$ladder" "$MUTANT")" "0" "control: both call lines are stripped"
seed_fleet auth_bot_fallback_mutant
touch "$CASE/auth-fail"
REPORT_UNDER_TEST="$MUTANT" run GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "control: without the ladder a revoked GH_TOKEN fails render's list"
new_case auth_due_fallback_mutant
report -60
fleet '' "$(lane KEN-1 running -86400)"
echo "[$(merged_pr 11 ken-1 -30 abcdef1234)]" > "$CASE/merged.json"
touch "$CASE/auth-fail"
REPORT_UNDER_TEST="$MUTANT" run ORCH_REPORT_EVERY_ISSUES=1 GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- due --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: pr-list=owner/repo" "control: without the ladder due's count fails on a revoked GH_TOKEN"

# The mailbox read's busy branch: without it a read lane-host refused at its
# cap reads as a mailbox that failed.
BUSY_MUTANT="$(mutant_scripts busy/orch oversee-report)/oversee-report" || exit 1
ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/busy/github"
mutate_file "$BUSY_MUTANT" '[[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || refuse lane-host-busy "$item" "$(cat "$WORK_DIR/mail.err")"' ':'
seed_fleet mail_busy_mutant
echo 'lane-mail: lane-host-busy=KEN-2' > "$CASE/mail-fail-KEN-2"
echo 69 > "$CASE/mail-exit-KEN-2"
REPORT_UNDER_TEST="$BUSY_MUTANT" run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: mail-read=KEN-2" "control: without it a refused mailbox read is mail-read"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
