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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

OLD_SYNC="2026-01-01T00:00:00+00:00"

# make_env <root> <existing-issues-json> <delta-node-id>
# Builds an isolated project root with a seeded cache and a curl stub whose
# SyncIssues delta updates the given issue id.
make_env() {
  local root="$1" existing="$2" delta_id="$3"
  mkdir -p "$root/.agents/skills" "$root/bin" "$root/.cache/linear/comments"
  cp -R "$SKILL_DIR" "$root/.agents/skills/linear"
  git -C "$root" init -q

  printf '%s' "$existing" > "$root/.cache/linear/issues.json"
  echo '[]' > "$root/.cache/linear/projects.json"
  # Old synced_at forces an issues delta; fresh reconciled_at skips reconcile
  jq -n --arg synced "$OLD_SYNC" --arg rec "$(date -Iseconds)" \
    '{synced_at: $synced, reconciled_at: $rec, stats: {}}' > "$root/.cache/linear/meta.json"

  delta_node="{\"id\":\"$delta_id\",\"identifier\":\"PROJ-1\",\"title\":\"updated\",\"description\":\"\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"assignee\":null,\"project\":null,\"projectMilestone\":null,\"cycle\":null,\"parent\":null,\"team\":{\"name\":\"Claude\"},\"labels\":{\"nodes\":[]},\"priority\":0,\"estimate\":null,\"sortOrder\":1,\"url\":\"u\",\"createdAt\":\"2026-07-01T00:00:00Z\",\"updatedAt\":\"2026-07-27T00:00:00Z\",\"archivedAt\":null,\"trashed\":null,\"comments\":{\"nodes\":[]},\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}}"

  cat >"$root/bin/curl" <<SH
#!/usr/bin/env bash
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
query="\$(jq -r '.query' <<<"\$payload")"
case "\$query" in
*"SyncIssues("*)
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[$delta_node]}}}___HTTP_CODE___200' ;;
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
  chmod +x "$root/bin/curl"
}

run_sync() {
  local root="$1"
  (cd "$root" && PATH="$root/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$root/.agents/skills/linear/scripts/linear.sh" sync --no-attachments)
}

# --- abort case: merge result would shrink below the existing cache --------------
# Two cached entries share an id, so the delta merge dedupes 3 -> 2 and trips
# the cache_merge guard — the same guard a transient empty/partial query
# result lands on.
ABORT_ROOT="$TMP_BASE/abort"
make_env "$ABORT_ROOT" \
  '[{"id":"dup-id","identifier":"PROJ-1","title":"a"},{"id":"dup-id","identifier":"PROJ-1","title":"b"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "dup-id"

set +e
run_sync "$ABORT_ROOT" >/dev/null 2>"$TMP_BASE/abort-err"
rc=$?
set -e
err="$(cat "$TMP_BASE/abort-err")"

if [[ $rc -eq 0 ]]; then
  echo "FAIL sync exited 0 despite an aborted cache merge: $err"
  exit 1
fi
if ! grep -q "aborting merge" <<<"$err"; then
  echo "FAIL cache_merge guard message missing: $err"
  exit 1
fi
if ! grep -q "Sync error: issues cache merge aborted" <<<"$err" || ! grep -qi "transient" <<<"$err"; then
  echo "FAIL sync did not name the aborted merge and likely transient query failure: $err"
  exit 1
fi
if grep -q "Done (" <<<"$err"; then
  echo "FAIL sync still reported completion after an aborted merge: $err"
  exit 1
fi
if [[ "$(jq 'length' "$ABORT_ROOT/.cache/linear/issues.json")" != "3" ]]; then
  echo "FAIL aborted merge modified issues.json"
  exit 1
fi
if [[ "$(jq -r '.synced_at' "$ABORT_ROOT/.cache/linear/meta.json")" != "$OLD_SYNC" ]]; then
  echo "FAIL failed sync still advanced synced_at"
  exit 1
fi

# --- control: healthy delta merges and sync succeeds -----------------------------
OK_ROOT="$TMP_BASE/ok"
make_env "$OK_ROOT" \
  '[{"id":"id-1","identifier":"PROJ-1","title":"a"},{"id":"id-2","identifier":"PROJ-2","title":"b"},{"id":"id-3","identifier":"PROJ-3","title":"c"}]' \
  "id-1"

set +e
run_sync "$OK_ROOT" >/dev/null 2>"$TMP_BASE/ok-err"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "FAIL healthy incremental sync no longer succeeds: $(cat "$TMP_BASE/ok-err")"
  exit 1
fi
if ! grep -q "Done (" "$TMP_BASE/ok-err"; then
  echo "FAIL healthy sync did not report completion: $(cat "$TMP_BASE/ok-err")"
  exit 1
fi
if [[ "$(jq 'length' "$OK_ROOT/.cache/linear/issues.json")" != "3" ]]; then
  echo "FAIL healthy merge lost cache entries"
  exit 1
fi
if [[ "$(jq -r '[.[] | select(.id == "id-1")] | first | .title' "$OK_ROOT/.cache/linear/issues.json")" != "updated" ]]; then
  echo "FAIL healthy merge did not apply the delta update"
  exit 1
fi
if [[ "$(jq -r '.synced_at' "$OK_ROOT/.cache/linear/meta.json")" == "$OLD_SYNC" ]]; then
  echo "FAIL successful sync did not advance synced_at"
  exit 1
fi

echo "all pass"
