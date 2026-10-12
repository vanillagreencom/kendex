#!/usr/bin/env bash
# Neutral offline watcher world shared by the reduction and input suites.
set -euo pipefail

SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Sandbox: the real pr-watch and its libraries, beside nothing else: the
# reducer reads GitHub alone, so a call to any other review-gate script fails
# here for want of the file.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin" "$TMP_ROOT/cwd"
cp "$SKILL_ROOT/scripts/pr-watch.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$SKILL_ROOT/scripts/lib/diagnostics.sh" \
  "$SKILL_ROOT/scripts/lib/refresh-identity.sh" "$TMP_ROOT/scripts/lib/"
chmod +x "$TMP_ROOT/scripts/pr-watch.sh"

# Parametrized gh stub. It answers the watcher's three GraphQL reads (the
# paged open-PR listing, the aliased named-PR read and a thread-page round)
# from REST-shaped rows, as GitHub would, in one jq run per call, so a pass's
# process count is the watcher's and not the stub's per PR:
#   STUB_OPEN_PRS       array of pulls rows ("fail" = a failed read,
#                       "emptybytes" = a zero-byte answer)
#   STUB_PR_<N>         row for a named PR, else its STUB_OPEN_PRS row
#   STUB_QUEUED         "yes" -> every PR answers a queue entry
#   STUB_DECISION       reviewDecision of every PR: APPROVED (the default),
#                       CHANGES_REQUESTED, REVIEW_REQUIRED, or null, GitHub's
#                       answer on a base no approval rule targets
#   STUB_REVIEW_RAW     a whole single-PR review-state answer whose fields
#                       every PR takes; one carrying errors fails the read the
#                       way gh does ("emptybytes" = a zero-byte answer)
#   STUB_REVIEW_FAIL    "yes" -> the PR read fails
#   STUB_UNRESOLVED     unresolved threads on the first page
#   STUB_THREADS_NEXTPAGE  hasNextPage of a generated first page (no cursor)
#   STUB_THREADS_RAW    a single-PR thread answer, served for every page
#   STUB_THREADS_PAGE2  the page a cursor gets, before STUB_THREADS_RAW
#   STUB_THREADS_PAGES  N distinct advancing resolved pages, CURk asking k+1
#   STUB_ROUND          "fail" or "emptybytes" for a thread-page round
#   STUB_HEAD_DATE      the head commit's committedDate ("null" = null)
#   STUB_HEAD_AFTER     the head commit's oid when it is not the PR's head
#   STUB_COMMITS        the PR's listed commit count (default 1)
#   STUB_CI_RAW         check-runs pages for the head commit
#   STUB_CI_MORE        "yes" -> the CI suites answer another page
#   STUB_READY_AT, STUB_REOPENED_AT, STUB_REREQUEST_AT  one timeline event
#   STUB_TIMELINE_RAW   the timeline nodes as given
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == api && "${2:-}" == graphql ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
query="" prev="" request=""
for arg in "$@"; do
  [[ "$prev" != -f || "$arg" != query=* ]] || query="${arg#query=}"
  prev="$arg"
done
case "$*" in
  *"--input -"*)
    kind=round
    request="$(cat)"
    case "${STUB_ROUND:-}" in
      fail) echo "HTTP 500" >&2; exit 1 ;;
      emptybytes) exit 0 ;;
    esac
    ;;
  *--paginate*)
    kind=list
    [[ "$query" == *"pullRequests("* ]] || { echo "unexpected paged read: $query" >&2; exit 1; }
    case "${STUB_OPEN_PRS:-[]}" in
      fail) echo "HTTP 500" >&2; exit 1 ;;
      emptybytes) exit 0 ;;
    esac
    ;;
  *)
    kind=named
    [[ "$query" == *"fragment PR on PullRequest"* ]] || { echo "unexpected gh api graphql: $query" >&2; exit 1; }
    ;;
esac
if [[ "$kind" != round ]]; then
  [[ "${STUB_REVIEW_FAIL:-}" != yes ]] || { echo "HTTP 500" >&2; exit 1; }
  [[ "${STUB_REVIEW_RAW:-}" != emptybytes ]] || exit 0
