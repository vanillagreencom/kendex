#!/usr/bin/env bash
# Regression test (kendex#43): reconcile_issues sends every cached issue id in
# one `id: {in: [...]}` GraphQL filter. Linear validates each entry as
# UUID-or-identifier and rejects the WHOLE query on one malformed entry — a
# handful of test-fixture ids (`child-uuid`, `issue-uuid`, `uuid-1`) that leaked
# into the live cache bricked every subsequent `sync`. Reconciliation must now
# validate ids before building the query: skip and log malformed entries
# (never send them to the API), prune them from the cache since a malformed id
# can never be a real Linear issue, and keep reconciling the valid ones.
#
# Runs fully offline against a mocked curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir ROOT

mkdir -p "$ROOT/.agents/skills" "$ROOT/bin" "$ROOT/.cache/linear/comments"
cp -R "$SKILL_DIR" "$ROOT/.agents/skills/linear"
git -C "$ROOT" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$ROOT"

VALID_UUID="11111111-1111-1111-1111-111111111111"

printf '%s' "[
  {\"id\":\"$VALID_UUID\",\"identifier\":\"PROJ-1\",\"title\":\"real issue\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}},
  {\"id\":\"child-uuid\",\"identifier\":\"CC-558\",\"title\":\"child\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}},
  {\"id\":\"uuid-1\",\"identifier\":\"CC-1\",\"title\":\"t\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}}
]" > "$ROOT/.cache/linear/issues.json"
echo '[]' > "$ROOT/.cache/linear/projects.json"

# Fresh synced_at (no delta sync needed) + stale reconciled_at forces the
# reconcile path without a full/incremental issues sync getting in the way.
jq -n --arg synced "$(date -Iseconds)" \
  '{synced_at: $synced, reconciled_at: "2020-01-01T00:00:00+00:00", stats: {}}' \
  > "$ROOT/.cache/linear/meta.json"

RECONCILE_LOG="$ROOT/reconcile-payload.json"

# kendex#799: a pre-#799 cache carries one .lock beside every issue whose
# comments were ever written, and the sync below is the shape that used to miss
# them — an incremental run whose issues delta comes back empty, so
# write_comments, where the sweep first lived, is never called at all. The
# shared lock sits in the cache root rather than in comments/, so the sweep's
# glob must not reach it.
: >"$ROOT/.cache/linear/comments/PROJ-1.json.lock"
: >"$ROOT/.cache/linear/comments/CC-558.json.lock"
: >"$ROOT/.cache/linear/.comments.lock"

cat >"$ROOT/bin/curl" <<SH
#!/usr/bin/env bash
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
query="\$(jq -r '.query' <<<"\$payload")"
case "\$query" in
*"ReconcileIssues("*)
  printf '%s' "\$payload" > "$RECONCILE_LOG"
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"$VALID_UUID","identifier":"PROJ-1","trashed":null,"archivedAt":null}]}}}___HTTP_CODE___200'
  ;;
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
*"SyncComments("*)
  printf '%s' '{"data":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$ROOT/bin/curl"

rc=0
out="$(cd "$ROOT" && PATH="$ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
  bash "$ROOT/.agents/skills/linear/scripts/linear.sh" sync --reconcile --no-attachments 2>"$ROOT/err.txt")" || rc=$?
err="$(cat "$ROOT/err.txt")"

assert_eq "a cache holding malformed ids still syncs" "$rc" 0
assert_contains "the diagnostic names how many cached ids were skipped" "$err" "skipping 2 cached id"
assert "the reconcile query was sent" test -f "$RECONCILE_LOG"
assert_not "the malformed id 'child-uuid' never reaches the API" \
  jq -e '.variables.filter.id.in | index("child-uuid")' "$RECONCILE_LOG"
assert_not "the identifier-shaped id 'uuid-1' never reaches the API" \
  jq -e '.variables.filter.id.in | index("uuid-1")' "$RECONCILE_LOG"
assert "the valid uuid does reach the API" \
  jq -e --arg id "$VALID_UUID" '.variables.filter.id.in | index($id)' "$RECONCILE_LOG"
assert "the malformed cache entries are pruned" \
  jq -e '[.[] | select(.id == "child-uuid" or .id == "uuid-1")] | length == 0' "$ROOT/.cache/linear/issues.json"
assert "the valid cache entry survives" \
  jq -e --arg id "$VALID_UUID" '[.[] | select(.id == $id)] | length == 1' "$ROOT/.cache/linear/issues.json"

assert_eq "a sync whose delta is empty still sweeps the legacy per-issue locks" \
  "$(find "$ROOT/.cache/linear/comments" -name '*.json.lock' | tr '\n' ' ')" ""
assert "the sweep leaves the shared comment lock alone" \
  test -f "$ROOT/.cache/linear/.comments.lock"
