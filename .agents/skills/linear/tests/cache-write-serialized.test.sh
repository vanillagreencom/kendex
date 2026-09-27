#!/usr/bin/env bash
# A merge and a write-through on the issue cache serialize on the cache's own
# lock and install through unique temp files, so the cache is one JSON array
# holding both results whatever their interleaving; and a cache that no longer
# parses is refused by the merge, never replaced with the delta.
#
# The sync lock only ever held syncs apart. A write-through from another
# session ran during a sync, and both wrote the same `issues.json.tmp`: each
# opened it with O_TRUNC, the shorter output was followed by the longer one's
# tail, and the first rename installed that as the cache. Every reader then
# refused the file as corrupt until a full sync replaced it.
#
# The merge case sources the cache library directly, the smallest surface that
# fails. The corrupt-cache case drives `sync` against a mocked curl, so the
# refusal is proved to reach the command's exit status. Fully offline.
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
CACHE="$ROOT/.cache/linear"
LINEAR="$ROOT/.agents/skills/linear/scripts/linear.sh"

# A jq that, for one invocation, holds its output back after it has read and
# transformed its input. jq reads all of its input before it writes, so this
# stretches the window between a writer's read of the cache and its write of
# the result: the window in which a second writer's rename lands. Every other
# invocation runs straight through.
REAL_JQ="$(command -v jq)"
cat >"$ROOT/bin/jq" <<SH
#!/usr/bin/env bash
if [[ -n "\${JQ_STALL_SECS:-}" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == *"\$JQ_STALL_FILTER"* ]]; then
      rc=0
      out="\$("$REAL_JQ" "\$@")" || rc=\$?
      sleep "\$JQ_STALL_SECS"
      printf '%s\n' "\$out"
      exit "\$rc"
    fi
  done
fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$ROOT/bin/jq"

issue() {
  printf '{"id":"%s","identifier":"%s","title":"%s","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}' "$1" "$2" "$3"
}

# --- a merge and a write-through interleave ------------------------------------
printf '[%s,%s,%s]' \
  "$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 seeded)" \
  "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 seeded)" \
  "$(issue 33333333-3333-3333-3333-333333333333 PROJ-3 seeded)" \
  >"$CACHE/issues.json"
printf '[%s,%s]' \
  "$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 merged)" \
  "$(issue 44444444-4444-4444-4444-444444444444 PROJ-4 merged)" \
  >"$ROOT/delta.json"

# shellcheck source=../scripts/lib/cache.sh
source "$ROOT/.agents/skills/linear/scripts/lib/cache.sh"

# The merge starts first and stalls between reading the cache and writing the
# merged result; the write-through starts inside that stall. Without one lock
# over both, the write-through's rename lands during the stall and the merge's
# rename then discards it.
(
  export PATH="$ROOT/bin:$PATH" JQ_STALL_FILTER="group_by" JQ_STALL_SECS=2
  cache_merge "issues.json" "$ROOT/delta.json"
) &
MERGE_PID=$!
# The merge must have read the cache before the write-through starts, or the
# write-through is simply first and the interleaving under test never occurs.
sleep 0.5
cache_upsert_issue "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 "written through")"
merge_rc=0
wait "$MERGE_PID" || merge_rc=$?

assert_eq "the merge succeeds beside a concurrent write-through" "$merge_rc" 0
assert "the cache is one JSON document after a merge and a write-through interleave" \
  jq empty "$CACHE/issues.json"
assert_eq "the cache holds every seeded issue plus the one the delta added" \
  "$(jq 'if type == "array" then length else "not an array" end' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" "4"
assert_eq "the write-through survives a concurrent merge" \
  "$(jq -r '[.[] | select(.identifier == "PROJ-2")] | first | .title' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" \
  "written through"
assert_eq "the merge delta survives a concurrent write-through" \
  "$(jq -r '[.[] | select(.identifier == "PROJ-1")] | first | .title' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" \
  "merged"
assert_eq "no writer leaves a temp file beside the cache" \
  "$(find "$CACHE" -maxdepth 1 -name 'issues.json.*' ! -name 'issues.json.lock' | wc -l | tr -d ' ')" "0"

# --- a corrupt cache is refused, not replaced with the delta -------------------
# The preserved fleet shape: one complete array followed by the tail of a
# longer serialization of the same array.
printf '[%s,%s,%s]\n' \
  "$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 seeded)" \
  "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 seeded)" \
  "$(issue 33333333-3333-3333-3333-333333333333 PROJ-3 seeded)" \
  >"$CACHE/issues.json"
printf 's": {\n      "nodes": []\n    }\n  }\n]\n' >>"$CACHE/issues.json"
cp "$CACHE/issues.json" "$ROOT/corrupt-before.json"
echo '[]' >"$CACHE/projects.json"
OLD_SYNC="2026-01-01T00:00:00+00:00"
# Old synced_at forces an issues delta; fresh reconciled_at skips reconcile
jq -n --arg synced "$OLD_SYNC" --arg rec "$(date -Iseconds)" \
  '{synced_at: $synced, reconciled_at: $rec, stats: {}}' >"$CACHE/meta.json"

DELTA_NODE="$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 updated | jq -c '. + {description: "", assignee: null, project: null, projectMilestone: null, cycle: null, parent: null, team: {name: "Claude"}, priority: 0, estimate: null, sortOrder: 1, url: "u", createdAt: "2026-07-01T00:00:00Z", updatedAt: "2026-07-27T00:00:00Z", archivedAt: null, trashed: null}')"
cat >"$ROOT/bin/curl" <<SH
#!/usr/bin/env bash
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
query="\$(jq -r '.query' <<<"\$payload")"
case "\$query" in
*"SyncIssues("*)
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[$DELTA_NODE]}}}___HTTP_CODE___200' ;;
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
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$ROOT/bin/curl"

sync_rc=0
(cd "$ROOT" && PATH="$ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
  bash "$LINEAR" sync --no-attachments) >/dev/null 2>"$ROOT/sync-err" || sync_rc=$?
err="$(cat "$ROOT/sync-err")"

assert_ne "a corrupt issue cache fails the sync" "$sync_rc" 0
assert_contains "the refusal names the corrupt cache" "$err" "corrupt"
assert_contains "the refusal names the full sync that repairs it" "$err" "sync --full"
assert_contains "sync names the aborted merge" "$err" "Sync error: issues cache merge aborted"
assert "the corrupt cache is left byte for byte as it was" \
  cmp -s "$ROOT/corrupt-before.json" "$CACHE/issues.json"
assert_eq "a refused merge leaves synced_at where it was" \
  "$(jq -r '.synced_at' "$CACHE/meta.json")" "$OLD_SYNC"
