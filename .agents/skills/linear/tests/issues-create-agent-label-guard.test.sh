#!/usr/bin/env bash
# Regression test for VST-147: issues created outside the TPM pipeline land
# with no agent:* label and are invisible to agent routing, while the CLI
# prints a URL that looks like success.
#
# When the project declares its agent-label taxonomy (LINEAR_AGENT_LABELS in
# kendex.settings.toml [env]), a bare `issues create` must refuse before any
# API call, with an actionable error naming the TPM pipeline and the
# --no-agent-label escape hatch. Projects with no declaration are unaffected.

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
  # agent:ghost simulates a label declared in LINEAR_AGENT_LABELS but since
  # deleted in Linear; any name that is not byte-exact (e.g. " agent:rust"
  # with a leading space) also misses, mirroring the API's eq filter.
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  if [ "$name" = "agent:ghost" ] || [ "$name" != "$(printf '%s' "$name" | sed 's/^ *//;s/ *$//')" ]; then
    printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  fi
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

# Run the CLI inside the temp project with LINEAR_TEAM and LINEAR_AGENT_LABELS
# absent from the process environment (parent env wins over project files).
run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

set_settings() {
  # $1: LINEAR_AGENT_LABELS value ("" = key present but empty)
  printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "%s"\n' "$1" \
    >"$PROJECT/kendex.settings.toml"
}

set_settings_no_taxonomy_key() {
  printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

assert_refused_bare() {
  local label="$1"
  assert_ne "$label is refused" "$RC" 0
  assert_contains "$label refusal mentions agent labels" "$ERR" "agent"
  assert_contains "$label refusal names LINEAR_AGENT_LABELS" "$ERR" "LINEAR_AGENT_LABELS"
  assert_contains "$label refusal routes to the TPM pipeline" "$ERR" "project-management"
  assert_contains "$label refusal names the --no-agent-label escape hatch" "$ERR" "--no-agent-label"
  assert_contains "$label refusal lists the declared agent labels" "$ERR" "agent:rust"
  assert_eq "$label refuses before any API call" "$(api_calls)" "0"
}

assert_created() {
  local label="$1"
  assert_eq "$label exits zero" "$RC" 0
  assert "$label reaches issueCreate" \
    jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG"
}

echo "=== declared taxonomy: bare create refuses before any API call ==="

set_settings "agent:generalist, agent:rust"

run_linear issues create --title "Unrouted follow-up"
assert_refused_bare "bare create"

run_linear issues create --title "Unrouted follow-up" --labels "bug,docs"
assert_refused_bare "create with only non-agent labels"

echo "=== declared taxonomy: an unknown agent:* label refuses (typo guard) ==="

# resolve_label_id warns and SKIPS unresolved labels, so a typoed agent label
# would otherwise create an unrouted issue that looks routed.
run_linear issues create --title "Typo" --labels "agent:generalst"
assert_ne "a typoed agent label is refused" "$RC" 0
assert_contains "the typo refusal names the unknown label" "$ERR" "agent:generalst"
assert_contains "the typo refusal names the declared set" "$ERR" "LINEAR_AGENT_LABELS"
assert_eq "a typoed agent label attempts no API call" "$(api_calls)" "0"

echo "=== declared taxonomy: a declared agent label passes ==="

run_linear issues create --title "Routed" --labels "bug,agent:rust"
assert_created "create with declared agent label"
assert "every label resolves onto the create" \
  jq -s -e 'any(.[]; (.query | contains("issueCreate")) and (.variables.input.labelIds | length == 2))' "$CURL_LOG"

run_linear issues create --title "Routed single" --label "agent:generalist"
assert_created "create with --label agent label"

echo "=== declared taxonomy: --no-agent-label permits a deliberate bare create ==="

run_linear issues create --title "Intake mirror" --no-agent-label
assert_created "bare create with --no-agent-label"

run_linear issues create --title "Intake mirror" --no-agent-label --labels "bug"
assert_created "non-agent-labeled create with --no-agent-label"

echo "=== no declaration: bare creates are unaffected ==="

set_settings_no_taxonomy_key
run_linear issues create --title "Bare repo create"
assert_created "bare create with no LINEAR_AGENT_LABELS key"

# Undeclared repos also keep the historical warn-and-skip for EVERY label,
# including an unresolvable agent:* one — the hard-fail applies only under a
# declared taxonomy.
run_linear issues create --title "Undeclared skip" --labels "agent:ghost"
assert_created "unresolvable agent label warn-skips when no taxonomy is declared"

set_settings ""
run_linear issues create --title "Empty declaration create"
assert_created "bare create with empty LINEAR_AGENT_LABELS"

echo "=== declared taxonomy: comma-space labels normalize for guard AND resolver ==="

# Natural input "bug, agent:rust": the guard must accept it AND the resolver
# must receive the TRIMMED names — an untrimmed " agent:rust" misses Linear's
# eq filter and is silently skipped, recreating the unrouted-but-looks-routed
# create the guard exists to prevent.
set_settings "agent:generalist, agent:rust"
run_linear issues create --title "Natural input" --labels "bug, agent:rust"
assert_created "create with comma-space labels"
assert "the resolver receives the trimmed agent label" \
  jq -s -e 'any(.[]; .variables.name == "agent:rust")' "$CURL_LOG"
assert_not "the resolver never receives an untrimmed label name" \
  jq -s -e 'any(.[]; .variables.name == " agent:rust")' "$CURL_LOG"
assert "both normalized labels resolve onto the create" \
  jq -s -e 'any(.[]; (.query | contains("issueCreate")) and (.variables.input.labelIds | length == 2))' "$CURL_LOG"

echo "=== declared taxonomy: a declared label missing in Linear hard-fails the create ==="

# The guard's promise is routed-or-refused: a label that passes the declared
# set but fails to resolve (declared in settings, deleted in Linear) must fail
# the create, never warn-and-skip into an unrouted issue.
set_settings "agent:generalist, agent:rust, agent:ghost"
run_linear issues create --title "Stale declared label" --labels "agent:ghost"
assert_ne "a declared label missing in Linear fails the create" "$RC" 0
assert_contains "the hard-fail names the unresolvable label" "$ERR" "agent:ghost"
assert_not "issueCreate is never reached with an unresolvable agent label" \
  jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG"

echo "=== help never trips the guard ==="

set_settings "agent:generalist, agent:rust"
run_linear issues create --help
assert_eq "issues create --help exits zero" "$RC" 0
assert_contains "issues create --help documents --no-agent-label" "$OUT" "--no-agent-label"
assert_eq "issues create --help issues no API call" "$(api_calls)" "0"

