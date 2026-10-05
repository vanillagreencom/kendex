#!/usr/bin/env bash
# `issues archive` / `issues trash` returned
# {"success": true, "identifier": null, "url": null} while the issue stayed
# active. The mutations requested only IssueArchivePayload.success — Linear's
# "request processed" flag — never the entity, and normalize_mutation_response
# read `.issue`, a field that does not exist on IssueArchivePayload. A
# server-side no-op was therefore indistinguishable from success.
#
# Contract under test:
#   - the mutation posts the RESOLVED UUID, not the human identifier
#   - success requires the returned entity to carry the marker (archivedAt
#     for archive, trashed=true for trash); envelope populates identifier/url
#   - success=true without a confirming entity is a nonzero-exit error that
#     names the reference and the resolved id
#
# Runs fully offline against a mocked curl; live-API confirmation pending.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# The CLI resolves its project from git, so the fixture is a repository.
git -C "$TMP_ROOT" init -q

# Writes require a configured Linear team, as in any real project
printf '[env]\nLINEAR_TEAM = "PROJ"\n' >"$TMP_ROOT/kendex.settings.toml"

UUID="aaaaaaaa-bbbb-cccc-dddd-000000000042"
URL="https://linear.app/test/issue/PROJ-42"

# Mocked curl: logs every payload, and serves the archive/delete mutation
# response shape selected via the mode file. "no_entity" returns success
# without an entity.
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

# --- archive happy path: entity confirms, envelope populated ------
: > "$TMP_ROOT/posted.log"
echo "entity_ok" > "$TMP_ROOT/mode"
archive_rc=0
out="$(run_linear issues archive PROJ-42)" || archive_rc=$?
assert_eq "a confirmed archive exits zero" "$archive_rc" 0

assert "the archive envelope carries identifier, url and the confirming entity" \
  jq -e --arg url "$URL" \
  '.success == true and .identifier == "PROJ-42" and .url == $url and .data.entity.archivedAt != null' <<<"$out"
assert_file_contains "the issueArchive mutation was posted" "$TMP_ROOT/posted.log" "issueArchive"
assert_eq "the archive mutation posts the resolved UUID" \
  "$(grep issueArchive "$TMP_ROOT/posted.log" | jq -r '.variables.id')" "$UUID"

# --- trash happy path: entity trashed=true confirms ------------------------------
: > "$TMP_ROOT/posted.log"
echo "entity_trashed" > "$TMP_ROOT/mode"
trash_rc=0
out="$(run_linear issues trash PROJ-42)" || trash_rc=$?
assert_eq "a confirmed trash exits zero" "$trash_rc" 0

assert_jq "the trash envelope carries the confirming entity" \
  "$out" '.success == true and .identifier == "PROJ-42" and .data.entity.trashed == true'
assert_eq "the trash mutation posts the resolved UUID" \
  "$(grep issueDelete "$TMP_ROOT/posted.log" | jq -r '.variables.id')" "$UUID"

# --- success=true, no entity: hard failure ------------------
echo "no_entity" > "$TMP_ROOT/mode"
rc=0
out="$(run_linear issues archive PROJ-42 2>"$TMP_ROOT/err")" || rc=$?
err="$(cat "$TMP_ROOT/err")"

assert_ne "an archive reporting success with no entity fails" "$rc" 0
assert_not "an unconfirmed archive prints no success envelope" jq -e '.success == true' <<<"$out"
assert_contains "the unconfirmed-archive error names the reference" "$err" "archive not confirmed for PROJ-42"
assert_contains "the unconfirmed-archive error names the resolved id" "$err" "$UUID"

# --- same shape on trash ----------------------------------------------------------
echo "no_entity" > "$TMP_ROOT/mode"
rc=0
run_linear issues trash PROJ-42 >/dev/null 2>"$TMP_ROOT/err" || rc=$?

assert_ne "a trash reporting success with no entity fails" "$rc" 0
assert_file_contains "the unconfirmed-trash error names the reference" \
  "$TMP_ROOT/err" "trash not confirmed for PROJ-42"

# --- entity returned but marker absent (archivedAt null) → still a failure -------
echo "entity_unconfirmed" > "$TMP_ROOT/mode"
rc=0
run_linear issues archive PROJ-42 >/dev/null 2>"$TMP_ROOT/err" || rc=$?

assert_ne "an entity without archivedAt is not accepted as success" "$rc" 0
assert_file_contains "the unconfirmed-entity error names the reference" \
  "$TMP_ROOT/err" "archive not confirmed for PROJ-42"
