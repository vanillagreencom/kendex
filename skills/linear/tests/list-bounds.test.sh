#!/usr/bin/env bash
# One owner bounds every list verb (lib/pages.sh linear_list_*): 75 rows by
# default, --limit N for a positive whole N, --max for every row, --first for
# one row, and a `linear-list: truncated` notice on stderr exactly when a
# bounded read left rows unread. The page each verb asks for comes from its own
# query, 50 where its rows select a connection, else 250, unless the verb names
# a page measured for it: issues list asks for 75. A bound
# that is no positive whole number, and a cycles --type Linear has no filter
# for, refuse before any request.
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

# Linear's paging over a collection of $TOTAL rows: the root connection the
# query names answers `first` rows from the cursor's offset. Each request's
# variables are kept in $CALLS.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
jq -c '.variables' <<<"$payload" >>"$CALLS"
jq -cj --argjson total "$TOTAL" '
    (.query | capture("[)] *[{] *(?<f>[A-Za-z]+)[(]").f) as $root |
    ((.variables.after // "c0") | ltrimstr("c") | tonumber) as $offset |
    ([$offset + .variables.first, $total] | min) as $end |
    {data: {($root): {pageInfo: {hasNextPage: ($end < $total), endCursor: "c\($end)"},
        nodes: [range($offset; $end) | {id: "row-\(.)", name: "row-\(.)"}]}}}' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# The rows, the requests sent, the largest page asked for and whether the
# notice printed, as one line.
list_summary() { # TOTAL ARGS...
    local total="$1" rc=0 out rows requests first notice
    shift
    : >"$TMP_ROOT/calls"
    out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" TOTAL="$total" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh "$@" --format=raw 2>"$TMP_ROOT/err") || rc=$?
    rows=$(jq -r '[.. | objects | select(has("nodes")) | .nodes | length] | first // 0' <<<"${out:-null}" 2>/dev/null) || rows=unparsed
    requests=$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')
    first=$(jq -s 'map(.first) | max' "$TMP_ROOT/calls")
    notice=no
    if grep -q '^linear-list: truncated ' "$TMP_ROOT/err"; then notice=yes; fi
    printf 'rc=%s rows=%s requests=%s first=%s notice=%s\n' "$rc" "$rows" "$requests" "$first" "$notice"
}

# label|total|args|want
while IFS='|' read -r label total args want; do
    [[ -n "$label" ]] || continue
    read -r -a argv <<<"$args"
    assert_eq "$label" "$(list_summary "$total" "${argv[@]}")" "$want"
done <<'ROWS'
issues list: 75 rows by default in one request, and the notice|100|issues list|rc=0 rows=75 requests=1 first=75 notice=yes
issues list --limit 300: pages of 75|400|issues list --limit 300|rc=0 rows=300 requests=4 first=75 notice=yes
issues list --limit 0: refused before any request|100|issues list --limit 0|rc=1 rows=0 requests=0 first=null notice=no
issues list --max: every row in pages of 75, no notice|160|issues list --max|rc=0 rows=160 requests=3 first=75 notice=no
issues list --limit 10 over 10 rows: no notice|10|issues list --limit 10|rc=0 rows=10 requests=1 first=10 notice=no
labels list --limit 300: a trimmed last page still notices|400|labels list --limit 300|rc=0 rows=300 requests=2 first=250 notice=yes
projects list: 75 rows by default in pages of 50|100|projects list|rc=0 rows=75 requests=2 first=50 notice=yes
projects list --limit 0: refused before any request|100|projects list --limit 0|rc=1 rows=0 requests=0 first=null notice=no
projects list --first: one row, no notice|100|projects list --first|rc=0 rows=unparsed requests=1 first=1 notice=no
users list --limit soon: refused before any request|100|users list --limit soon|rc=1 rows=0 requests=0 first=null notice=no
cycles list --type past: refused before any request|10|cycles list --type past|rc=1 rows=0 requests=0 first=null notice=no
teams list --max: rows with a connection, pages of 50|300|teams list --max|rc=0 rows=300 requests=6 first=50 notice=no
initiatives list --max: rows with a connection, pages of 50|300|initiatives list --max|rc=0 rows=300 requests=6 first=50 notice=no
projects list --max: rows with a connection, pages of 50|300|projects list --max|rc=0 rows=300 requests=6 first=50 notice=no
labels list --max: flat rows, pages of 250|300|labels list --max|rc=0 rows=300 requests=2 first=250 notice=no
project-labels list --max: flat rows, pages of 250|300|project-labels list --max|rc=0 rows=300 requests=2 first=250 notice=no
users list --max: flat rows, pages of 250|300|users list --max|rc=0 rows=300 requests=2 first=250 notice=no
cycles list --max: flat rows, pages of 250|300|cycles list --max|rc=0 rows=300 requests=2 first=250 notice=no
documents list --max: flat rows, pages of 250|300|documents list --max|rc=0 rows=300 requests=2 first=250 notice=no
ROWS
