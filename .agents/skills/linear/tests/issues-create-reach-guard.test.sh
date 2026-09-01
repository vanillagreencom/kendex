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

echo "=== guard on: a value naming the thread it came from, or a shape, is refused ==="

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the Copilot thread on the pull request\n')"
assert_refused_before_api "a reach naming a review thread"
assert_contains "the refusal quotes the offending value" "$ERR" "Copilot"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the reviewer thread on this pull request\n')"
assert_refused_before_api "a reach naming a reviewer thread"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the codex review of the second push\n')"
assert_refused_before_api "a reach naming a codex review"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the pull request comment on the second push\n')"
assert_refused_before_api "a reach naming a pull request comment"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: a pull-request thread\n')"
assert_refused_before_api "a reach naming a pull-request thread"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: the PR review suggestion\n')"
assert_refused_before_api "a reach naming a PR review suggestion"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: a name containing a quote\n')"
assert_refused_before_api "a reach naming only a shape"
assert_contains "the shape refusal comes from the value branch" "$ERR" "names no producer"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: an empty state directory\n')"
assert_refused_before_api "a reach naming an input form"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: a title starting with a dash\n')"
assert_refused_before_api "a reach naming an input form by its leading character"

run_linear issues create --title "From review" \
  --description "$(printf 'Reached by: a hypothetical second writer\n')"
assert_refused_before_api "a reach that is a hypothesis"

echo "=== guard on: a product noun in an honest reach still creates ==="

# The refusal list is matched against the value, and this project ships a
# `codex` harness id, a `reviewer` skill and reviewer-* agents. A bare product
# noun in the list refuses these four true reaches, and the guard has no
# escape flag to recover them.
run_linear issues create --title "Second opinion" \
  --description "$(printf 'Reached by: running `codex exec` via the second-opinion skill\n')"
assert_created "a reach naming the codex harness as its producer"

run_linear issues create --title "Guard run" \
  --description "$(printf 'Reached by: a reviewer running `tools/guard`\n')"
assert_created "a reach naming a reviewer as its producer"

run_linear issues create --title "Shortcut rebind" \
  --description "$(printf 'Reached by: a user whose shortcut key could not be rebound\n')"
assert_created "a reach reporting what a user could not do"

run_linear issues create --title "Harness install" \
  --description "$(printf 'Reached by: kendex install --harness codex on a fresh project\n')"
assert_created "a reach naming a harness install command"

# A shape word is not a verdict on the value: both of these name the user
# action or the shipped producer the rule asks for, and go on past the form to
# say where it comes from.
run_linear issues create --title "Spaces in a filename" \
  --description "$(printf 'Reached by: a user entering a filename containing spaces\n')"
assert_created "a reach whose user action ends in an input form"

run_linear issues create --title "Bad cache entry" \
  --description "$(printf 'Reached by: an invalid cache entry emitted by kendex sync\n')"
assert_created "a reach whose input form names the run that emits it"

# The artifact is what the list refuses, never the words around it: a pull
# request a user opens, and the pr-comments workflow, are both producers.
run_linear issues create --title "Contributor PR" \
  --description "$(printf 'Reached by: a user filing a pull request\n')"
assert_created "a reach naming a user filing a pull request"

run_linear issues create --title "Comments audit" \
  --description "$(printf 'Reached by: running the pr-comments audit path\n')"
assert_created "a reach naming the pr-comments workflow as its producer"

# The artifact head noun is what decides, not the words leading up to it: the
# review gate is a shipped check, and naming it is not naming a thread.
run_linear issues create --title "Stale head" \
  --description "$(printf 'Reached by: running the PR review gate on a stale head\n')"
assert_created "a reach naming the PR review gate as its producer"

run_linear issues create --title "Stale head" \
  --description "$(printf 'Reached by: the PR review gate on a stale head\n')"
assert_created "a determiner-led reach whose head noun is a shipped check"

echo "=== guard on: an unsubstituted placeholder and a null token are absent ==="

# The templates this repo ships carry `[REACH]` and `[SYMPTOM]`; copying one
# verbatim is the likeliest real path into the guard.
run_linear issues create --title "Template copied" \
  --description "$(printf '**Reached by**: [REACH]\n')"
assert_refused_before_api "a [REACH] placeholder body"
assert_contains "the placeholder refusal names the missing line" "$ERR" "Reached by"

run_linear issues create --title "Template copied whole-line bold" \
  --description "$(printf '**Reached by: [REACH]**\n')"
assert_refused_before_api "a whole-line bold [REACH] placeholder body"

run_linear issues create --title "Null token" \
  --description "$(printf 'Reached by: TBD\n')"
assert_refused_before_api "a TBD reach"

run_linear issues create --title "Null token" \
  --description "$(printf 'Reached by: n/a\n')"
assert_refused_before_api "an n/a reach"

run_linear issues create --title "Null token" \
  --description "$(printf 'Reached by: -\n')"
assert_refused_before_api "a dash reach"

echo "=== guard on: a reach naming a producer creates ==="

run_linear issues create --title "Refresh skips a worktree" \
  --description "$(printf '%s\n\nThe render is left stale.\n' "$REACH_LINE")"
assert_created "a create whose body names the run that reaches it"

# The line is read through markdown emphasis and through --description-file,
# the form the issue templates prescribe.
printf 'Reached by: `tools/guard` on a fresh clone\n' >"$TMP_ROOT/body.md"
run_linear issues create --title "Guard body" --description-file "$TMP_ROOT/body.md"
assert_created "a create whose reach arrives by --description-file"

# project-management SKILL.md states the rule as a bullet, so a bulleted body
# line is a form this repo's own guidance produces.
run_linear issues create --title "Bulleted body" \
  --description "$(printf -- '- %s\n' "$REACH_LINE")"
assert_created "a create whose reach is a list item"

echo "=== guard on: a review-born priority 2 needs a reported symptom ==="

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_refused_before_api "a review-born priority-2 create with no Symptom line"
assert_contains "the refusal names the missing line" "$ERR" "Symptom"
assert_contains "the refusal routes the item to priority 3" "$ERR" "priority 3"

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\n**Symptom**: [SYMPTOM]\n' "$REACH_LINE")"
assert_refused_before_api "a review-born priority-2 create whose Symptom is a placeholder"

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\nSymptom: none\n' "$REACH_LINE")"
assert_refused_before_api "a review-born priority-2 create whose Symptom is a null token"

run_linear issues create --title "High priority" --priority 2 --review-born \
  --description "$(printf '%s\n%s\n' "$REACH_LINE" "$SYMPTOM_LINE")"
assert_created "a review-born priority-2 create carrying a reported symptom"

# Priority 2 minted structurally — a planner, a roadmap layer, the merge-pr
# rebundle, a research spike — reports no symptom by construction. Refusing it
# would abort a merge on an orphan child.
run_linear issues create --title "Structural priority" --priority 2 \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_created "a structural priority-2 create with no Symptom line"

run_linear issues create --title "Normal priority" --priority 3 --review-born \
  --description "$(printf '%s\n' "$REACH_LINE")"
assert_created "a review-born priority-3 create with no Symptom line"

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
