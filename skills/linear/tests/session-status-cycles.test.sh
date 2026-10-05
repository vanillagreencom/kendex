#!/usr/bin/env bash
# session-status picks its cycles by date, in UTC: `cycle` is the started
# cycle whose end has not passed, whatever its progress, `prev_cycle` the
# latest one before it and `next_cycle` the earliest after it; with none
# running, both cut at now.
# Linear's startsAt is UTC with a `Z`, compared as a string, so TZ is pinned
# east of UTC, where a local-time cut would count a cycle starting in six
# hours as started.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
query=$(sed -n 's/^data = //p' <<<"$config" | jq -r 'fromjson | .query')
empty='{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}'
case "$query" in
*SessionProjects*) printf '{"data":{"projects":%s}}' "$empty" ;;
*SessionCycles*) jq -cjn --argjson rows "$CYCLES" '{data: {cycles: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $rows}}}' ;;
*SessionIssues*) printf '{"data":{"issues":%s}}' "$empty" ;;
*) printf '{"errors":[{"message":"unexpected query"}]}' ;;
esac
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# A timestamp OFFSET seconds from now, in Linear's shape.
at() { jq -rn --argjson off "$1" '(now + $off) | todate | sub("Z$"; ".000Z")'; }
# cycle ID START_OFFSET END_OFFSET PROGRESS
cycle() { jq -cn --arg id "$1" --arg starts "$(at "$2")" --arg ends "$(at "$3")" --argjson progress "$4" \
    '{id: $id, number: 1, name: null, startsAt: $starts, endsAt: $ends, progress: $progress,
      issueCountHistory: [], completedIssueCountHistory: [], scopeHistory: [], completedScopeHistory: [], team: {name: "T"}}'; }

status() {
    (cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" TZ=Pacific/Kiritimati \
        LINEAR_API_KEY_OVERRIDE=test-key CYCLES="$1" bash .agents/skills/linear/scripts/linear.sh session-status)
}

# Two finished cycles, one running, one starting in six hours; listed out of
# date order, as Linear may page them.
running=$(jq -cs . <<<"$(cycle future 21600 1231200 0)$(cycle old -2592000 -1296000 1)$(cycle current -3600 1206000 0.5)$(cycle recent -1296000 -3600 1)")
out=$(status "$running")
assert_jq "running cycle: cycle is the started one" "$out" '.cycle.id == "current"'
assert_jq "running cycle: prev is the latest earlier cycle" "$out" '.prev_cycle.id == "recent"'
assert_jq "running cycle: next is the earliest later cycle" "$out" '.next_cycle.id == "future"'

idle=$(jq -cs . <<<"$(cycle future 21600 1231200 0)$(cycle old -2592000 -1296000 1)$(cycle recent -1296000 -3600 1)")
out=$(status "$idle")
assert_jq "no cycle running: cycle is null" "$out" '.cycle == null'
assert_jq "no cycle running: prev cuts at now" "$out" '.prev_cycle.id == "recent"'
assert_jq "no cycle running: next cuts at now" "$out" '.next_cycle.id == "future"'

# A gap between cycles, after one that ended with issues unfinished: its
# progress stays below 1, and it is still not running.
gap=$(jq -cs . <<<"$(cycle future 21600 1231200 0)$(cycle old -2592000 -1296000 1)$(cycle unfinished -1296000 -86400 0.9)")
out=$(status "$gap")
assert_jq "ended unfinished cycle: cycle is null" "$out" '.cycle == null'
assert_jq "ended unfinished cycle: prev is the ended cycle" "$out" '.prev_cycle.id == "unfinished"'
assert_jq "ended unfinished cycle: next cuts at now" "$out" '.next_cycle.id == "future"'
