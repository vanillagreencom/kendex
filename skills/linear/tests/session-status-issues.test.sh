#!/usr/bin/env bash
# session-status counts the issues its own reads select. The research read
# asks for the research label, completed state and an updatedAt at or after
# the --research-days cut, and every issue it returns is counted. No read asks
# for archived issues, so the archived and trashed issues Linear leaves out by
# default reach no section.
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

# The clock: N days back from now answers 2026-09-N, so the cut names the day
# count it was asked for (GNU `-d "-N days"`, BSD `-v-Nd`); every other date
# call reaches the system's date.
REAL_DATE=$(command -v date) || { echo 'session-status-issues: date=missing' >&2; exit 1; }
cat >"$TMP_ROOT/bin/date" <<STUB
#!/usr/bin/env bash
if [[ "\$*" =~ -([0-9]+)\ days|-v-([0-9]+)d ]]; then
    printf '2026-09-%02dT12:00:00.000Z\\n' "\$((10#\${BASH_REMATCH[1]}\${BASH_REMATCH[2]}))"
else
    exec "$REAL_DATE" "\$@"
fi
STUB
chmod +x "$TMP_ROOT/bin/date"

# Linear as it pages: an archived row only when the query asks for archived
# rows, as includeArchived defaults to false. One started project. Its open
# issues: KEN-1 and the trashed KEN-2. The research read, answered only for
# its exact filter: KEN-3 and the archived KEN-4. Children of In Review
# parents: KEN-5 and the trashed KEN-6, both under the In Review KEN-7. Each
# request's variables are kept in $CALLS.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
jq -c '.variables' <<<"$payload" >>"$CALLS"
jq -cj '
def closed: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []};
def issue($id; $state; $type; $labels; $extra): {id: ("uuid-" + $id), identifier: $id, title: $id, description: "",
    url: "", priority: 2, state: {name: $state, type: $type},
    labels: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: ($labels | map({name: .}))},
    project: {id: "p1", name: "Project"}, cycle: null, parent: null, archivedAt: null, trashed: null,
    relations: closed, inverseRelations: closed} + $extra;
def page($rows): {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $rows};
def research: {labels: {name: {eq: "research"}}, state: {type: {eq: "completed"}},
    updatedAt: {gte: "2026-09-14T12:00:00.000Z"}};
.query as $q | .variables.filter as $f | ($q | test("includeArchived: *true")) as $archived | (
if ($q | test("SessionProjects")) then {data: {projects: page([{id: "p1", name: "Project", description: "", state: "started",
    progress: 0, priority: 1, sortOrder: 1, labels: closed, relations: closed, inverseRelations: closed}])}}
elif ($q | test("SessionCycles")) then {data: {cycles: page([])}}
elif ($f.project != null) then {data: {issues: page([
    issue("KEN-1"; "Todo"; "unstarted"; ["agent:runtime"]; {}),
    issue("KEN-2"; "Todo"; "unstarted"; ["agent:runtime"]; {archivedAt: "2026-10-01T00:00:00.000Z", trashed: true})])}}
elif ($f == research) then {data: {issues: page([
    issue("KEN-3"; "Done"; "completed"; ["research"]; {project: null}),
    issue("KEN-4"; "Done"; "completed"; ["research"]; {project: null, archivedAt: "2026-10-01T00:00:00.000Z"})])}}
elif ($f.parent.state != null) then {data: {issues: page([
    issue("KEN-5"; "Todo"; "unstarted"; []; {project: null, parent: {id: "uuid-KEN-7", identifier: "KEN-7", title: "KEN-7"}}),
    issue("KEN-8"; "Verifying"; "started"; []; {project: null, parent: {id: "uuid-KEN-7", identifier: "KEN-7", title: "KEN-7"}}),
    issue("KEN-6"; "Todo"; "unstarted"; []; {project: null, parent: {id: "uuid-KEN-7", identifier: "KEN-7", title: "KEN-7"},
        archivedAt: "2026-10-01T00:00:00.000Z", trashed: true})])}}
elif ($f.parent.id != null) then {data: {issues: page([
    $f.parent.id.in[] | select(. == "uuid-KEN-5")
    | issue("KEN-9"; "Verifying"; "started"; []; {project: null, parent: {id: "uuid-KEN-5", identifier: "KEN-5", title: "KEN-5"}})])}}
elif ($f.id != null) then {data: {issues: page([$f.id.in[] | select(. == "uuid-KEN-7")
    | issue("KEN-7"; "In Review"; "started"; []; {project: null})])}}
else {data: {issues: page([])}} end)
| .data |= map_values(.nodes |= map(select(.archivedAt == null or $archived) | del(.archivedAt, .trashed)))' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

rc=0
: >"$TMP_ROOT/calls"
out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" LINEAR_API_KEY_OVERRIDE=test-key \
    CALLS="$TMP_ROOT/calls" "$BASH" .agents/skills/linear/scripts/linear.sh session-status --research-days 14 \
    2>"$TMP_ROOT/err") || rc=$?
assert_eq "session-status succeeds" "$rc" 0
assert_jq "the research read asks for completed research updated since the cut" "$(jq -cs . "$TMP_ROOT/calls")" \
    'map(.filter | select(.labels != null)) == [{labels: {name: {eq: "research"}}, state: {type: {eq: "completed"}},
        updatedAt: {gte: "2026-09-14T12:00:00.000Z"}}]'
assert_eq "the research cut lies --research-days days back" \
    "$(jq -rs 'map(.filter | select(.labels != null) | .updatedAt.gte) | join(",")' "$TMP_ROOT/calls")" \
    2026-09-14T12:00:00.000Z
assert_jq "a research issue the research read returns is counted" "$out" '.research.count == 1'
assert_jq "an archived or trashed project issue reaches no section" "$out" '[.issues.actionable[].id] == ["KEN-1"]'
assert_jq "a trashed pending child is left out of pr_blockers" "$out" '[.pr_blockers[].id] == ["KEN-5"]'

assert_jq "Verifying is absent from development blocker items" "$out" '[.pr_blockers[].id] | index("KEN-8") == null'
assert_jq "Verifying is absent from development blocker child work" "$out" '[.pr_blockers[].children[].id] | index("KEN-9") == null'
