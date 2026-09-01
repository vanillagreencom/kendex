#!/usr/bin/env bash
# The review-born half of the creation bar is only real if the producer that
# files a review finding actually passes --review-born. The flag is opt-in, so
# a direct CLI test proves the check and nothing about the pipeline.
#
# This suite runs the create command audit-issues.md documents for a
# review-born candidate, verbatim from the file, against a mocked API: a
# priority-2 body with a reach and no Symptom: must be refused before any API
# call. The same command with the flag stripped must create — so if the
# workflow ever loses --review-born, the refusal case goes green-to-red here
# rather than silently filing symptomless issues.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINEAR_SKILL="$SKILL_DIR/../linear"
AUDIT_ISSUES="$SKILL_DIR/workflows/audit-issues.md"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[[ -f "$AUDIT_ISSUES" ]] || fail "workflow not found: $AUDIT_ISSUES"
[[ -d "$LINEAR_SKILL" ]] || fail "linear skill not found: $LINEAR_SKILL"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# --- the command under test comes from the workflow, never from this file ---
# The region is the review-born sentence through the fence that closes the
# block below it; the create line is the one linear.sh call inside it.
region="$TMP_ROOT/region.md"
sed -En '/create_fields.review_born` is true/,/^```$/p' -- "$AUDIT_ISSUES" >"$region"
[[ -s "$region" ]] || fail "audit-issues.md documents no review-born create block"

documented_cmd="$(grep -F 'linear.sh issues create' "$region" || true)"
[[ -n "$documented_cmd" ]] || fail "the review-born block in audit-issues.md contains no issues create command"
[[ "$(printf '%s\n' "$documented_cmd" | wc -l)" -eq 1 ]] ||
	fail "the review-born block in audit-issues.md contains more than one create command"
grep -Fq -- '--review-born' <<<"$documented_cmd" ||
	fail "the documented review-born create does not pass --review-born, so the symptom half of the creation bar reaches no producer"

# --- a project the documented path can run in --------------------------------
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$LINEAR_SKILL" "$PROJECT/.agents/skills/linear"
printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_REQUIRE_REACH = "1"\n' \
	>"$PROJECT/kendex.settings.toml"

CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*workflowStates*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-uuid"}]}}}___HTTP_CODE___200'
  ;;
*projects*)
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"project-uuid","name":"Phase 2"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Backlog","type":"backlog"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":2,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

# A body the analyzed-mode pipeline would write: the reach round 2 wired in,
# and no Symptom — the shape the bar exists to refuse at priority 2.
NO_SYMPTOM="$TMP_ROOT/no-symptom.md"
WITH_SYMPTOM="$TMP_ROOT/with-symptom.md"
{
	printf '**Reached by**: `kendex apply` on a project with a held package\n\n'
	printf 'The hold is dropped.\n'
} >"$NO_SYMPTOM"
{
	cat "$NO_SYMPTOM"
	printf '\n**Symptom**: the apply run reported "updated" and cleared the hold\n'
} >"$WITH_SYMPTOM"

RC=0
ERR=""

# run_documented <body-file> [strip-review-born]
run_documented() {
	local body="$1" strip="${2:-}" cmd="$documented_cmd"
	cmd="${cmd//\[TITLE\]/Held package is released}"
	cmd="${cmd//\[BODY_FILE\]/$body}"
	cmd="${cmd//\[PROJECT\]/Phase 2}"
	cmd="${cmd//\[VALIDATED_FINAL_LABELS\]/agent:generalist}"
	cmd="${cmd//\[PRIORITY\]/2}"
	[[ -n "$strip" ]] && cmd="${cmd//--review-born/}"
	: >"$CURL_LOG"
	RC=0
	(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH \
		PATH="$PROJECT/bin:$PATH" \
		LINEAR_API_KEY=test-token \
		CURL_LOG="$CURL_LOG" \
		bash -c "$cmd") >"$TMP_ROOT/out.txt" 2>"$TMP_ROOT/err.txt" || RC=$?
	ERR="$(cat "$TMP_ROOT/err.txt")"
}

api_calls() { wc -l <"$CURL_LOG" | tr -d ' '; }

run_documented "$NO_SYMPTOM"
[[ "$RC" -ne 0 ]] ||
	fail "the documented review-born create filed a priority-2 issue with no Symptom line"
grep -Fq 'Symptom' <<<"$ERR" ||
	fail "the refusal does not name the missing Symptom line: $ERR"
[[ "$(api_calls)" -eq 0 ]] ||
	fail "the refusal reached the API ($(api_calls) call(s))"

# The flag, not the body, is what refuses: strip it and the same body creates.
# A workflow that drops --review-born therefore turns the case above green.
run_documented "$NO_SYMPTOM" strip
[[ "$RC" -eq 0 ]] ||
	fail "the same create without --review-born was refused: $ERR"
jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG" >/dev/null ||
	fail "the create without --review-born never reached issueCreate"

run_documented "$WITH_SYMPTOM"
[[ "$RC" -eq 0 ]] ||
	fail "a review-born priority-2 create carrying a Symptom line was refused: $ERR"
jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG" >/dev/null ||
	fail "the review-born create with a Symptom never reached issueCreate"

echo "ok: the documented review-born create enforces the symptom half of the bar"
