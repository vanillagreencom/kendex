#!/usr/bin/env bash
# Regression test (#930, secondary): when cache_merge refuses a merge whose
# result is smaller than the existing cache (the signature of a transient
# query failure returning fewer/empty results), `sync` used to carry on and
# finish as success. The refusal itself is correct — the sync must now fail
# loudly: nonzero exit, an error naming the aborted merge and the likely
# transient query failure, and the cache and meta.json left unchanged.
#
# A healthy incremental sync (control case) must still succeed.
#
# Runs fully offline against a mocked curl; live-API confirmation pending.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_BASE

OLD_SYNC="2026-01-01T00:00:00+00:00"

# make_env <root> <existing-issues-json> <delta-node-id>
# Builds an isolated project root with a seeded cache and a curl stub whose
# SyncIssues delta updates the given issue id.
make_env() {
  local root="$1" existing="$2" delta_id="$3" extra_node="${4:-}"
  mkdir -p "$root/.agents/skills" "$root/bin" "$root/.cache/linear/comments"
  cp -R "$SKILL_DIR" "$root/.agents/skills/linear"
  git -C "$root" init -q

  printf '%s' "$existing" > "$root/.cache/linear/issues.json"
  echo '[]' > "$root/.cache/linear/projects.json"

  # Comment files the abort must leave alone: a comment write that ran before
  # the merge could reject would rewrite them while the command reports the
  # cache unchanged.
  printf '[{"id":"c1","body":"kept"}]' > "$root/.cache/linear/comments/PROJ-1.json"
  printf '[{"id":"c3","body":"kept too"}]' > "$root/.cache/linear/comments/PROJ-3.json"
  # Old synced_at forces an issues delta; fresh reconciled_at skips reconcile
  jq -n --arg synced "$OLD_SYNC" --arg rec "$(date -Iseconds)" \
    '{synced_at: $synced, reconciled_at: $rec, stats: {}}' > "$root/.cache/linear/meta.json"

  delta_node="{\"id\":\"$delta_id\",\"identifier\":\"PROJ-1\",\"title\":\"updated\",\"description\":\"\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"assignee\":null,\"project\":null,\"projectMilestone\":null,\"cycle\":null,\"parent\":null,\"team\":{\"name\":\"Claude\"},\"labels\":{\"nodes\":[]},\"priority\":0,\"estimate\":null,\"sortOrder\":1,\"url\":\"u\",\"createdAt\":\"2026-07-01T00:00:00Z\",\"updatedAt\":\"2026-07-27T00:00:00Z\",\"archivedAt\":null,\"trashed\":null,\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}}"

  local delta_nodes="$delta_node"
  [[ -n "$extra_node" ]] && delta_nodes="$delta_node,$extra_node"

  cat >"$root/bin/curl" <<SH
#!/usr/bin/env bash
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
query="\$(jq -r '.query' <<<"\$payload")"
case "\$query" in
*"SyncIssues("*)
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[$delta_nodes]}}}___HTTP_CODE___200' ;;
*"SyncProjects("*)
  printf '%s' '{"data":{"projects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncCycles("*)
  printf '%s' '{"data":{"cycles":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncInitiatives("*)
  printf '%s' '{"data":{"initiatives":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncLabels("*)
  printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncComments("*)
  printf '%s' '{"data":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"c3-new","body":"refetched","issue":{"identifier":"PROJ-3"}},{"id":"c9","body":"on a brand new issue","issue":{"identifier":"PROJ-9"}}]}}}___HTTP_CODE___200' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
  chmod +x "$root/bin/curl"
}

# Each case has its own project root, so the cache redirect is per invocation
# rather than one export for the suite. Every root is under TMP_BASE, so the
# exit verdict's containment check holds.
run_sync() {
  local root="$1"
  (cd "$root" && PATH="$root/bin:$PATH" LINEAR_CACHE_ROOT="$root" LINEAR_API_KEY=test-token \
    bash "$root/.agents/skills/linear/scripts/linear.sh" sync --no-attachments)
}

run_sync_if_stale() {
  local root="$1"
  (cd "$root" && PATH="$root/bin:$PATH" LINEAR_CACHE_ROOT="$root" LINEAR_API_KEY=test-token \
    bash "$root/.agents/skills/linear/scripts/linear.sh" sync --if-stale 15 --no-attachments)
}

# --- abort case: merge result would shrink below the existing cache --------------
# Two cached entries share an id, so the delta merge dedupes 3 -> 2 and trips
# the cache_merge guard — the same guard a transient empty/partial query
# result lands on.
ABORT_ROOT="$TMP_BASE/abort"
make_env "$ABORT_ROOT" \
  '[{"id":"dup-id","identifier":"PROJ-1","title":"a"},{"id":"dup-id","identifier":"PROJ-1","title":"b"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "dup-id"

COMMENTS_BEFORE="$(cd "$ABORT_ROOT/.cache/linear/comments" && find . -type f | LC_ALL=C sort | xargs cat)"

