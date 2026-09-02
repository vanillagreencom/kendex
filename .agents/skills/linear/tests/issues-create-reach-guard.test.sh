#!/usr/bin/env bash
# Regression test for the create-time reach guard. Filing is the cheap
# disposition — `Declined:` needs a disproof a gate checks, `Tracked: <ID>` needs
# only an issue to exist — so creation is the one chokepoint that can hold the
# filing bar. With LINEAR_REQUIRE_REACH set in kendex.settings.toml [env],
# `issues create` refuses, before any API call, a description with no `Reached
# by:` line and a review-born `--priority 2` body with no `Symptom:`.

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
payload="$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
case "$(jq -r '.query' <<<"$payload")" in
*"teams(filter:"*) printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200' ;;
*"issueLabels(filter:"*) printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200' ;;
*"issueCreate(input:"*) printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200' ;;
*) printf '%s' '{"data":{}}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

# The parent environment wins over project files, so every key the guard reads
# is unset for the run and the settings file below is the only source.
run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH \
    PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

api_calls() { wc -l <"$CURL_LOG" | tr -d ' '; }
assert_created() {
  assert_eq "$1 exits zero" "$RC" 0
  assert "$1 reaches issueCreate" jq -s -e 'any(.[];.query|contains("issueCreate"))' "$CURL_LOG"
}
assert_refused_before_api() {
  assert_ne "$1 is refused" "$RC" 0
  assert_eq "$1 refuses before any API call" "$(api_calls)" "0"
}
guard() { printf '[env]\nLINEAR_TEAM = "Configured"\n%b' "$1" >"$PROJECT/kendex.settings.toml"; }

REACH_LINE='**Reached by**: running `kendex refresh` in a linked worktree'
SYMPTOM_LINE='**Symptom**: the refresh printed "skipped" and left the render stale'

echo "=== guard on: a body naming nothing it reaches is refused, one naming it creates ==="
guard 'LINEAR_REQUIRE_REACH = "1"\n'
run_linear issues create --title "Filed from a thread"
assert_refused_before_api "a create with no description"
assert_contains "the refusal names the missing line" "$ERR" "Reached by"
# The one sentence that routes the author somewhere instead of naming a gap.
assert_contains "the refusal says an unnamed item is a decline" "$ERR" "decline"

# A value that says "nothing here" is no value, and each half has its own
# alternative: `[REACH]` is the placeholder this repo's templates ship (bold
# leaves its `**` on it); TBD is the other, and so is the symptom read below.
run_linear issues create --title "Template copied" \
  --description "$(printf '**Reached by: [REACH]**\n')"
assert_refused_before_api "a whole-line bold [REACH] placeholder body"

run_linear issues create --title "Null token" \
  --description "$(printf 'Reached by: TBD\n')"
assert_refused_before_api "a TBD reach"

run_linear issues create --title "Refresh skips a worktree" \
  --description "$(printf '%s\n\nThe render is left stale.\n' "$REACH_LINE")"
assert_created "a create whose body names the run that reaches it"

printf -- '- Reached by: `tools/guard` on a fresh clone\n' >"$TMP_ROOT/body.md"
run_linear issues create --title "Guard body" --description-file "$TMP_ROOT/body.md"
assert_created "a create whose reach is a list item arriving by --description-file"

echo "=== guard on: a review-born priority 2 needs a reported symptom ==="
run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_refused_before_api "a review-born priority-2 create with no Symptom line"
assert_contains "the refusal names the missing line" "$ERR" "Symptom"
assert_contains "the refusal routes the item to priority 3" "$ERR" "priority 3"

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\nSymptom: none\n' "$REACH_LINE")"
assert_refused_before_api "a review-born priority-2 create whose Symptom is a null token"

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\n%s\n' "$REACH_LINE" "$SYMPTOM_LINE")"
assert_created "a review-born priority-2 create carrying a reported symptom"

# Priority 2 minted structurally reports none by construction; refusing it would abort a merge on an orphan child.
run_linear issues create --title "Structural priority" --priority 2 \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_created "a structural priority-2 create with no Symptom line"

echo "=== no declaration: creates are unaffected, and help never trips ==="
guard ''
run_linear issues create --title "Unguarded repo"
assert_created "a bare create with no LINEAR_REQUIRE_REACH key"

guard 'LINEAR_REQUIRE_REACH = "1"\n'
run_linear issues create --help
assert_eq "issues create --help exits zero" "$RC" 0
assert_contains "issues create --help documents the reach guard" "$OUT" "LINEAR_REQUIRE_REACH"
assert_eq "issues create --help issues no API call" "$(api_calls)" "0"
