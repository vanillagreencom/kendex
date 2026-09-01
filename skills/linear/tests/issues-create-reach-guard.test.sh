#!/usr/bin/env bash
# Regression test for the create-time reach guard.
#
# `Declined:` needs a disproof a gate checks; `Tracked: <ID>` needs only an
# issue to exist. Filing is therefore the cheap disposition, and creation is
# the one chokepoint that can hold the filing bar. With LINEAR_REQUIRE_REACH
# set in kendex.settings.toml [env], `issues create` must refuse — before any
# API call — a description with no `Reached by:` line, a reach value naming
# only a review artifact, a hypothesis or a shape, and a `--priority 2` body
# with no reported `Symptom:`. Projects that do not set the key are unaffected.

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
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

OUT=""
ERR=""
RC=0

# The parent environment wins over project files, so both keys the guard reads
# are unset for the run and the settings file below is the only source.
run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

set_guard_on() {
  printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_REQUIRE_REACH = "1"\n' \
    >"$PROJECT/kendex.settings.toml"
}

set_guard_off() {
  printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

assert_created() {
  local label="$1"
  assert_eq "$label exits zero" "$RC" 0
  assert "$label reaches issueCreate" \
    jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG"
}

assert_refused_before_api() {
  local label="$1"
  assert_ne "$label is refused" "$RC" 0
  assert_eq "$label refuses before any API call" "$(api_calls)" "0"
}

REACH_LINE='**Reached by**: running `kendex refresh` in a linked worktree'
SYMPTOM_LINE='**Symptom**: the refresh printed "skipped" and left the render stale'

echo "=== guard on: a body with no Reached by line is refused ==="

set_guard_on

run_linear issues create --title "Filed from a thread"
assert_refused_before_api "a create with no description"
assert_contains "the refusal names the missing line" "$ERR" "Reached by"
assert_contains "the refusal says an unnamed item is a decline" "$ERR" "decline"

run_linear issues create --title "Filed from a thread" \
  --description "The catalog loader mishandles a nested package."
assert_refused_before_api "a description carrying no Reached by line"
assert_contains "the prose-only refusal names the missing line" "$ERR" "Reached by"

echo "=== guard on: a value naming a review artifact, a hypothesis or a shape is refused ==="

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the Copilot thread on the pull request\n')"
assert_refused_before_api "a reach naming a review thread"
assert_contains "the refusal quotes the offending value" "$ERR" "Copilot"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: a name containing a quote\n')"
assert_refused_before_api "a reach naming only a shape"
assert_contains "the shape refusal states the rule" "$ERR" "shape"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: an empty state directory could break the loader\n')"
assert_refused_before_api "a reach that is a hypothesis"

echo "=== guard on: a reach naming a producer creates ==="

run_linear issues create --title "Refresh skips a worktree" \
  --description "$(printf '%s\n\nThe render is left stale.\n' "$REACH_LINE")"
assert_created "a create whose body names the run that reaches it"

# The line is read through markdown emphasis and through --description-file,
# the form the issue templates prescribe.
printf 'Reached by: `tools/guard` on a fresh clone\n' >"$TMP_ROOT/body.md"
run_linear issues create --title "Guard body" --description-file "$TMP_ROOT/body.md"
assert_created "a create whose reach arrives by --description-file"

echo "=== guard on: priority 2 needs a reported symptom ==="

run_linear issues create --title "High priority" --priority 2 \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_refused_before_api "a priority-2 create with no Symptom line"
assert_contains "the refusal names the missing line" "$ERR" "Symptom"
assert_contains "the refusal routes the item to priority 3" "$ERR" "priority 3"

run_linear issues create --title "High priority" --priority 2 \
  --description "$(printf '%s\n%s\n' "$REACH_LINE" "$SYMPTOM_LINE")"
assert_created "a priority-2 create carrying a reported symptom"

run_linear issues create --title "Normal priority" --priority 3 \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_created "a priority-3 create with no Symptom line"

echo "=== no declaration: creates are unaffected ==="

set_guard_off
run_linear issues create --title "Unguarded repo"
assert_created "a bare create with no LINEAR_REQUIRE_REACH key"

printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_REQUIRE_REACH = ""\n' \
  >"$PROJECT/kendex.settings.toml"
run_linear issues create --title "Empty declaration"
assert_created "a bare create with an empty LINEAR_REQUIRE_REACH"

echo "=== help never trips the guard ==="

set_guard_on
run_linear issues create --help
assert_eq "issues create --help exits zero" "$RC" 0
assert_contains "issues create --help documents the reach guard" "$OUT" "LINEAR_REQUIRE_REACH"
assert_eq "issues create --help issues no API call" "$(api_calls)" "0"
