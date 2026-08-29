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

  # Comment files the abort must leave alone. meta.json carries no
  # comments_source, which is the legacy state and the wider blast radius: an
  # unmarked cache refetches every comment and scopes the write to the whole
  # issue set, so a write that ran before the merge would sweep these.
  printf '[{"id":"c1","body":"kept"}]' > "$root/.cache/linear/comments/PROJ-1.json"
  printf '[{"id":"c3","body":"kept too"}]' > "$root/.cache/linear/comments/PROJ-3.json"
  # Old synced_at forces an issues delta; fresh reconciled_at skips reconcile
  jq -n --arg synced "$OLD_SYNC" --arg rec "$(date -Iseconds)" \
    '{synced_at: $synced, reconciled_at: $rec, stats: {}}' > "$root/.cache/linear/meta.json"

  delta_node="{\"id\":\"$delta_id\",\"identifier\":\"PROJ-1\",\"title\":\"updated\",\"description\":\"\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"assignee\":null,\"project\":null,\"projectMilestone\":null,\"cycle\":null,\"parent\":null,\"team\":{\"name\":\"Claude\"},\"labels\":{\"nodes\":[]},\"priority\":0,\"estimate\":null,\"sortOrder\":1,\"url\":\"u\",\"createdAt\":\"2026-07-01T00:00:00Z\",\"updatedAt\":\"2026-07-27T00:00:00Z\",\"archivedAt\":null,\"trashed\":null,\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}}"

  local delta_nodes="$delta_node"
  [[ -n "$extra_node" ]] && delta_nodes="$delta_node,$extra_node"
  # "none" is the empty delta: nothing changed since synced_at. It is the
  # ordinary state of a machine that syncs regularly, and the upgrade case a
  # rebuild carried by the delta would never reach.
  [[ "$delta_id" == "none" ]] && delta_nodes=""

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

run_sync() {
  local root="$1"
  (cd "$root" && PATH="$root/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$root/.agents/skills/linear/scripts/linear.sh" sync --no-attachments)
}

run_sync_if_stale() {
  local root="$1"
  (cd "$root" && PATH="$root/bin:$PATH" LINEAR_API_KEY=test-token \
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
assert "sync names the aborted merge and its likely transient cause" \
  grep -q "Sync error: issues cache merge aborted" <<<"$err" || ! grep -qi "transient" <<<"$err"
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
# The marker is what stops the next incremental sync refetching every comment,
# and what stops --if-stale skipping the sync that would write it.
assert_eq "a successful sync records how the comment cache was built" \
  "$(jq -r '.comments_source // empty' "$OK_ROOT/.cache/linear/meta.json")" "paginated"
# PROJ-3 is not in the delta. A cache with no marker holds first-page-only
# threads for exactly the issues a delta never revisits, so an unmarked sync
# refetches every comment and scopes the write to the whole issue set. Scoped
# to the delta instead, PROJ-3 would keep its seeded file forever.
assert_eq "an unmarked cache refetches comments for an issue outside the delta" \
  "$(jq -r '.[0].id' "$OK_ROOT/.cache/linear/comments/PROJ-3.json")" "c3-new"
# PROJ-9 is created BY this delta, so it is absent from the issue set until the
# merge lands. Scope the write from a pre-merge issues.json and its comments are
# filtered out, the marker is stamped anyway, and no later delta revisits an
# issue that never changes again — the permanent empty thread this whole change
# exists to remove, reintroduced for exactly the newly created issue.
assert_eq "comments for an issue created by this delta are kept" \
  "$(jq -r '.[0].id' "$OK_ROOT/.cache/linear/comments/PROJ-9.json" 2>/dev/null)" "c9"

# --- freshness must not skip the sync that would mark the cache ------------------
# OK_ROOT is now both fresh and marked, so a read-only caller skips. Strip the
# marker and the same call has to run: a cache whose comments are legacy is not
# usable however recently it was synced, and skipping here is how a machine
# keeps first-page threads indefinitely.
run_sync_if_stale "$OK_ROOT" >/dev/null 2>"$TMP_BASE/stale-marked" || true
assert "--if-stale skips a fresh, marked cache" \
  grep -q "Cache fresh" "$TMP_BASE/stale-marked"

jq 'del(.comments_source)' "$OK_ROOT/.cache/linear/meta.json" > "$TMP_BASE/meta-unmarked"
mv "$TMP_BASE/meta-unmarked" "$OK_ROOT/.cache/linear/meta.json"
run_sync_if_stale "$OK_ROOT" >/dev/null 2>"$TMP_BASE/stale-unmarked" || true
assert_not "--if-stale re-syncs an unmarked cache rather than leaving legacy comments" \
  grep -q "Cache fresh" "$TMP_BASE/stale-unmarked"
assert_eq "the forced sync marks the cache" \
  "$(jq -r '.comments_source // empty' "$OK_ROOT/.cache/linear/meta.json")" "paginated"

# --- upgrade case: an unmarked cache with an EMPTY delta -------------------------
# The legacy threads belong to issues that have not changed, so the delta that
# would carry a rebuild is empty precisely when the rebuild is needed. The
# rebuild is a precondition of syncing, not part of the delta, so it runs here.
EMPTY_ROOT="$TMP_BASE/empty"
make_env "$EMPTY_ROOT" \
  '[{"id":"id-1","identifier":"PROJ-1","title":"a"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "none"

rc=0
run_sync "$EMPTY_ROOT" >/dev/null 2>"$TMP_BASE/empty-err" || rc=$?
assert_eq "sync succeeds on an unmarked cache with an empty delta" \
  $rc 0
assert_eq "an empty delta still rebuilds the legacy comment cache" \
  "$(jq -r '.[0].id' "$EMPTY_ROOT/.cache/linear/comments/PROJ-3.json" 2>/dev/null)" "c3-new"
assert_not "the rebuild owns the whole issue set, so PROJ-1 keeps no file the pull did not carry" \
  test -f "$EMPTY_ROOT/.cache/linear/comments/PROJ-1.json"
assert_eq "the rebuild marks the cache" \
  "$(jq -r '.comments_source // empty' "$EMPTY_ROOT/.cache/linear/meta.json")" "paginated"

# --- steady state: a MARKED cache takes the delta path only ---------------------
# Every case above starts unmarked, where the rebuild owns the whole issue set
# and would mask a wrong delta scope. This is the path every sync after the
# upgrade takes: no rebuild, and the write scoped to the delta alone.
MARKED_ROOT="$TMP_BASE/marked"
make_env "$MARKED_ROOT" \
  '[{"id":"id-1","identifier":"PROJ-1","title":"a"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "id-1"
jq '. + {comments_source: "paginated"}' "$MARKED_ROOT/.cache/linear/meta.json" > "$TMP_BASE/marked-meta"
mv "$TMP_BASE/marked-meta" "$MARKED_ROOT/.cache/linear/meta.json"

rc=0
run_sync "$MARKED_ROOT" >/dev/null 2>"$TMP_BASE/marked-err" || rc=$?
assert_eq "sync succeeds on a marked cache" \
  $rc 0
assert_not "a marked cache is not rebuilt" \
  grep -q "comment cache rebuilt" "$TMP_BASE/marked-err"
# PROJ-3 is outside this delta. The pull carries a comment for it, and only a
# write scoped past the delta would let that land.
assert_eq "the delta write stays inside its own scope" \
  "$(jq -r '.[0].id' "$MARKED_ROOT/.cache/linear/comments/PROJ-3.json" 2>/dev/null)" "c3"

