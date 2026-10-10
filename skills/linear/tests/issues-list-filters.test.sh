#!/usr/bin/env bash
# The `issues list` filter options an audit reads the whole backlog with:
# --all-projects sends no project filter, --no-project asks for issues with no
# project, every --label and --labels name must be on the issue, and two
# project-scope options together refuse before any request.
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
sed -n 's/^data = //p' <<<"$config" | jq -c 'fromjson' >>"$CALLS"
printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# label|args|expected rc|jq over the request's filter, or `none` for no request
while IFS='|' read -r label args want check; do
    : >"$TMP_ROOT/calls"
    rc=0
    # shellcheck disable=SC2086  # args is one command line of plain words
    (cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh issues list $args --max \
        >/dev/null 2>"$TMP_ROOT/err") || rc=$?
    assert_eq "$label: exit status" "$rc" "$want"
    if [[ "$check" == none ]]; then
        assert_not "$label: sends no request" test -s "$TMP_ROOT/calls"
    else
        assert_jq "$label: filter" "$(cat "$TMP_ROOT/calls")" ".variables.filter | $check"
    fi
done <<'ROWS'
email assignee|--assignee Owner@Example.com|0|.assignee == {email: {eqIgnoreCase: "Owner@Example.com"}}
all projects|--all-projects --state Todo|0|has("project") | not
no project|--no-project|0|.project == {null: true}
one label|--label bug|0|.labels == {name: {eq: "bug"}}
two labels by --labels|--labels bug,skills|0|.and == [{labels: {name: {eq: "bug"}}}, {labels: {name: {eq: "skills"}}}]
two labels by --label|--label bug --label skills|0|.and == [{labels: {name: {eq: "bug"}}}, {labels: {name: {eq: "skills"}}}]
--project with --all-projects|--project P --all-projects|1|none
--no-project with --project|--no-project --project P|1|none
--all-projects with --no-project|--all-projects --no-project|1|none
ROWS
