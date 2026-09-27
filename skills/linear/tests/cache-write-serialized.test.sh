#!/usr/bin/env bash
# A merge, a full sync's install and a write-through on the issue cache
# serialize on the cache's own lock and install through unique temp files, so
# the cache is one JSON array holding both results whatever their
# interleaving; a cache that no longer parses is refused by the merge, never
# replaced with the delta; and a write-through whose rewrite fails leaves the
# cache byte for byte as it was, with no temp file beside it.
#
# The sync lock only ever held syncs apart. A write-through from another
# session ran during a sync, and both wrote the same `issues.json.tmp`: each
# opened it with O_TRUNC, the shorter output was followed by the longer one's
# tail, and the first rename installed that as the cache. Every reader then
# refused the file as corrupt until a full sync replaced it.
#
# The merge row sources the cache library directly, the smallest surface that
# fails. The full-sync and corrupt-cache rows drive `sync` against a mocked
# curl, so the sync.sh surface and the exit status are proved. Fully offline.
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
REAL_JQ="$(command -v jq)"
REAL_FLOCK="$(command -v flock)"

# A jq that, for the one invocation whose filter carries JQ_STALL_FILTER,
# reads and transforms its input, touches JQ_STALL_MARK, and holds its output
# back until JQ_STALL_RELEASE exists. jq reads all of its input before it
# writes, so the mark says the writer has read the cache and the release says
# it may now write the result: the window in which a second writer's rename
# lands is opened and closed by files, not by the clock. Every other
# invocation runs straight through. The bound keeps a suite that never
# releases from hanging: it fails the stalled writer instead.
cat >"$ROOT/bin/jq" <<SH
#!/usr/bin/env bash
if [[ -n "\${JQ_STALL_FILTER:-}" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == *"\$JQ_STALL_FILTER"* ]]; then
      rc=0
      out="\$("$REAL_JQ" "\$@")" || rc=\$?
      : >"\$JQ_STALL_MARK"
      for (( i = 0; i < 1200; i++ )); do
        [[ -e "\$JQ_STALL_RELEASE" ]] && break
        sleep 0.05
      done
      [[ -e "\$JQ_STALL_RELEASE" ]] || { echo "jq stub: never released" >&2; exit 1; }
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

seed_cache() {
  printf '[%s,%s,%s]\n' \
    "$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 seeded)" \
    "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 seeded)" \
    "$(issue 33333333-3333-3333-3333-333333333333 PROJ-3 seeded)" \
    >"$CACHE/issues.json"
}

# wait_for_file PATH DESC — poll until PATH exists. The bound turns a subject
# that never gets there into a failed suite rather than a hung one.
wait_for_file() {
  local i
  for (( i = 0; i < 600; i++ )); do
    [[ -e "$1" ]] && return 0
    sleep 0.05
  done
  assert_stop "$2" "never appeared: $1"
}

# write_through_during_stall MARK RELEASE ISSUE_JSON — once the stalled writer
# has read the cache (MARK), run the write-through beside it, and release the
# stalled writer only when the write-through has either finished or is queued
# behind the held lock. A write-through the lock does not stop lands inside
# the window; one it does stop is ordered by the lock, whatever the clock
# says. The write-through's status arrives through WRITE_THROUGH_RC.
WRITE_THROUGH_RC=""
write_through_during_stall() {
  local mark="$1" release="$2" issue_json="$3" i
  wait_for_file "$mark" "the stalled writer reads the cache"
  local started="$ROOT/write-through.started" done="$ROOT/write-through.done"
  rm -f "$started" "$done"
  (
    : >"$started"
    cache_upsert_issue "$issue_json"
    : >"$done"
  ) &
  local pid=$!
  wait_for_file "$started" "the write-through starts"
  for (( i = 0; i < 600; i++ )); do
    [[ -e "$done" ]] && break
    # The lock is held by the stalled writer alone, so a held lock means the
    # write-through queues behind it and nothing more can land in the window.
    "$REAL_FLOCK" -n "$CACHE/issues.json.lock" true || break
    sleep 0.05
  done
  if [[ ! -e "$done" ]] && "$REAL_FLOCK" -n "$CACHE/issues.json.lock" true; then
    assert_stop "the write-through finishes or queues behind the lock"
  fi
  : >"$release"
  WRITE_THROUGH_RC=0
  wait "$pid" || WRITE_THROUGH_RC=$?
}

no_temp_beside_cache() {
  find "$CACHE" -maxdepth 1 -name 'issues.json.*' ! -name 'issues.json.lock' | wc -l | tr -d ' '
}

# shellcheck source=../scripts/lib/cache.sh
source "$ROOT/.agents/skills/linear/scripts/lib/cache.sh"

# --- a merge and a write-through interleave ------------------------------------
seed_cache
printf '[%s,%s]' \
  "$(issue 11111111-1111-1111-1111-111111111111 PROJ-1 merged)" \
  "$(issue 44444444-4444-4444-4444-444444444444 PROJ-4 merged)" \
  >"$ROOT/delta.json"