rc=0
run_sync "$ABORT_ROOT" >/dev/null 2>"$TMP_BASE/abort-err" || rc=$?
err="$(cat "$TMP_BASE/abort-err")"

assert_ne "an aborted cache merge fails the sync" \
  $rc 0
assert "the cache_merge guard says it aborted the merge" \
  grep -q "aborting merge" <<<"$err"
# Two claims, asserted separately. Chained with `||` they were dead twice
# over: a helper always returns zero after recording a failure, so the right
# operand never ran, and its negation would have accepted an ABSENT
# "transient" anyway.
assert "sync names the aborted merge" \
  grep -q "Sync error: issues cache merge aborted" <<<"$err"
assert "sync names the likely transient cause" \
  grep -qi "transient" <<<"$err"
assert_not "sync reports no completion after an aborted merge" \
  grep -q "Done (" <<<"$err"
assert_eq "an aborted merge leaves issues.json untouched" \
  "$(jq 'length' "$ABORT_ROOT/.cache/linear/issues.json")" "3"
assert_eq "a failed sync leaves synced_at where it was" \
  "$(jq -r '.synced_at' "$ABORT_ROOT/.cache/linear/meta.json")" "$OLD_SYNC"
# The per-issue comment files are the live cache, not a staging area: a pull
# written before the merge could reject leaves them rewritten or swept while
# the command reports the cache unchanged.
COMMENTS_AFTER="$(cd "$ABORT_ROOT/.cache/linear/comments" && find . -type f | LC_ALL=C sort | xargs cat)"
assert_eq "an aborted merge leaves the comment cache it reported unchanged" \
  "$COMMENTS_AFTER" "$COMMENTS_BEFORE"

# --- control: healthy delta merges and sync succeeds -----------------------------
OK_ROOT="$TMP_BASE/ok"
NEW_NODE='{"id":"id-9","identifier":"PROJ-9","title":"brand new","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":0,"estimate":null,"sortOrder":2,"url":"u","createdAt":"2026-07-27T00:00:00Z","updatedAt":"2026-07-27T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'
make_env "$OK_ROOT" \
  '[{"id":"id-1","identifier":"PROJ-1","title":"a"},{"id":"id-2","identifier":"PROJ-2","title":"b"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "id-1" "$NEW_NODE"

rc=0
run_sync "$OK_ROOT" >/dev/null 2>"$TMP_BASE/ok-err" || rc=$?
assert_eq "a healthy incremental sync still succeeds" \
  $rc 0
assert "a healthy sync reports completion" \
  grep -q "Done (" "$TMP_BASE/ok-err"
assert_eq "the healthy merge keeps every entry and adds the created issue" \
  "$(jq 'length' "$OK_ROOT/.cache/linear/issues.json")" "4"
assert_eq "the healthy merge applied the delta update" \
  "$(jq -r '[.[] | select(.id == "id-1")] | first | .title' "$OK_ROOT/.cache/linear/issues.json")" "updated"
assert_ne "a successful sync advances synced_at" \
  "$(jq -r '.synced_at' "$OK_ROOT/.cache/linear/meta.json")" "$OLD_SYNC"
# PROJ-9 is created BY this delta, so it is absent from the issue set until the
# merge lands. Scope the write from a pre-merge issues.json and its comments are
# filtered out, and no later delta revisits an issue that never changes again —
# a permanently empty thread for exactly the newly created issue.
assert_eq "comments for an issue created by this delta are kept" \
  "$(jq -r '.[0].id' "$OK_ROOT/.cache/linear/comments/PROJ-9.json" 2>/dev/null)" "c9"
# PROJ-3 is outside this delta. The pull carries a comment for it, and only a
# write scoped past the delta would let that land.
assert_eq "the delta write stays inside its own scope" \
  "$(jq -r '.[0].id' "$OK_ROOT/.cache/linear/comments/PROJ-3.json" 2>/dev/null)" "c3"

# --- freshness: a fresh cache skips the sync entirely ---------------------------
fresh_rc=0
run_sync_if_stale "$OK_ROOT" >/dev/null 2>"$TMP_BASE/stale-fresh" || fresh_rc=$?
assert_eq "--if-stale on a fresh cache exits zero" "$fresh_rc" 0
assert "--if-stale skips a fresh cache" \
  grep -q "Cache fresh" "$TMP_BASE/stale-fresh"

# Must-fail control for the skip above: the same call on a cache older than the
# window has to run rather than report it fresh.
jq --arg s "$OLD_SYNC" '.synced_at = $s' "$OK_ROOT/.cache/linear/meta.json" > "$TMP_BASE/meta-stale"
mv "$TMP_BASE/meta-stale" "$OK_ROOT/.cache/linear/meta.json"
stale_rc=0
run_sync_if_stale "$OK_ROOT" >/dev/null 2>"$TMP_BASE/stale-old" || stale_rc=$?
assert_eq "--if-stale on a stale cache exits zero" "$stale_rc" 0
assert_not "--if-stale re-syncs a cache older than the window" \
  grep -q "Cache fresh" "$TMP_BASE/stale-old"

