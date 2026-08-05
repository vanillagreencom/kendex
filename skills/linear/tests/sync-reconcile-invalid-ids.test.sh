#!/usr/bin/env bash
# Regression test (vstack#43): reconcile_issues sends every cached issue id in
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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/.agents/skills" "$ROOT/bin" "$ROOT/.cache/linear/comments"
cp -R "$SKILL_DIR" "$ROOT/.agents/skills/linear"
git -C "$ROOT" init -q -b main

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
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$ROOT/bin/curl"

set +e
out="$(cd "$ROOT" && PATH="$ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
  bash "$ROOT/.agents/skills/linear/scripts/linear.sh" sync --reconcile --no-attachments 2>"$ROOT/err.txt")"
rc=$?
set -e
err="$(cat "$ROOT/err.txt")"

if [[ $rc -ne 0 ]]; then
  echo "FAIL sync exited $rc on a cache with one malformed id: $out / $err"
  exit 1
fi

if ! grep -q "skipping 2 cached id" <<<"$err"; then
  echo "FAIL missing diagnostic naming the skipped malformed id: $err"
  exit 1
fi

if [[ ! -f "$RECONCILE_LOG" ]]; then
  echo "FAIL reconcile query was never sent"
  exit 1
fi
if jq -e '.variables.filter.id.in | index("child-uuid")' "$RECONCILE_LOG" >/dev/null 2>&1; then
  echo "FAIL malformed id 'child-uuid' was sent to the API: $(cat "$RECONCILE_LOG")"
  exit 1
fi
if jq -e '.variables.filter.id.in | index("uuid-1")' "$RECONCILE_LOG" >/dev/null 2>&1; then
  echo "FAIL malformed id 'uuid-1' (lowercase identifier shape) was sent to the API: $(cat "$RECONCILE_LOG")"
  exit 1
fi
if ! jq -e --arg id "$VALID_UUID" '.variables.filter.id.in | index($id)' "$RECONCILE_LOG" >/dev/null 2>&1; then
  echo "FAIL valid uuid was not sent to the API: $(cat "$RECONCILE_LOG")"
  exit 1
fi

if jq -e '[.[] | select(.id == "child-uuid" or .id == "uuid-1")] | length == 0' "$ROOT/.cache/linear/issues.json" >/dev/null 2>&1; then
  : # pruned, expected
else
  echo "FAIL malformed cache entry 'child-uuid' was not pruned: $(cat "$ROOT/.cache/linear/issues.json")"
  exit 1
fi
if ! jq -e --arg id "$VALID_UUID" '[.[] | select(.id == $id)] | length == 1' "$ROOT/.cache/linear/issues.json" >/dev/null 2>&1; then
  echo "FAIL valid cache entry was dropped: $(cat "$ROOT/.cache/linear/issues.json")"
  exit 1
fi

echo "all pass"
