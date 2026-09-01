#!/usr/bin/env bash
# The creation bar is only real where the producers feed it. This suite pins
# the three things that make it so, and every one of them is DERIVED from the
# tree rather than listed here — a rule written as a list of its instances
# breaks at instance N+1, which is what put this file in the tree.
#
#   1. Every documented `issues create` invocation passes a body and names
#      where that body comes from, so no site can file a body with no reach.
#   2. Every workflow that writes an audit-input file states a `source`, and
#      every stated source is one the schema declares — without it the
#      analysis cannot decide review_born and the symptom half fails open.
#   3. The review-born create audit-issues.md documents is run verbatim
#      against a mocked API: priority 2 with a reach and no Symptom: is
#      refused before any API call, the same command with the flag stripped
#      creates, and one carrying a Symptom: creates.
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

SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
INPUT_SCHEMA="$SKILL_DIR/schemas/audit-issues-input.md"
TPM_AUDIT="$SKILL_DIR/workflows/tpm-audit.md"
[[ -f "$INPUT_SCHEMA" ]] || fail "input schema not found: $INPUT_SCHEMA"
[[ -f "$TPM_AUDIT" ]] || fail "producer workflow not found: $TPM_AUDIT"

# --- 1. every create site names where its body comes from --------------------
# The site list is derived: the files a harness loads to ACT — workflows and
# patterns — not a list kept here. A create is command-shaped when linear.sh
# runs it, which is what separates the eight real sites from the prose that
# merely names the action. A `\`-continued command carries its flags on the
# lines below, so the invocation is the line plus its continuations.
site_files=()
while IFS= read -r f; do site_files+=("$f"); done < <(
	find "$SKILLS_ROOT" -type f -path '*/workflows/*.md' -o -type f -path '*/patterns/*.md' |
		sort
)
[[ ${#site_files[@]} -gt 0 ]] || fail "no workflow or pattern files under $SKILLS_ROOT"

sites_seen=0
for f in "${site_files[@]}"; do
	invocations="$(awk '
		/linear\.sh issues create( |$|\\)/ { collecting = 1; buf = $0; next }
		collecting { buf = buf " " $0 }
		collecting && $0 !~ /\\$/ { print buf; collecting = 0 }
		END { if (collecting) print buf }
	' "$f")"
	[[ -n "$invocations" ]] || continue
	sites_seen=$((sites_seen + 1))
	while IFS= read -r invocation; do
		[[ -n "$invocation" ]] || continue
		grep -qE -- '--description(-file)?' <<<"$invocation" ||
			fail "${f#"$SKILLS_ROOT/"} runs issues create with no body, so it can carry no reach: $invocation"
	done <<<"$invocations"
	grep -qE 'issue-description-template|parent-issue-template|Reached by' "$f" ||
		fail "${f#"$SKILLS_ROOT/"} runs issues create but names no body source — cite the issue template or state the Reached by: line"
done
[[ "$sites_seen" -ge 5 ]] ||
	fail "only $sites_seen create site(s) found; the derivation stopped matching the tree"

# --- 2. every audit-input writer states a source the schema declares ---------
enum_line="$(grep -m1 -E '"source": "[a-z|-]+"' "$INPUT_SCHEMA")" ||
	fail "the input schema declares no source enum"
enum_values="$(sed -E 's/.*"source": "([a-z|-]+)".*/\1/' <<<"$enum_line" | tr '|' ' ')"
[[ -n "$enum_values" ]] || fail "could not read the source enum from $INPUT_SCHEMA"

in_enum() {
	local want="$1" value
	for value in $enum_values; do [[ "$value" == "$want" ]] && return 0; done
	return 1
}

writers_seen=0
while IFS= read -r hit; do
	file="${hit%%:*}"
	rest="${hit#*:}"
	line="${rest#*:}"
	grep -qE 'tmp/audit-[a-z-]*-?YYYYMMDD' <<<"$line" || continue
	writers_seen=$((writers_seen + 1))
	stated="$(sed -nE 's/.*`?source: "([a-z-]+)"`?.*/\1/p' <<<"$line" | head -1)"
	[[ -n "$stated" ]] ||
		fail "${file#"$SKILLS_ROOT/"} writes an audit-input file but states no source, so review_born cannot be derived for it"
	in_enum "$stated" ||
		fail "${file#"$SKILLS_ROOT/"} states source \"$stated\", which the schema's enum does not declare ($enum_values)"
done < <(grep -rn 'audit-issues-input.md' "$SKILLS_ROOT"/*/workflows/*.md || true)
[[ "$writers_seen" -ge 3 ]] ||
	fail "only $writers_seen audit-input writer(s) found; the derivation stopped matching the tree"

# Every source the producer calls review-born must be one that can occur.
review_born_line="$(grep -m1 -F '`review_born` is true when' "$TPM_AUDIT")" ||
	fail "tpm-audit.md states no review_born derivation"
review_born_clause="${review_born_line#*is true when}"
review_born_clause="${review_born_clause%%false otherwise*}"
review_born_sources="$(grep -oE '`[a-z-]+`' <<<"$review_born_clause" | tr -d '`' |
	grep -vx 'SOURCE' || true)"
[[ -n "$review_born_sources" ]] || fail "the review_born derivation names no source"
for value in $review_born_sources; do
	in_enum "$value" ||
		fail "tpm-audit.md derives review_born from source \"$value\", which the schema's enum does not declare ($enum_values)"
done

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

echo "ok: $sites_seen create site(s) name a body source, $writers_seen audit-input writer(s) state a declared source, and the documented review-born create enforces the symptom half of the bar"
