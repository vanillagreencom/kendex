#!/usr/bin/env bash
# `issues update --labels` replaces the whole label set, so a requested name
# that resolves to nothing must refuse the update: silently dropping it ships
# a partial set — the same wipe class as a lookup failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid","name":"TestTeam"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  if [ "$name" = "ghost-label" ]; then
    printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"lbl-1","name":"real-label"}]}}}___HTTP_CODE___200'
  fi
  ;;
*"issue(id:"*|*"issues(filter:"*)
  printf '%s' '{"data":{"issue":{"id":"iss-uuid","identifier":"ISS-1","team":{"id":"team-uuid"}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"iss-uuid","identifier":"ISS-1"}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

run_update() {
  ( cd "$PROJECT" \
    && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=stub LINEAR_TEAM=TestTeam \
       "$LINEAR" issues update ISS-1 --labels "$1" ) >"$TMP_ROOT/out.txt" 2>"$ERR_FILE"
}

# Unknown label → refuse before any mutation.
: >"$CURL_LOG"
run_status refuse_rc run_update "real-label,ghost-label"

assert_ne "unknown label refuses the update" "$refuse_rc" 0
assert_file_contains "the refusal names the unknown label" "$ERR_FILE" "ghost-label"
assert_file_contains "the refusal names the partial-set hazard" "$ERR_FILE" "partial set"
assert_file_lacks "no mutation was sent for the refused update" "$CURL_LOG" "issueUpdate"

# Unknown label + --attach → refuse BEFORE the upload, so no asset is
# stranded in Linear storage (labels resolve ahead of upload_attach_paths).
: >"$CURL_LOG"
printf 'x' >"$TMP_ROOT/asset.bin"
attach_rc=0
( cd "$PROJECT" \
  && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=stub LINEAR_TEAM=TestTeam \
     "$LINEAR" issues update ISS-1 --labels "ghost-label" --attach "$TMP_ROOT/asset.bin" ) \
     >"$TMP_ROOT/out.txt" 2>"$ERR_FILE" || attach_rc=$?

assert_ne "unknown label with --attach refuses the update" "$attach_rc" 0
assert_not "no upload was sent before the refusal" grep -qiE "fileUpload|attachment" "$CURL_LOG"

# Control: all labels resolve → the update proceeds and mutates.
: >"$CURL_LOG"
run_status valid_rc run_update "real-label"

assert_eq "a fully-resolved label set still updates" "$valid_rc" 0
assert_file_contains "the valid update sends its mutation" "$CURL_LOG" "issueUpdate"