fi
ci="${STUB_CI_RAW:-}"
[[ -n "$ci" ]] || ci='{"check_runs":[]}'
answer="$(printf '%s\n' "$ci" | jq -nc --arg kind "$kind" --arg query "$query" --arg request "$request" '
  def opt($v): if $v == "null" then null else $v end;
  def rows: ($ENV.STUB_OPEN_PRS // "[]") | try fromjson catch [];
  def generated: {pageInfo: {hasNextPage: (($ENV.STUB_THREADS_NEXTPAGE // "false") == "true")},
    nodes: [range(($ENV.STUB_UNRESOLVED // "0") | tonumber) | {isResolved: false}]};
  def deep($k): if $k < ($ENV.STUB_THREADS_PAGES | tonumber)
    then {pageInfo: {hasNextPage: true, endCursor: "CUR\($k)"}, nodes: [{isResolved: true}]}
    else {pageInfo: {hasNextPage: false}, nodes: [{isResolved: true}]} end;
  def raw_threads($v): $v | fromjson | .data.repository.pullRequest.reviewThreads;
  def first_threads:
    if $ENV.STUB_THREADS_PAGES then deep(1)
    elif $ENV.STUB_THREADS_RAW then raw_threads($ENV.STUB_THREADS_RAW)
    else generated end;
  def later_threads($cursor):
    if $ENV.STUB_THREADS_PAGES then deep(($cursor | ltrimstr("CUR") | tonumber) + 1)
    elif $ENV.STUB_THREADS_PAGE2 then raw_threads($ENV.STUB_THREADS_PAGE2)
    elif $ENV.STUB_THREADS_RAW then raw_threads($ENV.STUB_THREADS_RAW)
    else generated end;
  def review_raw: $ENV.STUB_REVIEW_RAW | fromjson;
  def review_state:
    if $ENV.STUB_REVIEW_RAW then review_raw | .data.repository.pullRequest
      | with_entries(select(.key | IN("isInMergeQueue", "mergeQueueEntry", "reviewDecision")))
    else {isInMergeQueue: ($ENV.STUB_QUEUED == "yes"),
      mergeQueueEntry: (if $ENV.STUB_QUEUED == "yes" then {position: 1} else null end),
      reviewDecision: opt($ENV.STUB_DECISION // "APPROVED")} end;
  def run: if type == "object"
    then with_entries(if (.key | IN("status", "conclusion")) and (.value | type) == "string" then .value |= ascii_upcase else . end)
    else . end;
  def suite: if type == "object"
    then {checkRuns: {pageInfo: {hasNextPage: false}, nodes: (.check_runs | if type == "array" then map(run) elif type == "object" then map_values(run) else . end)}}
    else . end;
  def timeline: {nodes: (
    if $ENV.STUB_TIMELINE_RAW then $ENV.STUB_TIMELINE_RAW | fromjson
    elif $ENV.STUB_REREQUEST_AT then [{createdAt: $ENV.STUB_REREQUEST_AT}]
    elif $ENV.STUB_REOPENED_AT then [{createdAt: $ENV.STUB_REOPENED_AT}]
    elif $ENV.STUB_READY_AT then [{createdAt: $ENV.STUB_READY_AT}]
    else [] end)};
  [try inputs catch "unparsable"] as $ci_pages
  | def node: if type != "object" then . else . as $r
    | (if has("number") then {number} else {} end)
      + (if has("state") then {state: (.state | if . == "open" then "OPEN" elif . == "closed" then "CLOSED" else . end)} else {} end)
      + (if has("draft") then {isDraft: .draft} else {} end)
      + (if (.head | type) == "object" and (.head | has("sha")) then {headRefOid: .head.sha} else {} end)
      + {headRefName: (.head.ref? // null)}
      + (if has("created_at") then {createdAt: .created_at} else {} end)
      + (if has("user") then {author: (.user | if type == "object"
          then {login: (if .type == "Bot" then .login | sub("\\[bot\\]$"; "") else .login end), __typename: (.type // "User")}
          else . end)} else {} end)
      + (if has("auto_merge") then {autoMergeRequest: (.auto_merge | if type == "object"
          then (if has("merge_method") then {mergeMethod: (.merge_method | ascii_upcase)} else {} end) else . end)} else {} end)
      + review_state
      + {reviewThreads: first_threads,
         commits: {totalCount: (($ENV.STUB_COMMITS // "1") | tonumber), nodes: [{commit: {
           oid: (if $ENV.STUB_HEAD_AFTER then opt($ENV.STUB_HEAD_AFTER) else $r.head.sha? end),
           committedDate: opt($ENV.STUB_HEAD_DATE // "2026-01-01T00:00:00Z"),
           checkSuites: {pageInfo: {hasNextPage: ($ENV.STUB_CI_MORE == "yes")}, nodes: ($ci_pages | map(suite))}}}]},
         timelineItems: timeline}
    end;
  (if $kind == "list" then
     {data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null},
       nodes: (rows | if type == "array" then map(node) else . end)}}}}
   elif $kind == "named" then
     [$query | scan("p([0-9]+):pullRequest") | .[0] | tonumber | . as $n
      | {key: "p\($n)", value: ($ENV["STUB_PR_\($n)"] as $own
          | if $own then ($own | try fromjson catch $own)
            else [rows[] | select(type == "object" and .number == $n)] | first end)}] as $found
     | if any($found[]; .value == null)
       then {errors: [{message: "Could not resolve to a PullRequest"}], data: {repository: ($found | from_entries)}}
       else {data: {repository: ($found | map(.value |= node) | from_entries)}} end
   else ($request | fromjson | .variables | to_entries | map(select(.key | test("^c[0-9]+$")))) as $cursors
     | {data: {repository: ($cursors | map({key: "p\(.key | ltrimstr("c"))", value: {reviewThreads: later_threads(.value)}}) | from_entries)}}
   end) as $answer
  | if $kind != "round" and $ENV.STUB_REVIEW_RAW and (review_raw | has("errors"))
    then {errors: review_raw.errors} + $answer else $answer end')" || exit 1
printf '%s\n' "$answer"
[[ "$answer" != '{"errors"'* ]] || exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
pr_row() { # number, [state], [armed], [draft], [created_at] -> one pulls-list row
  jq -n --argjson n "$1" --arg state "${2:-open}" --arg armed "${3:-armed}" --arg draft "${4:-false}" \
    --arg created "${5:-2026-01-01T00:00:00Z}" --arg head "$HEAD_A" \
    '{number:$n, state:$state, draft:($draft=="true"), head:{sha:$head, ref:"lane"}, user:{login:"author"},
      created_at:$created,
      auto_merge: (if $armed=="armed" then {merge_method:"merge"} else null end)}'
}


REAL_DATE="$(command -v date)"
WATCH_NOW="$(date +%s)"
export REAL_DATE WATCH_NOW
cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "+%s" ]; then printf '%s\n' "$WATCH_NOW"; exit 0; fi
exec "$REAL_DATE" "$@"
EOF
chmod +x "$TMP_ROOT/bin/date"
FUTURE_EPOCH="$(date -u -d '2030-01-01T00:00:00Z' +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2030-01-01T00:00:00Z' +%s)"
FUTURE_SKEW=$((FUTURE_EPOCH - WATCH_NOW))
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OLD='2026-01-01T00:00:00Z'
P7="$(jq -cn --argjson r "$(pr_row 7)" '[$r]')"

# --- harness -----------------------------------------------------------------

# run_watch ENV FLAGS... — runs the sandboxed pr-watch with the stub PATH and
# GH_REPO set; ENV is a semicolon-separated list of `env` arguments (JSON
# values carry commas). OUT is stdout and stderr together, the way the
# scheduler sees it; RC the exit status.
WATCH_BIN="$TMP_ROOT/scripts/pr-watch.sh"   # a mutant row swaps this
LIVE_WATCH="$WATCH_BIN"
run_watch() {
  local env_list="$1" env_args=()
  shift
  [[ -z "$env_list" ]] || IFS=';' read -ra env_args <<<"$env_list"
  set +e
  OUT=$(cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" \
    env GH_REPO=acme/widgets ${env_args[@]+"${env_args[@]}"} "$WATCH_BIN" "$@" 2>&1)
  RC=$?
  set -e
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order:
#   rc               exit status
#   kinds            the kind column of every finding line, in order, or none
#                    (the tab-separated output is the contract --help states)
#   threads          the count a threads-open line reports, or `overflow`
#   queued_notes     finding lines carrying the queued dequeue note
#   protocol         whole stdout record, tabs as ~, spaces as +, lines as ;
#   error_payload    complete error TSV record when attention precedes it
#   diagnostic       exact global refusal record, spaces as +
observe() {
  local got="" token name value field_sep='~'
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      kinds) value="$(awk -F'\t' 'NF >= 3 {print $3}' <<<"$OUT" | paste -sd, - || true)"; value="${value:-none}" ;;
      threads)
        if grep -q 'threads-open.*overflow' <<<"$OUT"; then value=overflow
        else value="$(grep -o '[0-9]* unresolved review thread' <<<"$OUT" | head -1 | grep -o '^[0-9]*' || true)"; value="${value:-none}"; fi
        ;;
      queued_notes) value="$(grep -c 'QUEUED: dequeue' <<<"$OUT" || true)" ;;
      protocol)
        value="${OUT//$'\t'/$field_sep}"
        value="${value//$'\n'/;}"
        value="${value// /+}" ;;
      diagnostic)
        value="$(sed -n '/^review-gate-/p' <<<"$OUT")"
        value="${value// /+}" ;;
      error_payload)
        value="$(awk -F'\t' '$3 == "error" {print}' <<<"$OUT")"
        value="${value//$'\t'/$field_sep}"
        value="${value// /+}" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# mutant_watch LABEL SED-EXPR ANCHOR [FILE] — a copy with one planted
# defect, which the rows after it run against until WATCH_BIN="$LIVE_WATCH".
# The anchor must stand once in the live script and be gone from the copy, so
# a substitution that matched nothing never passes for a control.
mutant_watch() {
  local dir="$TMP_ROOT/mutants/$1" file="${4:-pr-watch.sh}"
  mkdir -p "$dir/lib"
  cp "$TMP_ROOT/scripts/pr-watch.sh" "$dir/"
  cp "$TMP_ROOT/scripts/lib/"* "$dir/lib/"
  chmod +x "$dir/pr-watch.sh"
  assert_eq "$(grep -Fc -- "$3" "$dir/$file")" "1" "mutant $1: its anchor stands once in the live script"
  sed -i.bak "$2" "$dir/$file"
  assert_eq "$(grep -Fc -- "$3" "$dir/$file")" "0" "mutant $1: the anchor is gone from the copy"
  WATCH_BIN="$dir/pr-watch.sh"
}

# table ROW... — one run and one assertion per row: `label|flags|env|expect`.
table() {
  local row label flags env expect
  for row in "$@"; do
    IFS='|' read -r label flags env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    # shellcheck disable=SC2086
    run_watch "$env" $flags
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
}
