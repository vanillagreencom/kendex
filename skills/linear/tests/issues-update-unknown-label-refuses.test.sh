#!/usr/bin/env bash
# `issues update --labels` replaces the whole label set, so a requested name
# that resolves to nothing must refuse the update: silently dropping it ships
# a partial set — the same wipe class as a lookup failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

run_update() {
  ( cd "$PROJECT" \
    && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=stub LINEAR_TEAM=TestTeam \
       "$LINEAR" issues update ISS-1 --labels "$1" ) >"$TMP_ROOT/out.txt" 2>"$ERR_FILE"
}

# Unknown label → refuse before any mutation.
: >"$CURL_LOG"
if run_update "real-label,ghost-label"; then
  bad "unknown label refuses the update (exited 0)"
else
  ok "unknown label refuses the update"
fi
if grep -q "ghost-label" "$ERR_FILE" && grep -qi "partial set" "$ERR_FILE"; then
  ok "refusal names the unknown label and the partial-set hazard"
else
  bad "refusal names the unknown label and the partial-set hazard ($(cat "$ERR_FILE"))"
fi
if grep -q "issueUpdate" "$CURL_LOG"; then
  bad "no mutation was sent for the refused update"
else
  ok "no mutation was sent for the refused update"
fi

# Unknown label + --attach → refuse BEFORE the upload, so no asset is
# stranded in Linear storage (labels resolve ahead of upload_attach_paths).
: >"$CURL_LOG"
printf 'x' >"$TMP_ROOT/asset.bin"
if ( cd "$PROJECT" \
    && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=stub LINEAR_TEAM=TestTeam \
       "$LINEAR" issues update ISS-1 --labels "ghost-label" --attach "$TMP_ROOT/asset.bin" ) \
       >"$TMP_ROOT/out.txt" 2>"$ERR_FILE"; then
  bad "unknown label with --attach refuses the update (exited 0)"
else
  ok "unknown label with --attach refuses the update"
fi
if grep -qiE "fileUpload|attachment" "$CURL_LOG"; then
  bad "no upload was sent before the refusal"
else
  ok "no upload was sent before the refusal"
fi

# Control: all labels resolve → the update proceeds and mutates.
: >"$CURL_LOG"
if run_update "real-label"; then
  ok "fully-resolved label set still updates"
else
  bad "fully-resolved label set still updates ($(cat "$ERR_FILE"))"
fi
grep -q "issueUpdate" "$CURL_LOG" && ok "mutation sent for the valid update" || bad "mutation sent for the valid update"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