# The merge stalls between reading the cache and writing the merged result;
# the write-through runs inside that stall. Without one lock over both, the
# write-through's rename lands during the stall and the merge's rename then
# discards it.
(
  export PATH="$ROOT/bin:$PATH" JQ_STALL_FILTER="group_by" \
    JQ_STALL_MARK="$ROOT/merge.read" JQ_STALL_RELEASE="$ROOT/merge.release"
  cache_merge "issues.json" "$ROOT/delta.json"
) &
MERGE_PID=$!
write_through_during_stall "$ROOT/merge.read" "$ROOT/merge.release" \
  "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 "written through")"
merge_rc=0
wait "$MERGE_PID" || merge_rc=$?

assert_eq "the merge succeeds beside a concurrent write-through" "$merge_rc" 0
assert_eq "the write-through succeeds beside a concurrent merge" "$WRITE_THROUGH_RC" 0
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
assert_eq "no writer leaves a temp file beside the cache after a merge" \
  "$(no_temp_beside_cache)" "0"

# --- the mocked API: one issue, PROJ-1 updated, from every issues pull --------
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

# run_sync ARGS... — `sync` in the fixture root against the mocked curl, its
# stderr in $ROOT/sync-err. The stall variables reach the sync's own jq calls
# only when the caller exports them.
run_sync() {
  (cd "$ROOT" && PATH="$ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR" sync --no-attachments "$@") >/dev/null 2>"$ROOT/sync-err"
}

# --- a full sync's install and a write-through interleave ----------------------
# No meta.json makes the sync full: it replaces the seeded cache with the one
# pulled issue. The install stalls between reading the pull and writing the
# cache; the write-through runs inside that stall.
seed_cache
rm -f "$CACHE/meta.json"
echo '[]' >"$CACHE/projects.json"
(
  export JQ_STALL_FILTER='gsub(' \
    JQ_STALL_MARK="$ROOT/full.read" JQ_STALL_RELEASE="$ROOT/full.release"
  run_sync
) &
FULL_PID=$!
write_through_during_stall "$ROOT/full.read" "$ROOT/full.release" \
  "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 "written through")"
full_rc=0
wait "$FULL_PID" || full_rc=$?

assert_eq "a full sync succeeds beside a concurrent write-through" "$full_rc" 0
assert_eq "the write-through succeeds beside a concurrent full sync" "$WRITE_THROUGH_RC" 0
assert "the cache is one JSON document after a full sync and a write-through interleave" \
  jq empty "$CACHE/issues.json"
assert_eq "the full sync replaces the seeded cache with the pull" \
  "$(jq -r '[.[] | select(.identifier == "PROJ-1")] | first | .title' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" \
  "updated"
assert_eq "the write-through survives a concurrent full sync" \
  "$(jq -r '[.[] | select(.identifier == "PROJ-2")] | first | .title' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" \
  "written through"
assert_eq "the full sync's cache holds the pull and the write-through and nothing seeded" \
  "$(jq 'if type == "array" then length else "not an array" end' "$CACHE/issues.json" 2>/dev/null || echo unparseable)" "2"
assert_not "the full sync removes its pulled scratch file" test -e "$CACHE/.full_issues.json"
assert_eq "no writer leaves a temp file beside the cache after a full sync" \
  "$(no_temp_beside_cache)" "0"

# --- a corrupt cache is refused, not replaced with the delta -------------------
# The preserved fleet shape: one complete array followed by the tail of a
# longer serialization of the same array.
seed_cache
printf 's": {\n      "nodes": []\n    }\n  }\n]\n' >>"$CACHE/issues.json"
cp "$CACHE/issues.json" "$ROOT/corrupt-before.json"
OLD_SYNC="2026-01-01T00:00:00+00:00"
# Old synced_at forces an issues delta; fresh reconciled_at skips reconcile
jq -n --arg synced "$OLD_SYNC" --arg rec "$(date -Iseconds)" \
  '{synced_at: $synced, reconciled_at: $rec, stats: {}}' >"$CACHE/meta.json"

sync_rc=0
run_sync || sync_rc=$?
err="$(cat "$ROOT/sync-err")"

assert_ne "a corrupt issue cache fails the sync" "$sync_rc" 0
assert_contains "the refusal names the corrupt cache" "$err" "corrupt"
assert_contains "the refusal names the full sync that repairs it" "$err" "sync --full"
assert_contains "sync names the aborted merge" "$err" "Sync error: issues cache merge aborted"
assert "the corrupt cache is left byte for byte as it was" \
  cmp -s "$ROOT/corrupt-before.json" "$CACHE/issues.json"
assert_eq "a refused merge leaves synced_at where it was" \
  "$(jq -r '.synced_at' "$CACHE/meta.json")" "$OLD_SYNC"

# --- a failing write-through leaves the cache as it was -----------------------
# The write-through's jq reads the corrupt cache and fails before it prints
# a document. Its exit status is the write-through's, and the install leaves
# the cache alone: an empty rewrite installed over the corrupt file would
# turn the corruption the merge refusal names into a cache every reader
# reports as no results.
wt_rc=0
cache_upsert_issue "$(issue 22222222-2222-2222-2222-222222222222 PROJ-2 "written through")" \
  2>/dev/null || wt_rc=$?

assert_ne "a write-through over a corrupt cache fails" "$wt_rc" 0
assert "a failing write-through leaves the cache byte for byte as it was" \
  cmp -s "$ROOT/corrupt-before.json" "$CACHE/issues.json"
assert_eq "a failing write-through leaves no temp file beside the cache" \
  "$(no_temp_beside_cache)" "0"
