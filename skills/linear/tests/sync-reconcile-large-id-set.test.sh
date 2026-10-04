#!/usr/bin/env bash
# reconcile_issues checks every cached issue id against the API, however many
# the cache holds, in requests of at most one page of ids, and prunes only the
# ids the API answered for as trashed, archived or absent. A batch the API
# reports as paged fails the sync and prunes nothing. The 6226-issue cache is a
# workspace-sized one: its id array passes the kernel's per-argument cap, and
# it holds more ids than ten pages of 250.
#
# Runs fully offline against a mocked curl that answers at most 250 nodes per
# request, as Linear's page limit does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir ROOT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$ROOT/.agents/skills" "$ROOT/bin" "$ROOT/.cache/linear/comments"
cp -R "$SKILL_DIR" "$ROOT/.agents/skills/linear"
git -C "$ROOT" init -q -b main
export LINEAR_CACHE_ROOT="$ROOT"

ISSUE_COUNT=6226
# Past the first 2500 ids, so a reconcile that stops early never sees it.
TRASHED_ID="00000000-0000-4000-8000-000000006000"

jq -n --argjson n "$ISSUE_COUNT" '[range($n) | {
    id: "00000000-0000-4000-8000-\(1000000000000 + . | tostring | .[1:])",
    identifier: "PROJ-\(. + 1)", title: "t",
    state: {name: "Todo", type: "unstarted"},
    labels: {nodes: []}, relations: {nodes: []}, inverseRelations: {nodes: []}}]' \
  >"$ROOT/issues.json"

# The mock reads its mode from a file: `whole` answers every id it was sent,
# up to the page limit; `paged` drops ten ids from each answer and reports
# another page.
cat >"$ROOT/bin/curl" <<SH
#!/usr/bin/env bash
payload="\$(sed -n 's/^data = //p' | jq -r .)"
case "\$(jq -r '.query' <<<"\$payload")" in
*"ReconcileIssues("*)
  jq -r '.variables.filter.id.in[]' <<<"\$payload" >>"$ROOT/sent-ids"
  jq -r '.variables.filter.id.in | length' <<<"\$payload" >>"$ROOT/batch-sizes"
  jq -c --arg mode "\$(cat "$ROOT/mode")" --arg trashed "$TRASHED_ID" '
    .variables as \$v
    | ([\$v.first, 250] | min) as \$page
    | \$v.filter.id.in as \$ids
    | (if \$mode == "paged" then \$ids[:-10] else \$ids[:\$page] end) as \$answered
    | {data: {issues: {
        pageInfo: {hasNextPage: (\$mode == "paged" or (\$ids | length) > \$page)},
        nodes: [\$answered[] | {id: ., identifier: null, trashed: (if . == \$trashed then true else null end), archivedAt: null}]}}}' \
    <<<"\$payload" | tr -d '\n'
  printf '___HTTP_CODE___200' ;;
*"SyncIssues("*)
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncProjects("*)
  printf '%s' '{"data":{"projects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncCycles("*)
  printf '%s' '{"data":{"cycles":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncInitiatives("*)
  printf '%s' '{"data":{"initiatives":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncLabels("*)
  printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$ROOT/bin/curl"

# run_reconcile MODE — a fresh cache whose reconcile stamp is stale, then one
# `sync --reconcile`. RC and ERR hold its status and stderr.
run_reconcile() {
  printf '%s\n' "$1" >"$ROOT/mode"
  : >"$ROOT/sent-ids"
  : >"$ROOT/batch-sizes"
  cp "$ROOT/issues.json" "$ROOT/.cache/linear/issues.json"
  echo '[]' >"$ROOT/.cache/linear/projects.json"
  # A fresh synced_at keeps the delta pull empty; the stale reconciled_at is
  # the stamp a reconcile must replace.
  jq -n --arg synced "$(date -Iseconds)" \
    '{synced_at: $synced, reconciled_at: "2020-01-01T00:00:00+00:00", stats: {}}' \
    >"$ROOT/.cache/linear/meta.json"
  RC=0
  (cd "$ROOT" && env PATH="$ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=lin_api_test \
    LINEAR_RETRY_BASE_DELAY=0 \
    bash "$ROOT/.agents/skills/linear/scripts/linear.sh" sync --reconcile --no-attachments \
    >/dev/null 2>"$ROOT/err") || RC=$?
  ERR="$(cat "$ROOT/err")"
}

jq -r '.[].id' "$ROOT/issues.json" | sort >"$ROOT/cached-ids"

run_reconcile whole
assert_eq "a reconcile past the per-argument cap succeeds" "$RC" 0
sort -u "$ROOT/sent-ids" >"$ROOT/sent-ids.sorted"
assert_eq "every cached id is checked against the API" \
  "$(comm -23 "$ROOT/cached-ids" "$ROOT/sent-ids.sorted" | awk 'END { print NR }')" 0
assert_eq "every reconcile request fits one page" \
  "$(sort -n "$ROOT/batch-sizes" | tail -n 1)" 250
assert "the trashed issue is pruned" \
  jq -e --arg id "$TRASHED_ID" 'all(.[]; .id != $id)' "$ROOT/.cache/linear/issues.json"
assert_eq "every live issue survives the reconcile" \
  "$(jq 'length' "$ROOT/.cache/linear/issues.json")" "$((ISSUE_COUNT - 1))"
assert "the reconcile stamps reconciled_at" \
  jq -e '.reconciled_at | startswith("2020") | not' "$ROOT/.cache/linear/meta.json"

run_reconcile paged
assert_ne "a paged reconcile batch fails the sync" "$RC" 0
assert_contains "a paged reconcile batch names the batch" "$ERR" "Reconciliation error: batch at offset 0 of $ISSUE_COUNT"
assert_eq "a paged reconcile batch prunes nothing" \
  "$(jq 'length' "$ROOT/.cache/linear/issues.json")" "$ISSUE_COUNT"
