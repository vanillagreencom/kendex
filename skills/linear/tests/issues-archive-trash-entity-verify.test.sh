#!/usr/bin/env bash
# Regression test (#930): `issues archive` / `issues trash` returned
# {"success": true, "identifier": null, "url": null} while the issue stayed
# active. The mutations requested only IssueArchivePayload.success — Linear's
# "request processed" flag — never the entity, and normalize_mutation_response
# read `.issue`, a field that does not exist on IssueArchivePayload. A
# server-side no-op was therefore indistinguishable from success, and the
# cache was purged before the response was even parsed.
#
# Contract under test:
#   - the mutation posts the RESOLVED UUID, not the human identifier
#   - success requires the returned entity to carry the marker (archivedAt
#     for archive, trashed=true for trash); envelope populates identifier/url
#   - the cache is updated only on confirmation
#   - success=true without a confirming entity is a nonzero-exit error that
#     names the reference and the resolved id
#
# Runs fully offline against a mocked curl; live-API confirmation pending.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Cache lives under the project root — make the tmp root a git repo
git -C "$TMP_ROOT" init -q

UUID="aaaaaaaa-bbbb-cccc-dddd-000000000042"
URL="https://linear.app/test/issue/PROJ-42"

seed_cache() {
  mkdir -p "$TMP_ROOT/.cache/linear/comments"
  cat > "$TMP_ROOT/.cache/linear/issues.json" <<JSON
[{"id":"$UUID","identifier":"PROJ-42","title":"t","state":{"name":"Backlog","type":"backlog"}},
 {"id":"aaaaaaaa-bbbb-cccc-dddd-000000000043","identifier":"PROJ-43","title":"other","state":{"name":"Backlog","type":"backlog"}}]
JSON
  echo '[{"id":"c1","body":"hi"}]' > "$TMP_ROOT/.cache/linear/comments/PROJ-42.json"
}

# Mocked curl: logs every payload, and serves the archive/delete mutation
# response shape selected via the mode file. "no_entity" is the exact live
# response observed in #930.
cat >"$TMP_ROOT/bin/curl" <<SH
#!/usr/bin/env bash
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
echo "\$payload" >> "$TMP_ROOT/posted.log"
query="\$(jq -r '.query' <<<"\$payload")"
mode="\$(cat "$TMP_ROOT/mode")"

entity='{"id":"$UUID","identifier":"PROJ-42","url":"$URL","archivedAt":"2026-07-27T00:00:00.000Z","trashed":null}'
trashed_entity='{"id":"$UUID","identifier":"PROJ-42","url":"$URL","archivedAt":"2026-07-27T00:00:00.000Z","trashed":true}'
unconfirmed_entity='{"id":"$UUID","identifier":"PROJ-42","url":"$URL","archivedAt":null,"trashed":null}'

case "\$query" in
*"issueArchive("*|*"issueDelete("*)
  op="issueArchive"
  case "\$query" in *"issueDelete("*) op="issueDelete" ;; esac
  case "\$mode" in
  entity_ok)
    printf '%s' "{\"data\":{\"\$op\":{\"success\":true,\"entity\":\$entity}}}___HTTP_CODE___200" ;;
  entity_trashed)
    printf '%s' "{\"data\":{\"\$op\":{\"success\":true,\"entity\":\$trashed_entity}}}___HTTP_CODE___200" ;;
  no_entity)
    printf '%s' "{\"data\":{\"\$op\":{\"success\":true}}}___HTTP_CODE___200" ;;
  entity_unconfirmed)
    printf '%s' "{\"data\":{\"\$op\":{\"success\":true,\"entity\":\$unconfirmed_entity}}}___HTTP_CODE___200" ;;
  esac ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"id":"$UUID"}}}___HTTP_CODE___200' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

run_linear() {
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token bash "$LINEAR" "$@")
}

# --- archive happy path: entity confirms, envelope populated, cache updated ------
seed_cache
: > "$TMP_ROOT/posted.log"
echo "entity_ok" > "$TMP_ROOT/mode"
out="$(run_linear issues archive PROJ-42)"
if ! jq -e --arg url "$URL" \
    '.success == true and .identifier == "PROJ-42" and .url == $url and .data.entity.archivedAt != null' \
    >/dev/null <<<"$out"; then
  echo "FAIL archive success envelope missing identifier/url/entity, got: $out"
  exit 1
