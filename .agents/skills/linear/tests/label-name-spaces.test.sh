#!/usr/bin/env bash
# Names and descriptions containing spaces must reach the GraphQL payload intact.
#
# The JSON-escaping helpers wrote `printf '%s' \"$var\"`: the backslash-escaped
# quotes are literal characters, not shell quoting, so $var went through word
# splitting and printf reused its format across the resulting words. `my label`
# arrived as `"mylabel"` — the space dropped and two stray quote characters
# baked into the stored name. This pins the whole family: labels, project
# labels, and milestones, on both create and update.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >>"${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"projects(filter:"*)
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"project-uuid"}]}}}___HTTP_CODE___200'
  ;;
*issueLabelCreate*)
  printf '%s' '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"label-uuid","name":"my label","color":null,"isGroup":false,"parent":null}}}}___HTTP_CODE___200'
  ;;
*issueLabelUpdate*)
  printf '%s' '{"data":{"issueLabelUpdate":{"success":true,"issueLabel":{"id":"label-uuid","name":"my label","color":null,"isGroup":false,"parent":null}}}}___HTTP_CODE___200'
  ;;
*projectLabelCreate*)
  printf '%s' '{"data":{"projectLabelCreate":{"success":true,"projectLabel":{"id":"plabel-uuid","name":"my label","color":null,"isGroup":false,"parent":null}}}}___HTTP_CODE___200'
  ;;
*projectLabelUpdate*)
  printf '%s' '{"data":{"projectLabelUpdate":{"success":true,"projectLabel":{"id":"plabel-uuid","name":"my label","color":null,"isGroup":false,"parent":null}}}}___HTTP_CODE___200'
  ;;
*projectMilestoneCreate*)
  printf '%s' '{"data":{"projectMilestoneCreate":{"success":true,"projectMilestone":{"id":"ms-uuid","name":"my milestone","description":"a long description","targetDate":null,"sortOrder":1.0}}}}___HTTP_CODE___200'
  ;;
*projectMilestoneUpdate*)
  printf '%s' '{"data":{"projectMilestoneUpdate":{"success":true,"projectMilestone":{"id":"ms-uuid","name":"my milestone","targetDate":null}}}}___HTTP_CODE___200'
  ;;
*projectUpdateCreate*)
  printf '%s' '{"data":{"projectUpdateCreate":{"success":true,"projectUpdate":{"id":"pu-uuid","health":"onTrack","body":"a long body","createdAt":"2026-08-12T00:00:00Z","project":{"id":"project-uuid","name":"X"}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" >&2; }

# Runs linear.sh with the stub curl, logging every payload to $1.
run_linear() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  (
    cd "$TMP_ROOT" &&
      PATH="$TMP_ROOT/bin:$PATH" \
        LINEAR_API_KEY_OVERRIDE=test-token \
        LINEAR_TEAM=Claude \
        CURL_PAYLOAD_LOG="$payload_log" \
        bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "$@"
  ) >/dev/null 2>&1 || true
}

# Asserts the logged payload for $mutation carries $field == $expected verbatim.
assert_field() {
  local label="$1" payload_log="$2" mutation="$3" field="$4" expected="$5"
  local got
  got="$(jq -s -r --arg m "$mutation" --arg f "$field" \
    'map(select(.query | contains($m))) | last | .variables.input[$f] // "<absent>"' \
    "$payload_log" 2>/dev/null || echo '<unparseable>')"
  if [[ "$got" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "expected [$expected], payload carried [$got]"
  fi
}

log="$TMP_ROOT/payloads.jsonl"

run_linear "$log" labels create --name 'my label' --description 'a long description' --team Claude
assert_field "labels create: spaced name reaches the payload intact" \
  "$log" issueLabelCreate name 'my label'
assert_field "labels create: spaced description reaches the payload intact" \
  "$log" issueLabelCreate description 'a long description'

run_linear "$log" labels update label-uuid --name 'my label' --description 'a long description'
assert_field "labels update: spaced name reaches the payload intact" \
  "$log" issueLabelUpdate name 'my label'
assert_field "labels update: spaced description reaches the payload intact" \
  "$log" issueLabelUpdate description 'a long description'

run_linear "$log" project-labels create --name 'my label' --description 'a long description'
assert_field "project-labels create: spaced name reaches the payload intact" \
  "$log" projectLabelCreate name 'my label'
assert_field "project-labels create: spaced description reaches the payload intact" \
  "$log" projectLabelCreate description 'a long description'

run_linear "$log" project-labels update plabel-uuid --name 'my label' --description 'a long description'
assert_field "project-labels update: spaced name reaches the payload intact" \
  "$log" projectLabelUpdate name 'my label'
assert_field "project-labels update: spaced description reaches the payload intact" \
  "$log" projectLabelUpdate description 'a long description'

run_linear "$log" milestones create --project X --name 'my milestone' --description 'a long description'
assert_field "milestones create: spaced name reaches the payload intact" \
  "$log" projectMilestoneCreate name 'my milestone'
assert_field "milestones create: spaced description reaches the payload intact" \
  "$log" projectMilestoneCreate description 'a long description'

run_linear "$log" milestones update ms-uuid --name 'my milestone' --description 'a long description'
assert_field "milestones update: spaced name reaches the payload intact" \
  "$log" projectMilestoneUpdate name 'my milestone'
assert_field "milestones update: spaced description reaches the payload intact" \
  "$log" projectMilestoneUpdate description 'a long description'

run_linear "$log" projects post-update project-uuid --health on-track --body 'a long body'
assert_field "projects post-update: spaced body reaches the payload intact" \
  "$log" projectUpdateCreate body 'a long body'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
