#!/usr/bin/env bash
# Neutral report world: a fixed clock and stand-ins for its external readers.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# mutant_scripts, for the must-fail controls and the missing-helper row.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/escapes-fixture.sh
source "$TEST_DIR/lib/escapes-fixture.sh"
REPORT_BIN="$(cd "$TEST_DIR/../scripts" && pwd)/oversee-report"
TMP_ROOT="$(mktemp -d)" || { echo "oversee_report: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_report: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_report: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REAL_DATE="$(command -v date)"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# The clock every case reads: `date -u +%s` answers the case's now file, else
# NOW; every other call is the host's date.
NOW=1790000000
OWNER_ROWS=$'\n*Landed*\n- Nothing\n\n*Running*\n- Nothing\n\n*Blocked*\n- Nothing\n\n*Waiting on you*\n- Nothing'
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
# it joins merged.json, once, mid-render. The Escapes line's sync is fresh,
# its label list holds bug and its issue list answers bugs.json.
cat > "$TMP_ROOT/bin/linear" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "sync --if-stale 15") exit 0 ;;
  "cache labels list --format=safe") echo '[{"name": "bug"}]'; exit ;;
  "cache issues list --all-projects --max --include-archived --format=safe") cat "$CASE/bugs.json"; exit ;;
esac
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
# --host under that host's ORCH_LANE_HOST, a local one without --host. The
# overseer's own asks are `pending --item overseer --to owner`, no root,
# answered by pending-overseer.jsonl, failed by owner-mail-fail. `notice --item overseer --to owner
# --attach PATH --file PATH` is the report notice: its argv is appended to
# mail.calls, and notice-fail makes it fail.
cat > "$TMP_ROOT/bin/lane-mail" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "events --item overseer" ]]; then
  [[ ! -f "$CASE/events-fail" ]] || { echo "lane-mail: mail-read-failed=overseer" >&2; exit 2; }
  [[ ! -f "$CASE/events.jsonl" ]] || cat "$CASE/events.jsonl"
  exit 0
fi
if [[ "$*" == "pending --item overseer --to owner" ]]; then
  [[ ! -f "$CASE/owner-mail-fail" ]] || { echo "lane-mail: mail-read-failed" >&2; exit 2; }
  [[ ! -f "$CASE/pending-overseer.jsonl" ]] || cat "$CASE/pending-overseer.jsonl"
  exit 0
fi
if [[ "$1 $2 $3 $4 $5 $6" == "notice --item overseer --to owner --attach" && "$8" == --file ]]; then
  printf '%s\n' "$*" >> "$CASE/mail.calls"
  [[ ! -f "$CASE/notice-fail" ]] || { echo "lane-mail: write-failed=$7" >&2; exit 2; }
  jq -cn --arg file "$7" '{kind: "notice", to: "owner", attach: $file}' >> "$CASE/events.jsonl"
  exit 0
fi
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
  jq -cn --arg file "$CASE/progress-reports/$name" '{kind: "notice", to: "owner", attach: $file}' >> "$CASE/events.jsonl"
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
    -u ORCH_REPORT_UPCOMING -u ORCH_REPORT_COLUMNS -u ORCH_REPORT_SUMMARY_LINES -u ORCH_REPORT_QUIET_HOURS -u ORCH_OWNER_TIME_ZONE \
    -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    -u GH_REPO -u WORKTREE_DEFAULT_BRANCH -u LINEAR_TEAM \
    PATH="$TMP_ROOT/bin:$PATH" CASE="$CASE" OVERSEE_REPORT_TRACKER="$TMP_ROOT/bin/linear" \
    OVERSEE_REPORT_GITHUB="$TMP_ROOT/bin/github" OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/lane-mail" \
    OVERSEE_REPORT_LANE_HOST="$TMP_ROOT/bin/lane-host" ORCH_STATE_DIR="$CASE/ws" \
    ORCH_PROGRESS_REPORT_DIR="$CASE/progress-reports" \
    ${envs[@]+"${envs[@]}"} "${REPORT_UNDER_TEST:-$REPORT_BIN}" "$@" 2>"$CASE/err")" || RC=$?
}
first_err() { awk 'NR == 1' "$CASE/err"; }