fi
if ! jq -e --arg id "$UUID" '.query | contains("issueArchive")' >/dev/null 2>&1 < <(grep issueArchive "$TMP_ROOT/posted.log"); then
  echo "FAIL issueArchive mutation was never posted"
  exit 1
fi
posted_id="$(grep issueArchive "$TMP_ROOT/posted.log" | jq -r '.variables.id')"
if [[ "$posted_id" != "$UUID" ]]; then
  echo "FAIL mutation posted [$posted_id] instead of the resolved UUID"
  exit 1
fi
if jq -e '.[] | select(.identifier == "PROJ-42")' >/dev/null <<<"$(cat "$TMP_ROOT/.cache/linear/issues.json")"; then
  echo "FAIL confirmed archive did not remove PROJ-42 from cache"
  exit 1
fi
if ! jq -e '.[] | select(.identifier == "PROJ-43")' >/dev/null <<<"$(cat "$TMP_ROOT/.cache/linear/issues.json")"; then
  echo "FAIL archive removed an unrelated issue from cache"
  exit 1
fi
if [[ -f "$TMP_ROOT/.cache/linear/comments/PROJ-42.json" ]]; then
  echo "FAIL confirmed archive left the comment cache behind"
  exit 1
fi

# --- trash happy path: entity trashed=true confirms ------------------------------
seed_cache
: > "$TMP_ROOT/posted.log"
echo "entity_trashed" > "$TMP_ROOT/mode"
out="$(run_linear issues trash PROJ-42)"
if ! jq -e '.success == true and .identifier == "PROJ-42" and .data.entity.trashed == true' >/dev/null <<<"$out"; then
  echo "FAIL trash success envelope mismatch, got: $out"
  exit 1
fi
posted_id="$(grep issueDelete "$TMP_ROOT/posted.log" | jq -r '.variables.id')"
if [[ "$posted_id" != "$UUID" ]]; then
  echo "FAIL trash mutation posted [$posted_id] instead of the resolved UUID"
  exit 1
fi
if jq -e '.[] | select(.identifier == "PROJ-42")' >/dev/null <<<"$(cat "$TMP_ROOT/.cache/linear/issues.json")"; then
  echo "FAIL confirmed trash did not remove PROJ-42 from cache"
  exit 1
fi

# --- the #930 shape: success=true, no entity → hard failure, cache untouched -----
seed_cache
echo "no_entity" > "$TMP_ROOT/mode"
set +e
out="$(run_linear issues archive PROJ-42 2>"$TMP_ROOT/err")"
rc=$?
set -e
err="$(cat "$TMP_ROOT/err")"
if [[ $rc -eq 0 ]]; then
  echo "FAIL archive with success=true but no entity exited 0 (silent no-op), stdout: $out"
  exit 1
fi
if jq -e '.success == true' >/dev/null 2>&1 <<<"$out"; then
  echo "FAIL archive no-op still printed a success envelope: $out"
  exit 1
fi
if ! grep -q "archive not confirmed for PROJ-42" <<<"$err" || ! grep -q "$UUID" <<<"$err"; then
  echo "FAIL archive no-op error does not name the reference and resolved id: $err"
  exit 1
fi
if ! jq -e '.[] | select(.identifier == "PROJ-42")' >/dev/null <<<"$(cat "$TMP_ROOT/.cache/linear/issues.json")"; then
  echo "FAIL unconfirmed archive purged PROJ-42 from cache"
  exit 1
fi

# --- same shape on trash ----------------------------------------------------------
echo "no_entity" > "$TMP_ROOT/mode"
set +e
run_linear issues trash PROJ-42 >/dev/null 2>"$TMP_ROOT/err"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  echo "FAIL trash with success=true but no entity exited 0 (silent no-op)"
  exit 1
fi
if ! grep -q "trash not confirmed for PROJ-42" "$TMP_ROOT/err"; then
  echo "FAIL trash no-op error missing, got: $(cat "$TMP_ROOT/err")"
  exit 1
fi

# --- entity returned but marker absent (archivedAt null) → still a failure -------
echo "entity_unconfirmed" > "$TMP_ROOT/mode"
set +e
run_linear issues archive PROJ-42 >/dev/null 2>"$TMP_ROOT/err"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  echo "FAIL archive accepted an entity without archivedAt as success"
  exit 1
fi
if ! grep -q "archive not confirmed for PROJ-42" "$TMP_ROOT/err"; then
  echo "FAIL unconfirmed-entity error missing, got: $(cat "$TMP_ROOT/err")"
  exit 1
fi

echo "all pass"
